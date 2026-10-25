<#
.SYNOPSIS
    Read-only checks on why a device stops answering ping. Changes nothing.

.DESCRIPTION
    Run it while the device is NOT responding. It checks ping, ARP, common TCP ports and
    what the Bell modem reports, then saves everything to Diagnose-<time>.txt next to the
    script. Paste that file's contents back for analysis.
#>
[CmdletBinding()]
param(
    [string]$TargetIp = '192.168.2.95',
    [string]$ModemIp = '192.168.2.1',
    [int[]]$Ports = @(3389, 445, 135, 139, 80, 443, 22, 5985)
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$report = Join-Path $scriptDir ('Diagnose-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Out-Report {
    param([string]$Text)
    Write-Host $Text
    Add-Content -Path $report -Value $Text
}

function Test-Ping {
    param([string]$Ip)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try { $r = $ping.Send($Ip, 2000); '{0} ({1} ms)' -f $r.Status, $r.RoundtripTime }
    catch { "Error: $($_.Exception.Message)" }
    finally { $ping.Dispose() }
}

function Test-Port {
    param([string]$Ip, [int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Ip, $Port)
        if ($task.Wait(2000) -and $client.Connected) { 'OPEN' } else { 'no answer' }
    }
    catch { 'refused/closed' }
    finally { $client.Dispose() }
}

Out-Report "=== Device diagnosis $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Out-Report "Target: $TargetIp   Modem: $ModemIp   This PC: $env:COMPUTERNAME"
Out-Report ''

Out-Report '--- This PC network connection ---'
try {
    Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | ForEach-Object {
        Out-Report ('{0} ({1}) IP={2} gateway={3}' -f $_.InterfaceAlias, $_.NetAdapter.MediaType,
            ($_.IPv4Address.IPAddress -join ','), ($_.IPv4DefaultGateway.NextHop -join ','))
    }
}
catch { Out-Report "Could not read: $($_.Exception.Message)" }
Out-Report ''

Out-Report '--- Ping ---'
Out-Report "Modem  $ModemIp : $(Test-Ping $ModemIp)"
Out-Report "Target $TargetIp : $(Test-Ping $TargetIp)"
Out-Report "Internet 8.8.8.8 : $(Test-Ping '8.8.8.8')"
Out-Report ''

Out-Report '--- ARP (fresh lookup) ---'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Out-Report 'NOTE: not run as administrator, so the old ARP entry could not be cleared; result may be stale.' }
arp -d $TargetIp 2>&1 | Out-Null
Test-Ping $TargetIp | Out-Null
Start-Sleep -Seconds 1
$arp = arp -a | Select-String -Pattern ('^\s*{0}\s' -f [regex]::Escape($TargetIp))
if ($arp) { Out-Report "ARP entry came back: $($arp.Line.Trim())  -> device answers on the network (layer 2)" }
else { Out-Report 'ARP entry did NOT come back -> device is not answering on the network at all' }
Out-Report ''

Out-Report '--- TCP ports on target ---'
foreach ($port in $Ports) {
    Out-Report ('Port {0,-5}: {1}' -f $port, (Test-Port $TargetIp $port))
}
Out-Report ''

Out-Report '--- What the modem reports ---'
$watchdog = Join-Path $scriptDir 'ModemWatchdog.ps1'
if (Test-Path $watchdog) {
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdog -TestLogin `
            -TargetIp $TargetIp -ModemIp $ModemIp -LogFile (Join-Path $scriptDir 'ModemWatchdog.log') 2>&1
        $output | ForEach-Object { Out-Report "$_" }
    }
    catch { Out-Report "Modem check failed: $($_.Exception.Message)" }
}
else { Out-Report 'ModemWatchdog.ps1 not found; skipped.' }
Out-Report ''
Out-Report "Report saved to: $report"
