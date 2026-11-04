<#
.SYNOPSIS
    对 New-Disc.ps1 生成的光盘目录树做静态校验（不启动 DSH、不联网）。

.DESCRIPTION
    逐项检查：
      · 必需文件是否齐全（autorun.inf / start.cmd / README.txt / pad.bin /
        .discpersona\manifest.json / persona\meta.json / persona\persona.yml）
      · manifest.json 是否为 UTF-8 无 BOM、可解析、format=1、必填字段齐全
      · manifest 里每个文件的 SHA-256 是否与磁盘一致（含缺失文件）
      · 磁盘上有没有 manifest 之外的多余文件
      · pad.bin 是否恰好 512 字节、魔数是否正确、时间戳字段是否为 ISO8601(UTC)
      · manifest.discID 是否由 pad.bin 算出（前 16 位小写十六进制）
      · persona\meta.json 的 discID 是否与 manifest 一致
      · persona\persona.yml 是否含 system_prompt:
      · start.cmd / autorun.inf 是否 CRLF（start.cmd 不应带 BOM）
      · autorun.inf 是否含 open=start.cmd，icon 指向的文件是否存在

    每项打印 ✓ / ✗，末尾给 PASS / FAIL 与退出码（PASS=0，FAIL=1）。

.PARAMETER Disc
    光盘目录树的根（例如 D:\build\disc 或拷到硬盘的整盘副本）。

.EXAMPLE
    .\Test-Disc.ps1 -Disc D:\build\disc
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = '光盘目录树根目录')]
    [string]$Disc
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:PassCount = 0
$script:FailCount = 0
$script:Failures   = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# 小工具
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

function Add-Check([string]$Label, [bool]$Pass, [string]$Detail) {
    if ($Pass) {
        $script:PassCount++
        Write-Host "  ✓ $Label" -ForegroundColor Green
    } else {
        $script:FailCount++
        if ($Detail) { [void]$script:Failures.Add("$Label —— $Detail") } else { [void]$script:Failures.Add($Label) }
        Write-Host "  ✗ $Label" -ForegroundColor Red
        if ($Detail) { Write-Host "      $Detail" -ForegroundColor Yellow }
    }
}

function Add-NoteLine([string]$Text) {
    Write-Host "  · $Text" -ForegroundColor DarkGray
}

function Test-Crlf([string]$Text, [ref]$Problem) {
    if ($Text -match "[^`r]`n") { $Problem.Value = '存在裸 LF 行尾（应为 CRLF）'; return $false }
    if ($Text -match "`r(?!`n)") { $Problem.Value = '存在裸 CR 行尾（应为 CRLF）'; return $false }
    if ($Text -notmatch "`r`n") { $Problem.Value = '整份文件没有 CRLF 行尾'; return $false }
    $Problem.Value = ''
    return $true
}

function Get-RelPath([string]$Root, [string]$FullPath) {
    $r = $Root.TrimEnd('\')
    if ($FullPath.Length -le $r.Length) { throw "无法计算相对路径：$FullPath" }
    return $FullPath.Substring($r.Length).TrimStart('\').Replace('\', '/')
}

# ---------------------------------------------------------------------------
# 起步
# ---------------------------------------------------------------------------
$discPath = (Resolve-FullPath $Disc).TrimEnd('\')

Write-Host ''
Write-Host 'DiscPersona 光盘静态校验' -ForegroundColor White
Write-Host "  目录：$discPath"

if (-not (Test-Path -LiteralPath $discPath -PathType Container)) {
    Write-Host ''
    Write-Host "  ✗ 目录不存在或不是目录：$discPath" -ForegroundColor Red
    Write-Host ''
    Write-Host 'FAIL' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 1. 必需文件
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[必需文件]' -ForegroundColor Cyan

$requiredFiles = @(
    'autorun.inf',
    'start.cmd',
    'README.txt',
    'pad.bin',
    '.discpersona\manifest.json',
    'persona\meta.json',
    'persona\persona.yml'
)
foreach ($rel in $requiredFiles) {
    $full = Join-Path $discPath $rel
    Add-Check "存在 $rel" (Test-Path -LiteralPath $full -PathType Leaf) '文件缺失'
}

# ---------------------------------------------------------------------------
# 2. manifest.json
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[manifest.json]' -ForegroundColor Cyan

$manifestPath = Join-Path $discPath '.discpersona\manifest.json'
$manifest = $null
$manifestUsable = $false

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $bytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Add-Check 'manifest.json 是 UTF-8 无 BOM' (-not $hasBom) '检测到 UTF-8 BOM（规范要求无 BOM）'

    $text = Read-TextFile $manifestPath

    # 缩进规范：2 空格、`": "` 分隔（Windows PowerShell 5.1 的 ConvertTo-Json 会写出 `":  "`）
    $indentProblem = ''
    foreach ($ln in ($text -split "`r?`n")) {
        if ($ln.Trim().Length -eq 0) { continue }
        if ($ln -match '^\s*"[^"\r\n]*":\s{2}') { $indentProblem = "冒号后不止一个空格：$($ln.Trim())"; break }
        $lead = 0
        while ($lead -lt $ln.Length -and $ln[$lead] -eq ' ') { $lead++ }
        if (($lead % 2) -ne 0) { $indentProblem = "缩进不是 2 的倍数：$($ln.Trim())"; break }
    }
    Add-Check 'manifest.json 缩进 2 空格、冒号后一个空格' ([string]::IsNullOrEmpty($indentProblem)) $indentProblem

    try {
        $manifest = $text | ConvertFrom-Json
        $manifestUsable = $true
        Add-Check 'manifest.json 可解析为 JSON' $true
    } catch {
        Add-Check 'manifest.json 可解析为 JSON' $false $_.Exception.Message
    }

    if ($manifestUsable) {
        $format = $manifest.format
        Add-Check 'manifest.format = 1' ($format -eq 1) "实际：$format"

        $missingFields = New-Object System.Collections.Generic.List[string]
        foreach ($f in @('discID', 'name', 'version', 'builtAt', 'engine')) {
            $v = $manifest.PSObject.Properties[$f]
            if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v.Value)) { $missingFields.Add($f) }
        }
        Add-Check 'manifest 必填字段齐全（discID/name/version/builtAt/engine）' `
            ($missingFields.Count -eq 0) ("缺：" + ($missingFields -join ', '))

        $discIdText = [string]$manifest.discID
        Add-Check 'manifest.discID 是 16 位小写十六进制' ($discIdText -cmatch '^[0-9a-f]{16}$') "实际：$discIdText"

        $filesProp = $manifest.PSObject.Properties['files']
        Add-Check 'manifest.files 是非空对象' `
            ($null -ne $filesProp -and $null -ne $filesProp.Value -and @($filesProp.Value.PSObject.Properties).Count -gt 0) `
            'files 缺失或为空（至少应含 persona 文件）'

        # pad.bin 是 discID 的唯一来源，必须在哈希表里，否则它被改掉也发现不了
        $padEntry = $null
        if ($null -ne $filesProp -and $null -ne $filesProp.Value) {
            $padEntry = $filesProp.Value.PSObject.Properties['pad.bin']
        }
        Add-Check 'manifest.files 含 pad.bin（改了 pad.bin 就该校验失败）' ($null -ne $padEntry) 'files 里没有 pad.bin'
    }
} else {
    Add-Check 'manifest.json 存在，可做后续校验' $false '文件缺失，跳过 manifest 检查'
}

# ---------------------------------------------------------------------------
# 3. pad.bin / discID
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[pad.bin 与 discID]' -ForegroundColor Cyan

$padPath = Join-Path $discPath 'pad.bin'
$discIDFromPad = $null

if (Test-Path -LiteralPath $padPath -PathType Leaf) {
    $padBytes = [System.IO.File]::ReadAllBytes($padPath)
    Add-Check 'pad.bin 恰好 512 字节' ($padBytes.Length -eq 512) "实际：$($padBytes.Length) 字节"

    if ($padBytes.Length -ge 18) {
        $magic = [System.Text.Encoding]::ASCII.GetString($padBytes, 0, 18)
        Add-Check 'pad.bin 魔数为 DISCPERSONA-PAD-V1' ($magic -ceq 'DISCPERSONA-PAD-V1') "实际：'$magic'"
    } else {
        Add-Check 'pad.bin 魔数为 DISCPERSONA-PAD-V1' $false '文件太短，读不到魔数'
    }

    if ($padBytes.Length -ge 96) {
        $stamp = [System.Text.Encoding]::ASCII.GetString($padBytes, 64, 32).Trim([char]0, [char]32)
        Add-Check 'pad.bin 含 ISO8601(UTC) 生成时间' `
            ($stamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') "读到：'$stamp'"
    } else {
        Add-Check 'pad.bin 含 ISO8601(UTC) 生成时间' $false '文件太短，读不到时间戳'
    }

    $padHash = (Get-FileHash -LiteralPath $padPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $discIDFromPad = $padHash.Substring(0, 16)
    Add-NoteLine "由 pad.bin 算出的 discID：$discIDFromPad"

    $hashProp = if ($manifestUsable) { $manifest.PSObject.Properties['discID'] } else { $null }
    if ($hashProp) {
        Add-Check 'manifest.discID 与 pad.bin 一致' `
            ([string]$hashProp.Value -eq $discIDFromPad) `
            "manifest=$($hashProp.Value)  pad.bin=$discIDFromPad"
    } else {
        Add-Check 'manifest.discID 与 pad.bin 一致' $false 'manifest 不可用，无法比对'
    }
} else {
    Add-Check 'pad.bin 存在，可做后续校验' $false '文件缺失'
}

# ---------------------------------------------------------------------------
# 4. persona 侧一致性
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[persona]' -ForegroundColor Cyan

$metaPath = Join-Path $discPath 'persona\meta.json'
if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
    $meta = $null
    $metaOk = $false
    try {
        $meta = (Read-TextFile $metaPath) | ConvertFrom-Json
        $metaOk = $true
        Add-Check 'persona\meta.json 可解析为 JSON' $true
    } catch {
        Add-Check 'persona\meta.json 可解析为 JSON' $false $_.Exception.Message
    }
    if ($metaOk) {
        $metaMissing = New-Object System.Collections.Generic.List[string]
        foreach ($f in @('name')) {
            $p = $meta.PSObject.Properties[$f]
            if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.Value)) { $metaMissing.Add($f) }
        }
        # 现役人设包用 personaVersion 记版本号，两种都认
        $metaVer = [string]$meta.version
        if ([string]::IsNullOrWhiteSpace($metaVer)) { $metaVer = [string]$meta.personaVersion }
        if ([string]::IsNullOrWhiteSpace($metaVer)) { $metaMissing.Add('version/personaVersion') }
        Add-Check 'persona\meta.json 含 name / version' ($metaMissing.Count -eq 0) ("缺：" + ($metaMissing -join ', '))

        $metaDisc = [string]$meta.discID
        if ($manifestUsable) {
            Add-Check 'persona\meta.json 的 discID 与 manifest 一致' `
                ($metaDisc -eq [string]$manifest.discID) `
                "meta=$metaDisc  manifest=$($manifest.discID)"
        }
    }
}

$ymlPath = Join-Path $discPath 'persona\persona.yml'
if (Test-Path -LiteralPath $ymlPath -PathType Leaf) {
    $yml = Read-TextFile $ymlPath
    Add-Check 'persona\persona.yml 含 system_prompt:' ($yml -match '(?m)system_prompt\s*:') '没有找到 system_prompt: 键'
} else {
    Add-Check 'persona\persona.yml 含 system_prompt:' $false '文件缺失'
}

# ---------------------------------------------------------------------------
# 5. 哈希与多余文件
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[文件完整性]' -ForegroundColor Cyan

$manifestFiles = $null
if ($manifestUsable) {
    $filesProp = $manifest.PSObject.Properties['files']
    if ($filesProp) { $manifestFiles = $filesProp.Value }
}

if ($null -ne $manifestFiles) {
    $entries = @($manifestFiles.PSObject.Properties)
    $bad = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]

    $discFull = [System.IO.Path]::GetFullPath($discPath).TrimEnd('\') + '\'
    foreach ($entry in $entries) {
        $rel = [string]$entry.Name
        # manifest 来自不可信介质：键必须是盘内相对路径，不许 .. 或绝对路径逃出盘根
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath((Join-Path $discPath ($rel.Replace('/', '\')))) } catch { $full = $null }
        if (-not $full -or -not $full.StartsWith($discFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $bad.Add("$rel（非法路径，已跳过）")
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $missing.Add($rel)
            continue
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = ([string]$entry.Value).ToLowerInvariant()
        if ($actual -ne $expected) {
            $bad.Add("$rel（期望 $expected，实际 $actual）")
        }
    }

    $detail = @()
    if ($missing.Count -gt 0) { $detail += ('缺失：' + ($missing -join '；')) }
    if ($bad.Count -gt 0)    { $detail += ('哈希不符：' + ($bad -join '；')) }
    Add-Check "manifest 内 $($entries.Count) 个文件的 SHA-256 都与磁盘一致" `
        ($missing.Count -eq 0 -and $bad.Count -eq 0) ($detail -join ' / ')

    # 反向：磁盘上是否有 manifest 之外的文件
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) { [void]$allowed.Add(([string]$entry.Name).Replace('\', '/')) }
    [void]$allowed.Add('pad.bin')
    [void]$allowed.Add('.discpersona/manifest.json')

    $extra = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $discPath -Recurse -Force)) {
        if ($file.PSIsContainer) { continue }
        $rel = Get-RelPath -Root $discPath -FullPath $file.FullName
        if (-not $allowed.Contains($rel)) { $extra.Add($rel) }
    }
    $extraDetail = if ($extra.Count -gt 0) {
        '多余：' + ($extra -join '；') + '（Thumbs.db / desktop.ini 之类系统生成的文件也会算多余，校验前先删掉）'
    } else { '' }
    Add-Check '没有 manifest 之外的多余文件' ($extra.Count -eq 0) $extraDetail
} else {
    Add-Check '文件哈希可校验' $false 'manifest 不可用或没有 files'
}

# ---------------------------------------------------------------------------
# 6. start.cmd
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[start.cmd]' -ForegroundColor Cyan

$startPath = Join-Path $discPath 'start.cmd'
if (Test-Path -LiteralPath $startPath -PathType Leaf) {
    $startBytes = [System.IO.File]::ReadAllBytes($startPath)
    Add-Check 'start.cmd 非空' ($startBytes.Length -gt 0) '文件是 0 字节'

    $bom = ($startBytes.Length -ge 3 -and $startBytes[0] -eq 0xEF -and $startBytes[1] -eq 0xBB -and $startBytes[2] -eq 0xBF)
    $utf16 = ($startBytes.Length -ge 2 -and $startBytes[0] -eq 0xFF -and $startBytes[1] -eq 0xFE)
    Add-Check 'start.cmd 不带 BOM（cmd.exe 才吃得下）' (-not $bom -and -not $utf16) `
        $(if ($utf16) { 'UTF-16 编码，cmd.exe 无法执行' } else { 'UTF-8 BOM 可能被 cmd.exe 当成命令' })

    $text = Read-TextFile $startPath
    $problem = ''
    $crlfOk = Test-Crlf -Text $text -Problem ([ref]$problem)
    Add-Check 'start.cmd 使用 CRLF 行尾' $crlfOk $problem

    if ($text -match 'placeholder start\.cmd') {
        Add-NoteLine 'start.cmd 是占位版本（打包时工作区没有 start.cmd）——这张盘还不能启动。'
    }
} else {
    Add-Check 'start.cmd 存在，可做后续校验' $false '文件缺失'
}

# ---------------------------------------------------------------------------
# 7. engine（可选，缺失只提示不判失败）
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[engine（可选）]' -ForegroundColor Cyan

$engineDir = Join-Path $discPath 'engine'
if (Test-Path -LiteralPath $engineDir -PathType Container) {
    $engineFiles = @(Get-ChildItem -LiteralPath $engineDir -Recurse -Force -File)
    if ($engineFiles.Count -eq 0) {
        Add-NoteLine 'engine\ 存在但是空的——盘上没有引擎，启动会报错 1。'
    } else {
        Add-Check "engine\ 有 $($engineFiles.Count) 个文件" $true
    }
} else {
    Add-NoteLine '盘上没有 engine\（打包时工作区没有引擎）——启动会报错 1。'
}


# ---------------------------------------------------------------------------
# 8. autorun.inf
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[autorun.inf]' -ForegroundColor Cyan

$autorunPath = Join-Path $discPath 'autorun.inf'
if (Test-Path -LiteralPath $autorunPath -PathType Leaf) {
    $autorunBytes = [System.IO.File]::ReadAllBytes($autorunPath)
    $isUtf16 = ($autorunBytes.Length -ge 2 -and $autorunBytes[0] -eq 0xFF -and $autorunBytes[1] -eq 0xFE)
    if ($isUtf16) {
        Add-NoteLine '编码 UTF-16LE（含中文标签/动作行，Windows 原生支持）'
    } else {
        Add-NoteLine '编码 ASCII/UTF-8'
    }

    $autorunText = Read-TextFile $autorunPath
    $hasOpen = $autorunText -match '(?m)^\s*open=start\.cmd\s*$'
    Add-Check 'autorun.inf 含 open=start.cmd' $hasOpen '缺少 open=start.cmd 行'

    Add-Check 'autorun.inf 含 label=' ($autorunText -match '(?m)^\s*label=.+$') '缺少 label 行'

    $problem = ''
    $crlfOk = Test-Crlf -Text $autorunText -Problem ([ref]$problem)
    Add-Check 'autorun.inf 使用 CRLF 行尾' $crlfOk $problem

    $iconMatch = [regex]::Match($autorunText, '(?m)^\s*icon=(.+?)\s*$')
    if ($iconMatch.Success) {
        $iconRel = $iconMatch.Groups[1].Value.Trim().Replace('/', '\')
        $iconFull = Join-Path $discPath $iconRel
        Add-Check "autorun.inf 的 icon 指向存在的文件（$iconRel）" (Test-Path -LiteralPath $iconFull -PathType Leaf) 'icon 行指向的文件不存在'
    } else {
        Add-NoteLine '没有 icon 行（人设包没有 avatar.ico 时这是正常的）'
    }
} else {
    Add-Check 'autorun.inf 存在，可做后续校验' $false '文件缺失'
}

# ---------------------------------------------------------------------------
# 9. README.txt
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[README.txt]' -ForegroundColor Cyan

$readmePath = Join-Path $discPath 'README.txt'
if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
    $readmeText = Read-TextFile $readmePath
    Add-Check 'README.txt 非空' ($readmeText.Trim().Length -gt 0) '文件只有空白'
    Add-Check 'README.txt 提到 home 目录' ($readmeText -match 'LOCALAPPDATA') '没有说明 home 落在哪'
    $problem = ''
    $crlfOk = Test-Crlf -Text $readmeText -Problem ([ref]$problem)
    Add-Check 'README.txt 使用 CRLF 行尾' $crlfOk $problem
} else {
    Add-Check 'README.txt 存在，可做后续校验' $false '文件缺失'
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
$total = $script:PassCount + $script:FailCount
Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host "  检查项：$total    通过：$($script:PassCount)    失败：$($script:FailCount)"
if ($manifestUsable) {
    Write-Host "  discID：$([string]$manifest.discID)    名称：$([string]$manifest.name)    版本：$([string]$manifest.version)"
}
if ($discIDFromPad) { Write-Host "  pad.bin 算出：$discIDFromPad" }
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray

if ($script:FailCount -eq 0) {
    Write-Host ''
    Write-Host 'PASS' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ''
Write-Host '失败项：' -ForegroundColor Red
foreach ($f in $script:Failures) { Write-Host "  ✗ $f" -ForegroundColor Red }
Write-Host ''
Write-Host 'FAIL' -ForegroundColor Red
Write-Host ''
exit 1
