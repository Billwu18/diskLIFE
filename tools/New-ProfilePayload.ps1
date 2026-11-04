<#
.SYNOPSIS
    Prepare a conversation comfort pack for a Persona disc: install the chosen DSH plugins into a clean
    profile and pack it as a payload that ships on the disc (works offline; first start needs no network).

.DESCRIPTION
    The DiscPersona launcher copies .discpersona\payload\profile-web from the disc into
    the child's room instead of letting dsh cold-start a profile. So the payload must contain:
      package.json (dsh.profile.bundles lists the plugins)
      node_modules (the plugins themselves and their dependencies)
      payload.json (metadata for the launcher: dsh version, plugin list)

    This script installs plugins with dsh's own plugin command in a temporary DSH_HOME, copies the
    generated profiles\web to -Out, then writes payload.json. The optional -Verify step really starts
    dsh against that payload once to make sure the plugins do not break startup.

.PARAMETER Preset
    Preset combination; defaults to comfort:
      comfort  comfort pack = dsh-soul-md (persona card + file-based memory) + dsh-persona-dafeiyu (persona library + switch without restart)
      token    token saver = dsh-context-compress (soft compression) + dsh-faster-compress (background summaries)
               + dsh-read-image-compress (compress images before they enter the context)
      full     both of the above
      custom   supply -Plugins yourself

.PARAMETER Plugins
    npm package names to install (required with -Preset custom; separate several with spaces).

.PARAMETER Out
    Output directory; defaults to build\payload\<preset>\profile-web (the packer picks this path up automatically).

.PARAMETER Force
    Delete and rebuild the output directory if it already exists.

.PARAMETER SkipVerify
    Skip the final real-start verification (use when you only want a quick artifact).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\New-ProfilePayload.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\New-ProfilePayload.ps1 -Plugins dsh-soul-md -Out build\payload\profile-web -Force
#>
[CmdletBinding()]
param(
    [ValidateSet('comfort', 'token', 'full', 'custom')]
    [string]$Preset = 'comfort',
    [string[]]$Plugins = @(),
    [string]$Out = '',
    [switch]$Force,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptPath = $MyInvocation.MyCommand.Path
$toolsDir = Split-Path -Parent $scriptPath
$workspaceRoot = Split-Path -Parent $toolsDir
$presetTable = [ordered]@{
    comfort = @('dsh-soul-md', 'dsh-persona-dafeiyu')
    token   = @('dsh-context-compress', 'dsh-faster-compress', 'dsh-read-image-compress')
    full    = @('dsh-soul-md', 'dsh-persona-dafeiyu', 'dsh-context-compress', 'dsh-faster-compress', 'dsh-read-image-compress')
}
if ($Preset -ne 'custom') {
    $Plugins = $presetTable[$Preset]
}
elseif (-not $Plugins -or $Plugins.Count -eq 0) {
    Write-Host '  !!  -Preset custom needs -Plugins to name the packages (separate several with spaces).' -ForegroundColor Red
    exit 1
}

if (-not $Out) { $Out = Join-Path $workspaceRoot ('build\payload' + $Preset + '\profile-web') }
elseif (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $workspaceRoot $Out }

$buildDir = Join-Path $workspaceRoot 'build'
$tempHome = Join-Path $buildDir '_payload-home'
$verifyHome = Join-Path $buildDir '_payload-verify'

function Write-Step { param([string]$Message) Write-Host ('==> ' + $Message) -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host ('  OK  ' + $Message) -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host ('  --  ' + $Message) -ForegroundColor DarkGray }
function Fail { param([string]$Code, [string]$Message)
    Write-Host ('PAYLOAD_FAIL ' + $Code + ' ' + $Message) -ForegroundColor Red
    exit 1
}

function Test-UnderAllowedRoot {
    param([string]$Path)
    $roots = @($workspaceRoot)
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'DiscPersona') }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('')
    foreach ($r in $roots) {
        $rr = [System.IO.Path]::GetFullPath($r).TrimEnd('') + ''
        if ($full.StartsWith($rr, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Remove-Tree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    # Guard: only directories under the workspace / %LOCALAPPDATA%\DiscPersona may be deleted wholesale
    if (-not (Test-UnderAllowedRoot -Path $Path)) {
        throw ('Refusing to delete a directory outside the workspace: ' + $Path)
    }
    # Long paths + read-only files: mirroring an empty dir with robocopy is more reliable than Remove-Item
    $empty = Join-Path $buildDir '_empty'
    if (-not (Test-Path -LiteralPath $empty)) { New-Item -ItemType Directory -Force -Path $empty | Out-Null }
    & robocopy $empty $Path /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    & robocopy $Source $Destination /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1 /MT:8 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('robocopy failed (exit ' + $LASTEXITCODE + '): ' + $Source + ' -> ' + $Destination) }
}

function Get-TreeStats {
    param([string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $bytes = 0
    foreach ($f in $files) { $bytes += $f.Length }
    return [pscustomobject]@{ FileCount = $files.Count; Bytes = $bytes }
}

function Resolve-DshExe {
    if ($env:DISCPERSONA_DSH -and (Test-Path -LiteralPath $env:DISCPERSONA_DSH)) { return $env:DISCPERSONA_DSH }
    foreach ($name in @('dsh.cmd', 'dsh.exe', 'dsh')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# Guard: -Out must live under the workspace or %LOCALAPPDATA%\DiscPersona.
# This directory is wiped and rewritten wholesale (see Remove-Tree); one wrong path deletes the user's data.
if (-not (Test-UnderAllowedRoot -Path $Out)) {
    Fail 'PL00' ('The output directory must live under the workspace or %LOCALAPPDATA%\DiscPersona: ' + $Out)
}

Write-Step ('Output: ' + $Out)
if (Test-Path -LiteralPath $Out) {
    if (-not $Force) { Fail 'PL01' ('Output directory already exists: ' + $Out + ' (use -Force to overwrite)') }
    $looksPayload = (Test-Path -LiteralPath (Join-Path $Out 'payload.json')) -or
                    (Test-Path -LiteralPath (Join-Path $Out 'profiles\web'))
    if (-not $looksPayload) {
        Write-Host ('  WARN: this directory has no payload.json / profiles\web, so it does not look like a plugin payload; overwriting anyway because -Force was given.') -ForegroundColor Yellow
    }
    Remove-Tree -Path $Out
}

$dshExe = Resolve-DshExe
if (-not $dshExe) { Fail 'PL02' 'Cannot find the dsh command, so plugins cannot be installed.' }
Write-Ok ('dsh: ' + $dshExe)

$dshVersion = 'unknown'
try {
    $v = & $dshExe --version 2>$null | Select-Object -First 1
    if ($v) { $dshVersion = ($v -replace '^.*?(\d+\.\d+\.\d+[^\s]*)', '$1').Trim() }
} catch { }
Write-Ok ('dsh version: ' + $dshVersion)

# ---------- 1. Install plugins into a temporary home ----------
Write-Step ('Installing plugins into a temporary home: ' + ($Plugins -join ', '))
Remove-Tree -Path $tempHome
New-Item -ItemType Directory -Force -Path $tempHome | Out-Null

$oldHome = $env:DSH_HOME
$env:DSH_HOME = $tempHome
try {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # dsh writes progress to stderr; do not treat it as fatal
    $installOutput = & $dshExe plugin --profile web add @Plugins 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    $text = ($installOutput | Out-String)
    Write-Host $text.TrimEnd()
    if ($code -ne 0) { Fail 'PL03' ('Plugin install failed (exit ' + $code + '): ' + ($text -split "`n" | Select-Object -Last 3)) }
} finally {
    if ($null -eq $oldHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $oldHome }
}

$profileSrc = Join-Path $tempHome 'profiles\web'
if (-not (Test-Path -LiteralPath (Join-Path $profileSrc 'package.json'))) { Fail 'PL04' 'profiles\web\package.json was not created after install.' }

$pkg = Get-Content -LiteralPath (Join-Path $profileSrc 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$bundles = @($pkg.dsh.profile.bundles)
Write-Ok ('bundles: ' + ($bundles -join ', '))

$pluginInfo = @()
foreach ($name in $Plugins) {
    $depVersion = $null
    if ($pkg.dependencies.PSObject.Properties.Name -contains $name) { $depVersion = $pkg.dependencies.$name }
    $installed = $null
    $pkgJson = Join-Path $profileSrc ('node_modules\' + ($name -replace '/', '\') + '\package.json')
    if (Test-Path -LiteralPath $pkgJson) {
        try { $installed = (Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
    }
    $pluginInfo += [ordered]@{ name = $name; range = $depVersion; version = $installed }
}

# ---------- 2. Copy to the output ----------
Write-Step ('Copying the profile to ' + $Out)
Copy-Tree -Source $profileSrc -Destination $Out
# Do not carry local traces from the temporary home outside
foreach ($junk in @('node_modules\.cache', '.pnpm-store')) {
    $p = Join-Path $Out $junk
    if (Test-Path -LiteralPath $p) { Remove-Tree -Path $p }
}

$stats = Get-TreeStats -Path $Out
Write-Ok ('payload files: ' + $stats.FileCount + ', size: ' + [math]::Round($stats.Bytes / 1MB, 2) + ' MB')

# ---------- 3. payload.json ----------
$manifest = [ordered]@{
    format     = 1
    kind       = 'discpersona/profile-payload'
    preset     = $Preset
    builtAt    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    dshVersion = $dshVersion
    plugins    = $pluginInfo
    bundles    = $bundles
    fileCount  = $stats.FileCount
    bytes      = $stats.Bytes
    note       = 'Generated by tools/New-ProfilePayload.ps1; the launcher copies it into profiles\web under the persona home.'
}
$manifestPath = Join-Path $Out 'payload.json'
$json = $manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($manifestPath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Ok ('payload.json: ' + $manifestPath)

# ---------- 4. Real-start verification ----------
if (-not $SkipVerify) {
    Write-Step 'Verify: start dsh once with the payload as its profile'
    Remove-Tree -Path $verifyHome
    New-Item -ItemType Directory -Force -Path (Join-Path $verifyHome 'profiles') | Out-Null
    Copy-Tree -Source $Out -Destination (Join-Path $verifyHome 'profiles\web')

    $stdout = Join-Path $buildDir '_payload-verify.out.log'
    $stderr = Join-Path $buildDir '_payload-verify.err.log'
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    $oldHome2 = $env:DSH_HOME
    $env:DSH_HOME = $verifyHome
    $proc = $null
    try {
        $proc = Start-Process -FilePath $dshExe -ArgumentList @('--profile', 'web', '--port', '0', '--no-open') `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
        $url = $null
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            if (Test-Path -LiteralPath $stdout) {
                $line = Select-String -LiteralPath $stdout -Pattern 'http://127\.0\.0\.1:\d+' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($line) { $url = $line.Matches[0].Value; break }
            }
            if ($proc.HasExited) { break }
        }
        if (-not $url) {
            $tail = ''
            if (Test-Path -LiteralPath $stderr) { $tail = (Get-Content -LiteralPath $stderr -Tail 8 -Encoding UTF8) -join ' / ' }
            if (Test-Path -LiteralPath $stdout) { $tail += ' | ' + ((Get-Content -LiteralPath $stdout -Tail 8 -Encoding UTF8) -join ' / ') }
            Fail 'PL05' ('payload did not start (no ready URL within 90 s): ' + $tail)
        }
        Write-Ok ('payload started: ' + $url)
    } finally {
        if ($proc -and -not $proc.HasExited) {
            & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
        }
        if ($null -eq $oldHome2) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $oldHome2 }
    }
    Remove-Tree -Path $verifyHome
}

Write-Host ''
Write-Host ('PAYLOAD_OK preset=' + $Preset + ' ' + [math]::Round($stats.Bytes / 1MB, 2) + 'MB files=' + $stats.FileCount + ' plugins=' + $Plugins.Count + ' out=' + $Out) -ForegroundColor Green
Write-Host ('Next: pack with tools\New-Disc.ps1 -PayloadPreset ' + $Preset + ', which picks up ' + $Out + ' automatically.')
