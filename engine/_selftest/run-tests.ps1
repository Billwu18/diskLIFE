#requires -Version 5.1
# diskLIFE launch engine self-test: build a fake disc + fake dsh and exercise first run / single instance / every error code.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File engine\_selftest\run-tests.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = $PSScriptRoot
$engine = Split-Path -Parent $here
$launch = Join-Path $engine 'launch.ps1'
$stub = Join-Path $here 'stub-dsh.cmd'
$silent = Join-Path $here 'stub-silent.cmd'
$stubAlive = Join-Path $here 'stub-alive.cmd'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$root = Join-Path $env:TEMP ('dp-selftest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root -Force | Out-Null

$results = New-Object System.Collections.ArrayList
function Write-Case {
    param([string]$Id, [string]$Title)
    Write-Host ''
    Write-Host ('=== ' + $Id + ' ' + $Title + ' ===') -ForegroundColor Cyan
}
function Add-Result {
    param([string]$Id, [string]$Title, [bool]$Pass, [string]$Detail)
    [void]$results.Add([pscustomobject]@{ Id = $Id; Title = $Title; Pass = $Pass; Detail = $Detail })
    if ($Pass) { Write-Host ('  [PASS] ' + $Id) -ForegroundColor Green }
    else { Write-Host ('  [FAIL] ' + $Id + ' :: ' + $Detail) -ForegroundColor Red }
}

function Save-Text {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function New-TestDisc {
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [switch]$NoPad,
        [switch]$NoSystemPrompt,
        [switch]$NoManifest
    )
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'persona\seed') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir '.discpersona') | Out-Null

    if (-not $NoPad) {
        $bytes = New-Object byte[] 4096
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        [System.IO.File]::WriteAllBytes((Join-Path $Dir 'pad.bin'), $bytes)
    }

    $personaYml = @"
# Fake persona for the self-test (diskLIFE selftest)
# this comment must be ignored
name: Alice
version: 1.2.3
system_prompt: |
  You are Alice, a member of the Millennium Science School game development club.
  You speak lightly, and now and then use "bonbon kabon" as a catchphrase.

  You like to explain complicated things very simply.
"@
    if ($NoSystemPrompt) {
        $personaYml = "# system_prompt deliberately missing`nname: Alice`nversion: 1.2.3`n"
    }
    Save-Text -Path (Join-Path $Dir 'persona\persona.yml') -Text $personaYml
    Save-Text -Path (Join-Path $Dir 'persona\meta.json') -Text ('{"name":"Alice","personaVersion":"1.2.3","format":1}')
    Save-Text -Path (Join-Path $Dir 'persona\seed\README.md') -Text 'One seed from the seed folder.'
    Save-Text -Path (Join-Path $Dir 'persona\AGENTS.md') -Text 'This is the AGENTS.md from the disc (written once on first run).'

    if (-not $NoManifest) {
        $files = [ordered]@{}
        foreach ($rel in @('persona/persona.yml', 'persona/meta.json', 'pad.bin')) {
            $full = Join-Path $Dir ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $full) {
                $files[$rel] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $manifest = [ordered]@{ format = 1; discID = ''; files = $files }
        Save-Text -Path (Join-Path $Dir '.discpersona\manifest.json') -Text ($manifest | ConvertTo-Json -Depth 5)
    }
}

function New-SourceHome {
    param([Parameter(Mandatory = $true)][string]$Dir, [switch]$NoCreds)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    if ($NoCreds) {
        Save-Text -Path (Join-Path $Dir '.credentials.yaml') -Text "version: 1`nrecords: {}`n"
        return
    }
    $cred = @"
version: 1
records:
  client-connection/browser-session:
    kind: grant
    payload:
      version: 1
      secret: selftest-browser-secret
  deepseek-account-platform/device:
    kind: grant
    payload:
      id: 00000000-0000-4000-8000-000000000000
  deepseek-account-platform/default:
    kind: grant
    payload:
      version: 1
      token: selftest-token-not-a-real-secret
      issuer: https://platform.deepseek.com
refs:
  DEEPSEEK_API_KEY: selftest-api-key-not-a-real-secret
"@
    Save-Text -Path (Join-Path $Dir '.credentials.yaml') -Text $cred
}

function Invoke-Launch {
    param([string[]]$ArgList)
    # The self-test must pass -NoWait: otherwise the engine waits for a key press and the test hangs
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $launch @ArgList '-NoWait' 2>&1 | Out-String
    return [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
}

function Show-Output {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim().Length -gt 0) { Write-Host ('  | ' + $line) -ForegroundColor DarkGray }
    }
}

function Stop-LockProcess {
    param([string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return }
    try {
        $obj = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($obj.pid) { & taskkill /PID ([int]$obj.pid) /T /F 2>$null | Out-Null }
    } catch { }
}

# ---------------------------------------------------------------- shared fixtures
$srcHome = Join-Path $root 'source-home'
New-SourceHome -Dir $srcHome
$srcHomeNoCred = Join-Path $root 'source-home-nocred'
New-SourceHome -Dir $srcHomeNoCred -NoCreds

# The self-test must bring its own credential source; it must not depend on the real source home of the test machine,
# or CI (a clean machine that never signed in to DSH) fails T1 with E07.
$savedRunSrc = $env:DISCPERSONA_SOURCE_HOME
$env:DISCPERSONA_SOURCE_HOME = $srcHome

$discBase = Join-Path $root 'disc-base'
New-TestDisc -Dir $discBase

# ---------------------------------------------------------------- T1 first run succeeds
Write-Case 'T1' 'first-run success path (prints the launch text + URL + correct patch content)'
$homeRoot1 = Join-Path $root 'homes-t1'
$t1 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '20')
Show-Output $t1.Output
Add-Result 'T1' 'first run' ($t1.Code -eq 0 -and $t1.Output -match 'diskLIFE started' -and $t1.Output -match '34567') ('exit=' + $t1.Code)

$personaRoot1 = @(Get-ChildItem -LiteralPath $homeRoot1 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
$patchPath = if ($personaRoot1) { Join-Path $personaRoot1.FullName 'home\persona.patch.yml' } else { $null }
$patchOk = $false
if ($patchPath -and (Test-Path -LiteralPath $patchPath)) {
    $patchText = [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8)
    Write-Host '  -- persona.patch.yml --' -ForegroundColor DarkGray
    foreach ($line in ($patchText -split "`r?`n")) { if ($line.Length -gt 0) { Write-Host ('  | ' + $line) -ForegroundColor DarkGray } }
    $patchOk = ($patchText -match '(?m)^- id: system-prompt') -and ($patchText -match 'personaPrefix: \|') -and
               ($patchText -match 'You are Alice') -and ($patchText -match 'bonbon kabon') -and
               ($patchText -notmatch 'this comment must be ignored')
}
Add-Result 'T1-patch' 'patch structure and content' $patchOk 'checks - id: system-prompt / personaPrefix: | / both body lines present'

$stateOk = $false
$statePath1 = if ($personaRoot1) { Join-Path $personaRoot1.FullName 'state.json' } else { $null }
if ($statePath1 -and (Test-Path -LiteralPath $statePath1)) {
    $st = Get-Content -LiteralPath $statePath1 -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('  state.json: ' + ($st | ConvertTo-Json -Compress)) -ForegroundColor DarkGray
    $stateOk = ($st.bootCount -eq 1) -and $st.discID -and $st.name -eq 'Alice' -and $st.personaVersion -eq '1.2.3' -and $st.lastPort -eq 34567
}
Add-Result 'T1-state' 'state.json fields' $stateOk 'discID/name/personaVersion/bootCount=1/lastPort=34567'

$seedOk = $false
$agentsOk = $false
if ($personaRoot1) {
    $seedOk = Test-Path -LiteralPath (Join-Path $personaRoot1.FullName 'workspace\memories\README.md')
    $agentsOk = Test-Path -LiteralPath (Join-Path $personaRoot1.FullName 'home\AGENTS.md')
}
Add-Result 'T1-seed' 'seed and AGENTS.md land on disk' ($seedOk -and $agentsOk) ('seed=' + $seedOk + ' agents=' + $agentsOk)

# ---------------------------------------------------------------- T2 second run -> E10
Write-Case 'T2' 'launch again while the process still runs -> E10 (already running, exit code 0)'
# Start an instance with a long-lived stub (prints the URL then sleeps 60), then start a second one at once
if ($statePath1) { Stop-LockProcess -LockPath (Join-Path (Split-Path -Parent $statePath1) 'home\.lock') }
$t2a = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stubAlive, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '20')
Write-Host '  -- first (long-lived stub) --' -ForegroundColor DarkGray
Show-Output $t2a.Output
$t2 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stubAlive, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '20')
Write-Host '  -- second (expect E10) --' -ForegroundColor DarkGray
Show-Output $t2.Output
$e10ok = ($t2a.Code -eq 0) -and ($t2.Code -eq 0) -and ($t2.Output -match 'already running') -and ($t2.Output -match 'E10') -and ($t2.Output -match '34568')
Add-Result 'T2' 'E10 already running' $e10ok ('first=' + $t2a.Code + ' second=' + $t2.Code)

if ($statePath1) { Stop-LockProcess -LockPath (Join-Path (Split-Path -Parent $statePath1) 'home\.lock') }

# ---------------------------------------------------------------- T3 missing pad.bin -> E01
Write-Case 'T3' 'delete pad.bin -> E01 incomplete disc'
$disc3 = Join-Path $root 'disc-no-pad'
Copy-Item -LiteralPath $discBase -Destination $disc3 -Recurse -Force
Remove-Item -LiteralPath (Join-Path $disc3 'pad.bin') -Force
$t3 = Invoke-Launch @('-DiscRoot', $disc3, '-DshPath', $stub, '-HomeRoot', (Join-Path $root 'homes-t3'), '-NoBrowser')
Show-Output $t3.Output
$ok3 = ($t3.Code -eq 1) -and ($t3.Output -match 'E01') -and ($t3.Output -match 'pad\.bin')
Add-Result 'T3' 'E01 incomplete disc' $ok3 ('exit=' + $t3.Code)

# ---------------------------------------------------------------- T4 manifest mismatch -> E03
Write-Case 'T4' 'modify persona.yml -> E03 files were modified'
$disc4 = Join-Path $root 'disc-tampered'
Copy-Item -LiteralPath $discBase -Destination $disc4 -Recurse -Force
Add-Content -LiteralPath (Join-Path $disc4 'persona\persona.yml') -Value '# sneaky extra line'
$t4 = Invoke-Launch @('-DiscRoot', $disc4, '-DshPath', $stub, '-HomeRoot', (Join-Path $root 'homes-t4'), '-NoBrowser')
Show-Output $t4.Output
$ok4 = ($t4.Code -eq 1) -and ($t4.Output -match 'E03') -and ($t4.Output -match 'persona/persona\.yml')
Add-Result 'T4' 'E03 files modified' $ok4 ('exit=' + $t4.Code)

# ---------------------------------------------------------------- T5 no credentials -> E07
Write-Case 'T5' 'source home has no LLM credentials -> E07'
$savedSrc = $env:DISCPERSONA_SOURCE_HOME
$env:DISCPERSONA_SOURCE_HOME = $srcHomeNoCred
$t5 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', (Join-Path $root 'homes-t5'), '-NoBrowser', '-StartTimeoutSec', '20')
if ($null -eq $savedSrc) { Remove-Item Env:\DISCPERSONA_SOURCE_HOME -ErrorAction SilentlyContinue } else { $env:DISCPERSONA_SOURCE_HOME = $savedSrc }
Show-Output $t5.Output
$ok5 = ($t5.Code -eq 1) -and ($t5.Output -match 'E07') -and ($t5.Output -match 'Sign in to DSH')
Add-Result 'T5' 'E07 missing credentials' $ok5 ('exit=' + $t5.Code)

# ---------------------------------------------------------------- T6 missing system_prompt -> E08
Write-Case 'T6' 'persona.yml has no system_prompt -> E08'
$disc6 = Join-Path $root 'disc-no-prompt'
New-TestDisc -Dir $disc6 -NoSystemPrompt
$t6 = Invoke-Launch @('-DiscRoot', $disc6, '-DshPath', $stub, '-HomeRoot', (Join-Path $root 'homes-t6'), '-NoBrowser')
Show-Output $t6.Output
$ok6 = ($t6.Code -eq 1) -and ($t6.Output -match 'E08')
Add-Result 'T6' 'E08 persona parse failure' $ok6 ('exit=' + $t6.Code)

# ---------------------------------------------------------------- T7 no dsh -> E04
Write-Case 'T7' 'no dsh on PATH -> E04'
$savedPath = $env:PATH
$env:PATH = (Join-Path $env:SystemRoot 'System32')
$t7 = Invoke-Launch @('-DiscRoot', $discBase, '-HomeRoot', (Join-Path $root 'homes-t7'), '-NoBrowser', '-StartTimeoutSec', '5')
$env:PATH = $savedPath
Show-Output $t7.Output
$ok7 = ($t7.Code -eq 1) -and ($t7.Output -match 'E04') -and ($t7.Output -match 'DISCPERSONA_DSH')
Add-Result 'T7' 'E04 dsh not found' $ok7 ('exit=' + $t7.Code)

# ---------------------------------------------------------------- T8 startup timeout -> E09
Write-Case 'T8' 'silent dsh + 3 second timeout -> E09 (with the last 15 lines)'
$t8 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $silent, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '3')
Show-Output $t8.Output
$ok8 = ($t8.Code -eq 1) -and ($t8.Output -match 'E09')
Add-Result 'T8' 'E09 startup timed out' $ok8 ('exit=' + $t8.Code)

# ---------------------------------------------------------------- T9 directory not writable -> E06
Write-Case 'T9' 'persona directory points at a file -> E06'
$blocker = Join-Path $root 'blocker.txt'
Save-Text -Path $blocker -Text 'not a directory'
$t9 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $blocker, '-NoBrowser')
Show-Output $t9.Output
$ok9 = ($t9.Code -eq 1) -and ($t9.Output -match 'E06')
Add-Result 'T9' 'E06 home not writable' $ok9 ('exit=' + $t9.Code)

# ---------------------------------------------------------------- T10 freeze on first run
Write-Case 'T10' 'the first run freezes the disc persona into the room (state.personaSource=room)'
$roomPersona = $null
$solidOk = $false
if ($personaRoot1) { $roomPersona = Join-Path $personaRoot1.FullName 'persona\persona.yml' }
if ($roomPersona -and (Test-Path -LiteralPath $roomPersona) -and $statePath1) {
    $roomText = [System.IO.File]::ReadAllText($roomPersona, [System.Text.Encoding]::UTF8)
    $st10 = Get-Content -LiteralPath $statePath1 -Raw -Encoding UTF8 | ConvertFrom-Json
    $solidOk = ($roomText -match 'bonbon kabon') -and ($st10.personaSource -eq 'room')
    Write-Host ('  personaSource=' + $st10.personaSource + '  personaVersion=' + $st10.personaVersion) -ForegroundColor DarkGray
}
Add-Result 'T10' 'freeze on first run' $solidOk 'room persona\persona.yml holds the body, state.personaSource=room'

# ---------------------------------------------------------------- T11 room wins + pending
Write-Case 'T11' 'a room persona edit takes effect; a newer disc version only records pendingPersonaUpgrade, never overwrites'
if ($roomPersona -and (Test-Path -LiteralPath $roomPersona)) {
    $roomText = [System.IO.File]::ReadAllText($roomPersona, [System.Text.Encoding]::UTF8)
    $roomText = $roomText.Replace('You are Alice, a member of the Millennium Science School game development club.', 'You are the edited room persona.')
    Save-Text -Path $roomPersona -Text $roomText
}

# Another disc with the same pad.bin (same discID), persona version 1.3.0
$disc11 = Join-Path $root 'disc-new-version'
Copy-Item -LiteralPath $discBase -Destination $disc11 -Recurse -Force
$yml11 = Join-Path $disc11 'persona\persona.yml'
$ymlText = [System.IO.File]::ReadAllText($yml11, [System.Text.Encoding]::UTF8)
$ymlText = $ymlText.Replace('You are Alice, a member of the Millennium Science School game development club.', 'You are a newer persona from the disc.')
Save-Text -Path $yml11 -Text $ymlText
Save-Text -Path (Join-Path $disc11 'persona\meta.json') -Text '{"name":"Alice","personaVersion":"1.3.0","format":1}'
$files11 = [ordered]@{}
foreach ($rel in @('persona/persona.yml', 'persona/meta.json', 'pad.bin')) {
    $full11 = Join-Path $disc11 ($rel -replace '/', '\')
    $files11[$rel] = (Get-FileHash -LiteralPath $full11 -Algorithm SHA256).Hash.ToLowerInvariant()
}
Save-Text -Path (Join-Path $disc11 '.discpersona\manifest.json') -Text ([ordered]@{ format = 1; discID = ''; files = $files11 } | ConvertTo-Json -Depth 5)

$t11 = Invoke-Launch @('-DiscRoot', $disc11, '-DshPath', $stub, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '20')
Show-Output $t11.Output
$pendingOk = $false
if ($patchPath -and (Test-Path -LiteralPath $patchPath) -and $statePath1) {
    $patch11 = [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8)
    $st11 = Get-Content -LiteralPath $statePath1 -Raw -Encoding UTF8 | ConvertFrom-Json
    $pending11 = $null
    if ($st11.PSObject.Properties['pendingPersonaUpgrade']) { $pending11 = $st11.pendingPersonaUpgrade }
    Write-Host ('  pendingPersonaUpgrade=' + ($pending11 | ConvertTo-Json -Compress)) -ForegroundColor DarkGray
    $pendingOk = ($patch11 -match 'You are the edited room persona.') -and ($patch11 -notmatch 'You are a newer persona from the disc.') -and
                 $pending11 -and ($pending11.to -eq '1.3.0') -and ($st11.personaVersion -eq '1.2.3')
}
Add-Result 'T11' 'room wins + pending' $pendingOk 'patch uses the room body; state records pendingPersonaUpgrade.to=1.3.0 and personaVersion stays 1.2.3'

# ---------------------------------------------------------------- T12 -UpgradePersona
Write-Case 'T12' '-UpgradePersona backs up, then overwrites, and clears pending'
if ($statePath1) { Stop-LockProcess -LockPath (Join-Path (Split-Path -Parent $statePath1) 'home\.lock') }
Start-Sleep -Milliseconds 300
$t12 = Invoke-Launch @('-DiscRoot', $disc11, '-DshPath', $stub, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '20', '-UpgradePersona')
Show-Output $t12.Output
$upgradeOk = $false
if ($patchPath -and (Test-Path -LiteralPath $patchPath) -and $statePath1 -and $personaRoot1) {
    $patch12 = [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8)
    $st12 = Get-Content -LiteralPath $statePath1 -Raw -Encoding UTF8 | ConvertFrom-Json
    $backups = @(Get-ChildItem -LiteralPath $personaRoot1.FullName -Directory -Filter 'persona.bak-*' -ErrorAction SilentlyContinue)
    $backupHasOld = $false
    foreach ($b in $backups) {
        $oldYml = Join-Path $b.FullName 'persona.yml'
        if (Test-Path -LiteralPath $oldYml) {
            $oldText = [System.IO.File]::ReadAllText($oldYml, [System.Text.Encoding]::UTF8)
            if ($oldText -match 'You are the edited room persona.') { $backupHasOld = $true }
        }
    }
    Write-Host ('  backup dirs=' + $backups.Count + '  personaVersion=' + $st12.personaVersion) -ForegroundColor DarkGray
    $upgradeOk = ($t12.Code -eq 0) -and ($patch12 -match 'You are a newer persona from the disc.') -and
                 ($backups.Count -ge 1) -and $backupHasOld -and
                 ($st12.personaVersion -eq '1.3.0') -and (-not $st12.PSObject.Properties['pendingPersonaUpgrade'])
}
Add-Result 'T12' '-UpgradePersona' $upgradeOk 'patch switches to the disc body; persona.bak-* holds the old body; state version 1.3.0 with no pending'

# ---------------------------------------------------------------- T13 recovery after a first-run E07
Write-Case 'T13' 'after a first-run E07 with the profile already created, a rerun fills in the credentials'
$home13 = Join-Path $root 'homes-t13'
$savedSrc13 = $env:DISCPERSONA_SOURCE_HOME
$env:DISCPERSONA_SOURCE_HOME = $srcHomeNoCred
$t13a = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $home13, '-NoBrowser', '-StartTimeoutSec', '20')
# Simulate "payload copy / cold boot bootstrap already created profiles\web" --
# This is exactly the situation where firstBoot is wrong and credentials would never be restored
New-Item -ItemType Directory -Force -Path (Join-Path $home13 'profiles\web') | Out-Null
$env:DISCPERSONA_SOURCE_HOME = $srcHome
$t13 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $home13, '-NoBrowser', '-StartTimeoutSec', '20')
if ($null -eq $savedSrc13) { Remove-Item Env:\DISCPERSONA_SOURCE_HOME -ErrorAction SilentlyContinue } else { $env:DISCPERSONA_SOURCE_HOME = $savedSrc13 }
Show-Output $t13.Output
# Under -HomeRoot is <discID>\home; the real room is that level
$home13Home = ''
$home13Child = @(Get-ChildItem -LiteralPath $home13 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($home13Child.Count -gt 0) { $home13Home = Join-Path $home13Child[0].FullName 'home' }
$cred13 = Join-Path $home13Home '.credentials.yaml'
$cred13Text = ''
if (Test-Path -LiteralPath $cred13) { $cred13Text = [System.IO.File]::ReadAllText($cred13, [System.Text.Encoding]::UTF8) }
Write-Host ('  first exit=' + $t13a.Code + ' / second exit=' + $t13.Code + ' / has credentials=' + ($cred13Text -ne '')) -ForegroundColor DarkGray
$ok13 = ($t13a.Code -eq 1) -and ($t13a.Output -match 'E07') -and
        ($t13.Code -eq 0) -and ($cred13Text -match 'DEEPSEEK_API_KEY') -and ($cred13Text -match 'deepseek-account-platform/default')
Add-Result 'T13' 'recovery after E07' $ok13 'with the profile already present, credentials are still imported and the launch succeeds'

# ---------------------------------------------------------------- T14 the workspace survives a pin
Write-Case 'T14' 'a rerun keeps pinnedSessionIds / archivedSessionIds'
$wsPath = Join-Path $home13Home 'storages\workspace.json'
$pinnedOk = $false
if (Test-Path -LiteralPath $wsPath) {
    $ws = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($wsPath, [System.Text.Encoding]::UTF8))
    # Add a pin by hand, launch again, and see whether it is written back
    $json = [System.IO.File]::ReadAllText($wsPath, [System.Text.Encoding]::UTF8).Replace('"pinnedSessionIds":[]', '"pinnedSessionIds":["sess-keep-me"]')
    [System.IO.File]::WriteAllText($wsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $t14 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $home13, '-NoBrowser', '-StartTimeoutSec', '20')
    $ws2 = [System.IO.File]::ReadAllText($wsPath, [System.Text.Encoding]::UTF8)
    $pinnedOk = ($t14.Code -eq 0) -and ($ws2 -match 'sess-keep-me')
    Write-Host ('  pin kept=' + ($ws2 -match 'sess-keep-me')) -ForegroundColor DarkGray
}
Add-Result 'T14' 'pin is not emptied' $pinnedOk 'a launch never resets pinnedSessionIds to an empty array'

if ($statePath1) { Stop-LockProcess -LockPath (Join-Path (Split-Path -Parent $statePath1) 'home\.lock') }

# ---------------------------------------------------------------- summary
Write-Host ''
Write-Host '================ self-test summary ================' -ForegroundColor Cyan
foreach ($r in $results) {
    $mark = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ('  [' + $mark + '] ' + $r.Id.PadRight(12) + ' ' + $r.Title)
}
$failed = @($results | Where-Object { -not $_.Pass })
if ($null -eq $savedRunSrc) { Remove-Item Env:\DISCPERSONA_SOURCE_HOME -ErrorAction SilentlyContinue } else { $env:DISCPERSONA_SOURCE_HOME = $savedRunSrc }
Write-Host ('  passed ' + ($results.Count - $failed.Count) + '/' + $results.Count)
Write-Host ('  temp dir: ' + $root)
Write-Host ''
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
