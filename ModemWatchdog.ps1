<#
.SYNOPSIS
    Pings a device on the LAN and reboots the Bell modem when it stops responding.

.DESCRIPTION
    Every few seconds the script pings the target IP. After several failed pings in a row
    it logs diagnostic details (is the modem reachable? is the device in the ARP table?
    what does the modem's device list say about it?) and then reboots the Bell Home Hub /
    Giga Hub through its web API. After a reboot it waits before checking again.

    The modem password is never stored in this script. On first run you are asked for it
    and it is saved encrypted for your Windows user (DPAPI) in %APPDATA%\ModemWatchdog.

.EXAMPLE
    .\ModemWatchdog.ps1
    Start watching with the default settings.

.EXAMPLE
    .\ModemWatchdog.ps1 -TestLogin
    Log in to the modem and show what it knows about the device, without rebooting.

.EXAMPLE
    .\ModemWatchdog.ps1 -SetPassword
    Change the saved modem password.
#>
[CmdletBinding()]
param(
    [string]$TargetIp = '192.168.2.95',
    [string]$ModemIp = '192.168.2.1',
    [string]$ModemUser = 'admin',
    [int]$IntervalSeconds = 15,
    [int]$FailuresBeforeReboot = 4,
    [int]$PingTimeoutMs = 2000,
    [int]$CooldownMinutes = 6,
    [string]$LogFile = (Join-Path $PSScriptRoot 'ModemWatchdog.log'),
    [switch]$SetPassword,
    [switch]$TestLogin,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$CredFile = Join-Path $env:APPDATA 'ModemWatchdog\modem.cred'
$ApiPath = '/cgi/json-req'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    Add-Content -Path $LogFile -Value $line
}

# --- Password storage (DPAPI, only readable by this Windows user on this PC) ---

function Save-ModemPassword {
    $secure = Read-Host "Bell modem admin password" -AsSecureString
    New-Item -ItemType Directory -Force -Path (Split-Path $CredFile) | Out-Null
    $secure | ConvertFrom-SecureString | Set-Content -Path $CredFile
    Write-Host "Password saved to $CredFile"
}

function Get-ModemPassword {
    if (-not (Test-Path $CredFile)) { Save-ModemPassword }
    $secure = Get-Content $CredFile | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# --- Network checks ---

function Test-Ping {
    param([string]$Ip, [int]$TimeoutMs = $PingTimeoutMs)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try { ($ping.Send($Ip, $TimeoutMs)).Status -eq 'Success' }
    catch { $false }
    finally { $ping.Dispose() }
}

function Get-ArpEntry {
    param([string]$Ip)
    try {
        $line = arp -a 2>$null | Select-String -Pattern ('^\s*{0}\s' -f [regex]::Escape($Ip)) | Select-Object -First 1
        if ($line) { ($line.Line.Trim() -split '\s+')[1] } else { 'none' }
    }
    catch { 'unknown' }
}

# --- Bell Home Hub / Giga Hub (Sagemcom) web API ---

function Get-Hash {
    param([string]$Text, [string]$Algorithm)
    $hasher = if ($Algorithm -eq 'MD5') { [Security.Cryptography.MD5]::Create() } else { [Security.Cryptography.SHA512]::Create() }
    $bytes = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function New-ModemSession {
    param([string]$User, [string]$Password, [string]$Algorithm)
    @{
        User         = $User
        PasswordHash = Get-Hash $Password $Algorithm
        Algorithm    = $Algorithm
        SessionId    = 0
        ServerNonce  = ''
        RequestId    = -1
    }
}

function Invoke-ModemApi {
    param([hashtable]$Session, [object[]]$Actions, [bool]$Priority = $false)

    $Session.RequestId++
    $cnonce = Get-Random -Minimum 0 -Maximum 4294967295
    $credHash = Get-Hash ('{0}:{1}:{2}' -f $Session.User, $Session.ServerNonce, $Session.PasswordHash) $Session.Algorithm
    $authKey = Get-Hash ('{0}:{1}:{2}:JSON:{3}' -f $credHash, $Session.RequestId, $cnonce, $ApiPath) $Session.Algorithm

    $payload = [ordered]@{
        request = [ordered]@{
            id           = $Session.RequestId
            'session-id' = [int64]$Session.SessionId
            priority     = $Priority
            actions      = $Actions
            cnonce       = $cnonce
            'auth-key'   = $authKey
        }
    }
    $json = ConvertTo-Json $payload -Depth 20 -Compress
    $body = 'req=' + [uri]::EscapeDataString($json)

    $resp = Invoke-WebRequest -Uri "http://$ModemIp$ApiPath" -Method Post -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 20
    $content = $resp.Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    $reply = ($content | ConvertFrom-Json).reply

    $err = $reply.error
    if ($err -and $err.description -and $err.description -ne 'XMO_REQUEST_NO_ERR') {
        $detail = ($reply.actions | ForEach-Object { $_.error.description }) -join ', '
        throw "Modem API error: $($err.description) $detail"
    }
    $reply
}

function Connect-Modem {
    param([string]$Password)
    $loginAction = [ordered]@{
        id         = 0
        method     = 'logIn'
        parameters = [ordered]@{
            user              = $ModemUser
            persistent        = $true
            'session-options' = [ordered]@{
                nss                           = @([ordered]@{ name = 'gtw'; uri = 'http://sagemcom.com/gateway-data' })
                language                      = 'ident'
                'context-flags'               = [ordered]@{ 'get-content-name' = $true; 'local-time' = $true }
                'capability-depth'            = 2
                'capability-flags'            = [ordered]@{ name = $true; 'default-value' = $false; restriction = $true; description = $false }
                'time-format'                 = 'ISO_8601'
                'write-only-string'           = '_XMO_WRITE_ONLY_'
                'undefined-write-only-string' = '_XMO_UNDEFINED_WRITE_ONLY_'
            }
        }
    }

    # Bell hubs use SHA512; some older Sagemcom firmware uses MD5.
    $lastError = $null
    foreach ($algorithm in 'SHA512', 'MD5') {
        $session = New-ModemSession -User $ModemUser -Password $Password -Algorithm $algorithm
        try {
            $reply = Invoke-ModemApi -Session $session -Actions @($loginAction) -Priority $true
            $params = $reply.actions[0].callbacks[0].parameters
            $session.SessionId = $params.id
            $session.ServerNonce = [string]$params.nonce
            return $session
        }
        catch { $lastError = $_ }
    }
    throw "Could not log in to the modem: $lastError"
}

function Get-ModemHostInfo {
    param([hashtable]$Session, [string]$Ip)
    $action = [ordered]@{ id = 0; method = 'getValue'; xpath = 'Device/Hosts/Hosts' }
    $reply = Invoke-ModemApi -Session $Session -Actions @($action)
    $hosts = $reply.actions[0].callbacks[0].parameters.value
    $hosts | Where-Object { $_.IPAddress -eq $Ip } | Select-Object -First 1
}

function Restart-Modem {
    param([hashtable]$Session)
    $action = [ordered]@{ id = 0; method = 'reboot'; xpath = 'Device'; parameters = @{ source = 'GUI' } }
    Invoke-ModemApi -Session $Session -Actions @($action) | Out-Null
}

function Format-HostInfo {
    param($HostInfo)
    if (-not $HostInfo) { return 'device NOT in modem host list' }
    'name={0} mac={1} active={2} interface={3} {4} addressSource={5} leaseRemaining={6}s' -f `
        $HostInfo.HostName, $HostInfo.PhysAddress, $HostInfo.Active, $HostInfo.InterfaceType,
        $HostInfo.LayerTwoInterface, $HostInfo.AddressSource, $HostInfo.LeaseTimeRemaining
}

# --- Main ---

if ($SetPassword) { Save-ModemPassword; return }

$password = Get-ModemPassword

if ($TestLogin) {
    Write-Log "Testing login to modem $ModemIp ..."
    $session = Connect-Modem -Password $password
    Write-Log "Login OK ($($session.Algorithm))." 'OK'
    Write-Log "Modem info for ${TargetIp}: $(Format-HostInfo (Get-ModemHostInfo -Session $session -Ip $TargetIp))"
    Write-Log "Ping ${TargetIp}: $(Test-Ping $TargetIp)  ARP MAC: $(Get-ArpEntry $TargetIp)"
    return
}

Write-Log "Watching $TargetIp every ${IntervalSeconds}s; reboot modem $ModemIp after $FailuresBeforeReboot failed pings in a row.$(if ($DryRun) { ' (dry run: no reboot)' })"
$failures = 0
$downSince = $null

while ($true) {
    if (Test-Ping $TargetIp) {
        if ($failures -gt 0) {
            Write-Log "$TargetIp responding again after $failures failed ping(s)." 'OK'
        }
        $failures = 0
        $downSince = $null
    }
    else {
        $failures++
        if (-not $downSince) { $downSince = Get-Date }
        Write-Log "$TargetIp did not respond ($failures/$FailuresBeforeReboot)." 'WARN'

        if ($failures -ge $FailuresBeforeReboot) {
            # Collect clues about *why* before rebooting; this is what the log is for.
            $modemUp = Test-Ping $ModemIp
            Write-Log "DIAG: down since $($downSince.ToString('HH:mm:ss')); modem ping=$modemUp; ARP MAC for ${TargetIp}=$(Get-ArpEntry $TargetIp)"

            try {
                $session = Connect-Modem -Password $password
                Write-Log "DIAG: modem says: $(Format-HostInfo (Get-ModemHostInfo -Session $session -Ip $TargetIp))"
            }
            catch {
                Write-Log "Modem login failed: $($_.Exception.Message)" 'ERROR'
                $session = $null
            }

            if ($DryRun) {
                Write-Log 'Dry run: skipping modem reboot.' 'WARN'
            }
            elseif ($session) {
                try {
                    Write-Log "Rebooting modem $ModemIp ..." 'WARN'
                    Restart-Modem -Session $session
                    Write-Log "Reboot command sent. Waiting $CooldownMinutes minutes." 'WARN'
                }
                catch {
                    # The modem often drops the connection while rebooting; that still counts.
                    Write-Log "Reboot request returned: $($_.Exception.Message)" 'WARN'
                }
                Start-Sleep -Seconds ($CooldownMinutes * 60)
            }
            $failures = 0
            $downSince = $null
        }
    }
    Start-Sleep -Seconds $IntervalSeconds
}
