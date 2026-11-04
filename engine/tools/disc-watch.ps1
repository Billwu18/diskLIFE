#requires -Version 5.1
<#
    DiscPersona · 光驱守望者 (disc-watch.ps1)

    插盘即唤醒：常驻在托盘后面的一个小脚本，监听「新卷出现」事件，
    一旦发现插进来的盘根上有 pad.bin + persona\persona.yml，就替用户双击 start.cmd。

    用法：
      # 前台试跑（看日志，Ctrl+C 退出）
      powershell -NoProfile -ExecutionPolicy Bypass -File disc-watch.ps1

      # 只做一次检测（拿这张盘/这个目录试一下判断逻辑，不启动实例）
      powershell -File disc-watch.ps1 -TestDriveRoot "E:\disc-build\aris" -DryRun

      # 装成登录自启（在 %APPDATA%\...\Startup 放一个快捷方式，无窗口）
      powershell -File disc-watch.ps1 -Install

      # 卸载自启
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
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DiscPersona 光驱守望者.lnk'
$script:LastDrive = ''
$script:LastTick  = [datetime]::MinValue

function Write-WatchLog {
    param([string]$Message, [string]$Level = '信息')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        $dir = Split-Path -Parent $script:LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

# 判断一个盘根是不是 DiscPersona 光盘
function Test-DiscPersonaRoot {
    param([string]$Root)
    if (-not $Root) { return $false }
    $root2 = $Root.TrimEnd('\')
    $pad = Join-Path $root2 'pad.bin'
    $per = Join-Path $root2 'persona\persona.yml'
    return ((Test-Path -LiteralPath $pad -PathType Leaf) -and (Test-Path -LiteralPath $per -PathType Leaf))
}

# 找到这张盘的启动入口：优先 start.cmd（和用户双击同一路径），否则 engine\launch.ps1
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
        Write-WatchLog ("不是 DiscPersona 光盘，忽略：{0}" -f $Root) '忽略'
        return
    }

    $now = Get-Date
    if ($script:LastDrive -eq $Root -and ($now - $script:LastTick).TotalSeconds -lt 15) {
        Write-WatchLog ("同一张盘 15 秒内重复触发，跳过：{0}" -f $Root) '去重'
        return
    }

    $launcher = Get-DiscLauncher -Root $Root
    if (-not $launcher) {
        Write-WatchLog ("盘上没有 start.cmd 也没有 engine\launch.ps1：{0}" -f $Root) '错误'
        return
    }

    $root2 = $Root.TrimEnd('\')
    Write-WatchLog ("发现光盘，开始唤醒：{0}（入口 {1}）" -f $root2, $launcher.Kind) '唤醒'

    if ($DryRun) {
        $script:LastDrive = $Root
        $script:LastTick  = $now
        Write-WatchLog '（-DryRun：只检测，不启动）' '演练'
        return
    }

    try {
        if ($launcher.Kind -eq 'cmd') {
            # 用 cmd 起，工作目录设成盘根；-NoBrowser 透传不了，所以这里按需直接调 launch.ps1
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
        Write-WatchLog '已把启动器拉起来（它会在控制台里报告结果）。' '成功'
        $script:LastDrive = $Root
        $script:LastTick  = Get-Date
    } catch {
        Write-WatchLog ("拉起失败：{0}" -f $_.Exception.Message) '错误'
        # 故意不写去重状态：拉起失败后 15 秒内再插一次，仍然可以重试
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
    $lnk.Description = '插入 DiscPersona 光盘时自动唤醒'
    $lnk.Save()
    Write-WatchLog ("已装成登录自启：{0}" -f $script:StartupLnk) '安装'
    Write-WatchLog '下次登录后生效；想立刻生效，就现在手动跑一次 disc-watch.ps1。' '安装'
    Write-Host ''
    Write-Host '提示：守望者只在「插入光盘/新卷挂载」时动作；如果你插的是已识别过的盘' -ForegroundColor DarkGray
    Write-Host '      而 Windows 没发事件，双击 start.cmd 仍然是最可靠的方式。' -ForegroundColor DarkGray
}

function Uninstall-Watcher {
    if (Test-Path -LiteralPath $script:StartupLnk) {
        Remove-Item -LiteralPath $script:StartupLnk -Force
        Write-WatchLog '已移除登录自启。' '卸载'
    } else {
        Write-WatchLog '没有找到自启快捷方式，可能本来就没装。' '卸载'
    }
}

function Start-Watching {
    Write-WatchLog '光驱守望者已启动，等待插盘……（Ctrl+C 退出）' '就绪'
    Write-WatchLog ("日志：{0}" -f $script:LogFile) '就绪'

    # 先扫一遍已经挂着的盘，避免「脚本启动前盘就插着」这种情况
    foreach ($d in ([System.IO.DriveInfo]::GetDrives())) {
        try {
            if ($d.DriveType -eq [System.IO.DriveType]::CDRom -and $d.IsReady) {
                Invoke-DiscBoot -Root ($d.Name.TrimEnd('\'))
            }
        } catch { }
    }

    # Win32_VolumeChangeEvent：EventType 2 = 挂载/插入，3 = 卸载
    $query = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2 OR EventType = 3"
    $watcher = $null
    $failCount = 0

    while ($true) {
        if (-not $watcher) {
            try {
                $watcher = New-Object System.Management.ManagementEventWatcher($query)
                $watcher.Options.Timeout = [TimeSpan]::FromSeconds(30)
                if ($failCount -gt 0) { Write-WatchLog '监听已重建，继续等插盘。' '就绪' }
                $failCount = 0
            } catch {
                $failCount++
                Write-WatchLog ("监听器创建失败（第 {0} 次，10 秒后重试）：{1}" -f $failCount, $_.Exception.Message) '错误'
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
                # 拔出：清掉去重状态，这样「拔了再插」能立刻再触发一次
                if ($drive) {
                    $gone = $drive.TrimEnd("\")
                    Write-WatchLog ("卷已卸载：{0}" -f $gone) '事件'
                    if ($script:LastDrive -eq $gone) { $script:LastDrive = $null }
                }
                continue
            }

            Write-WatchLog ("新卷出现：{0}" -f $drive) '事件'
            if ($drive) {
                $root = $drive.TrimEnd("\")
                # 给 Windows 一点时间让卷真正可读
                for ($i = 0; $i -lt 10; $i++) {
                    if (Test-Path -LiteralPath $root) { break }
                    Start-Sleep -Milliseconds 400
                }
                Invoke-DiscBoot -Root $root
            }
        } catch [System.Management.ManagementException] {
            $msg = [string]$_.Exception.Message
            # 30 秒没有事件就会抛超时，这是正常的等待，不是故障
            if ($msg -match 'timed out|Timed out|超时|timeout') { continue }
            Write-WatchLog ("监听中断（3 秒后重建）：{0}" -f $msg) '警告'
            try { $watcher.Stop() } catch { }
            $watcher = $null
            Start-Sleep -Seconds 3
        } catch {
            Write-WatchLog ("监听出错（3 秒后重建）：{0}" -f $_.Exception.Message) '警告'
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
