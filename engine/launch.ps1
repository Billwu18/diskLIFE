#requires -Version 5.1
<#
  diskLIFE launch engine
  Usage (called by start.cmd in the disc root):
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<disc>\engine\launch.ps1" -DiscRoot "<disc>"

  Optional parameters (for tests and troubleshooting; not needed in normal use):
    -DshPath <path>        full path to dsh.cmd (same as the DISCPERSONA_DSH env var)
    -HomeRoot <path>       parent directory of the persona home (default follows the dsh install: <install root>\DiscPersona\personas)
    -StartTimeoutSec <n>   max seconds to wait for readiness (default 60)
    -NoBrowser             do not open a browser automatically
    -UpgradePersona        overwrite the room persona with the one on the disc (backed up to persona.bak-<timestamp> first)
    -PassphraseStdin       read the sealed-persona passphrase from the first stdin line (automation / self-test)
    -NoWait                return right after launch instead of waiting for a key (automation / self-test / disc watcher)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DiscRoot,
    [string]$DshPath,
    [string]$HomeRoot,
    [int]$StartTimeoutSec = 60,
    [switch]$NoBrowser,
    [switch]$UpgradePersona,
    [switch]$PassphraseStdin,
    [switch]$NoWait
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:EngineDir = Split-Path -Parent $PSCommandPath
. (Join-Path $script:EngineDir 'lib\Common.ps1')
. (Join-Path $script:EngineDir 'lib\Yaml.ps1')
. (Join-Path $script:EngineDir 'lib\Credentials.ps1')
. (Join-Path $script:EngineDir 'lib\Manifest.ps1')
. (Join-Path $script:EngineDir 'lib\Dsh.ps1')

Initialize-DPConsole
Assert-DPPlatform

# ---------------------------------------------------------------- 1. disc integrity
$disc = Get-DPNormalizedPath -Path $DiscRoot
if (-not $disc -or -not (Test-Path -LiteralPath $disc -PathType Container)) {
    Stop-DiscPersona -Code 'E01' `
        -Message ('Cannot find the root of this disc: ' + $DiscRoot) `
        -Hint 'Double-click start.cmd in the disc root instead of copying the engine folder elsewhere.'
}

$required = @(
    @{ Rel = 'persona\meta.json'; Label = 'persona metadata' },
    @{ Rel = 'pad.bin'; Label = 'disc fingerprint file' }
)
$missing = New-Object System.Collections.ArrayList
foreach ($item in $required) {
    $full = Join-Path $disc $item.Rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        [void]$missing.Add($item.Rel + ' (' + $item.Label + ')')
    }
}
$hasPlainPersona = Test-Path -LiteralPath (Join-Path $disc 'persona\persona.yml') -PathType Leaf
$hasSealedPersona = Test-Path -LiteralPath (Join-Path $disc 'persona\persona.sealed') -PathType Leaf
if (-not $hasPlainPersona -and -not $hasSealedPersona) {
    [void]$missing.Add('persona\persona.yml or persona\persona.sealed (persona file)')
}
if ($missing.Count -gt 0) {
    Stop-DiscPersona -Code 'E01' `
        -Message ('This disc is incomplete, missing: ' + ($missing -join ', ')) `
        -Hint 'Use another disc, or rebuild one with tools\New-Disc.ps1.'
}

# ---------------------------------------------------------------- 2. discID + manifest
$padPath = Join-Path $disc 'pad.bin'
try {
    $padHash = Get-DPFileSha256 -Path $padPath
} catch {
    Stop-DiscPersona -Code 'E02' `
        -Message 'Cannot read pad.bin, so this disc cannot be identified.' `
        -Hint 'The disc may be worn or the drive may be failing: clean the disc, try another drive, or rebuild the disc.'
}
$discID = $padHash.Substring(0, 16)

$manifestPath = Join-Path $disc '.discpersona\manifest.json'
$manifestChecked = 0
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifestResult = Assert-DPDiscManifest -DiscRoot $disc -ManifestPath $manifestPath
    $manifestChecked = $manifestResult.Checked
}

# ---------------------------------------------------------------- 3. home / logs
# Where the room lives: prefer the dsh install location; fall back to the user directory only if that fails.
$baseRootSource = ''
if (-not [string]::IsNullOrWhiteSpace($HomeRoot)) {
    $baseRoot = Get-DPNormalizedPath -Path $HomeRoot
    if (-not $baseRoot) { $baseRoot = $HomeRoot }
    $baseRootSource = 'command line -HomeRoot'
} elseif (-not [string]::IsNullOrWhiteSpace($env:DISCPERSONA_HOME)) {
    $baseRoot = Get-DPNormalizedPath -Path $env:DISCPERSONA_HOME
    if (-not $baseRoot) { $baseRoot = $env:DISCPERSONA_HOME }
    $baseRootSource = 'env var DISCPERSONA_HOME'
} else {
    $baseRoot = $null
    $installRoot = Get-DPInstallRootFromDsh -DshPath $DshPath
    if ($installRoot) {
        $candidate = Join-Path $installRoot 'DiscPersona\personas'
        if (Test-DPDirectoryWritable -Path $candidate) {
            $baseRoot = $candidate
            $baseRootSource = 'next to the dsh install (' + $installRoot + ')'
        }
    }
    if (-not $baseRoot) {
        $baseRoot = Join-Path $env:LOCALAPPDATA 'DiscPersona\personas'
        $baseRootSource = 'no usable dsh install location, falling back to the user directory'
    }
}
$personaRoot = Join-Path $baseRoot $discID
$homeDir = Join-Path $personaRoot 'home'
$logsDir = Join-Path $personaRoot 'logs'
$workspaceDir = Join-Path $personaRoot 'workspace'
$statePath = Join-Path $personaRoot 'state.json'
$lockPath = Join-Path $homeDir '.lock'

if (-not (Test-DPDirectoryWritable -Path $personaRoot)) {
    Stop-DiscPersona -Code 'E06' `
        -Message ('Cannot write to this persona room: ' + $personaRoot) `
        -Hint 'Check free disk space and folder permissions, or point LOCALAPPDATA at a writable directory and retry.'
}
foreach ($dir in @($homeDir, $logsDir, $workspaceDir)) {
    if (-not (Test-DPDirectoryWritable -Path $dir)) {
        Stop-DiscPersona -Code 'E06' `
            -Message ('Cannot write to this persona room: ' + $dir) `
            -Hint 'Check free disk space and folder permissions, then retry.'
    }
}

$stamp = Format-DPFileStamp
$script:DPLogPath = Join-Path $logsDir ('launch-' + $stamp + '.log')
$script:DPPersonaHome = $personaRoot
Add-DPLog -Message ('diskLIFE launch: disc ' + $disc + ', discID ' + $discID)
Add-DPLog -Message ('Persona directory: ' + $personaRoot)
Add-DPLog -Message ('Room root: ' + $baseRoot + ' (' + $baseRootSource + ')')
if ($manifestChecked -gt 0) {
    Add-DPLog -Message ('Integrity check: ' + $manifestChecked + ' files verified.')
} else {
    Add-DPLog -Message 'No .discpersona\manifest.json, skipping the per-file check (only the three required files were confirmed).' -Level 'Warn'
}

# Keep only the 10 most recent launch logs
try {
    $oldLogs = @(Get-ChildItem -LiteralPath $logsDir -Filter 'launch-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -Skip 10)
    foreach ($f in $oldLogs) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
} catch { }

# ---------------------------------------------------------------- 4. load the persona (room first, disc as fallback)
function Resolve-DPNodeExe {
    foreach ($name in @('node.exe', 'node')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    return $null
}

function Read-DPSealPassphrase {
    if ($env:DISKLIFE_PASSPHRASE) { return $env:DISKLIFE_PASSPHRASE }
    if ($PassphraseStdin) {
        try { return [Console]::In.ReadLine() } catch { return $null }
    }
    $secure = Read-Host -AsSecureString 'Passphrase for this persona disc'
    if ($null -eq $secure) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
    }
}

function Invoke-DPSealDecrypt {
    param(
        [Parameter(Mandatory = $true)][string]$SealedPath,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][string]$Passphrase
    )
    $node = Resolve-DPNodeExe
    if (-not $node) {
        Stop-DiscPersona -Code 'E11' `
            -Message 'This disc has an encrypted persona, but Node.js was not found to unlock it.' `
            -Hint 'Install DeepSeek Harness (Node.js comes with it) or put node.exe on PATH, then retry.'
    }
    $sealScript = Join-Path $script:EngineDir 'lib\seal.js'
    if (-not (Test-Path -LiteralPath $sealScript -PathType Leaf)) {
        Stop-DiscPersona -Code 'E11' `
            -Message ('The sealed-persona helper is missing from this disc: ' + $sealScript) `
            -Hint 'Rebuild the disc with tools\New-Disc.ps1.'
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = '"' + $sealScript + '" decrypt --in "' + $SealedPath + '" --out "' + $OutDir + '" --passphrase-stdin'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Stop-DiscPersona -Code 'E12' `
            -Message ('Cannot start the sealed-persona helper: ' + $_.Exception.Message) `
            -Hint 'Check that Node.js can run, then retry.'
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
        if (-not $detail) { $detail = 'the helper exited with code ' + $exitCode }
        Stop-DiscPersona -Code 'E12' `
            -Message ('Cannot unlock the encrypted persona: ' + $detail) `
            -Hint 'Check the passphrase. If it is correct, the sealed file on the disc may be damaged.'
    }
    return $stdout
}

function Copy-DPVisiblePersonaFiles {
    param([string]$FromDir, [string]$ToDir)
    foreach ($name in @('meta.json', 'avatar.png', 'avatar.ico')) {
        $src = Join-Path $FromDir $name
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $ToDir $name) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Sync-DPPersonaCard {
    <#
      Sync the room persona into a card of dsh-persona-dafeiyu and make it the selected one.

      Why this is needed: an empty dafeiyu library injects its built-in "Big Fatty Fish",
      so the system prompt would hold both that identity and the one from AGENTS.md, and the model would split.
      Here we write personas.json: current = discpersona (our persona),
      disable the built-in dafeiyu / acha, and rewrite the body from the room persona.yml on every launch,
      so it always matches AGENTS.md. Skipped silently when the plugin is absent.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HomeDir,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $pluginDir = Join-Path $HomeDir 'profiles\web\node_modules\dsh-persona-dafeiyu'
    if (-not (Test-Path -LiteralPath $pluginDir -PathType Container)) { return $false }
    try {
        $storeDir = Join-Path $HomeDir 'storages\dsh-persona-dafeiyu'
        if (-not (Test-Path -LiteralPath $storeDir)) { New-Item -ItemType Directory -Force -Path $storeDir | Out-Null }
        $storeFile = Join-Path $storeDir 'personas.json'

        $kept = @()
        if (Test-Path -LiteralPath $storeFile -PathType Leaf) {
            try {
                $old = ConvertFrom-Json -InputObject (Read-DPTextFile -Path $storeFile) -ErrorAction Stop
                foreach ($item in @($old.personas)) {
                    if ($item -and [string]$item.id -ne 'discpersona') { $kept += $item }
                }
            } catch {
                Add-DPLog -Message ('Cannot read the existing persona library, starting fresh: ' + $_.Exception.Message) -Level 'Warn'
            }
        }

        $card = [ordered]@{
            id          = 'discpersona'
            name        = $Name
            source      = 'imported'
            description = 'The persona on this disc, synced by the launcher on every launch'
            text        = $Text
        }
        $store = [ordered]@{
            version    = 1
            mode       = 'global'
            current    = 'discpersona'
            disabled   = @('dafeiyu', 'acha')
            personas   = @($kept) + @($card)
            workspaces = @()
        }

        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = 8388608
        Write-DPTextFile -Path $storeFile -Text $ser.Serialize($store)
        Add-DPLog -Message ('Persona card synced: ' + $Name + ' (built-in Big Fatty Fish / Acha disabled)')
        return $true
    } catch {
        Add-DPLog -Message ('Persona card sync failed (launch continues): ' + $_.Exception.Message) -Level 'Warn'
        return $false
    }
}

function Read-DPMetaFile {
    param([string]$Path)
    $result = [pscustomobject]@{ Name = $null; Version = $null; Raw = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    try {
        $json = ConvertFrom-Json -InputObject (Read-DPTextFile -Path $Path) -ErrorAction Stop
        $result.Raw = $json
        foreach ($name in @('name', 'personaName', 'title')) {
            $prop = $json.PSObject.Properties[$name]
            if ($prop -and $prop.Value) { $result.Name = [string]$prop.Value; break }
        }
        foreach ($name in @('version', 'personaVersion')) {
            $prop = $json.PSObject.Properties[$name]
            if ($prop -and $prop.Value) { $result.Version = [string]$prop.Value; break }
        }
    } catch { }
    return $result
}

function Get-DPLorebookText {
    <#
      Join the entries in lorebook.json into a "lorebook" appendix.
      diskLIFE uses the --patch channel, which has no keyword retrieval, so everything is always on by default:
      sort by constant=true first, then insertion_order, and stop at -MaxChars.
      Entries that do not fit are reported in the log as "skipped N", never dropped silently.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxChars = 6000
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $doc = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $doc = $raw | ConvertFrom-Json
    } catch {
        Add-DPLog -Message ('Cannot parse lorebook.json, ignoring it: ' + $_.Exception.Message) -Level 'Warn'
        return ''
    }
    if ($null -eq $doc) { return '' }

    $entries = @()
    if ($doc.PSObject.Properties.Name -contains 'entries' -and $doc.entries) { $entries = @($doc.entries) }
    if ($entries.Count -eq 0) { return '' }

    $rows = @()
    $idx = 0
    foreach ($e in $entries) {
        $body = ''
        if ($e.PSObject.Properties.Name -contains 'content') { $body = [string]$e.content }
        if ([string]::IsNullOrWhiteSpace($body)) { $idx++; continue }
        $isConst = $false
        if ($e.PSObject.Properties.Name -contains 'constant') { $isConst = [bool]$e.constant }
        $order = $idx
        if ($e.PSObject.Properties.Name -contains 'insertion_order') {
            $tmp = 0
            if ([int]::TryParse([string]$e.insertion_order, [ref]$tmp)) { $order = $tmp }
        }
        $title = ''
        if ($e.PSObject.Properties.Name -contains 'comment') { $title = [string]$e.comment }
        if ([string]::IsNullOrWhiteSpace($title) -and ($e.PSObject.Properties.Name -contains 'keys')) {
            $title = (@($e.keys) -join ' / ')
        }
        $rows += [pscustomobject]@{ Title = $title; Body = $body.Trim(); Order = $order; Const = $isConst }
        $idx++
    }
    if ($rows.Count -eq 0) { return '' }

    $sorted = @($rows | Sort-Object -Property @{ Expression = 'Const'; Descending = $true }, @{ Expression = 'Order'; Descending = $false })

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("## Lorebook (setting, not dialogue)`n")
    [void]$sb.Append("These are facts about the world you live in. They always hold, but do not recite them unprompted or repeat them entry by entry.`n")
    $used = 0
    $kept = 0
    $skipped = 0
    foreach ($r in $sorted) {
        $need = $r.Body.Length + 8
        if ($used + $need -gt $MaxChars) { $skipped++; continue }
        [void]$sb.Append("`n")
        if (-not [string]::IsNullOrWhiteSpace($r.Title)) {
            [void]$sb.Append('### ' + $r.Title.Trim() + "`n")
        }
        [void]$sb.Append(($r.Body -replace "`r`n", "`n" -replace "`r", "`n") + "`n")
        $used += $need
        $kept++
    }
    if ($kept -eq 0) { return '' }
    Add-DPLog -Message ('Lorebook: ' + $kept + ' entries merged (~' + $used + ' chars), limit ' + $MaxChars + ' chars' + $(if ($skipped -gt 0) { ', skipped ' + $skipped } else { '' }))
    return $sb.ToString()
}

function Compare-DPVersionText {
    <# Semantic compare: returns -1 / 0 / 1; non-numeric parts compare as strings, missing parts as 0. #>
    param([string]$Left, [string]$Right)
    if ([string]::IsNullOrWhiteSpace($Left)) { $Left = '0.0.0' }
    if ([string]::IsNullOrWhiteSpace($Right)) { $Right = '0.0.0' }
    $a = @($Left.Trim().TrimStart('v') -split '[.\-_+]' | Where-Object { $_ -ne '' })
    $b = @($Right.Trim().TrimStart('v') -split '[.\-_+]' | Where-Object { $_ -ne '' })
    $n = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { '0' }
        $y = if ($i -lt $b.Count) { $b[$i] } else { '0' }
        $nx = 0; $ny = 0
        $xIsNum = [int]::TryParse($x, [ref]$nx)
        $yIsNum = [int]::TryParse($y, [ref]$ny)
        if ($xIsNum -and $yIsNum) {
            if ($nx -lt $ny) { return -1 }
            if ($nx -gt $ny) { return 1 }
        } else {
            $c = [string]::CompareOrdinal($x, $y)
            if ($c -lt 0) { return -1 }
            if ($c -gt 0) { return 1 }
        }
    }
    return 0
}

$discPersonaDir = Join-Path $disc 'persona'
$roomPersonaDir = Join-Path $personaRoot 'persona'
$discPersonaYml = Join-Path $discPersonaDir 'persona.yml'
$roomPersonaYml = Join-Path $roomPersonaDir 'persona.yml'
$discMeta = Read-DPMetaFile -Path (Join-Path $discPersonaDir 'meta.json')

# -UpgradePersona: back up the room persona, then let the freeze below rebuild it from the disc version
$backupDir = $null
if ($UpgradePersona -and (Test-Path -LiteralPath $roomPersonaDir -PathType Container)) {
    $backupDir = Join-Path $personaRoot ('persona.bak-' + $stamp)
    try {
        Copy-Item -LiteralPath $roomPersonaDir -Destination $backupDir -Recurse -Force -ErrorAction Stop
        Remove-Item -LiteralPath $roomPersonaDir -Recurse -Force -ErrorAction Stop
        Add-DPLog -Message ('-UpgradePersona: room persona backed up to ' + $backupDir + ', using the disc version.') -Level 'Notice'
    } catch {
        Add-DPLog -Message ('-UpgradePersona backup failed, not overwriting: ' + $_.Exception.Message) -Level 'Error'
        $backupDir = $null
    }
}

$roomHadPersona = Test-Path -LiteralPath $roomPersonaYml -PathType Leaf
$discSealed = Join-Path $discPersonaDir 'persona.sealed'
if (-not $roomHadPersona -and (Test-Path -LiteralPath $discSealed -PathType Leaf)) {
    # Sealed disc: decrypt into a temporary directory, then move it into the room.
    $passphrase = Read-DPSealPassphrase
    if (-not $passphrase) {
        Stop-DiscPersona -Code 'E11' `
            -Message 'This disc has an encrypted persona, but the passphrase is empty.' `
            -Hint 'Run start.cmd again and enter the passphrase used when the disc was built.'
    }
    $unlockDir = $roomPersonaDir + '.unlock-' + $stamp
    try {
        if (Test-Path -LiteralPath $unlockDir) { Remove-Item -LiteralPath $unlockDir -Recurse -Force }
        [void](Invoke-DPSealDecrypt -SealedPath $discSealed -OutDir $unlockDir -Passphrase $passphrase)
        if (Test-Path -LiteralPath $roomPersonaDir) { Remove-Item -LiteralPath $roomPersonaDir -Recurse -Force }
        Move-Item -LiteralPath $unlockDir -Destination $roomPersonaDir -Force
        Copy-DPVisiblePersonaFiles -FromDir $discPersonaDir -ToDir $roomPersonaDir
        [void](Clear-DPReadOnly -Path $roomPersonaDir)
        Add-DPLog -Message ('Sealed persona unlocked into the room: ' + $roomPersonaDir) -Level 'Notice'
        $roomHadPersona = Test-Path -LiteralPath $roomPersonaYml -PathType Leaf
    } catch {
        try { if (Test-Path -LiteralPath $unlockDir) { Remove-Item -LiteralPath $unlockDir -Recurse -Force } } catch { }
        if ($_.Exception.Message -match '^E1[12]') { throw }
        Stop-DiscPersona -Code 'E12' `
            -Message ('Cannot unlock the encrypted persona: ' + $_.Exception.Message) `
            -Hint 'Check the passphrase. If it is correct, the sealed file on the disc may be damaged.'
    } finally {
        $passphrase = $null
    }
} elseif (-not $roomHadPersona) {
    # First run: freeze the whole disc persona into the room; the room wins from then on
    try {
        if (Test-Path -LiteralPath $roomPersonaDir) { Remove-Item -LiteralPath $roomPersonaDir -Recurse -Force }
        Copy-Item -LiteralPath $discPersonaDir -Destination $roomPersonaDir -Recurse -Force -ErrorAction Stop
        [void](Clear-DPReadOnly -Path $roomPersonaDir)
        Add-DPLog -Message ('Disc persona frozen into the room: ' + $roomPersonaDir) -Level 'Notice'
    } catch {
        Add-DPLog -Message ('Freeze failed, using the disc persona for this launch: ' + $_.Exception.Message) -Level 'Warn'
    }
    $roomHadPersona = Test-Path -LiteralPath $roomPersonaYml -PathType Leaf
}

$personaDir = if ($roomHadPersona) { $roomPersonaDir } else { $discPersonaDir }
$personaSource = if ($roomHadPersona) { 'room' } else { 'disc' }
$personaYml = Join-Path $personaDir 'persona.yml'

$meta = Read-DPMetaFile -Path (Join-Path $personaDir 'meta.json')
if (-not $meta.Name) {
    Add-DPLog -Message 'persona meta.json has no name field, using the default name.' -Level 'Warn'
}

# When the disc persona is newer than the room one: never overwrite silently, only record a pending upgrade
$pendingUpgrade = $null
if ($personaSource -eq 'room') {
    $roomVersion = $meta.Version
    $discVersion = $discMeta.Version
    if ($discVersion -and (Compare-DPVersionText -Left $discVersion -Right $roomVersion) -gt 0) {
        $pendingUpgrade = [ordered]@{ from = $roomVersion; to = $discVersion }
        Add-DPLog -Message ('The persona on this disc is newer than the room one (' + $discVersion + ' > ' + $roomVersion + '); the room version was kept. Add -UpgradePersona to update.') -Level 'Notice'
    }
}

try {
    $personaDoc = Read-DPPersonaDocument -Path $personaYml
} catch {
    Stop-DiscPersona -Code 'E08' `
        -Message ('Cannot read the persona file, or its format is wrong: ' + $personaYml) `
        -Hint 'Make sure persona.yml is UTF-8 text and system_prompt uses the | block scalar form.'
}
if (-not $personaDoc.HasSystemPrompt -or [string]::IsNullOrWhiteSpace([string]$personaDoc.SystemPrompt)) {
    Stop-DiscPersona -Code 'E08' `
        -Message ('No system_prompt found in the persona file: ' + $personaYml) `
        -Hint 'Add a persona text starting with system_prompt: | to the persona file, or use another disc.'
}
if ($null -eq $personaDoc.SystemPrompt) { $personaDoc.SystemPrompt = '' }

# Lorebook: always-on entries are appended to system_prompt (lorebook.json on the disc / in the room)
$lorebookPath = Join-Path $personaDir 'lorebook.json'
$lorebookText = Get-DPLorebookText -Path $lorebookPath
if ($lorebookText -ne '') {
    $personaDoc.SystemPrompt = $personaDoc.SystemPrompt.TrimEnd() + "`n`n" + $lorebookText
}

$personaName = 'Unnamed'
if ($meta.Name) { $personaName = $meta.Name }
elseif ($personaDoc.Name) { $personaName = $personaDoc.Name }

$personaVersion = '1.0.0'
if ($meta.Version) { $personaVersion = $meta.Version }
elseif ($personaDoc.Version) { $personaVersion = $personaDoc.Version }

Add-DPLog -Message ('Persona source: ' + $personaSource + ' (' + $personaYml + '), version ' + $personaVersion)

# ---------------------------------------------------------------- 5. single-instance lock
$lock = Read-DPLock -Path $lockPath
$lockAlive = $false
if ($lock) {
    $lockPid = 0
    try { $lockPid = [int]$lock.pid } catch { $lockPid = 0 }
    $lockTicks = 0
    try { $lockTicks = [long]$lock.startTicks } catch { $lockTicks = 0 }
    $lockAlive = Test-DPProcessIdentity -ProcessId $lockPid -StartTicks $lockTicks
}

if ($lockAlive) {
    $lastUrl = ''
    if (Test-Path -LiteralPath $statePath) {
        try {
            $stateObj = ConvertFrom-Json -InputObject (Read-DPTextFile -Path $statePath) -ErrorAction Stop
            if ($stateObj.PSObject.Properties['lastUrl'] -and $stateObj.lastUrl) { $lastUrl = [string]$stateObj.lastUrl }
        } catch { }
    }
    Add-DPLog -Message ('An instance is already running (PID ' + $lockPid + '), not starting another.') -Level 'Notice'
    Write-DPLine ''
    if ($lastUrl) {
        Write-DPLine ('  This persona is already running: ' + $lastUrl) 'Cyan'
        if (-not $NoBrowser) { Open-DPUrl -Url $lastUrl | Out-Null }
    } else {
        Write-DPLine '  This persona is already running, but no URL was recorded.' 'Cyan'
    }
    Write-DPLine '  Error code: E10 (already running)' 'DarkGray'
    Write-DPLine ''
    exit 0
}
if ($lock) {
    Add-DPLog -Message 'Found a lock left by a previous run (process exited), continuing.' -Level 'Warn'
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}

# Take the single-instance lock early: payload copy + cold boot bootstrap take tens of seconds,
# and a second double-click in that window would start another instance (a lock written at the end cannot stop it).
try {
    Write-DPLock -Path $lockPath -ProcessId $PID -StartTicks 0 -StartedAt ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Port 0
} catch {
    Add-DPLog -Message ('Early lock write failed (launch continues): ' + $_.Exception.Message) -Level 'Warn'
}

# ---------------------------------------------------------------- 6. first-run preparation
$profileDir = Join-Path $homeDir 'profiles\web'
$firstBoot = -not (Test-Path -LiteralPath $profileDir -PathType Container)
$payloadUsedNow = $false
$payloadPluginNames = $null
$payloadPresetName = 'none'

function ConvertTo-DPJsonString {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '""' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$sb.Append('\"'); continue }
            '\' { [void]$sb.Append('\\'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            default {
                if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Sync-DPWorkspace {
    <#
      Pin the dsh default workspace inside this persona room instead of
      deepseek-harness\default-workspace under the system Documents folder.

      Why this must change: on the first page load dsh creates the default workspace under Documents,
      so the persona instance and the main instance share one directory -- memory, AGENTS.md, scratch files
      all bleed together. Here we write a storage v2 workspace.json directly,
      keeping only the room workspace and making it the default (JSON written by hand to avoid the ConvertTo-Json empty-array trap).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HomeDir,
        [Parameter(Mandatory = $true)][string]$WorkspaceDir,
        [Parameter(Mandatory = $true)][string]$Title
    )
    $file = Join-Path $HomeDir 'storages\workspace.json'
    try {
        $id = $null
        $sessions = @()
        $archived = @()
        $pinned = @()
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            try {
                $old = ConvertFrom-Json -InputObject (Read-DPTextFile -Path $file) -ErrorAction Stop
                if ($old.global) {
                    $id = [string]$old.global.defaultWorkspaceId
                    if ($old.global.archivedSessionIds) { $archived = @($old.global.archivedSessionIds | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
                    if ($old.global.pinnedSessionIds) { $pinned = @($old.global.pinnedSessionIds | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
                }
                if ($old.tables -and $old.tables.workspaces) {
                    foreach ($prop in $old.tables.workspaces.PSObject.Properties) {
                        $v = $prop.Value
                        if ([string]$v.path -eq $WorkspaceDir) {
                            $id = $prop.Name
                            $sessions = @($v.sessionIds | Where-Object { $_ } | ForEach-Object { [string]$_ })
                        }
                    }
                }
            } catch {
                Add-DPLog -Message ('Cannot read the existing workspace record, starting fresh: ' + $_.Exception.Message) -Level 'Warn'
            }
        }
        if (-not $id) { $id = [guid]::NewGuid().ToString() }
        $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

        $sessionJson = if ($sessions.Count -gt 0) { (@($sessions | ForEach-Object { ConvertTo-DPJsonString $_ }) -join ',') } else { '' }
        $archivedJson = if ($archived.Count -gt 0) { (@($archived | ForEach-Object { ConvertTo-DPJsonString $_ }) -join ',') } else { '' }
        $pinnedJson = if ($pinned.Count -gt 0) { (@($pinned | ForEach-Object { ConvertTo-DPJsonString $_ }) -join ',') } else { '' }
        $json = '{' +
            '"unit":{"name":"workspace","version":2},' +
            '"global":{"initialized":true,"defaultWorkspaceId":' + (ConvertTo-DPJsonString $id) +
                ',"workspaceIds":[' + (ConvertTo-DPJsonString $id) + '],"archivedSessionIds":[' + $archivedJson + '],"pinnedSessionIds":[' + $pinnedJson + ']},' +
            '"tables":{"workspaces":{' + (ConvertTo-DPJsonString $id) + ':{' +
                '"path":' + (ConvertTo-DPJsonString $WorkspaceDir) + ',' +
                '"title":' + (ConvertTo-DPJsonString $Title) + ',' +
                '"sessionIds":[' + $sessionJson + '],' +
                '"createdAt":' + (ConvertTo-DPJsonString $now) + ',' +
                '"updatedAt":' + (ConvertTo-DPJsonString $now) + '}}}}'
        Write-DPTextFile -Path $file -Text $json
        Add-DPLog -Message ('Default workspace: ' + $WorkspaceDir)
        return $true
    } catch {
        Add-DPLog -Message ('Workspace record fix failed (launch continues): ' + $_.Exception.Message) -Level 'Warn'
        return $false
    }
}

function Invoke-DPProfileBootstrap {
    <#
      On first run, let dsh drop its shipped web profile into DSH_HOME\profiles\web itself.
      Why not `dsh --profile web --from-default-profile web`: dsh refuses that (see docs\engine.md).
      Instead: cold-start once with --port 0, grab the URL (after the profile is written), then kill it at once.
    #>
    param([string]$DshPath, [string]$HomeDir, [string]$WorkspaceDir, [string]$LogsDir, [string]$Stamp)

    $stdout = Join-Path $LogsDir ('bootstrap-' + $Stamp + '.log')
    $stderr = Join-Path $LogsDir ('bootstrap-' + $Stamp + '.err.log')
    $inst = Start-DshInstance -DshPath $DshPath -HomeDir $HomeDir -WorkingDir $WorkspaceDir -Port 0 `
        -Patches @() -StdoutPath $stdout -StderrPath $stderr
    Add-DPLog -Message ('Bootstrap: cold-starting dsh to generate the shipped web profile (PID ' + $inst.Process.Id + ').')
    $ready = Wait-DshUrl -Instance $inst -TimeoutSec 45
    if ($inst.Process -and -not $inst.Process.HasExited) { Stop-DPProcessTree -ProcessId $inst.Process.Id }
    if (-not $ready.Url) {
        $tail = Get-DPLogTail -Path $stdout -Lines 15
        Add-DPLog -Message 'Bootstrap cold start never reported a ready URL.' -Level 'Warn'
        foreach ($line in $tail) { Add-DPLog -Message ('  | ' + $line) -Level 'Warn' }
        return $false
    }
    # A printed ready URL is enough to call this step a success; profiles\web is filled in by the real launch.
    return $true
}

function Initialize-DPPersonaAssets {
    <#
      Idempotent catch-up for credentials / seed / AGENTS.md.

      Why this is its own function: these steps used to run once under firstBoot, which only checks
      whether profiles\web exists (payload copy creates it). If the first run fails at the credentials step
      (E07, power loss, Ctrl-C), the next run takes the else branch and the credentials are never restored.
      So it runs on every launch and fills in whatever is missing.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HomeDir,
        [Parameter(Mandatory = $true)][string]$PersonaDir,
        [Parameter(Mandatory = $true)][string]$WorkspaceDir
    )

    # 1) credentials: copy the three LLM records only, never parse or print them
    $targetCred = Join-Path $HomeDir '.credentials.yaml'
    if (-not (Test-DPCredentialHasLlm -Path $targetCred)) {
        $sourceHome = Get-DPSourceHome
        if (-not $sourceHome) {
            Stop-DiscPersona -Code 'E07' `
                -Message 'Cannot find the DeepSeek Harness credentials directory on this machine.' `
                -Hint 'Sign in to DSH once on this machine first, or point DISCPERSONA_SOURCE_HOME at the source home.'
        }
        $sourceCred = Join-Path $sourceHome '.credentials.yaml'
        if (-not (Test-DPCredentialHasLlm -Path $sourceCred)) {
            Stop-DiscPersona -Code 'E07' `
                -Message ('No usable DeepSeek credentials in the source home (' + $sourceHome + ').') `
                -Hint 'Sign in to DSH once on this machine first (open DSH and sign in with your DeepSeek account), then insert this disc.'
        }
        $import = Import-DPLlmCredentials -SourcePath $sourceCred -TargetPath $targetCred
        if (-not $import.Ok) {
            if ($import.Reason -eq 'write-failed') {
                Stop-DiscPersona -Code 'E06' `
                    -Message ('Cannot write credentials into this room: ' + $targetCred) `
                    -Hint 'Check free disk space and folder permissions, then retry.'
            }
            Stop-DiscPersona -Code 'E07' `
                -Message ('Credentials import failed (' + $import.Reason + '): ' + $sourceCred) `
                -Hint 'Sign in to DSH once on this machine, then retry.'
        }
        Add-DPLog -Message 'DeepSeek credentials imported (records copied, key values never read).'
    }

    # 2) seed: lay it down once while the room is still empty, so a user-edited memory is never overwritten
    $seedSrc = Join-Path $PersonaDir 'seed'
    $seedDst = Join-Path $WorkspaceDir 'memories'
    $seedMissing = -not (Test-Path -LiteralPath $seedDst -PathType Container) -or
        @(Get-ChildItem -LiteralPath $seedDst -Force -ErrorAction SilentlyContinue).Count -eq 0
    if ((Test-Path -LiteralPath $seedSrc -PathType Container) -and $seedMissing) {
        try {
            if (-not (Test-Path -LiteralPath $seedDst)) { New-Item -ItemType Directory -Force -Path $seedDst | Out-Null }
            Copy-Item -Path (Join-Path $seedSrc '*') -Destination $seedDst -Recurse -Force -ErrorAction Stop
            [void](Clear-DPReadOnly -Path $seedDst)
            Add-DPLog -Message ('persona\seed copied to: ' + $seedDst)
        } catch {
            Add-DPLog -Message ('persona\seed copy failed (launch continues): ' + $_.Exception.Message) -Level 'Warn'
        }
    }

    # 3) AGENTS.md: write only when missing, never overwrite (protects user edits)
    $agentsSrc = Join-Path $PersonaDir 'AGENTS.md'
    $agentsDst = Join-Path $HomeDir 'AGENTS.md'
    if ((Test-Path -LiteralPath $agentsSrc -PathType Leaf) -and -not (Test-Path -LiteralPath $agentsDst)) {
        try {
            Copy-Item -LiteralPath $agentsSrc -Destination $agentsDst -Force -ErrorAction Stop
            [void](Clear-DPReadOnly -Path $agentsDst)
            Add-DPLog -Message ('AGENTS.md written: ' + $agentsDst)
        } catch {
            Add-DPLog -Message ('AGENTS.md copy failed (launch continues): ' + $_.Exception.Message) -Level 'Warn'
        }
    }
}

if ($firstBoot) {
    Add-DPLog -Message 'First run: preparing profile, credentials, seed.' -Level 'Notice'

    $payloadCandidates = @(
        (Join-Path $disc '.discpersona\payload\profile-web'),
        (Join-Path $disc '.discpersona\payload\profile-persona'),
        (Join-Path $disc '.discpersona\payload')
    )
    $payloadDir = $null
    foreach ($c in $payloadCandidates) {
        if (Test-Path -LiteralPath $c -PathType Container) { $payloadDir = $c; break }
    }

    if ($payloadDir) {
        Add-DPLog -Message ('Using the pre-packaged profile from the disc: ' + $payloadDir)
        try {
            $parent = Split-Path -Parent $profileDir
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            if (Test-Path -LiteralPath $profileDir) { Remove-Item -LiteralPath $profileDir -Recurse -Force }
            Copy-Item -LiteralPath $payloadDir -Destination $profileDir -Recurse -Force -ErrorAction Stop
        } catch {
            Stop-DiscPersona -Code 'E06' `
                -Message ('Pre-packaged profile copy failed: ' + $profileDir) `
                -Hint 'Check free disk space and folder permissions, then retry.'
        }
        # Files on the disc are ReadOnly; copied over, they make dsh hit EPERM when writing settings (a temp file renamed over cordis.patch.yml)
        Add-DPLog -Message ('Cleared the read-only attribute on the pre-packaged profile: ' + (Clear-DPReadOnly -Path $profileDir) + ' files')
        $payloadUsedNow = $true

        # payload.json: records which plugins are installed and which dsh version packaged them (a parse failure does not block)
        $payloadManifest = Join-Path $payloadDir 'payload.json'
        if (Test-Path -LiteralPath $payloadManifest -PathType Leaf) {
            try {
                $pm = ConvertFrom-Json -InputObject (Read-DPTextFile -Path $payloadManifest) -ErrorAction Stop
                $names = @()
                foreach ($pl in @($pm.plugins)) { if ($pl) { $names += ([string]$pl.name + ' ' + [string]$pl.version) } }
                $payloadPluginNames = $names
                if ($pm.PSObject.Properties['preset'] -and $pm.preset) { $payloadPresetName = [string]$pm.preset }
                Add-DPLog -Message ('Plugin payload: ' + ($names -join ', ') + ' (packaged with dsh ' + [string]$pm.dshVersion + ', preset ' + $payloadPresetName + ')')
            } catch {
                Add-DPLog -Message ('Cannot parse payload.json (launch continues): ' + $_.Exception.Message) -Level 'Warn'
            }
        }
    }

    $dshExe = Resolve-DshExecutable -Explicit $DshPath
    if (-not $dshExe) {
        Stop-DiscPersona -Code 'E04' `
            -Message 'Cannot find dsh (DeepSeek Harness) on this machine.' `
            -Hint 'Install DeepSeek Harness first, or set DISCPERSONA_DSH to the full path of dsh.cmd.'
    }
    Add-DPLog -Message ('dsh: ' + $dshExe)

    if (-not $payloadDir) {
        $ok = Invoke-DPProfileBootstrap -DshPath $dshExe -HomeDir $homeDir -WorkspaceDir $workspaceDir -LogsDir $logsDir -Stamp $stamp
        if (-not $ok) {
            Stop-DiscPersona -Code 'E09' `
                -Message 'The dsh web profile could not be generated on the first run.' `
                -Hint 'Make sure dsh runs on its own (dsh --profile web --port 0 --no-open in a terminal), or use a disc with a pre-packaged profile.'
        }
    }

    [void](Initialize-DPPersonaAssets -HomeDir $homeDir -PersonaDir $personaDir -WorkspaceDir $workspaceDir)
} else {
    Add-DPLog -Message 'Profile already exists, skipping first-run preparation.'
    # But credentials / seed / AGENTS may still be missing (a first run that failed midway), so catch up here
    [void](Initialize-DPPersonaAssets -HomeDir $homeDir -PersonaDir $personaDir -WorkspaceDir $workspaceDir)
}

# Persona card: synced on every launch (if the room persona.yml changes, the card follows)
[void](Sync-DPPersonaCard -HomeDir $homeDir -Name $personaName -Text $personaDoc.SystemPrompt)

# Workspace: pin the default workspace inside the room so it never shares the one under Documents
[void](Sync-DPWorkspace -HomeDir $homeDir -WorkspaceDir $workspaceDir -Title ($personaName + "'s room"))

# ---------------------------------------------------------------- 7. generate the patch
$personaPatch = Join-Path $homeDir 'persona.patch.yml'
try {
    Write-DPTextFile -Path $personaPatch -Text (New-DPPersonaPatchText -SystemPrompt $personaDoc.SystemPrompt)
} catch {
    Stop-DiscPersona -Code 'E06' `
        -Message ('Cannot write the persona patch: ' + $personaPatch) `
        -Hint 'Check free disk space and folder permissions, then retry.'
}
Add-DPLog -Message ('Patch generated: ' + $personaPatch)

$patchArgs = New-Object System.Collections.ArrayList
$userPatch = Join-Path $homeDir 'user.patch.yml'
if (Test-Path -LiteralPath $userPatch -PathType Leaf) {
    [void]$patchArgs.Add($userPatch)
    Add-DPLog -Message ('Found user.patch.yml; it is applied before the persona: ' + $userPatch)
}
[void]$patchArgs.Add($personaPatch)

# ---------------------------------------------------------------- 8. launch
$dshExecutable = Resolve-DshExecutable -Explicit $DshPath
if (-not $dshExecutable) {
    Stop-DiscPersona -Code 'E04' `
        -Message 'Cannot find dsh (DeepSeek Harness) on this machine.' `
        -Hint 'Install DeepSeek Harness first, or set DISCPERSONA_DSH to the full path of dsh.cmd.'
}

$lastPort = 0
if (Test-Path -LiteralPath $statePath) {
    try {
        $prevState = ConvertFrom-Json -InputObject (Read-DPTextFile -Path $statePath) -ErrorAction Stop
        if ($prevState.PSObject.Properties['lastPort'] -and $prevState.lastPort) { $lastPort = [int]$prevState.lastPort }
    } catch { }
}

$started = $null
$readyUrl = $null
$usedPort = 0
$attempts = New-Object System.Collections.ArrayList

# If the plugin payload (.discpersona\payload) fails to start, delete it, fall back to persona only, and retry once.
# That way a broken plugin on a disc never makes the persona completely unusable.
$payloadRetryLeft = 0
if ($payloadUsedNow) { $payloadRetryLeft = 1 }

for ($pass = 1; $pass -le 2; $pass++) {
    $portsToTry = New-Object System.Collections.ArrayList
    if ($lastPort -gt 0 -and -not (Test-DPPortListening -Port $lastPort)) {
        [void]$portsToTry.Add($lastPort)
        Add-DPLog -Message ('Reusing the previous port ' + $lastPort + '.')
    } elseif ($lastPort -gt 0) {
        Add-DPLog -Message ('The previous port ' + $lastPort + ' is in use, switching to automatic assignment.') -Level 'Warn'
    }
    [void]$portsToTry.Add(0)

    foreach ($port in $portsToTry) {
        $runStamp = Format-DPFileStamp
        $stdout = Join-Path $logsDir ('stdout-' + $runStamp + '.log')
        $stderr = Join-Path $logsDir ('stderr-' + $runStamp + '.log')
        try {
            $started = Start-DshInstance -DshPath $dshExecutable -HomeDir $homeDir -WorkingDir $workspaceDir `
                -Port $port -Patches @($patchArgs) -StdoutPath $stdout -StderrPath $stderr
        } catch {
            Add-DPLog -Message ('Failed to start dsh (port ' + $port + '): ' + $_.Exception.Message) -Level 'Error'
            [void]$attempts.Add($port)
            continue
        }
        $usedPort = $port
        Add-DPLog -Message ('dsh started (port ' + $port + ', wrapper PID ' + $started.Process.Id + ', waiting up to ' + $StartTimeoutSec + ' s).')
        $ready = Wait-DshUrl -Instance $started -TimeoutSec $StartTimeoutSec
        if ($ready.Url) {
            $readyUrl = $ready.Url
            break
        }
        Add-DPLog -Message ('Not ready this time (port ' + $port + ', process exited=' + $ready.Exited + ').') -Level 'Warn'
        if ($started.Process -and -not $started.Process.HasExited) { Stop-DPProcessTree -ProcessId $started.Process.Id }
        [void]$attempts.Add($port)
        if ($port -ne 0) { Add-DPLog -Message 'Retrying once with an automatically assigned port.' -Level 'Warn' }
        else { break }
    }

    if ($readyUrl) { break }
    if ($payloadRetryLeft -le 0) { break }

    # Reaching here means it did not start with the plugin payload: drop the payload and retry with the persona only
    $payloadRetryLeft = 0
    Add-DPLog -Message 'Start failed with the plugin payload; discarding the pre-packaged profile and retrying with the persona only.' -Level 'Warn'
    Write-DPLine ''
    Write-DPLine '  The plugin payload did not start; retrying with the persona only...' 'Yellow'
    try {
        if (Test-Path -LiteralPath $profileDir) { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction Stop }
    } catch {
        Add-DPLog -Message ('Failed to delete the pre-packaged profile: ' + $_.Exception.Message) -Level 'Error'
        break
    }
    $payloadUsedNow = $false
    $okFallback = Invoke-DPProfileBootstrap -DshPath $dshExecutable -HomeDir $homeDir -WorkspaceDir $workspaceDir -LogsDir $logsDir -Stamp (Format-DPFileStamp)
    if (-not $okFallback) {
        Add-DPLog -Message 'The fallback cold start could not generate a profile either.' -Level 'Error'
        break
    }
}

if (-not $readyUrl) {
    $lastStdout = $null
    try { $lastStdout = $started.Stdout } catch { }
    $tail = @()
    if ($lastStdout) { $tail = Get-DPLogTail -Path $lastStdout -Lines 15 }
    $errTail = @()
    try { $errTail = Get-DPLogTail -Path $started.Stderr -Lines 15 } catch { }
    Write-DPLine ''
    Write-DPLine '  ERROR E09: dsh did not finish starting within the time limit.' 'Red'
    Write-DPLine ('  What to do: retry once; if it still fails, send the log to the maintainer: ' + $script:DPLogPath) 'Yellow'
    if ($tail.Count -gt 0) {
        Write-DPLine '  -- last 15 lines of dsh output --' 'DarkGray'
        foreach ($line in $tail) { Write-DPLine ('  | ' + $line) 'DarkGray' }
    }
    if ($errTail.Count -gt 0) {
        Write-DPLine '  -- last lines of stderr --' 'DarkGray'
        foreach ($line in $errTail) { Write-DPLine ('  | ' + $line) 'DarkGray' }
    }
    Write-DPLine '  Error code: E09 (startup timed out)' 'DarkGray'
    Write-DPLine ''
    Add-DPLog -Message 'Startup timed out; the process was terminated.' -Level 'Error'
    exit 1
}

# ---------------------------------------------------------------- 9. record state / lock
$now = Format-DPTime
$state = [ordered]@{
    discID         = $discID
    name           = $personaName
    personaSource  = $personaSource
    personaVersion = $personaVersion
    bootCount      = 1
    firstBootAt    = $now
    lastBootAt     = $now
    lastPort       = 0
    lastUrl        = $readyUrl
}
if (Test-Path -LiteralPath $statePath) {
    try {
        $prev = ConvertFrom-Json -InputObject (Read-DPTextFile -Path $statePath) -ErrorAction Stop
        if ($prev.PSObject.Properties['bootCount'] -and $prev.bootCount) { $state.bootCount = [int]$prev.bootCount + 1 }
        if ($prev.PSObject.Properties['firstBootAt'] -and $prev.firstBootAt) { $state.firstBootAt = [string]$prev.firstBootAt }
    } catch { }
}
if ($pendingUpgrade) { $state.pendingPersonaUpgrade = $pendingUpgrade }
if ($payloadPluginNames) { $state.payloadPlugins = @($payloadPluginNames) }
if ($payloadPresetName) { $state.payloadPreset = $payloadPresetName }
$portMatch = [regex]::Match($readyUrl, '127\.0\.0\.1:(\d+)/')
if ($portMatch.Success) { $state.lastPort = [int]$portMatch.Groups[1].Value }

try {
    Write-DPTextFile -Path $statePath -Text ($state | ConvertTo-Json -Depth 4)
} catch {
    Add-DPLog -Message ('Failed to write state.json (launch continues): ' + $_.Exception.Message) -Level 'Warn'
}

$startTicks = Get-DPProcessStartTicks -ProcessId $started.Process.Id
Write-DPLock -Path $lockPath -ProcessId $started.Process.Id -StartTicks $startTicks -StartedAt $now -Port $state.lastPort
Add-DPLog -Message ('Lock recorded: PID ' + $started.Process.Id + ', port ' + $state.lastPort)

# ---------------------------------------------------------------- 10. final output
if (-not $NoBrowser) { Open-DPUrl -Url $readyUrl | Out-Null }

Write-DPLine ''
Write-DPLine '  diskLIFE started' 'Cyan'
$runNote = ''
if (-not $firstBoot) { $runNote = ' - run #' + $state.bootCount }
Write-DPLine ('  Persona: ' + $personaName + ' (v' + $personaVersion + ')' + $runNote)
Write-DPLine ('  URL: ' + $readyUrl)
Write-DPLine ('  Room: ' + $personaRoot)
Write-DPLine ('  Log: ' + $script:DPLogPath) 'DarkGray'
Write-DPLine ''
Add-DPLog -Message ('Launch complete: ' + $readyUrl + ' (run #' + $state.bootCount + ')')

# In an interactive window (double-clicked start.cmd) wait for a key; when output is redirected (script / automation) return at once so nothing hangs
$interactive = $true
try {
    if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { $interactive = $false }
} catch { $interactive = $false }

if (-not $NoWait -and $interactive) {
    Write-DPLine '  Press any key to close this window; closing it does not stop the instance, which keeps running in the background.' 'DarkGray'
    try {
        [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Start-Sleep -Seconds 1
    }
}
exit 0
