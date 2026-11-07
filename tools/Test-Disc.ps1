<#
.SYNOPSIS
    Static check of a disc tree produced by New-Disc.ps1 (does not start DSH, no network).

.DESCRIPTION
    Checks, one by one:
      - required files present (autorun.inf / start.cmd / README.txt / pad.bin /
        .discpersona\manifest.json / persona\meta.json / (persona\persona.yml or persona\persona.sealed))
      - manifest.json is UTF-8 without BOM, parses, format=1, required fields present
      - every SHA-256 in the manifest matches the file on disc (missing files included)
      - the disc has no files beyond the manifest
      - pad.bin is exactly 512 bytes, magic correct, timestamp field is ISO8601(UTC)
      - manifest.discID is derived from pad.bin (first 16 lowercase hex chars)
      - persona\meta.json discID matches the manifest
      - persona\persona.yml contains system_prompt: (plaintext discs)
      - persona\persona.sealed is a diskLIFE sealed file and no plaintext persona files remain (encrypted discs)
      - start.cmd / autorun.inf use CRLF (start.cmd must not have a BOM)
      - autorun.inf contains open=start.cmd and the file its icon points at exists

    Each check prints a green check or a red cross; the run ends with PASS / FAIL and an exit code (PASS=0, FAIL=1).

.PARAMETER Disc
    Root of the disc tree (e.g. D:\build\disc or a full copy of the disc on disk).

.EXAMPLE
    .\Test-Disc.ps1 -Disc D:\build\disc
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Root of the disc tree')]
    [string]$Disc
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:PassCount = 0
$script:FailCount = 0
$script:Failures   = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Small helpers
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
        if ($Detail) { [void]$script:Failures.Add("$Label - $Detail") } else { [void]$script:Failures.Add($Label) }
        Write-Host "  ✗ $Label" -ForegroundColor Red
        if ($Detail) { Write-Host "      $Detail" -ForegroundColor Yellow }
    }
}

function Add-NoteLine([string]$Text) {
    Write-Host "  · $Text" -ForegroundColor DarkGray
}

function Test-Crlf([string]$Text, [ref]$Problem) {
    if ($Text -match "[^`r]`n") { $Problem.Value = 'found a bare LF line ending (expected CRLF)'; return $false }
    if ($Text -match "`r(?!`n)") { $Problem.Value = 'found a bare CR line ending (expected CRLF)'; return $false }
    if ($Text -notmatch "`r`n") { $Problem.Value = 'the whole file has no CRLF line endings'; return $false }
    $Problem.Value = ''
    return $true
}

function Get-RelPath([string]$Root, [string]$FullPath) {
    $r = $Root.TrimEnd('\')
    if ($FullPath.Length -le $r.Length) { throw "Cannot compute a relative path: $FullPath" }
    return $FullPath.Substring($r.Length).TrimStart('\').Replace('\', '/')
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
$discPath = (Resolve-FullPath $Disc).TrimEnd('\')

Write-Host ''
Write-Host 'DiscPersona disc static check' -ForegroundColor White
Write-Host "  Directory: $discPath"

if (-not (Test-Path -LiteralPath $discPath -PathType Container)) {
    Write-Host ''
    Write-Host "  ✗ Directory missing or not a directory: $discPath" -ForegroundColor Red
    Write-Host ''
    Write-Host 'FAIL' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Required files
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[required files]' -ForegroundColor Cyan

$requiredFiles = @(
    'autorun.inf',
    'start.cmd',
    'README.txt',
    'pad.bin',
    '.discpersona\manifest.json',
    'persona\meta.json'
)
foreach ($rel in $requiredFiles) {
    $full = Join-Path $discPath $rel
    Add-Check "exists: $rel" (Test-Path -LiteralPath $full -PathType Leaf) 'file missing'
}
$hasPlainPersona = Test-Path -LiteralPath (Join-Path $discPath 'persona\persona.yml') -PathType Leaf
$hasSealedPersona = Test-Path -LiteralPath (Join-Path $discPath 'persona\persona.sealed') -PathType Leaf
Add-Check 'persona is present (persona.yml or persona.sealed)' ($hasPlainPersona -or $hasSealedPersona) 'neither exists'

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
    Add-Check 'manifest.json is UTF-8 without BOM' (-not $hasBom) 'found a UTF-8 BOM (the spec requires none)'

    $text = Read-TextFile $manifestPath

    # Indent style: 2 spaces, `": "` separator (Windows PowerShell 5.1 ConvertTo-Json writes `":  "`)
    $indentProblem = ''
    foreach ($ln in ($text -split "`r?`n")) {
        if ($ln.Trim().Length -eq 0) { continue }
        if ($ln -match '^\s*"[^"\r\n]*":\s{2}') { $indentProblem = "more than one space after a colon: $($ln.Trim())"; break }
        $lead = 0
        while ($lead -lt $ln.Length -and $ln[$lead] -eq ' ') { $lead++ }
        if (($lead % 2) -ne 0) { $indentProblem = "indent is not a multiple of 2: $($ln.Trim())"; break }
    }
    Add-Check 'manifest.json uses 2-space indent and one space after the colon' ([string]::IsNullOrEmpty($indentProblem)) $indentProblem

    try {
        $manifest = $text | ConvertFrom-Json
        $manifestUsable = $true
        Add-Check 'manifest.json parses as JSON' $true
    } catch {
        Add-Check 'manifest.json parses as JSON' $false $_.Exception.Message
    }

    if ($manifestUsable) {
        $format = $manifest.format
        Add-Check 'manifest.format = 1' ($format -eq 1) "actual: $format"

        $missingFields = New-Object System.Collections.Generic.List[string]
        foreach ($f in @('discID', 'name', 'version', 'builtAt', 'engine')) {
            $v = $manifest.PSObject.Properties[$f]
            if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v.Value)) { $missingFields.Add($f) }
        }
        Add-Check 'manifest has all required fields (discID/name/version/builtAt/engine)' `
            ($missingFields.Count -eq 0) ("missing: " + ($missingFields -join ', '))

        $discIdText = [string]$manifest.discID
        Add-Check 'manifest.discID is 16 lowercase hex chars' ($discIdText -cmatch '^[0-9a-f]{16}$') "actual: $discIdText"

        $filesProp = $manifest.PSObject.Properties['files']
        Add-Check 'manifest.files is a non-empty object' `
            ($null -ne $filesProp -and $null -ne $filesProp.Value -and @($filesProp.Value.PSObject.Properties).Count -gt 0) `
            'files missing or empty (should at least contain the persona files)'

        # pad.bin is the only source of discID, so it must be in the hash table; otherwise edits go unnoticed
        $padEntry = $null
        if ($null -ne $filesProp -and $null -ne $filesProp.Value) {
            $padEntry = $filesProp.Value.PSObject.Properties['pad.bin']
        }
        Add-Check 'manifest.files contains pad.bin (editing pad.bin must fail this check)' ($null -ne $padEntry) 'files has no pad.bin'
    }
} else {
    Add-Check 'manifest.json exists so later checks can run' $false 'file missing, skipping the manifest checks'
}

# ---------------------------------------------------------------------------
# 3. pad.bin / discID
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[pad.bin and discID]' -ForegroundColor Cyan

$padPath = Join-Path $discPath 'pad.bin'
$discIDFromPad = $null

if (Test-Path -LiteralPath $padPath -PathType Leaf) {
    $padBytes = [System.IO.File]::ReadAllBytes($padPath)
    Add-Check 'pad.bin is exactly 512 bytes' ($padBytes.Length -eq 512) "actual: $($padBytes.Length) bytes"

    if ($padBytes.Length -ge 18) {
        $magic = [System.Text.Encoding]::ASCII.GetString($padBytes, 0, 18)
        Add-Check 'pad.bin magic is DISCPERSONA-PAD-V1' ($magic -ceq 'DISCPERSONA-PAD-V1') "actual: '$magic'"
    } else {
        Add-Check 'pad.bin magic is DISCPERSONA-PAD-V1' $false 'file too short to read the magic'
    }

    if ($padBytes.Length -ge 96) {
        $stamp = [System.Text.Encoding]::ASCII.GetString($padBytes, 64, 32).Trim([char]0, [char]32)
        Add-Check 'pad.bin has an ISO8601(UTC) build time' `
            ($stamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') "read: '$stamp'"
    } else {
        Add-Check 'pad.bin has an ISO8601(UTC) build time' $false 'file too short to read the timestamp'
    }

    $padHash = (Get-FileHash -LiteralPath $padPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $discIDFromPad = $padHash.Substring(0, 16)
    Add-NoteLine "discID computed from pad.bin: $discIDFromPad"

    $hashProp = if ($manifestUsable) { $manifest.PSObject.Properties['discID'] } else { $null }
    if ($hashProp) {
        Add-Check 'manifest.discID matches pad.bin' `
            ([string]$hashProp.Value -eq $discIDFromPad) `
            "manifest=$($hashProp.Value)  pad.bin=$discIDFromPad"
    } else {
        Add-Check 'manifest.discID matches pad.bin' $false 'manifest unusable, cannot compare'
    }
} else {
    Add-Check 'pad.bin exists so later checks can run' $false 'file missing'
}

# ---------------------------------------------------------------------------
# 4. persona-side consistency
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
        Add-Check 'persona\meta.json parses as JSON' $true
    } catch {
        Add-Check 'persona\meta.json parses as JSON' $false $_.Exception.Message
    }
    if ($metaOk) {
        $metaMissing = New-Object System.Collections.Generic.List[string]
        foreach ($f in @('name')) {
            $p = $meta.PSObject.Properties[$f]
            if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.Value)) { $metaMissing.Add($f) }
        }
        # Current persona packs store the version in personaVersion; accept both
        $metaVer = [string]$meta.version
        if ([string]::IsNullOrWhiteSpace($metaVer)) { $metaVer = [string]$meta.personaVersion }
        if ([string]::IsNullOrWhiteSpace($metaVer)) { $metaMissing.Add('version/personaVersion') }
        Add-Check 'persona\meta.json has name / version' ($metaMissing.Count -eq 0) ("missing: " + ($metaMissing -join ', '))

        $metaDisc = [string]$meta.discID
        if ($manifestUsable) {
            Add-Check 'persona\meta.json discID matches the manifest' `
                ($metaDisc -eq [string]$manifest.discID) `
                "meta=$metaDisc  manifest=$($manifest.discID)"
        }
    }
}

$ymlPath = Join-Path $discPath 'persona\persona.yml'
$sealedPath = Join-Path $discPath 'persona\persona.sealed'
if (Test-Path -LiteralPath $sealedPath -PathType Leaf) {
    $sealedBytes = [System.IO.File]::ReadAllBytes($sealedPath)
    $magic = ''
    if ($sealedBytes.Length -ge 10) { $magic = [System.Text.Encoding]::ASCII.GetString($sealedBytes, 0, 10) }
    Add-Check 'persona\persona.sealed is a diskLIFE sealed file' (($magic -ceq 'DLIFESEAL1') -and ($sealedBytes.Length -gt 60)) 'bad magic or truncated sealed payload'
    $leftovers = New-Object System.Collections.Generic.List[string]
    $personaDir = Join-Path $discPath 'persona'
    foreach ($item in @(Get-ChildItem -LiteralPath $personaDir -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        $rel = $item.FullName.Substring($personaDir.Length).TrimStart('\').Replace('\', '/')
        if ($rel -eq 'meta.json' -or $rel -eq 'persona.sealed') { continue }
        if ($rel -match '^avatar\.(png|ico)$') { continue }
        $leftovers.Add($rel)
    }
    Add-Check 'no plaintext persona files next to persona.sealed' ($leftovers.Count -eq 0) ('plaintext: ' + (($leftovers | Select-Object -First 8) -join ', '))
    Add-NoteLine 'the persona is encrypted; the first boot asks for its passphrase'
} elseif (Test-Path -LiteralPath $ymlPath -PathType Leaf) {
    $yml = Read-TextFile $ymlPath
    Add-Check 'persona\persona.yml contains system_prompt:' ($yml -match '(?m)system_prompt\s*:') 'system_prompt: key not found'
} else {
    Add-Check 'persona\persona.yml or persona\persona.sealed exists' $false 'both are missing'
}

# ---------------------------------------------------------------------------
# 5. Hashes and extra files
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[file integrity]' -ForegroundColor Cyan

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
        # The manifest comes from untrusted media: keys must be relative disc paths, no .. or absolute escape
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath((Join-Path $discPath ($rel.Replace('/', '\')))) } catch { $full = $null }
        if (-not $full -or -not $full.StartsWith($discFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $bad.Add("$rel (illegal path, skipped)")
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $missing.Add($rel)
            continue
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = ([string]$entry.Value).ToLowerInvariant()
        if ($actual -ne $expected) {
            $bad.Add("$rel (expected $expected, actual $actual)")
        }
    }

    $detail = @()
    if ($missing.Count -gt 0) { $detail += ('missing: ' + ($missing -join '; ')) }
    if ($bad.Count -gt 0)    { $detail += ('hash mismatch: ' + ($bad -join '; ')) }
    Add-Check "SHA-256 of all $($entries.Count) files in the manifest match the disc" `
        ($missing.Count -eq 0 -and $bad.Count -eq 0) ($detail -join ' / ')

    # Reverse direction: does the disc hold files outside the manifest?
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
        'extra: ' + ($extra -join '; ') + ' (system files such as Thumbs.db / desktop.ini also count as extra; delete them before checking)'
    } else { '' }
    Add-Check 'no extra files beyond the manifest' ($extra.Count -eq 0) $extraDetail
} else {
    Add-Check 'file hashes can be checked' $false 'manifest unusable or has no files'
}

# ---------------------------------------------------------------------------
# 6. start.cmd
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[start.cmd]' -ForegroundColor Cyan

$startPath = Join-Path $discPath 'start.cmd'
if (Test-Path -LiteralPath $startPath -PathType Leaf) {
    $startBytes = [System.IO.File]::ReadAllBytes($startPath)
    Add-Check 'start.cmd is not empty' ($startBytes.Length -gt 0) 'file is 0 bytes'

    $bom = ($startBytes.Length -ge 3 -and $startBytes[0] -eq 0xEF -and $startBytes[1] -eq 0xBB -and $startBytes[2] -eq 0xBF)
    $utf16 = ($startBytes.Length -ge 2 -and $startBytes[0] -eq 0xFF -and $startBytes[1] -eq 0xFE)
    Add-Check 'start.cmd has no BOM (cmd.exe needs it that way)' (-not $bom -and -not $utf16) `
        $(if ($utf16) { 'UTF-16 encoded; cmd.exe cannot run it' } else { 'a UTF-8 BOM may be treated as a command by cmd.exe' })

    $text = Read-TextFile $startPath
    $problem = ''
    $crlfOk = Test-Crlf -Text $text -Problem ([ref]$problem)
    Add-Check 'start.cmd uses CRLF line endings' $crlfOk $problem

    if ($text -match 'placeholder start\.cmd') {
        Add-NoteLine 'start.cmd is a placeholder (the workspace had no start.cmd when packing) - this disc cannot start yet.'
    }
} else {
    Add-Check 'start.cmd exists so later checks can run' $false 'file missing'
}

# ---------------------------------------------------------------------------
# 7. engine (optional; a missing engine is only a note, not a failure)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[engine (optional)]' -ForegroundColor Cyan

$engineDir = Join-Path $discPath 'engine'
if (Test-Path -LiteralPath $engineDir -PathType Container) {
    $engineFiles = @(Get-ChildItem -LiteralPath $engineDir -Recurse -Force -File)
    if ($engineFiles.Count -eq 0) {
        Add-NoteLine 'engine\ exists but is empty - no engine on the disc; starting will fail with code 1.'
    } else {
        Add-Check "engine\ has $($engineFiles.Count) files" $true
    }
} else {
    Add-NoteLine 'no engine\ on the disc (the workspace had no engine when packing) - starting will fail with code 1.'
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
        Add-NoteLine 'encoding UTF-16LE (label/action lines may contain non-ASCII; Windows supports this natively)'
    } else {
        Add-NoteLine 'encoding ASCII/UTF-8'
    }

    $autorunText = Read-TextFile $autorunPath
    $hasOpen = $autorunText -match '(?m)^\s*open=start\.cmd\s*$'
    Add-Check 'autorun.inf contains open=start.cmd' $hasOpen 'missing the open=start.cmd line'

    Add-Check 'autorun.inf contains label=' ($autorunText -match '(?m)^\s*label=.+$') 'missing the label line'

    $problem = ''
    $crlfOk = Test-Crlf -Text $autorunText -Problem ([ref]$problem)
    Add-Check 'autorun.inf uses CRLF line endings' $crlfOk $problem

    $iconMatch = [regex]::Match($autorunText, '(?m)^\s*icon=(.+?)\s*$')
    if ($iconMatch.Success) {
        $iconRel = $iconMatch.Groups[1].Value.Trim().Replace('/', '\')
        $iconFull = Join-Path $discPath $iconRel
        Add-Check "autorun.inf icon points at an existing file ($iconRel)" (Test-Path -LiteralPath $iconFull -PathType Leaf) 'the file named on the icon line does not exist'
    } else {
        Add-NoteLine 'no icon line (normal when the persona pack has no avatar.ico)'
    }
} else {
    Add-Check 'autorun.inf exists so later checks can run' $false 'file missing'
}

# ---------------------------------------------------------------------------
# 9. README.txt
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[README.txt]' -ForegroundColor Cyan

$readmePath = Join-Path $discPath 'README.txt'
if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
    $readmeText = Read-TextFile $readmePath
    Add-Check 'README.txt is not empty' ($readmeText.Trim().Length -gt 0) 'file contains only whitespace'
    Add-Check 'README.txt mentions the home directory' ($readmeText -match 'LOCALAPPDATA') 'does not say where home lives'
    $problem = ''
    $crlfOk = Test-Crlf -Text $readmeText -Problem ([ref]$problem)
    Add-Check 'README.txt uses CRLF line endings' $crlfOk $problem
} else {
    Add-Check 'README.txt exists so later checks can run' $false 'file missing'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$total = $script:PassCount + $script:FailCount
Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host "  Checks: $total    Passed: $($script:PassCount)    Failed: $($script:FailCount)"
if ($manifestUsable) {
    Write-Host "  discID: $([string]$manifest.discID)    Name: $([string]$manifest.name)    Version: $([string]$manifest.version)"
}
if ($discIDFromPad) { Write-Host "  pad.bin computes: $discIDFromPad" }
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray

if ($script:FailCount -eq 0) {
    Write-Host ''
    Write-Host 'PASS' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ''
Write-Host 'Failed checks:' -ForegroundColor Red
foreach ($f in $script:Failures) { Write-Host "  ✗ $f" -ForegroundColor Red }
Write-Host ''
Write-Host 'FAIL' -ForegroundColor Red
Write-Host ''
exit 1
