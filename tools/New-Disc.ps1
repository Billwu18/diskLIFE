<#
.SYNOPSIS
    把 Persona Pack 打包成「可直接烧录到 CD-R」的光盘目录树。

.DESCRIPTION
    产物结构（启动引擎按这个路径找文件）：

        <out>\autorun.inf
        <out>\start.cmd
        <out>\README.txt
        <out>\pad.bin                      512 字节光盘身份文件（discID 的唯一来源）
        <out>\engine\...                   工作区 engine\ 的副本（不存在则跳过并警告）
        <out>\persona\...                  Persona Pack 的副本
        <out>\.discpersona\manifest.json   文件哈希清单
        <out>\.discpersona\payload\...     payload\profile-web（或 build\payload\profile-web）的副本（若存在）

    所有内容先写进 <out>.tmp，全部成功后再原子重命名成 <out>；
    任何一步失败都会清掉临时目录，既不产出半成品、也不破坏已有的 <out>。

    discID 由 pad.bin 的 SHA-256 前 16 位小写十六进制决定。重新打包同一张盘时
    加 -ReusePad，复用 <out>\pad.bin，discID 保持不变。

.PARAMETER Persona
    Persona Pack 目录。必须含 meta.json（name / version）与含 system_prompt: 的 persona.yml。
    meta.json 缺 discID 时，用 pad.bin 算出的 discID 写进「输出副本」（不改源目录）。

.PARAMETER Out
    输出的光盘目录。会被完整重建；已存在时先整体替换（失败会回滚）。

.PARAMETER ReusePad
    若 <out>\pad.bin 已存在且合法，直接复用，保证 discID 不变。

.EXAMPLE
    .\New-Disc.ps1 -Persona ..\persona\dafeiyu -Out D:\build\disc

.EXAMPLE
    .\New-Disc.ps1 -Persona ..\persona\dafeiyu -Out D:\build\disc -ReusePad
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Persona Pack 目录')]
    [string]$Persona,

    [Parameter(Mandatory = $true, HelpMessage = '输出光盘目录')]
    [string]$Out,

    [switch]$ReusePad,

    [Parameter(HelpMessage = '插件包预设：none / comfort / token / full（默认 comfort）')]
    [string]$PayloadPreset = 'comfort',

    [Parameter(HelpMessage = '允许覆盖一个不是 DiscPersona 光盘的非空目录')]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
$script:PadSize          = 512
$script:PadMagic         = 'DISCPERSONA-PAD-V1'
$script:PadTsOffset      = 64
$script:PadTsSize        = 32
$script:PadRandomOffset  = 96

$script:EncAscii     = [System.Text.Encoding]::ASCII
$script:EncUtf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:EncUtf8Bom   = [System.Text.UTF8Encoding]::new($true)
$script:EncUtf16Le   = [System.Text.UnicodeEncoding]::new($false, $true)

$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Notes    = New-Object System.Collections.Generic.List[string]

# 启动器/引擎可能返回的错误码。README.txt 里的简表由这里生成。
$script:ErrorCodes = @(
    @(0, '正常退出'),
    @(1, '盘不完整：engine\ 缺失（常见于烧录中断或盘内文件缺失）'),
    @(2, 'start.cmd 仍是占位文件，需要重新打包'),
    @(3, '找不到可用的 Node.js 运行时'),
    @(4, 'home 目录无法创建或不可写（%LOCALAPPDATA% 权限 / 组策略限制）'),
    @(5, '读盘失败（光盘被拔出、划伤或光驱故障）'),
    @(6, '.discpersona\manifest.json 缺失或无法解析'),
    @(7, 'discID 校验失败：pad.bin 与 manifest.json 不一致（盘被改动过）'),
    @(8, '端口被占用或浏览器启动失败')
)

# ---------------------------------------------------------------------------
# 输出小工具
# ---------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Skip([string]$Text) { Write-Host "  - $Text" -ForegroundColor DarkGray }
function Write-Note([string]$Text) { Write-Host "  · $Text" -ForegroundColor DarkGray }
function Write-WarnLine([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }

function Add-Warn([string]$Text) {
    [void]$script:Warnings.Add($Text)
    Write-WarnLine $Text
}

function Add-Note([string]$Text) {
    [void]$script:Notes.Add($Text)
    Write-Note $Text
}

function Fail-With([string[]]$Messages) {
    Write-Host ''
    Write-Host '[FAIL] Persona Pack 校验未通过，未生成任何文件。' -ForegroundColor Red
    foreach ($m in $Messages) { Write-Host "  ✗ $m" -ForegroundColor Red }
    Write-Host ''
    exit 1
}

# ---------------------------------------------------------------------------
# 通用文件工具
# ---------------------------------------------------------------------------
function Resolve-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-TextFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Write-TextFile([string]$Path, [string]$Text, [System.Text.Encoding]$Encoding) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
}

function ConvertTo-RelPath([string]$Root, [string]$FullPath) {
    $r = $Root.TrimEnd('\')
    if ($FullPath.Length -le $r.Length) { throw "无法计算相对路径：$FullPath（根：$Root）" }
    $rel = $FullPath.Substring($r.Length).TrimStart('\')
    return $rel.Replace('\', '/')
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Copy-Tree([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        $target = Join-Path $Destination $item.Name
        # 不跟随符号链接/目录联接：人设包可能是外部输入，别把盘外的东西复制进光盘
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Add-Warn ("跳过符号链接/目录联接（不会被刻进光盘）：" + $item.FullName)
            continue
        }
        if ($item.PSIsContainer) {
            Copy-Tree -Source $item.FullName -Destination $target
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

function Remove-Tree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)) {
            try { $item.Attributes = 'Normal' } catch { }
        }
        (Get-Item -LiteralPath $Path -Force).Attributes = 'Normal'
    } catch { }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Get-TreeFileCount([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { -not $_.PSIsContainer }).Count
}

function Clear-ReadOnly([string]$Path) {
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)) {
        if (-not $item.PSIsContainer -and $item.IsReadOnly) {
            try { $item.IsReadOnly = $false } catch { }
        }
    }
}

function Get-JsonProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# ---------------------------------------------------------------------------
# pad.bin / discID
# ---------------------------------------------------------------------------
function Test-PadMagic([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -lt 18) { return $false }
    $magic = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 18)
    return ($magic -ceq $script:PadMagic)
}

function New-PadFile([string]$Path) {
    $bytes = New-Object byte[] $script:PadSize
    for ($i = 0; $i -lt $script:PadSize; $i++) { $bytes[$i] = 0x20 }   # 默认填空格，便于按文本读取

    $magicBytes = $script:EncAscii.GetBytes($script:PadMagic)
    [Array]::Copy($magicBytes, 0, $bytes, 0, $magicBytes.Length)

    $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $stampBytes = $script:EncAscii.GetBytes($stamp)
    if ($stampBytes.Length -gt $script:PadTsSize) { throw "内部错误：时间戳超过 $($script:PadTsSize) 字节" }
    [Array]::Copy($stampBytes, 0, $bytes, $script:PadTsOffset, $stampBytes.Length)

    $randomLength = $script:PadSize - $script:PadRandomOffset
    $random = New-Object byte[] $randomLength
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    [Array]::Copy($random, 0, $bytes, $script:PadRandomOffset, $randomLength)

    [System.IO.File]::WriteAllBytes($Path, $bytes)
    return $stamp
}

# ---------------------------------------------------------------------------
# 文本生成
# ---------------------------------------------------------------------------
function Limit-Label([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $n = $Max
    if ($n -gt 0 -and [char]::IsHighSurrogate($Text[$n - 1])) { $n-- }   # 不要把代理对劈开
    return $Text.Substring(0, $n)
}

function New-AutorunText([string]$DisplayName, [string]$Label, [string]$IconRel) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[autorun]')
    $lines.Add('open=start.cmd')
    if ($IconRel) { $lines.Add("icon=$IconRel") }
    $lines.Add("label=$Label")
    $lines.Add("action=唤醒 $DisplayName")
    $lines.Add('shell\open\command=start.cmd')
    return (($lines -join "`r`n") + "`r`n")
}

function New-ReadmeText {
    param(
        [string]$DisplayName,
        [string]$PersonaVersion,
        [string]$DiscID,
        [string]$BuiltAt,
        [string]$EngineVersion,
        [bool]$HasPayload,
        [bool]$HasEngine
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('DiscPersona 光盘说明')
    $lines.Add('====================')
    $lines.Add('')
    $lines.Add('这张盘是什么')
    $lines.Add('--------------')
    $lines.Add("名称：$DisplayName")
    $lines.Add("版本：$PersonaVersion")
    $lines.Add("光盘 ID（discID）：$DiscID")
    $lines.Add("构建时间（UTC）：$BuiltAt")
    $lines.Add("引擎版本：$EngineVersion")
    $lines.Add('')
    $lines.Add('这是一张自带启动器的「人设光盘」：盘上放着人设包（persona\）、运行引擎（engine\）')
    $lines.Add('和一份启动脚本（start.cmd）。引擎只读盘上的文件、不往盘上写——CD-R 本来就是只读的。')
    $lines.Add('')
    $lines.Add('怎么用')
    $lines.Add('------')
    $lines.Add('1. 把光盘插入光驱。')
    $lines.Add('2. 双击盘根目录的 start.cmd；若系统弹出自动播放，选「运行 start.cmd」。')
    $lines.Add('3. 浏览器会自动打开本地页面。若没有自动打开，请看启动窗口里打印的地址，')
    $lines.Add('   手动复制到浏览器访问。')
    $lines.Add('')
    $lines.Add('数据存在哪（重要）')
    $lines.Add('------------------')
    $lines.Add("盘上：只读的人设与引擎，正常情况下不会被修改，也改不了。")
    $lines.Add("硬盘：%LOCALAPPDATA%\DiscPersona\personas\$DiscID\")
    $lines.Add('      这是这张盘的 home：会话记录、记忆、设置等所有可写状态都在这里。')
    $lines.Add('      - discID 不同 = 不同的 home，多张盘互不干扰；')
    $lines.Add('      - 同一张盘插到另一台电脑 = 那边另有一份 home，不会自动同步；')
    $lines.Add('      - 想备份或迁移，复制整个 home 目录即可。')
    $lines.Add('')
    $lines.Add('删掉 home 会怎样')
    $lines.Add('----------------')
    $lines.Add('等同于「在这台机器上把这张盘恢复出厂」：下次启动会重建一个空 home，')
    $lines.Add('之前积累的对话、记忆、设置全部丢失。盘上的人设本身不受影响（它是只读的）。')
    $lines.Add('')
    $lines.Add('拔盘后会怎样')
    $lines.Add('------------')
    $lines.Add('- 运行中断：引擎读不到盘上的资源，正在进行的请求会失败，页面可能报错。')
    $lines.Add('- 已经写入 home 的数据仍然保留（它在硬盘上，与光盘无关）。')
    $lines.Add('- 重新插盘、再跑一次 start.cmd 即可继续；断开的那次请求不会自动重跑。')
    $lines.Add('')
    $lines.Add('光盘是只读的')
    $lines.Add('------------')
    $lines.Add('CD-R 封盘后不能写入。所有需要写的东西都走 home。若看到「只读文件系统」之类的错误，')
    $lines.Add('先确认 home 是否可写（%LOCALAPPDATA% 是否被权限或组策略限制），而不是去修光盘。')
    $lines.Add('')
    $lines.Add('烧录注意（别当启动盘烧）')
    $lines.Add('------------------------')
    $lines.Add('这是一张「数据光盘」，不是系统启动盘：')
    $lines.Add('  - 不要勾选「制作可启动光盘 / Bootable」，不要用启动盘工具写引导记录；')
    $lines.Add('  - 直接按「数据光盘 / 文件与文件夹」方式把本目录烧进 CD-R 即可；')
    $lines.Add('  - 刻好后盘根能看到 start.cmd、persona\ 和本文件，就说明烧对了。')
    $lines.Add('')
    $lines.Add('错误码简表')
    $lines.Add('----------')
    foreach ($pair in $script:ErrorCodes) {
        $lines.Add(('  {0,-3}{1}' -f [string]$pair[0], [string]$pair[1]))
    }
    $lines.Add('')
    $lines.Add('盘里有什么')
    $lines.Add('----------')
    $lines.Add('  autorun.inf                  自动播放描述（可选，不影响手动双击）')
    $lines.Add('  start.cmd                    启动脚本')
    $lines.Add('  README.txt                   本文件')
    $lines.Add('  pad.bin                      512 字节身份文件，discID 由它算出')
    $lines.Add('  persona\...                  人设包（meta.json / persona.yml / AGENTS.md ...）')
    if ($HasEngine) {
        $lines.Add('  engine\...                   运行引擎')
    } else {
        $lines.Add('  engine\                      本盘未包含（打包时工作区没有 engine\）')
    }
    $lines.Add('  .discpersona\manifest.json   文件哈希清单（含 discID，可用于校验完整性）')
    if ($HasPayload) {
        $lines.Add('  .discpersona\payload\...     前端静态资源')
    }
    $lines.Add('')
    $lines.Add('校验这张盘是否完整')
    $lines.Add('--------------------')
    $lines.Add('把整张盘拷到硬盘，在打包机上执行（tools 不进盘）：')
    $lines.Add('  powershell -ExecutionPolicy Bypass -File tools\Test-Disc.ps1 -Disc <拷出来的目录>')
    $lines.Add('全部 ✓ 即 PASS；哈希对不上说明文件在烧录或拷贝过程中损坏。')
    $lines.Add('')
    $lines.Add('—— 本文件由 tools\New-Disc.ps1 生成，请勿手工编辑。')
    return (($lines -join "`r`n") + "`r`n")
}

function ConvertTo-JsonString([string]$Text) {
    # JSON 字符串字面量：转义必须字符，非 ASCII 原样输出（文件按 UTF-8 存）。
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -ceq '"') { [void]$sb.Append('\"') }
        elseif ($ch -ceq '\') { [void]$sb.Append('\\') }
        elseif ($code -eq 8) { [void]$sb.Append('\b') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-JsonText {
    # 自写的 2 空格缩进 JSON 序列化。不用 ConvertTo-Json 的原因：Windows PowerShell 5.1
    # 会在冒号后塞两个空格、嵌套缩进也不规整（"files" 的子项会缩 9 格），而 manifest
    # 要求严格 2 空格缩进、": " 分隔、非 ASCII 原样。
    param($Value, [int]$Level = 0, [int]$MaxDepth = 20)
    $pad = ' ' * (2 * $Level)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $d = [double]$Value
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return 'null' }
        return $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or
        $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [uint16] -or $Value -is [sbyte]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary])) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        if ($Level -ge $MaxDepth) { return '[]' }
        $innerPad = ' ' * (2 * ($Level + 1))
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $items) {
            $parts.Add($innerPad + (ConvertTo-JsonText $item ($Level + 1) $MaxDepth))
        }
        return ("[`r`n" + ($parts -join ",`r`n") + "`r`n" + $pad + ']')
    }

    $names = New-Object System.Collections.Generic.List[string]
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) { $names.Add([string]$k) }
    } else {
        foreach ($p in $Value.PSObject.Properties) { $names.Add($p.Name) }
    }
    if ($names.Count -eq 0) { return '{}' }
    if ($Level -ge $MaxDepth) { return '{}' }

    $innerPad = ' ' * (2 * ($Level + 1))
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($n in $names) {
        if ($Value -is [System.Collections.IDictionary]) { $v = $Value[$n] }
        else { $v = $Value.PSObject.Properties[$n].Value }
        $parts.Add($innerPad + (ConvertTo-JsonString $n) + ': ' + (ConvertTo-JsonText $v ($Level + 1) $MaxDepth))
    }
    return ("{`r`n" + ($parts -join ",`r`n") + "`r`n" + $pad + '}')
}

function Get-JsonTextForFile {
    # 序列化后回读一次；万一碰上没覆盖的类型，退回 ConvertTo-Json，保证文件是合法 JSON。
    param($Object)
    $text = ConvertTo-JsonText $Object 0 20
    $ok = $false
    try {
        $null = ($text | ConvertFrom-Json)
        $ok = $true
    } catch {
        $ok = $false
    }
    if (-not $ok) {
        Add-Warn '自写 JSON 序列化未通过回读校验，改用 ConvertTo-Json（缩进可能不是 2 空格）。'
        $text = ($Object | ConvertTo-Json -Depth 20)
    }
    return ($text -replace "`r?`n", "`r`n")
}

function Get-EngineVersion([string]$EngineDir) {
    if (-not (Test-Path -LiteralPath $EngineDir -PathType Container)) { return 'dev' }
    $versionFile = Join-Path $EngineDir 'version.txt'
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        $v = (Read-TextFile $versionFile).Trim()
        if ($v) { return (($v -split "`r?`n")[0]).Trim() }
    }
    $pkgFile = Join-Path $EngineDir 'package.json'
    if (Test-Path -LiteralPath $pkgFile -PathType Leaf) {
        try {
            $pkg = (Read-TextFile $pkgFile) | ConvertFrom-Json
            $v = Get-JsonProp $pkg 'version'
            if ($v) { return [string]$v }
        } catch {
            Add-Warn "engine\package.json 无法解析，引擎版本记为 dev（$($_.Exception.Message)）"
        }
    }
    return 'dev'
}

# ---------------------------------------------------------------------------
# 0. 输出路径与前置检查
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'DiscPersona 打包器' -ForegroundColor White

$personaPath = (Resolve-FullPath $Persona).TrimEnd('\')
$outPath     = (Resolve-FullPath $Out).TrimEnd('\')
$workspaceRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }

Write-Host "  Persona     : $personaPath"
Write-Host "  Out         : $outPath"
Write-Host "  ReusePad    : $(if ($ReusePad) { '是' } else { '否' })"
Write-Host "  工作区根目录: $workspaceRoot"

if (-not (Test-Path -LiteralPath $personaPath -PathType Container)) {
    Write-Host ''
    Write-Host "[FAIL] Persona Pack 目录不存在：$personaPath" -ForegroundColor Red
    Write-Host ''
    exit 1
}

$pathRoot = [System.IO.Path]::GetPathRoot($outPath)
if ($pathRoot -and ($outPath.TrimEnd('\') -ieq $pathRoot.TrimEnd('\'))) {
    Write-Host ''
    Write-Host "[FAIL] 拒绝把光盘树写到盘符根目录：$outPath" -ForegroundColor Red
    Write-Host '       请用类似 D:\build\disc 这样的子目录。'
    Write-Host ''
    exit 1
}

$personaCmp = $personaPath.TrimEnd('\')
$outCmp     = $outPath.TrimEnd('\')
if ($outCmp -ieq $personaCmp) {
    Write-Host ''
    Write-Host '[FAIL] 输出目录不能与 Persona Pack 是同一个目录。' -ForegroundColor Red
    Write-Host ''
    exit 1
}
if ($outCmp.StartsWith($personaCmp + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host ''
    Write-Host '[FAIL] 输出目录不能位于 Persona Pack 内部。' -ForegroundColor Red
    Write-Host ''
    exit 1
}
if ($personaCmp.StartsWith($outCmp + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host ''
    Write-Host '[FAIL] Persona Pack 不能位于输出目录内部（会随重建被删掉）。' -ForegroundColor Red
    Write-Host ''
    exit 1
}

# 覆盖前的护栏：只允许覆盖「空目录」或「上一张 DiscPersona 光盘」，其余必须显式 -Force
if (Test-Path -LiteralPath $outPath -PathType Container) {
    $looksLikeDisc = Test-Path -LiteralPath (Join-Path $outCmp '.discpersona\manifest.json') -PathType Leaf
    $isEmpty = -not (Get-ChildItem -LiteralPath $outCmp -Force | Select-Object -First 1)
    if (-not $looksLikeDisc -and -not $isEmpty -and -not $Force) {
        Fail-With @(
            "输出目录里已经有别的东西，且看起来不是 DiscPersona 光盘：$outCmp",
            '为了不误删你的文件，本次不做任何改动。',
            '换一个空目录（-Out），或确认要覆盖时加 -Force。'
        )
    }
    if (-not $looksLikeDisc -and -not $isEmpty -and $Force) {
        Add-Warn "输出目录不是 DiscPersona 光盘，但给了 -Force，里面的内容将被替换：$outCmp"
    }
}

$tmpPath = $outCmp + '.tmp'
if (Test-Path -LiteralPath $tmpPath) {
    Add-Warn "发现上次残留的临时目录，已清理：$tmpPath"
    Remove-Tree $tmpPath
}

# ---------------------------------------------------------------------------
# 1. 校验 Persona Pack
# ---------------------------------------------------------------------------
Write-Step '[1/7] 校验 Persona Pack'

$metaPath = Join-Path $personaPath 'meta.json'
$ymlPath  = Join-Path $personaPath 'persona.yml'
$problems = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
    $problems.Add('meta.json：整个文件缺失')
} else {
    $meta = $null
    try {
        $meta = (Read-TextFile $metaPath) | ConvertFrom-Json
    } catch {
        $problems.Add("meta.json：不是合法 JSON（$($_.Exception.Message)）")
    }
    if ($null -ne $meta) {
        $name    = [string](Get-JsonProp $meta 'name')
        $version = [string](Get-JsonProp $meta 'version')
        if ([string]::IsNullOrWhiteSpace($version)) {
            # 现役人设包用 personaVersion 记版本号，兼容之（manifest 的 version 取到值即可）
            $version = [string](Get-JsonProp $meta 'personaVersion')
            if (-not [string]::IsNullOrWhiteSpace($version)) {
                Add-Note 'meta.json 没有 version，按 personaVersion 取版本号'
            }
        }
        $discIDInMeta = [string](Get-JsonProp $meta 'discID')
        if ([string]::IsNullOrWhiteSpace($name))    { $problems.Add('meta.json：缺少 name（或为空）') }
        if ([string]::IsNullOrWhiteSpace($version)) { $problems.Add('meta.json：缺少 version / personaVersion（或为空）') }
        if ([string]::IsNullOrWhiteSpace($discIDInMeta)) {
            Add-Note 'meta.json 没有 discID，将按 pad.bin 生成并写进输出副本（源目录不改）。'
        }
    }
}

if (-not (Test-Path -LiteralPath $ymlPath -PathType Leaf)) {
    $problems.Add('persona.yml：整个文件缺失')
} else {
    $ymlText = Read-TextFile $ymlPath
    if ($ymlText -notmatch '(?m)system_prompt\s*:') {
        $problems.Add('persona.yml：缺少 system_prompt:')
    }
}

if ($problems.Count -gt 0) { Fail-With $problems.ToArray() }

$meta = (Read-TextFile $metaPath) | ConvertFrom-Json
$personaName    = ([string](Get-JsonProp $meta 'name')).Trim()
$personaVersion = ([string](Get-JsonProp $meta 'version')).Trim()
if (-not $personaVersion) { $personaVersion = ([string](Get-JsonProp $meta 'personaVersion')).Trim() }
Write-Ok "Persona Pack 合格（name=$personaName, version=$personaVersion）"

foreach ($optional in @('AGENTS.md', 'card.json', 'avatar.png', 'avatar.ico', 'lorebook.json', 'seed')) {
    if (-not (Test-Path -LiteralPath (Join-Path $personaPath $optional))) {
        Add-Note "人设包里没有 $optional（可选，打包不报错）"
    }
}

# ---------------------------------------------------------------------------
# 2. 准备临时目录 + pad.bin
# ---------------------------------------------------------------------------
Write-Step '[2/7] 准备 pad.bin（光盘身份）'

New-Item -ItemType Directory -Path $tmpPath -Force | Out-Null
$padPath = Join-Path $tmpPath 'pad.bin'

$padReused = $false
if ($ReusePad) {
    $oldPad = Join-Path $outPath 'pad.bin'
    if (Test-Path -LiteralPath $oldPad -PathType Leaf) {
        $oldBytes = [System.IO.File]::ReadAllBytes($oldPad)
        if ($oldBytes.Length -eq $script:PadSize -and (Test-PadMagic $oldBytes)) {
            [System.IO.File]::WriteAllBytes($padPath, $oldBytes)
            $padReused = $true
        } else {
            Add-Warn "已指定 -ReusePad，但旧的 pad.bin 长度或魔数不对，改成重新生成（discID 会变）。"
        }
    } else {
        Add-Warn '已指定 -ReusePad，但输出目录里没有 pad.bin，改成重新生成。'
    }
}
if (-not $padReused) {
    $padStamp = New-PadFile $padPath
}

$discID = (Get-Sha256 $padPath).Substring(0, 16)
if ($padReused) {
    Write-Ok "复用旧 pad.bin，discID=$discID"
} else {
    Write-Ok "已生成 512 字节 pad.bin，discID=$discID"
}

# ---------------------------------------------------------------------------
# 3. 复制 Persona Pack
# ---------------------------------------------------------------------------
Write-Step '[3/7] 复制 persona\'

$personaDst = Join-Path $tmpPath 'persona'
Copy-Tree -Source $personaPath -Destination $personaDst
$personaCount = Get-TreeFileCount $personaDst
Write-Ok "persona\ 已复制（$personaCount 个文件）"

# meta.json 的 discID 同步（只改输出副本）
$dstMetaPath = Join-Path $personaDst 'meta.json'
$dstMeta = (Read-TextFile $dstMetaPath) | ConvertFrom-Json
$metaDiscID = [string](Get-JsonProp $dstMeta 'discID')
if ([string]::IsNullOrWhiteSpace($metaDiscID)) {
    $dstMeta | Add-Member -NotePropertyName 'discID' -NotePropertyValue $discID -Force
    $json = Get-JsonTextForFile $dstMeta
    Write-TextFile $dstMetaPath ($json + "`r`n") $script:EncUtf8NoBom
    Write-Ok '已把人设包 meta.json（输出副本）补上 discID'
} elseif ($metaDiscID -ne $discID) {
    $dstMeta.discID = $discID
    $json = Get-JsonTextForFile $dstMeta
    Write-TextFile $dstMetaPath ($json + "`r`n") $script:EncUtf8NoBom
    Add-Warn "人设包 meta.json 里的 discID（$metaDiscID）与 pad.bin 算出的不一致，已按 pad.bin 覆写输出副本。"
} else {
    Write-Skip 'meta.json 的 discID 已与 pad.bin 一致'
}

# 必须同步进 manifest 的 name / version（manifest 用源 meta；输出副本已一致）
$outMeta = (Read-TextFile $dstMetaPath) | ConvertFrom-Json
$personaName    = ([string](Get-JsonProp $outMeta 'name')).Trim()
$personaVersion = ([string](Get-JsonProp $outMeta 'version')).Trim()
if (-not $personaVersion) { $personaVersion = ([string](Get-JsonProp $outMeta 'personaVersion')).Trim() }

# ---------------------------------------------------------------------------
# 4. 复制 engine
# ---------------------------------------------------------------------------
Write-Step '[4/7] 复制 engine\'

$engineSrc = Join-Path $workspaceRoot 'engine'
$hasEngine = $false
if (Test-Path -LiteralPath $engineSrc -PathType Container) {
    $engineDst = Join-Path $tmpPath 'engine'
    Copy-Tree -Source $engineSrc -Destination $engineDst
    $hasEngine = $true
    $engineCount = Get-TreeFileCount $engineDst
    if ($engineCount -eq 0) {
        Add-Warn "工作区 engine\ 存在但没有文件（$engineSrc）——盘上没有可执行的引擎，启动会报错 1。"
    } else {
        Write-Ok "engine\ 已复制（$engineCount 个文件）"
    }
} else {
    Add-Warn "工作区没有 engine\（$engineSrc），盘上不会有引擎——这张盘目前只能当数据盘用。"
}
$engineVersion = Get-EngineVersion (Join-Path $tmpPath 'engine')

# ---------------------------------------------------------------------------
# 5. start.cmd
# ---------------------------------------------------------------------------
Write-Step '[5/7] 写入 start.cmd'

$startSrc = Join-Path $workspaceRoot 'start.cmd'
$startDst = Join-Path $tmpPath 'start.cmd'

if (Test-Path -LiteralPath $startSrc -PathType Leaf) {
    $startBytes = [System.IO.File]::ReadAllBytes($startSrc)
    $isUtf16 = ($startBytes.Length -ge 2 -and $startBytes[0] -eq 0xFF -and $startBytes[1] -eq 0xFE)
    $hasUtf8Bom = ($startBytes.Length -ge 3 -and $startBytes[0] -eq 0xEF -and $startBytes[1] -eq 0xBB -and $startBytes[2] -eq 0xBF)

    if ($isUtf16) {
        Add-Warn 'start.cmd 是 UTF-16 编码，cmd.exe 无法执行；已原样复制，请在源文件里改回 ANSI/UTF-8 无 BOM。'
        [System.IO.File]::WriteAllBytes($startDst, $startBytes)
    } elseif ($hasUtf8Bom) {
        Add-Warn 'start.cmd 带 UTF-8 BOM，cmd.exe 可能把 BOM 当成命令的一部分；已原样复制。'
        [System.IO.File]::WriteAllBytes($startDst, $startBytes)
    } else {
        # 检查行尾：只允许 CRLF
        $loneLf = $false
        for ($i = 0; $i -lt $startBytes.Length; $i++) {
            if ($startBytes[$i] -eq 0x0A -and ($i -eq 0 -or $startBytes[$i - 1] -ne 0x0D)) { $loneLf = $true; break }
        }
        if ($loneLf) {
            $text = Read-TextFile $startSrc
            $text = ($text -replace "`r`n", "`n") -replace "`r", "`n"
            $text = $text -replace "`n", "`r`n"
            Write-TextFile $startDst $text $script:EncUtf8NoBom
            Add-Warn 'start.cmd 含裸 LF 行尾，已统一成 CRLF。'
        } else {
            [System.IO.File]::Copy($startSrc, $startDst, $true)
        }
    }
    Write-Ok "start.cmd 已从工作区复制（$([System.IO.File]::ReadAllBytes($startDst).Length) 字节）"
} else {
    $placeholder = @(
        '@echo off',
        'echo.',
        'echo  [DiscPersona] placeholder start.cmd',
        'echo  This disc was built before start.cmd existed in the workspace,',
        'echo  so it only contains the persona data and manifest.',
        'echo  Put start.cmd into the disc root and rebuild the disc.',
        'echo.',
        'pause',
        'exit /b 2'
    )
    $text = (($placeholder -join "`r`n") + "`r`n")
    Write-TextFile $startDst $text $script:EncAscii
    Add-Warn 'start.cmd 尚未提供（工作区没有 start.cmd），已写入占位文件；这张盘不能启动。'
}

# 交叉检查：start.cmd 若调用 engine\launch.ps1，盘上就必须真的有它
if (Test-Path -LiteralPath $startDst -PathType Leaf) {
    $startText = Read-TextFile $startDst
    if ($startText -match 'engine\\launch\.ps1') {
        $launchOnDisc = Join-Path $tmpPath 'engine\launch.ps1'
        if (-not (Test-Path -LiteralPath $launchOnDisc -PathType Leaf)) {
            Add-Warn 'start.cmd 调用 engine\launch.ps1，但盘上没有这个文件——启动会失败（错误码 1）。'
        }
    }
}

# ---------------------------------------------------------------------------
# 6. payload / autorun.inf / README.txt
# ---------------------------------------------------------------------------
Write-Step '[6/7] 写入 autorun.inf 与 README.txt'

$preset = $PayloadPreset
if (-not $preset) { $preset = 'comfort' }
$payloadSrc = $null
if ($preset -ne 'none') {
    $candidates = @(
        (Join-Path $workspaceRoot ('payload\' + $preset + '\profile-web')),
        (Join-Path $workspaceRoot ('build\payload\' + $preset + '\profile-web')),
        (Join-Path $workspaceRoot 'payload\profile-web'),
        (Join-Path $workspaceRoot 'build\payload\profile-web')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Container) { $payloadSrc = $c; break }
    }
}
$hasPayload = $false
$payloadPresetUsed = 'none'
if ($payloadSrc) {
    $payloadDst = Join-Path $tmpPath '.discpersona\payload\profile-web'
    Copy-Tree -Source $payloadSrc -Destination $payloadDst
    $hasPayload = $true
    $payloadPresetUsed = $preset
    Write-Ok "payload 已复制（$(Get-TreeFileCount $payloadDst) 个文件，预设 $preset）"
} elseif ($preset -eq 'none') {
    Write-Skip '按 -PayloadPreset none 打包纯人设盘：人格 DSH 不带任何预装插件'
} else {
    Write-Skip ('没有找到预设 ' + $preset + ' 的 payload：将打包纯人设盘。跑 tools\New-ProfilePayload.ps1 -Preset ' + $preset + ' 可以补')
}

# 把用到哪个插件包写进 meta.json（输出副本），Studio / 启动器 / 人都能看出来
try {
    $metaOutPath = Join-Path $tmpPath 'persona\meta.json'
    if (Test-Path -LiteralPath $metaOutPath -PathType Leaf) {
        $metaObj = (Read-TextFile $metaOutPath) | ConvertFrom-Json
        $pluginNames = @()
        if ($hasPayload) {
            $pjPath = Join-Path $tmpPath '.discpersona\payload\profile-web\payload.json'
            if (Test-Path -LiteralPath $pjPath -PathType Leaf) {
                $pj = (Read-TextFile $pjPath) | ConvertFrom-Json
                foreach ($item in @(Get-JsonProp $pj 'plugins')) {
                    $n = [string](Get-JsonProp $item 'name')
                    if ($n) { $pluginNames += $n }
                }
            }
        }
        $payloadInfo = [ordered]@{
            preset  = $payloadPresetUsed
            plugins = @($pluginNames)
        }
        $metaObj | Add-Member -NotePropertyName 'payload' -NotePropertyValue $payloadInfo -Force
        Write-TextFile $metaOutPath ((Get-JsonTextForFile $metaObj) + "`r`n") $script:EncUtf8NoBom
        Write-Ok ('meta.json 记录插件包：' + $payloadPresetUsed + '（' + (@($pluginNames).Count) + ' 个插件）')
    }
} catch {
    Add-Warn ('写 meta.json 的插件包信息失败：' + $_.Exception.Message)
}

# autorun.inf
$avatarIco = Join-Path $tmpPath 'persona\avatar.ico'
$avatarPng = Join-Path $tmpPath 'persona\avatar.png'
$iconRel = ''
if (Test-Path -LiteralPath $avatarIco -PathType Leaf) {
    $iconRel = 'persona\avatar.ico'
} elseif (Test-Path -LiteralPath $avatarPng -PathType Leaf) {
    $iconRel = 'persona\avatar.png'
    Add-Note '人设包没有 avatar.ico，icon 回退指向 avatar.png（部分系统不显示图标，可先转成 .ico）'
}
$hasIcon = (-not [string]::IsNullOrEmpty($iconRel))
$safeName = ($personaName -replace "[\r\n]", ' ').Trim()
if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = $discID }
$label = (Limit-Label $safeName 32)
if ($label.Length -lt $safeName.Length) {
    Add-Note "显示名超过 32 字符，autorun label 截断为：$label"
}

$autorunText = New-AutorunText -DisplayName $safeName -Label $label -IconRel $iconRel
$autorunPath = Join-Path $tmpPath 'autorun.inf'

$ascii = $true
foreach ($ch in $autorunText.ToCharArray()) { if ([int]$ch -gt 0x7F) { $ascii = $false; break } }

if ($ascii) {
    Write-TextFile $autorunPath $autorunText $script:EncAscii
} else {
    # 内容里有中文（action=唤醒 / 中文人设名）。ASCII 存不下，改用 Windows 原生支持的
    # UTF-16LE + BOM；这是 autorun.inf 的官方 Unicode 形式，Explorer 能正确显示中文标签。
    Write-TextFile $autorunPath $autorunText $script:EncUtf16Le
    Add-Note 'autorun.inf 用 UTF-16LE(带 BOM)：内容含中文，纯 ASCII 存不下（Windows 原生支持该形式）。'
}
if ($hasIcon) {
    Write-Ok "autorun.inf 已写入（icon=$iconRel）"
} else {
    Write-Ok 'autorun.inf 已写入（没有人设头像，省略 icon 行）'
}

# README.txt
$builtAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$readmeText = New-ReadmeText -DisplayName $safeName -PersonaVersion $personaVersion `
    -DiscID $discID -BuiltAt $builtAt -EngineVersion $engineVersion `
    -HasPayload $hasPayload -HasEngine $hasEngine
Write-TextFile (Join-Path $tmpPath 'README.txt') $readmeText $script:EncUtf8Bom
Write-Ok 'README.txt 已写入（UTF-8 带 BOM，CRLF）'

# ---------------------------------------------------------------------------
# 7. 哈希清单
# ---------------------------------------------------------------------------
Write-Step '[7/7] 计算哈希并写 manifest.json'

Clear-ReadOnly $tmpPath

$relList = New-Object System.Collections.Generic.List[string]
foreach ($file in @(Get-ChildItem -LiteralPath $tmpPath -Recurse -Force)) {
    if ($file.PSIsContainer) { continue }
    $rel = ConvertTo-RelPath -Root $tmpPath -FullPath $file.FullName
    if ($rel -eq '.discpersona/manifest.json') { continue }
    $relList.Add($rel)
}
$sortedRel = $relList.ToArray()
[Array]::Sort($sortedRel, [System.StringComparer]::Ordinal)

$filesObj = [ordered]@{}
foreach ($rel in $sortedRel) {
    $full = Join-Path $tmpPath ($rel.Replace('/', '\'))
    $filesObj[$rel] = Get-Sha256 $full
}

$manifest = [ordered]@{
    format  = 1
    discID  = $discID
    name    = $personaName
    version = $personaVersion
    builtAt = $builtAt
    engine  = $engineVersion
    files   = $filesObj
}

$manifestPath = Join-Path $tmpPath '.discpersona\manifest.json'
$json = ConvertTo-JsonText $manifest 0 20
Write-TextFile $manifestPath ($json + "`r`n") $script:EncUtf8NoBom
Write-Ok "manifest.json 已写入（$($sortedRel.Count) 个文件，含 pad.bin；盘上共 $($sortedRel.Count + 1) 个文件）"

# ---------------------------------------------------------------------------
# 原子替换 <out>
# ---------------------------------------------------------------------------
Write-Step '提交到输出目录'

$backupPath = $null
if (Test-Path -LiteralPath $outPath) {
    $backupPath = $outPath + '.old-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    [System.IO.Directory]::Move($outPath, $backupPath)
    Write-Note "已有输出目录，先移到：$backupPath"
}
try {
    [System.IO.Directory]::Move($tmpPath, $outPath)
} catch {
    if ($backupPath -and (Test-Path -LiteralPath $backupPath) -and -not (Test-Path -LiteralPath $outPath)) {
        [System.IO.Directory]::Move($backupPath, $outPath)
        Write-WarnLine '提交失败，已回滚到原来的输出目录。'
    }
    throw
}
if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
    Remove-Tree $backupPath
}
Write-Ok "已原子提交：$outPath"

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
$totalFiles = @(Get-ChildItem -LiteralPath $outPath -Recurse -Force | Where-Object { -not $_.PSIsContainer }).Count

Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host 'DiscPersona 光盘已生成' -ForegroundColor Green
Write-Host "  名称        : $personaName"
Write-Host "  版本        : $personaVersion"
Write-Host "  discID      : $discID"
Write-Host "  引擎版本    : $engineVersion"
Write-Host "  输出目录    : $outPath"
Write-Host "  文件总数    : $totalFiles（含 pad.bin 与 manifest.json）"
Write-Host "  home        : %LOCALAPPDATA%\DiscPersona\personas\$discID"
Write-Host "  pad.bin     : $(if ($padReused) { '复用旧文件' } else { '新生成' })"
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray

if ($script:Warnings.Count -gt 0) {
    Write-Host ''
    Write-Host "警告（$($script:Warnings.Count) 条，盘的完整性可能受影响）：" -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }
}
if ($script:Notes.Count -gt 0) {
    Write-Host ''
    Write-Host "提示（$($script:Notes.Count) 条，不影响使用）：" -ForegroundColor DarkGray
    foreach ($n in $script:Notes) { Write-Host "  · $n" -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host "DISC_OK discID=$discID files=$totalFiles out=$outPath" -ForegroundColor Green
exit 0
