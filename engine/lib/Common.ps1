# DiscPersona 启动引擎 · 公共基础设施
# 路径 / 输出编码 / 中文日志 / 错误码
# 本文件由 engine\launch.ps1 点源加载，不单独执行。兼容 Windows PowerShell 5.1。

# 错误码表：代码 -> 一句话类别（详细文案在调用处给）
$script:DPErrorCodes = [ordered]@{
    E01 = '光盘不完整'
    E02 = 'pad.bin 读不了'
    E03 = '文件被改动过'
    E04 = '找不到 dsh'
    E05 = '环境不支持'
    E06 = 'home 写不进去'
    E07 = '凭据缺失'
    E08 = '人设文件解析失败'
    E09 = '启动超时'
    E10 = '已在运行'
}

# 运行期状态（launch.ps1 会设置）
$script:DPLogPath = $null
$script:DPPersonaHome = $null

$script:DPUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Initialize-DPConsole {
    # PS 5.1 控制台默认按 ANSI 解码 UTF-8 脚本里的中文，必须显式改成 UTF-8
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try { $global:OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}

function Get-DPNow {
    return (Get-Date)
}

function Format-DPTime {
    param([datetime]$Value = (Get-Date))
    return $Value.ToString('yyyy-MM-dd HH:mm:ss')
}

function Format-DPFileStamp {
    param([datetime]$Value = (Get-Date))
    return $Value.ToString('yyyyMMdd-HHmmss')
}

function Add-DPLog {
    <#
      写一行中文日志（始终写文件；控制台是否回声由 -Echo 决定）。
      返回拼好的整行，便于调用方复用。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('信息', '提示', '警告', '错误')][string]$Level = '信息',
        [switch]$Echo
    )
    $line = '[{0}] [{1}] {2}' -f (Format-DPTime), $Level, $Message
    if ($script:DPLogPath) {
        try {
            [System.IO.File]::AppendAllText($script:DPLogPath, $line + "`r`n", $script:DPUtf8NoBom)
        } catch { }
    }
    if ($Echo) {
        switch ($Level) {
            '警告' { Write-Host $line -ForegroundColor Yellow }
            '错误' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line }
        }
    }
    # 故意不返回值：调用方常把本函数当纯日志用，返回值会污染函数的返回值通道。
}

function Write-DPLine {
    param(
        [string]$Text = '',
        [string]$Color
    )
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Stop-DiscPersona {
    <#
      统一失败出口：中文一句话结论 + 「怎么办」一句 + 错误码，退出码 1。
      所有错误都必须经过这里，保证口径一致。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Hint
    )
    $kind = $script:DPErrorCodes[$Code]
    if (-not $kind) { $kind = '未知错误' }
    if ($script:DPLogPath) {
        try {
            [System.IO.File]::AppendAllText($script:DPLogPath, ('[{0}] [错误] {1} {2}' -f (Format-DPTime), $Code, $Message) + "`r`n", $script:DPUtf8NoBom)
            if ($Hint) {
                [System.IO.File]::AppendAllText($script:DPLogPath, ('[{0}] [错误] 怎么办：{1}' -f (Format-DPTime), $Hint) + "`r`n", $script:DPUtf8NoBom)
            }
        } catch { }
    }
    Write-DPLine ''
    Write-DPLine ('  [' + $Code + '] ' + $Message) 'Red'
    if ($Hint) { Write-DPLine ('  怎么办：' + $Hint) 'Yellow' }
    Write-DPLine ('  错误码：' + $Code + '（' + $kind + '）') 'DarkGray'
    Write-DPLine ''
    exit 1
}

function Assert-DPPlatform {
    <#
      E05：非 Windows 或 PowerShell < 5.1。
    #>
    $v = $PSVersionTable.PSVersion
    $onWindows = $false
    try {
        $onWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    } catch {
        $onWindows = $false
    }
    $tooOld = ($v.Major -lt 5) -or (($v.Major -eq 5) -and ($v.Minor -lt 1))
    if ((-not $onWindows) -or $tooOld) {
        Stop-DiscPersona -Code 'E05' `
            -Message ('这个环境跑不了 DiscPersona：需要 Windows + PowerShell 5.1 以上（当前系统 ' + [System.Environment]::OSVersion.VersionString + '，PowerShell ' + $v.ToString() + '）。') `
            -Hint '请换一台 Windows 10 / Windows 11 电脑，双击光盘根目录的 start.cmd 运行。'
    }
}

function Get-DPNormalizedPath {
    <#
      把用户/start.cmd 传来的路径规范化：去首尾引号、转绝对路径、去掉末尾反斜杠。
      失败返回 $null。
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim()
    if ($p.Length -ge 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) {
        $p = $p.Substring(1, $p.Length - 2).Trim()
    }
    if ($p.Length -eq 0) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($p)
    } catch {
        return $null
    }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-DPDirectoryWritable {
    <#
      创建目录并写一个探针文件验证真实可写（E06 用）。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Path ('.dp-write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($probe, 'ok', $script:DPUtf8NoBom)
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Get-DPFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Test-DPProcessIdentity {
    <#
      判断 pid（配合记录的进程启动时间）是否还活着。
      PID 可能被系统复用，所以启动时间对不上就当作已退出。
    #>
    param(
        [int]$ProcessId,
        [long]$StartTicks = 0
    )
    if ($ProcessId -le 0) { return $false }
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($StartTicks -gt 0) {
        try {
            $actual = $p.StartTime.ToUniversalTime().Ticks
            $delta = [Math]::Abs($actual - $StartTicks)
            if ($delta -gt (2 * [TimeSpan]::TicksPerSecond)) { return $false }
        } catch { }
    }
    return $true
}

function Stop-DPProcessTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    try {
        $p = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c taskkill /PID ' + $ProcessId + ' /T /F') -WindowStyle Hidden -PassThru
        $p.WaitForExit(10000) | Out-Null
    } catch { }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($proc) { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Open-DPUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        Start-Process -FilePath $Url -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Read-DPTextFile {
    <#
      严格按 UTF-8 读取（自动跳过 BOM），便于读中文 YAML / JSON。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    $enc = New-Object System.Text.UTF8Encoding($false)
    return $enc.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Clear-DPReadOnly {
    <#
    .SYNOPSIS
    清掉一棵树（或单个文件）的只读属性，返回清掉的数量。
    .DESCRIPTION
    光盘上的文件带 ReadOnly 属性，Copy-Item -Recurse 会把它一起复制过来。
    之后 dsh 写设置（临时文件 rename 覆盖 cordis.patch.yml）就会 EPERM，
    用户改房间里的人设也会被编辑器拒绝。所以凡是从盘上复制过来的东西都要清一遍。
    注意：Get-ChildItem -Recurse 会连目录一起返回，而 DirectoryInfo 没有 IsReadOnly，
    在 StrictMode 下访问会抛错并中断整个循环 —— 所以只取 -File，目录单独按 Attributes 判断。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $count = 0
    $ro = [System.IO.FileAttributes]::ReadOnly
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            if (($f.Attributes -band $ro) -ne 0) { try { $f.Attributes = ($f.Attributes -bxor $ro); $count++ } catch { } }
        }
        $root = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($root -and (($root.Attributes -band $ro) -ne 0)) {
            try { $root.Attributes = ($root.Attributes -bxor $ro); $count++ } catch { }
        }
    } catch { }
    return $count
}

function Write-DPTextFile {
    <#
      写 UTF-8（无 BOM）。YAML / JSON 一律无 BOM，避免解析器把 BOM 当内容。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-DPLogTail {
    <#
      取日志尾部若干行，用于 E09 展示。
    #>
    param(
        [string]$Path,
        [int]$Lines = 15
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $all = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)
        if ($all.Count -le $Lines) { return $all }
        return @($all[($all.Count - $Lines)..($all.Count - 1)])
    } catch {
        return @()
    }
}
