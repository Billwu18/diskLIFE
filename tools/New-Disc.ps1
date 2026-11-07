<#
.SYNOPSIS
    Package a persona pack into a disc tree that can be burned to CD-R as-is.

.DESCRIPTION
    Output layout (the launcher looks up files along these paths):

        <out>\autorun.inf
        <out>\start.cmd
        <out>\README.txt
        <out>\pad.bin                      512-byte disc identity file (the only source of discID)
        <out>\engine\...                   copy of the workspace engine\ (skipped with a warning if absent)
        <out>\persona\...                  copy of the persona pack
        <out>\.discpersona\manifest.json   file hash manifest
        <out>\.discpersona\payload\...     copy of payload\profile-web (or build\payload\profile-web), if present

    Everything is written to <out>.tmp first and renamed atomically to <out> on success;
    any failure clears the temp directory: no half-built tree, and an existing <out> is left untouched.

    discID is the first 16 lowercase hex chars of the SHA-256 of pad.bin. When rebuilding the same disc,
    pass -ReusePad to reuse <out>\pad.bin and keep discID unchanged.

.PARAMETER Persona
    Persona pack directory. Must contain meta.json (name / version) and a persona.yml with system_prompt:.
    If meta.json has no discID, the discID computed from pad.bin is written into the output copy (source untouched).

.PARAMETER Out
    Output disc directory. Rebuilt from scratch; if it already exists it is replaced wholesale (rolled back on failure).

.PARAMETER ReusePad
    If <out>\pad.bin already exists and is valid, reuse it so discID stays the same.

.EXAMPLE
    .\New-Disc.ps1 -Persona ..\persona\dafeiyu -Out D:\build\disc

.EXAMPLE
    .\New-Disc.ps1 -Persona ..\persona\dafeiyu -Out D:\build\disc -ReusePad
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Persona pack directory')]
    [string]$Persona,

    [Parameter(Mandatory = $true, HelpMessage = 'Output disc directory')]
    [string]$Out,

    [switch]$ReusePad,

    [Parameter(HelpMessage = 'Payload preset: none / comfort / token / full (default comfort)')]
    [string]$PayloadPreset = 'comfort',

    [Parameter(HelpMessage = 'Allow overwriting a non-empty directory that is not a DiscPersona disc')]
    [switch]$Force,

    [Parameter(HelpMessage = 'Encrypt persona.yml/AGENTS.md/lorebook/seed into persona.sealed')]
    [switch]$SealPersona,

    [Parameter(HelpMessage = 'Read the seal passphrase from the first stdin line (automation)')]
    [switch]$PassphraseStdin
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Constants
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

# Error codes the launcher/engine may return. The short table in README.txt is generated from this.
$script:ErrorCodes = @(
    @(0, 'Normal exit'),
    @(1, 'Incomplete disc: engine\ is missing (usually an interrupted burn, or files missing from the disc)'),
    @(2, 'start.cmd is still the placeholder file; rebuild the disc'),
    @(3, 'No usable Node.js runtime found'),
    @(4, 'home directory cannot be created or is not writable (%LOCALAPPDATA% permissions / group policy)'),
    @(5, 'Disc read failed (disc removed, scratched, or drive failure)'),
    @(6, '.discpersona\manifest.json is missing or cannot be parsed'),
    @(7, 'discID check failed: pad.bin and manifest.json disagree (the disc was modified)'),
    @(8, 'Port already in use, or the browser failed to start')
)

# ---------------------------------------------------------------------------
# Output helpers
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
    Write-Host '[FAIL] Persona pack check failed; no files were written.' -ForegroundColor Red
    foreach ($m in $Messages) { Write-Host "  ✗ $m" -ForegroundColor Red }
    Write-Host ''
    exit 1
}

function Resolve-NodeExe {
    foreach ($name in @('node.exe', 'node')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    return $null
}

function ConvertFrom-SecurePassphrase {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
    }
}

function Fail-Seal {
    param([string]$Message)
    Write-Host ''
    Write-Host '[FAIL] Encrypted-persona step failed; no disc was written.' -ForegroundColor Red
    Write-Host ('  ✗ ' + $Message) -ForegroundColor Red
    Write-Host ''
    exit 1
}

function Invoke-SealPersonaWithNode {
    param(
        [Parameter(Mandatory = $true)][string]$SealScript,
        [Parameter(Mandatory = $true)][string]$PersonaDir,
        [Parameter(Mandatory = $true)][string]$Passphrase
    )
    $node = Resolve-NodeExe
    if (-not $node) {
        Fail-Seal 'Node.js was not found. DeepSeek Harness ships with Node.js; install it or put node.exe on PATH, then retry.'
    }
    if (-not (Test-Path -LiteralPath $SealScript -PathType Leaf)) {
        Fail-Seal ('The sealed-persona helper is missing: ' + $SealScript)
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = '"' + $SealScript + '" seal --dir "' + $PersonaDir + '" --passphrase-stdin'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Fail-Seal ('Cannot start the sealed-persona helper: ' + $_.Exception.Message)
    }
    $exitCode = $null
    try {
        $proc.StandardInput.WriteLine($Passphrase)
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
    } finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
        if ($proc) { $proc.Dispose() }
    }
    if ($exitCode -ne 0) {
        $detail = ([string]$stderr).Trim()
        if (-not $detail) { $detail = 'helper exited with code ' + $exitCode }
        Fail-Seal ('Cannot encrypt the persona: ' + $detail)
    }
    return $stdout
}

# ---------------------------------------------------------------------------
# Generic file helpers
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
    if ($FullPath.Length -le $r.Length) { throw "Cannot compute relative path: $FullPath (root: $Root)" }
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
        # Do not follow symlinks/junctions: the persona pack is external input, keep outside content off the disc
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Add-Warn ("Skipping symlink/junction (not burned to disc): " + $item.FullName)
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
    for ($i = 0; $i -lt $script:PadSize; $i++) { $bytes[$i] = 0x20 }   # fill with spaces so it reads as text

    $magicBytes = $script:EncAscii.GetBytes($script:PadMagic)
    [Array]::Copy($magicBytes, 0, $bytes, 0, $magicBytes.Length)

    $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $stampBytes = $script:EncAscii.GetBytes($stamp)
    if ($stampBytes.Length -gt $script:PadTsSize) { throw "Internal error: timestamp exceeds $($script:PadTsSize) bytes" }
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
# Text generation
# ---------------------------------------------------------------------------
function Limit-Label([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $n = $Max
    if ($n -gt 0 -and [char]::IsHighSurrogate($Text[$n - 1])) { $n-- }   # do not split a surrogate pair
    return $Text.Substring(0, $n)
}

function New-AutorunText([string]$DisplayName, [string]$Label, [string]$IconRel) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[autorun]')
    $lines.Add('open=start.cmd')
    if ($IconRel) { $lines.Add("icon=$IconRel") }
    $lines.Add("label=$Label")
    $lines.Add("action=Wake $DisplayName")
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
    $lines.Add('DiscPersona disc notes')
    $lines.Add('====================')
    $lines.Add('')
    $lines.Add('What this disc is')
    $lines.Add('--------------')
    $lines.Add("Name: $DisplayName")
    $lines.Add("Version: $PersonaVersion")
    $lines.Add("Disc ID (discID): $DiscID")
    $lines.Add("Built at (UTC): $BuiltAt")
    $lines.Add("Engine version: $EngineVersion")
    $lines.Add('')
    $lines.Add('This is a persona disc with its own launcher: the disc holds the persona pack (persona\), the runtime engine (engine\)')
    $lines.Add('and a launch script (start.cmd). The engine only reads from the disc and never writes to it - CD-R is read-only anyway.')
    $lines.Add('')
    $lines.Add('How to use')
    $lines.Add('------')
    $lines.Add('1. Insert the disc into the drive.')
    $lines.Add('2. Double-click start.cmd in the disc root; if autoplay appears, choose Run start.cmd.')
    $lines.Add('3. The browser opens the local page automatically. If it does not, copy the address printed in')
    $lines.Add('   the launch window into your browser.')
    $lines.Add('')
    $lines.Add('Where data lives (important)')
    $lines.Add('------------------')
    $lines.Add("On the disc: read-only persona and engine; normally never modified, and it cannot be modified.")
    $lines.Add("On the hard drive: %LOCALAPPDATA%\DiscPersona\personas\$DiscID")
    $lines.Add('      This is the home for this disc: sessions, memory, settings - all writable state lives here.')
    $lines.Add('      - a different discID = a different home, so discs do not interfere with each other;')
    $lines.Add('      - the same disc in another computer = a separate home there, with no automatic sync;')
    $lines.Add('      - to back up or migrate, copy the whole home directory.')
    $lines.Add('')
    $lines.Add('What happens if the home is deleted')
    $lines.Add('----------------')
    $lines.Add('It is the same as factory-resetting this disc on this machine: the next launch recreates an empty home and')
    $lines.Add('all conversations, memory and settings are lost. The persona on the disc is unaffected (it is read-only).')
    $lines.Add('')
    $lines.Add('What happens if the disc is removed')
    $lines.Add('------------')
    $lines.Add('- The run is interrupted: the engine cannot read disc resources, in-flight requests fail, the page may show errors.')
    $lines.Add('- Data already written to the home is kept (it is on the hard drive, unrelated to the disc).')
    $lines.Add('- Reinsert the disc and run start.cmd again to continue; the interrupted request is not retried automatically.')
    $lines.Add('')
    $lines.Add('The disc is read-only')
    $lines.Add('------------')
    $lines.Add('A CD-R cannot be written once it is finalized. Everything that needs writing goes to the home. If you see a')
    $lines.Add('read-only file system style error, check that the home is writable (%LOCALAPPDATA% not restricted by policy) instead of trying to fix the disc.')
    $lines.Add('')
    $lines.Add('Burning notes (do not burn it as a boot disc)')
    $lines.Add('------------------------')
    $lines.Add('This is a data disc, not a system boot disc:')
    $lines.Add('  - do not tick Make bootable disc / Bootable, and do not write a boot record with boot-disc tools;')
    $lines.Add('  - burn this directory as a data disc / files and folders disc;')
    $lines.Add('  - if start.cmd, persona\ and this file are visible in the disc root after burning, the burn is correct.')
    $lines.Add('')
    $lines.Add('Error code quick reference')
    $lines.Add('----------')
    foreach ($pair in $script:ErrorCodes) {
        $lines.Add(('  {0,-3}{1}' -f [string]$pair[0], [string]$pair[1]))
    }
    $lines.Add('')
    $lines.Add('What is on the disc')
    $lines.Add('----------')
    $lines.Add('  autorun.inf                  autoplay description (optional; manual double-click still works)')
    $lines.Add('  start.cmd                    launch script')
    $lines.Add('  README.txt                   this file')
    $lines.Add('  pad.bin                      512-byte identity file; discID is derived from it')
    $lines.Add('  persona\...                  persona pack (meta.json / persona.yml / AGENTS.md ...)')
    if ($HasEngine) {
        $lines.Add('  engine\...                   runtime engine')
    } else {
        $lines.Add('  engine\                      not included on this disc (the workspace had no engine\ at build time)')
    }
    $lines.Add('  .discpersona\manifest.json   file hash manifest (contains discID; use it to verify integrity)')
    if ($HasPayload) {
        $lines.Add('  .discpersona\payload\...     front-end static assets')
    }
    $lines.Add('')
    $lines.Add('Checking that this disc is complete')
    $lines.Add('--------------------')
    $lines.Add('Copy the whole disc to a hard drive and run this on the build machine (tools is not on the disc):')
    $lines.Add('  powershell -ExecutionPolicy Bypass -File tools\Test-Disc.ps1 -Disc <copied directory>')
    $lines.Add('Every check marked OK means PASS; a hash mismatch means files were damaged during burn or copy.')
    $lines.Add('')
    $lines.Add('-- Generated by tools\New-Disc.ps1; do not edit by hand.')
    return (($lines -join "`r`n") + "`r`n")
}

function ConvertTo-JsonString([string]$Text) {
    # JSON string literal: escape required characters, keep non-ASCII as-is (files are stored as UTF-8).
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
    # Hand-written JSON serializer with 2-space indent. Why not ConvertTo-Json: Windows PowerShell 5.1
    # adds two spaces after the colon and indents nested objects inconsistently (children of files get 9 spaces),
    # while the manifest requires strict 2-space indent, a colon+space separator, and non-ASCII passed through.
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
    # Serialize, then parse it back once; if an uncovered type shows up, fall back to ConvertTo-Json so the file stays valid JSON.
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
        Add-Warn 'The hand-written JSON serializer failed the parse-back check; falling back to ConvertTo-Json (indent may not be 2 spaces).'
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
            Add-Warn "Cannot parse engine\package.json; engine version recorded as dev ($($_.Exception.Message))"
        }
    }
    return 'dev'
}

# ---------------------------------------------------------------------------
# 0. Output paths and preflight checks
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'DiscPersona builder' -ForegroundColor White

$personaPath = (Resolve-FullPath $Persona).TrimEnd('\')
$outPath     = (Resolve-FullPath $Out).TrimEnd('\')
$workspaceRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }

Write-Host "  Persona     : $personaPath"
Write-Host "  Out         : $outPath"
Write-Host "  ReusePad    : $(if ($ReusePad) { 'yes' } else { 'no' })"
Write-Host "  Workspace   : $workspaceRoot"

if (-not (Test-Path -LiteralPath $personaPath -PathType Container)) {
    Write-Host ''
    Write-Host "[FAIL] Persona pack directory does not exist: $personaPath" -ForegroundColor Red
    Write-Host ''
    exit 1
}

$pathRoot = [System.IO.Path]::GetPathRoot($outPath)
if ($pathRoot -and ($outPath.TrimEnd('\') -ieq $pathRoot.TrimEnd('\'))) {
    Write-Host ''
    Write-Host "[FAIL] Refusing to write the disc tree to a drive root: $outPath" -ForegroundColor Red
    Write-Host '       Use a subdirectory such as D:\build\disc.'
    Write-Host ''
    exit 1
}

$personaCmp = $personaPath.TrimEnd('\')
$outCmp     = $outPath.TrimEnd('\')
if ($outCmp -ieq $personaCmp) {
    Write-Host ''
    Write-Host '[FAIL] The output directory cannot be the persona pack directory.' -ForegroundColor Red
    Write-Host ''
    exit 1
}
if ($outCmp.StartsWith($personaCmp + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host ''
    Write-Host '[FAIL] The output directory cannot be inside the persona pack.' -ForegroundColor Red
    Write-Host ''
    exit 1
}
if ($personaCmp.StartsWith($outCmp + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host ''
    Write-Host '[FAIL] The persona pack cannot be inside the output directory (it would be deleted on rebuild).' -ForegroundColor Red
    Write-Host ''
    exit 1
}

# Guard before overwriting: only an empty directory or a previous DiscPersona disc may be replaced; anything else needs -Force
if (Test-Path -LiteralPath $outPath -PathType Container) {
    $looksLikeDisc = Test-Path -LiteralPath (Join-Path $outCmp '.discpersona\manifest.json') -PathType Leaf
    $isEmpty = -not (Get-ChildItem -LiteralPath $outCmp -Force | Select-Object -First 1)
    if (-not $looksLikeDisc -and -not $isEmpty -and -not $Force) {
        Fail-With @(
            "The output directory already contains something else and does not look like a DiscPersona disc: $outCmp",
            'Nothing was changed, so your files are safe.',
            'Use an empty directory (-Out), or add -Force to confirm overwriting.'
        )
    }
    if (-not $looksLikeDisc -and -not $isEmpty -and $Force) {
        Add-Warn "The output directory is not a DiscPersona disc, but -Force was given; its contents will be replaced: $outCmp"
    }
}

$tmpPath = $outCmp + '.tmp'
if (Test-Path -LiteralPath $tmpPath) {
    Add-Warn "Found a leftover temp directory from a previous run; cleaned up: $tmpPath"
    Remove-Tree $tmpPath
}

# ---------------------------------------------------------------------------
# 1. Check the persona pack
# ---------------------------------------------------------------------------
Write-Step '[1/7] Checking the persona pack'

$metaPath = Join-Path $personaPath 'meta.json'
$ymlPath  = Join-Path $personaPath 'persona.yml'
$problems = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
    $problems.Add('meta.json: file is missing')
} else {
    $meta = $null
    try {
        $meta = (Read-TextFile $metaPath) | ConvertFrom-Json
    } catch {
        $problems.Add("meta.json: not valid JSON ($($_.Exception.Message))")
    }
    if ($null -ne $meta) {
        $name    = [string](Get-JsonProp $meta 'name')
        $version = [string](Get-JsonProp $meta 'version')
        if ([string]::IsNullOrWhiteSpace($version)) {
            # Current persona packs record the version in personaVersion; accept it (the manifest only needs a version)
            $version = [string](Get-JsonProp $meta 'personaVersion')
            if (-not [string]::IsNullOrWhiteSpace($version)) {
                Add-Note 'meta.json has no version; using personaVersion'
            }
        }
        $discIDInMeta = [string](Get-JsonProp $meta 'discID')
        if ([string]::IsNullOrWhiteSpace($name))    { $problems.Add('meta.json: name is missing (or empty)') }
        if ([string]::IsNullOrWhiteSpace($version)) { $problems.Add('meta.json: version / personaVersion is missing (or empty)') }
        if ([string]::IsNullOrWhiteSpace($discIDInMeta)) {
            Add-Note 'meta.json has no discID; one will be derived from pad.bin and written into the output copy (source untouched).'
        }
    }
}

if (-not (Test-Path -LiteralPath $ymlPath -PathType Leaf)) {
    $problems.Add('persona.yml: file is missing')
} else {
    $ymlText = Read-TextFile $ymlPath
    if ($ymlText -notmatch '(?m)system_prompt\s*:') {
        $problems.Add('persona.yml: system_prompt: is missing')
    }
}

if ($problems.Count -gt 0) { Fail-With $problems.ToArray() }

$meta = (Read-TextFile $metaPath) | ConvertFrom-Json
$personaName    = ([string](Get-JsonProp $meta 'name')).Trim()
$personaVersion = ([string](Get-JsonProp $meta 'version')).Trim()
if (-not $personaVersion) { $personaVersion = ([string](Get-JsonProp $meta 'personaVersion')).Trim() }
Write-Ok "Persona pack is valid (name=$personaName, version=$personaVersion)"

foreach ($optional in @('AGENTS.md', 'card.json', 'avatar.png', 'avatar.ico', 'lorebook.json', 'seed')) {
    if (-not (Test-Path -LiteralPath (Join-Path $personaPath $optional))) {
        Add-Note "persona pack has no $optional (optional; not an error)"
    }
}

# ---------------------------------------------------------------------------
# 2. Prepare the temp directory + pad.bin
# ---------------------------------------------------------------------------
Write-Step '[2/7] Preparing pad.bin (disc identity)'

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
            Add-Warn "ReusePad was requested, but the old pad.bin has the wrong size or magic; regenerating (discID will change)."
        }
    } else {
        Add-Warn 'ReusePad was requested, but the output directory has no pad.bin; regenerating.'
    }
}
if (-not $padReused) {
    $padStamp = New-PadFile $padPath
}

$discID = (Get-Sha256 $padPath).Substring(0, 16)
if ($padReused) {
    Write-Ok "Reused the existing pad.bin, discID=$discID"
} else {
    Write-Ok "Generated 512-byte pad.bin, discID=$discID"
}

# ---------------------------------------------------------------------------
# 3. Copy the persona pack
# ---------------------------------------------------------------------------
Write-Step '[3/7] Copying persona\'

$personaDst = Join-Path $tmpPath 'persona'
Copy-Tree -Source $personaPath -Destination $personaDst
$personaCount = Get-TreeFileCount $personaDst
Write-Ok "persona\ copied ($personaCount files)"

# Sync the meta.json discID (output copy only)
$dstMetaPath = Join-Path $personaDst 'meta.json'
$dstMeta = (Read-TextFile $dstMetaPath) | ConvertFrom-Json
$metaDiscID = [string](Get-JsonProp $dstMeta 'discID')
if ([string]::IsNullOrWhiteSpace($metaDiscID)) {
    $dstMeta | Add-Member -NotePropertyName 'discID' -NotePropertyValue $discID -Force
    $json = Get-JsonTextForFile $dstMeta
    Write-TextFile $dstMetaPath ($json + "`r`n") $script:EncUtf8NoBom
    Write-Ok 'Added discID to the persona pack meta.json (output copy)'
} elseif ($metaDiscID -ne $discID) {
    $dstMeta.discID = $discID
    $json = Get-JsonTextForFile $dstMeta
    Write-TextFile $dstMetaPath ($json + "`r`n") $script:EncUtf8NoBom
    Add-Warn "The discID in the persona pack meta.json ($metaDiscID) does not match the one from pad.bin; overwrote the output copy."
} else {
    Write-Skip 'meta.json discID already matches pad.bin'
}

# name / version must reach the manifest (it uses the source meta; the output copy now matches)
$outMeta = (Read-TextFile $dstMetaPath) | ConvertFrom-Json
$personaName    = ([string](Get-JsonProp $outMeta 'name')).Trim()
$personaVersion = ([string](Get-JsonProp $outMeta 'version')).Trim()
if (-not $personaVersion) { $personaVersion = ([string](Get-JsonProp $outMeta 'personaVersion')).Trim() }

if ($SealPersona) {
    Write-Step '[3/7] Encrypting the persona (sealed)'
    $sealPass = $null
    if ($PassphraseStdin) {
        try { $sealPass = [Console]::In.ReadLine() } catch { $sealPass = $null }
    } elseif ($env:DISKLIFE_PASSPHRASE) {
        $sealPass = $env:DISKLIFE_PASSPHRASE
    } else {
        $secure1 = Read-Host -AsSecureString 'Passphrase for encrypted persona'
        $secure2 = Read-Host -AsSecureString 'Repeat passphrase'
        $sealPass = ConvertFrom-SecurePassphrase -Secure $secure1
        $repeat = ConvertFrom-SecurePassphrase -Secure $secure2
        if ($sealPass -ne $repeat) { Fail-Seal 'The two passphrases do not match.' }
    }
    if (-not $sealPass -or $sealPass.Length -lt 8) {
        Fail-Seal 'The seal passphrase must be at least 8 characters.'
    }
    $sealScript = Join-Path $workspaceRoot 'engine\lib\seal.js'
    [void](Invoke-SealPersonaWithNode -SealScript $sealScript -PersonaDir $personaDst -Passphrase $sealPass)
    $sealPass = $null
    if (-not (Test-Path -LiteralPath (Join-Path $personaDst 'persona.sealed') -PathType Leaf)) {
        Fail-Seal 'The seal helper finished but persona.sealed was not created.'
    }
    Add-Note 'Persona encrypted on the disc (persona.yml/AGENTS.md/lorebook/seed -> persona.sealed); the passphrase is required on first boot.'
    Write-Ok 'persona\ sealed: plaintext persona.yml/AGENTS.md/lorebook/seed removed'
}

# ---------------------------------------------------------------------------
# 4. Copy the engine
# ---------------------------------------------------------------------------
Write-Step '[4/7] Copying engine\'

$engineSrc = Join-Path $workspaceRoot 'engine'
$hasEngine = $false
if (Test-Path -LiteralPath $engineSrc -PathType Container) {
    $engineDst = Join-Path $tmpPath 'engine'
    Copy-Tree -Source $engineSrc -Destination $engineDst
    $hasEngine = $true
    $engineCount = Get-TreeFileCount $engineDst
    if ($engineCount -eq 0) {
        Add-Warn "The workspace engine\ exists but has no files ($engineSrc); the disc has no runnable engine and launch will fail with code 1."
    } else {
        Write-Ok "engine\ copied ($engineCount files)"
    }
} else {
    Add-Warn "The workspace has no engine\ ($engineSrc), so the disc will not carry an engine; this disc can only be used as a data disc."
}
$engineVersion = Get-EngineVersion (Join-Path $tmpPath 'engine')

# ---------------------------------------------------------------------------
# 5. start.cmd
# ---------------------------------------------------------------------------
Write-Step '[5/7] Writing start.cmd'

$startSrc = Join-Path $workspaceRoot 'start.cmd'
$startDst = Join-Path $tmpPath 'start.cmd'

if (Test-Path -LiteralPath $startSrc -PathType Leaf) {
    $startBytes = [System.IO.File]::ReadAllBytes($startSrc)
    $isUtf16 = ($startBytes.Length -ge 2 -and $startBytes[0] -eq 0xFF -and $startBytes[1] -eq 0xFE)
    $hasUtf8Bom = ($startBytes.Length -ge 3 -and $startBytes[0] -eq 0xEF -and $startBytes[1] -eq 0xBB -and $startBytes[2] -eq 0xBF)

    if ($isUtf16) {
        Add-Warn 'start.cmd is UTF-16 encoded, which cmd.exe cannot run; copied as-is, so change the source file back to ANSI/UTF-8 without BOM.'
        [System.IO.File]::WriteAllBytes($startDst, $startBytes)
    } elseif ($hasUtf8Bom) {
        Add-Warn 'start.cmd has a UTF-8 BOM, which cmd.exe may treat as part of the command; copied as-is.'
        [System.IO.File]::WriteAllBytes($startDst, $startBytes)
    } else {
        # Check line endings: only CRLF is allowed
        $loneLf = $false
        for ($i = 0; $i -lt $startBytes.Length; $i++) {
            if ($startBytes[$i] -eq 0x0A -and ($i -eq 0 -or $startBytes[$i - 1] -ne 0x0D)) { $loneLf = $true; break }
        }
        if ($loneLf) {
            $text = Read-TextFile $startSrc
            $text = ($text -replace "`r`n", "`n") -replace "`r", "`n"
            $text = $text -replace "`n", "`r`n"
            Write-TextFile $startDst $text $script:EncUtf8NoBom
            Add-Warn 'start.cmd contains bare LF line endings; normalized to CRLF.'
        } else {
            [System.IO.File]::Copy($startSrc, $startDst, $true)
        }
    }
    Write-Ok "start.cmd copied from the workspace ($([System.IO.File]::ReadAllBytes($startDst).Length) bytes)"
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
    Add-Warn 'start.cmd is not available (no start.cmd in the workspace), so a placeholder was written; this disc cannot launch.'
}

# Cross-check: if start.cmd calls engine\launch.ps1, that file must exist on the disc
if (Test-Path -LiteralPath $startDst -PathType Leaf) {
    $startText = Read-TextFile $startDst
    if ($startText -match 'engine\\launch\.ps1') {
        $launchOnDisc = Join-Path $tmpPath 'engine\launch.ps1'
        if (-not (Test-Path -LiteralPath $launchOnDisc -PathType Leaf)) {
            Add-Warn 'start.cmd calls engine\launch.ps1, but the disc does not have it; launch will fail (error code 1).'
        }
    }
}

# ---------------------------------------------------------------------------
# 6. payload / autorun.inf / README.txt
# ---------------------------------------------------------------------------
Write-Step '[6/7] Writing autorun.inf and README.txt'

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
    Write-Ok "payload copied ($(Get-TreeFileCount $payloadDst) files, preset $preset)"
} elseif ($preset -eq 'none') {
    Write-Skip 'Packaging a pure persona disc by -PayloadPreset none: the persona DSH ships without preinstalled plugins'
} else {
    Write-Skip ('No payload found for preset ' + $preset + ': packaging a pure persona disc. Run tools\New-ProfilePayload.ps1 -Preset ' + $preset + ' to add it')
}

# Record which plugin payload was used in meta.json (output copy) so Studio, the launcher and people can see it
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
        Write-Ok ('meta.json records plugin payload: ' + $payloadPresetUsed + ' (' + (@($pluginNames).Count) + ' plugins)')
    }
} catch {
    Add-Warn (Failed to write the plugin payload info into meta.json:  + $_.Exception.Message)
}

# autorun.inf
$avatarIco = Join-Path $tmpPath 'persona\avatar.ico'
$avatarPng = Join-Path $tmpPath 'persona\avatar.png'
$iconRel = ''
if (Test-Path -LiteralPath $avatarIco -PathType Leaf) {
    $iconRel = 'persona\avatar.ico'
} elseif (Test-Path -LiteralPath $avatarPng -PathType Leaf) {
    $iconRel = 'persona\avatar.png'
    Add-Note 'persona pack has no avatar.ico; the icon falls back to avatar.png (some systems show no icon; converting to .ico helps)'
}
$hasIcon = (-not [string]::IsNullOrEmpty($iconRel))
$safeName = ($personaName -replace "[\r\n]", ' ').Trim()
if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = $discID }
$label = (Limit-Label $safeName 32)
if ($label.Length -lt $safeName.Length) {
    Add-Note "Display name exceeds 32 characters; autorun label truncated to: $label"
}

$autorunText = New-AutorunText -DisplayName $safeName -Label $label -IconRel $iconRel
$autorunPath = Join-Path $tmpPath 'autorun.inf'

$ascii = $true
foreach ($ch in $autorunText.ToCharArray()) { if ([int]$ch -gt 0x7F) { $ascii = $false; break } }

if ($ascii) {
    Write-TextFile $autorunPath $autorunText $script:EncAscii
} else {
    # The content is not ASCII (action=Wake / non-ASCII persona name). ASCII cannot hold it, so use the
    # natively supported UTF-16LE + BOM form of autorun.inf, which Explorer displays correctly.
    Write-TextFile $autorunPath $autorunText $script:EncUtf16Le
    Add-Note 'autorun.inf written as UTF-16LE with BOM: the content is not ASCII, which plain ASCII cannot hold (native Windows form).'
}
if ($hasIcon) {
    Write-Ok "autorun.inf written (icon=$iconRel)"
} else {
    Write-Ok 'autorun.inf written (no persona avatar; icon line omitted)'
}

# README.txt
$builtAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$readmeText = New-ReadmeText -DisplayName $safeName -PersonaVersion $personaVersion `
    -DiscID $discID -BuiltAt $builtAt -EngineVersion $engineVersion `
    -HasPayload $hasPayload -HasEngine $hasEngine
Write-TextFile (Join-Path $tmpPath 'README.txt') $readmeText $script:EncUtf8Bom
Write-Ok 'README.txt written (UTF-8 with BOM, CRLF)'

# ---------------------------------------------------------------------------
# 7. Hash manifest
# ---------------------------------------------------------------------------
Write-Step '[7/7] Hashing files and writing manifest.json'

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
Write-Ok "manifest.json written ($($sortedRel.Count) files, including pad.bin; $($sortedRel.Count + 1) files on the disc in total)"

# ---------------------------------------------------------------------------
# Atomic replacement of <out>
# ---------------------------------------------------------------------------
Write-Step 'Committing to the output directory'

$backupPath = $null
if (Test-Path -LiteralPath $outPath) {
    $backupPath = $outPath + '.old-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    [System.IO.Directory]::Move($outPath, $backupPath)
    Write-Note "Existing output directory moved to: $backupPath"
}
try {
    [System.IO.Directory]::Move($tmpPath, $outPath)
} catch {
    if ($backupPath -and (Test-Path -LiteralPath $backupPath) -and -not (Test-Path -LiteralPath $outPath)) {
        [System.IO.Directory]::Move($backupPath, $outPath)
        Write-WarnLine 'Commit failed; rolled back to the previous output directory.'
    }
    throw
}
if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
    Remove-Tree $backupPath
}
Write-Ok "Committed atomically: $outPath"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$totalFiles = @(Get-ChildItem -LiteralPath $outPath -Recurse -Force | Where-Object { -not $_.PSIsContainer }).Count

Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host 'DiscPersona disc created' -ForegroundColor Green
Write-Host "  Name        : $personaName"
Write-Host "  Version     : $personaVersion"
Write-Host "  discID      : $discID"
Write-Host "  Engine      : $engineVersion"
Write-Host "  Output      : $outPath"
Write-Host "  Files       : $totalFiles (including pad.bin and manifest.json)"
Write-Host "  home        : %LOCALAPPDATA%\DiscPersona\personas\$discID"
Write-Host "  pad.bin     : $(if ($padReused) { 'reused' } else { 'newly generated' })"
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray

if ($script:Warnings.Count -gt 0) {
    Write-Host ''
    Write-Host "Warnings ($($script:Warnings.Count); disc integrity may be affected):" -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }
}
if ($script:Notes.Count -gt 0) {
    Write-Host ''
    Write-Host "Notes ($($script:Notes.Count); informational):" -ForegroundColor DarkGray
    foreach ($n in $script:Notes) { Write-Host "  · $n" -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host "DISC_OK discID=$discID files=$totalFiles out=$outPath" -ForegroundColor Green
exit 0
