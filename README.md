# Modem Watchdog

A small Windows PowerShell app that keeps pinging a device on your network (by default
`192.168.2.95`). If the device stops answering, it reboots the Bell modem at `192.168.2.1`.
Before each reboot it also writes down clues about **why** the device dropped, so you can
fix the real problem and stop needing reboots.

It works with Bell's Sagemcom-based hubs: Home Hub 3000, Home Hub 4000 and Giga Hub.

## Setup

1. Put `ModemWatchdog.ps1` and `Start-ModemWatchdog.bat` in the same folder, for example `C:\ModemWatchdog`.
2. Double-click **`Start-ModemWatchdog.bat`**.
3. The first time, it asks for the modem's admin password. This is the password you use at
   http://192.168.2.1, often printed on the sticker on the modem. The password is saved
   encrypted for your Windows user only (in `%APPDATA%\ModemWatchdog\modem.cred`). It is
   never written into the script or this repository.

To check that login works **without rebooting**, open a Command Prompt in the folder and run:

```
Start-ModemWatchdog.bat -TestLogin
```

This should print `Login OK`, followed by what the modem knows about `192.168.2.95`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `-TargetIp` | `192.168.2.95` | Device to watch |
| `-ModemIp` | `192.168.2.1` | Bell modem address |
| `-IntervalSeconds` | `15` | Time between pings |
| `-FailuresBeforeReboot` | `4` | Failed pings in a row before rebooting (4 × 15 s ≈ 1 minute) |
| `-CooldownMinutes` | `6` | How long to wait after a reboot before checking again |
| `-DryRun` | off | Log and diagnose only; never reboot |
| `-TestLogin` | off | Test the modem login once and exit |
| `-SetPassword` | off | Change the saved modem password |

Example: `Start-ModemWatchdog.bat -IntervalSeconds 30 -DryRun`

Everything is logged to `ModemWatchdog.log`, next to the script.

## Start it automatically with Windows

Open **Task Scheduler**, then choose **Create Task**:
- **General:** "Run only when user is logged on" (needed because the password is saved for your user).
- **Triggers:** At log on.
- **Actions:** Start a program
  - Program: `powershell.exe`
  - Arguments: `-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "C:\ModemWatchdog\ModemWatchdog.ps1"`
- **Settings:** untick "Stop the task if it runs longer than…".

## Why does .95 stop responding? Finding the real cause

Rebooting the modem fixes it, which means the problem is most likely the modem's network
(Wi-Fi or DHCP), not the device itself. When the device goes down, the watchdog logs a
`DIAG` line like this:

```
DIAG: modem ping=True; ARP MAC for 192.168.2.95=none
DIAG: modem says: name=camera mac=aa:bb:.. active=False interface=802.11 Device/WiFi/SSIDs/SSID[...] addressSource=DHCP leaseRemaining=0s
```

How to read it. Run the watchdog with `-DryRun` for a while first if you want to watch an
outage without rebooting.

| What the log shows | Likely cause | Fix |
|---|---|---|
| `modem ping=False` | The **PC** lost its connection, not the device | Check the PC's own Wi-Fi or cable |
| `interface=802.11…` and `active=False` | The device dropped off **Wi-Fi**. This is very common on Bell hubs: "Wi-Fi Optimization"/band steering pushes devices between 2.4 GHz and 5 GHz, and many smart devices, cameras and printers can't reconnect | In the hub (http://192.168.2.1, Advanced settings, Wi-Fi), **turn off Wi-Fi Optimization** and give 2.4 GHz and 5 GHz **different names**. Connect the device to the 2.4 GHz network only. Set a fixed channel (1, 6 or 11) for 2.4 GHz |
| `device NOT in modem host list`, or a different IP for the same MAC | The **DHCP lease** expired and the device got a new address, or none | In the hub, add a **DHCP reservation** so that MAC always gets `.95`. Or give the device a static IP outside the DHCP range |
| `leaseRemaining` near 0 when it fails | Same DHCP problem | DHCP reservation, or a longer lease time in the hub's DHCP settings |
| `interface=Ethernet` and `active=False` | A cable or switch problem, or the device's network port goes to sleep | Try another cable or port; turn off "green"/energy-saving Ethernet on the device |
| `active=True` but ping fails | The device is up but blocking ping, or it is asleep | Turn off the device's power-saving mode; check its firewall |

Other things worth checking in the hub:
- **Firmware:** make sure the hub is up to date (Bell pushes updates automatically, and some fix Wi-Fi drop bugs).
- **IP conflict:** make sure nothing else is set to a static `192.168.2.95`.
- If failures happen at the **same time every day**, check the log. A fixed schedule
  points to the lease time or to a device sleep/energy schedule.

**Simplest fix for most cases:** turn off Wi-Fi Optimization (separate 2.4 GHz and 5 GHz
networks), put the device on 2.4 GHz, and add a DHCP reservation for `.95`. If it is
possible, an Ethernet cable avoids the problem entirely.
