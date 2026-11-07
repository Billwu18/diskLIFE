#requires -Version 5.1
<#
    DiscPersona · disc watcher (disc-watch.ps1)

    Wake on insertion: a small background script that listens for "new volume" events.
    When the disc root carries pad.bin + persona\persona.yml, it double-clicks start.cmd for you.

    Usage:
      # run in the foreground (see the log, Ctrl+C to quit)
      powershell -NoProfile -ExecutionPolicy Bypass -File disc-watch.ps1

      # single check (try the detection on this disc/directory, start nothing)
      powershell -File disc-watch.ps1 -TestDriveRoot "E:\disc-build\aris" -DryRun

      # install as a logon autostart (a hidden shortcut in %APPDATA%\...\Startup)
      powershell -File disc-watch.ps1 -Install

      # remove the autostart
      powershell -File disc-watch.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$DryRun,
    [string]$TestDriveRoot,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:StateDir  = Join-Path $env:LOCALAPPDATA 'DiscPersona'
$script:ScriptDst = Join-Path $script:StateDir 'disc-watch.ps1'
$script:LogFile   = if ($LogPath) { $LogPath } else { Join-Path $script:StateDir 'disc-watch.log' }
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DiscPersona disc watcher.lnk'
$script:LastDrive = ''
$script:LastTick  = [datetime]::MinValue

function Write-WatchLog {
    param([string]$Message, [string]$Level = 'info')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        $dir = Split-Path -Parent $script:LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

# Is this root a DiscPersona disc?
function Test-DiscPersonaRoot {
    param([string]$Root)
    if (-not $Root) { return $false }
    $root2 = $Root.TrimEnd('\')
    $pad = Join-Path $root2 'pad.bin'
    $per = Join-Path $root2 'persona\persona.yml'
    $sealed = Join-Path $root2 'persona\persona.sealed'
    return ((Test-Path -LiteralPath $pad -PathType Leaf) -and
        ((Test-Path -LiteralPath $per -PathType Leaf) -or (Test-Path -LiteralPath $sealed -PathType Leaf)))
}

# Entry point: prefer start.cmd (the same path the user would double-click), else engine\launch.ps1
function Get-DiscLauncher {
    param([string]$Root)
    $root2 = $Root.TrimEnd('\')
    $cmd = Join-Path $root2 'start.cmd'
    if (Test-Path -LiteralPath $cmd -PathType Leaf) { return @{ Kind = 'cmd'; Path = $cmd } }
    $ps1 = Join-Path $root2 'engine\launch.ps1'
    if (Test-Path -LiteralPath $ps1 -PathType Leaf) { return @{ Kind = 'ps1'; Path = $ps1 } }
    return $null
}

function Invoke-DiscBoot {
    param([string]$Root, [switch]$NoBrowser)

    if (-not (Test-DiscPersonaRoot -Root $Root)) {
        Write-WatchLog ("Not a DiscPersona disc, ignoring: {0}" -f $Root) 'skip'
        return
    }

    $now = Get-Date
    if ($script:LastDrive -eq $Root -and ($now - $script:LastTick).TotalSeconds -lt 15) {
        Write-WatchLog ("Same disc fired twice within 15s, skipping: {0}" -f $Root) 'dup'
        return
    }

    $launcher = Get-DiscLauncher -Root $Root
    if (-not $launcher) {
        Write-WatchLog ("No start.cmd and no engine\launch.ps1 on the disc: {0}" -f $Root) 'error'
        return
    }

    $root2 = $Root.TrimEnd('\')
    Write-WatchLog ("Disc inserted, waking up: {0} (entry: {1})" -f $root2, $launcher.Kind) 'wake'

    if ($DryRun) {
        $script:LastDrive = $Root
        $script:LastTick  = $now
        Write-WatchLog '(-DryRun: detection only, nothing is started)' 'dry-run'
        return
    }

    try {
        if ($launcher.Kind -eq 'cmd') {
            # start through cmd with the disc root as the working directory; -NoBrowser cannot be
            # forwarded through start.cmd, so call launch.ps1 directly when it is needed
            if ($NoBrowser) {
                $ps1 = Join-Path $root2 'engine\launch.ps1'
                $argList = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ps1), '-DiscRoot', ('"{0}"' -f $root2), '-NoBrowser', '-NoWait')
                Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $root2 -WindowStyle Minimized | Out-Null
            } else {
                Start-Process -FilePath $launcher.Path -ArgumentList '-NoWait' -WorkingDirectory $root2 -WindowStyle Minimized | Out-Null
            }
        } else {
            $argList = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $launcher.Path), '-DiscRoot', ('"{0}"' -f $root2), '-NoWait')
            if ($NoBrowser) { $argList += '-NoBrowser' }
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $root2 -WindowStyle Minimized | Out-Null
        }
        Write-WatchLog 'Launcher started (it reports the result in its own console).' 'ok'
        $script:LastDrive = $Root
        $script:LastTick  = Get-Date
    } catch {
        Write-WatchLog ("Failed to start the launcher: {0}" -f $_.Exception.Message) 'error'
        # The dedup state is written only after a successful start, so a failed attempt can be retried
    }
}

function Install-Watcher {
    if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
    Copy-Item -LiteralPath $PSCommandPath -Destination $script:ScriptDst -Force -ErrorAction Stop
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:ScriptDst
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($script:StartupLnk)
    $lnk.TargetPath = $ps
    $lnk.Arguments = $args
    $lnk.WorkingDirectory = $script:StateDir
    $lnk.WindowStyle = 7
    $lnk.Description = 'Wake the persona when a DiscPersona disc is inserted'
    $lnk.Save()
    Write-WatchLog ("Installed as a logon autostart: {0}" -f $script:StartupLnk) 'install'
    Write-WatchLog 'Takes effect after the next sign-in; run disc-watch.ps1 once now if you want it immediately.' 'install'
    Write-Host ''
    Write-Host 'Note: the watcher only reacts to a disc insertion / new volume. If Windows already knows the disc' -ForegroundColor DarkGray
    Write-Host '      and sends no event, double-clicking start.cmd is still the most reliable route.' -ForegroundColor DarkGray
}

function Uninstall-Watcher {
    if (Test-Path -LiteralPath $script:StartupLnk) {
        Remove-Item -LiteralPath $script:StartupLnk -Force
        Write-WatchLog 'Removed the logon autostart.' 'uninstall'
    } else {
        Write-WatchLog 'No autostart shortcut found — it may never have been installed.' 'uninstall'
    }
}

function Start-Watching {
    Write-WatchLog 'Disc watcher started, waiting for a disc… (Ctrl+C to quit)' 'ready'
    Write-WatchLog ("Log: {0}" -f $script:LogFile) 'ready'

    # Scan already-mounted drives first, so a disc inserted before the script started still counts
    foreach ($d in ([System.IO.DriveInfo]::GetDrives())) {
        try {
            if ($d.DriveType -eq [System.IO.DriveType]::CDRom -and $d.IsReady) {
                Invoke-DiscBoot -Root ($d.Name.TrimEnd('\'))
            }
        } catch { }
    }

    # Win32_VolumeChangeEvent: EventType 2 = mounted/inserted, 3 = removed
    $query = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2 OR EventType = 3"
    $watcher = $null
    $failCount = 0

    while ($true) {
        if (-not $watcher) {
            try {
                $watcher = New-Object System.Management.ManagementEventWatcher($query)
                $watcher.Options.Timeout = [TimeSpan]::FromSeconds(30)
                if ($failCount -gt 0) { Write-WatchLog 'Listener rebuilt, still waiting for a disc.' 'ready' }
                $failCount = 0
            } catch {
                $failCount++
                Write-WatchLog ("Could not create the listener (attempt {0}, retrying in 10s): {1}" -f $failCount, $_.Exception.Message) 'error'
                $watcher = $null
                Start-Sleep -Seconds 10
                continue
            }
        }

        try {
            $evt = $watcher.WaitForNextEvent()
            $drive = $evt.DriveName
            $evtType = 0
            try { $evtType = [int]$evt.EventType } catch { }

            if ($evtType -eq 3) {
                # On removal, clear the dedup state so re-inserting fires again right away
                if ($drive) {
                    $gone = $drive.TrimEnd("\")
                    Write-WatchLog ("Volume removed: {0}" -f $gone) 'event'
                    if ($script:LastDrive -eq $gone) { $script:LastDrive = $null }
                }
                continue
            }

            Write-WatchLog ("New volume: {0}" -f $drive) 'event'
            if ($drive) {
                $root = $drive.TrimEnd("\")
                # Give Windows a moment to make the volume readable
                for ($i = 0; $i -lt 10; $i++) {
                    if (Test-Path -LiteralPath $root) { break }
                    Start-Sleep -Milliseconds 400
                }
                Invoke-DiscBoot -Root $root
            }
        } catch [System.Management.ManagementException] {
            $msg = [string]$_.Exception.Message
            # A 30-second timeout is the normal idle wait, not a failure
            if ($msg -match 'timed out|Timed out|timeout') { continue }
            Write-WatchLog ("Listener interrupted (rebuilding in 3s): {0}" -f $msg) 'warn'
            try { $watcher.Stop() } catch { }
            $watcher = $null
            Start-Sleep -Seconds 3
        } catch {
            Write-WatchLog ("Listener error (rebuilding in 3s): {0}" -f $_.Exception.Message) 'warn'
            try { $watcher.Stop() } catch { }
            $watcher = $null
            Start-Sleep -Seconds 3
        }
    }
}

# ---------------------------------------------------------------------------
if ($Install)   { Install-Watcher;   return }
if ($Uninstall) { Uninstall-Watcher; return }
if ($TestDriveRoot) { Invoke-DiscBoot -Root $TestDriveRoot; return }
Start-Watching
