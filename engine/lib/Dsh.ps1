# DiscPersona 启动引擎 · dsh 进程管理
# 负责：找 dsh、探测端口、拉起进程、等就绪 URL、单实例锁。
# 复用 Common.ps1 里的 Test-DPProcessIdentity / Stop-DPProcessTree / Open-DPUrl。

$script:DPDshReadyRegex = 'http://127\.0\.0\.1:\d+/\?token=[^\s"''<>]+'

function Resolve-DshExecutable {
    <#
      查找 dsh 可执行文件。优先级：
        -DshPath > DISCPERSONA_DSH > PATH 上的 dsh.cmd / dsh.exe / dsh.bat / dsh
      返回全路径；找不到返回 $null。
      注意：npm 全局装的 dsh 是 .cmd shim；PATH 上那个无扩展名的 `dsh` 是 bash 脚本，Windows 起不来。
    #>
    param([string]$Explicit)

    $candidates = New-Object System.Collections.ArrayList
    if ($Explicit) { [void]$candidates.Add($Explicit) }
    if ($env:DISCPERSONA_DSH) { [void]$candidates.Add($env:DISCPERSONA_DSH) }

    foreach ($name in @('dsh.cmd', 'dsh.exe', 'dsh.bat')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { [void]$candidates.Add($cmd.Source) }
    }

    foreach ($dir in ($env:PATH -split ';')) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        foreach ($name in @('dsh.cmd', 'dsh.exe', 'dsh.bat')) {
            $p = Join-Path $dir $name
            if (Test-Path -LiteralPath $p -PathType Leaf) { [void]$candidates.Add($p) }
        }
    }

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $full = Get-DPNormalizedPath -Path $c
        if (-not $full) { continue }
        if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
    }
    return $null
}

function Test-DPPortListening {
    <#
      用 TcpClient 探测本机某端口是否已被监听（不依赖 netstat，避免本地化输出差异）。
    #>
    param([int]$Port)
    if ($Port -le 0 -or $Port -gt 65535) { return $false }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(400, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-DPFreePortHint {
    <#
      返回一个「大概率可用」的端口，仅供日志展示；实际仍以 --port 0 让 dsh 自己分配为准。
    #>
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } catch {
        return 0
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

function Start-DshInstance {
    <#
      以 DSH_HOME = $HomeDir、工作目录 = $WorkingDir 拉起 dsh web。
      stdout/stderr 重定向到文件（PS 5.1 的 Start-Process 不能直接重定向到文件，所以套一层 cmd /d /s /c）。
      返回 @{ Process = <包装进程 cmd.exe>; CommandLine = '...' ; Stdout; Stderr }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DshPath,
        [Parameter(Mandatory = $true)][string]$HomeDir,
        [Parameter(Mandatory = $true)][string]$WorkingDir,
        [int]$Port = 0,
        [string[]]$Patches = @(),
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('--profile web')
    foreach ($patch in @($Patches)) {
        if ([string]::IsNullOrWhiteSpace($patch)) { continue }
        [void]$parts.Add('--patch "' + $patch + '"')
    }
    [void]$parts.Add('--port ' + [string]$Port)
    [void]$parts.Add('--no-open')
    $argString = ($parts -join ' ')

    # cmd 的单行语法：/d /s /c ""<exe>" <args> > "<out>" 2> "<err>""（外层一对引号被 /s 剥掉）
    $cmdLine = '/d /s /c ""' + $DshPath + '" ' + $argString + ' > "' + $StdoutPath + '" 2> "' + $StderrPath + '""'

    $savedHome = $env:DSH_HOME
    try {
        $env:DSH_HOME = $HomeDir
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -WorkingDirectory $WorkingDir -PassThru -WindowStyle Hidden
    } finally {
        if ($null -eq $savedHome) { Remove-Item Env:\DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $savedHome }
    }

    return [pscustomobject]@{
        Process     = $proc
        CommandLine = $cmdLine
        Stdout      = $StdoutPath
        Stderr      = $StderrPath
    }
}

function Read-DPSharedText {
    <#
      读一个正被别的进程写入的文件（cmd 的 > 重定向只给写句柄，普通读会撞共享冲突）。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $len = [int]$fs.Length
        if ($len -le 0) { return '' }
        $buf = New-Object byte[] $len
        [void]$fs.Read($buf, 0, $len)
        return ([System.Text.Encoding]::UTF8.GetString($buf))
    } catch {
        return ''
    } finally {
        if ($fs) { try { $fs.Dispose() } catch { } }
    }
}

function Wait-DshUrl {
    <#
      轮询 stdout 日志里的就绪行，返回 URL；进程提前退出或超时返回 $null。
      同时把进程是否已退出告诉调用方（Exited / ExitCode）。
    #>
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [int]$TimeoutSec = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $url = $null
    $exited = $false
    $exitCode = $null

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Instance.Stdout) {
            $text = Read-DPSharedText -Path $Instance.Stdout
            $m = [regex]::Match($text, $script:DPDshReadyRegex)
            if ($m.Success) { $url = $m.Value; break }
        }
        $proc = $Instance.Process
        if ($proc -and $proc.HasExited) {
            $exited = $true
            try { $exitCode = $proc.ExitCode } catch { }
            # 再读一次，避免「刚打印就退出」被漏掉
            if (Test-Path -LiteralPath $Instance.Stdout) {
                $text = Read-DPSharedText -Path $Instance.Stdout
                $m = [regex]::Match($text, $script:DPDshReadyRegex)
                if ($m.Success) { $url = $m.Value }
            }
            if ($url) { break }
            # 进程已经退了、也没有就绪地址：再等下去没有意义
            break
        }
        Start-Sleep -Milliseconds 250
    }

    return [pscustomobject]@{
        Url      = $url
        Exited   = $exited
        ExitCode = $exitCode
    }
}

function Read-DPLock {
    <#
      读 home\.lock（JSON）。损坏/不存在返回 $null。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = Read-DPTextFile -Path $Path
        $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        return $obj
    } catch {
        return $null
    }
}

function Write-DPLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [long]$StartTicks = 0,
        [string]$StartedAt = '',
        [int]$Port = 0
    )
    $obj = [ordered]@{
        pid        = $ProcessId
        startTicks = $StartTicks
        startedAt  = $StartedAt
        port       = $Port
        host       = $env:COMPUTERNAME
    }
    Write-DPTextFile -Path $Path -Text ($obj | ConvertTo-Json -Depth 4)
}

function Get-DPProcessStartTicks {
    param([int]$ProcessId)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return $p.StartTime.ToUniversalTime().Ticks
    } catch {
        return 0
    }
}

function Test-DPIsUsableInstallRoot {
    <#
      判断一个目录能不能当"dsh 装在哪"的锚点：
      排除系统目录、用户 AppData、Program Files（这些位置放房间不合适），并要求可写。
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = Get-DPNormalizedPath -Path $Path
    if (-not $full) { return $false }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }

    $bad = New-Object System.Collections.ArrayList
    foreach ($v in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:APPDATA, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $n = Get-DPNormalizedPath -Path $v
        if ($n) { [void]$bad.Add($n) }
    }
    foreach ($b in $bad) {
        if ($full -eq $b) { return $false }
        if ($full.StartsWith($b + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return (Test-DPDirectoryWritable -Path $full)
}

function Get-DPInstallRootFromDsh {
    <#
      推断"dsh 安装在哪"，作为人格房间的默认落点（用户要求：原本 dsh 装在哪就保存在哪）。

        1. 找到 dsh 可执行文件（-DshPath / DISCPERSONA_DSH / PATH）。
        2. 如果它所在目录名叫 npm-global / node_modules / .bin / npm，
           说明这是包管理器目录，往上退一级当作安装根。
        3. 该目录必须是"合适的根"（非系统/AppData/Program Files，且可写）。

      找不到或不合格返回 $null，调用方退回 %LOCALAPPDATA%。
    #>
    param([string]$DshPath)

    $exe = Resolve-DshExecutable -Explicit $DshPath
    if (-not $exe) { return $null }

    $dir = Split-Path -Parent $exe
    $leaf = (Split-Path -Leaf $dir).ToLowerInvariant()
    $managerDirs = @('npm-global', 'node_modules', '.bin', 'npm', 'pnpm-global', 'yarn')

    if ($managerDirs -contains $leaf) {
        $up = Split-Path -Parent $dir
        if (Test-DPIsUsableInstallRoot -Path $up) { return $up }
    }
    if (Test-DPIsUsableInstallRoot -Path $dir) { return $dir }
    return $null
}
