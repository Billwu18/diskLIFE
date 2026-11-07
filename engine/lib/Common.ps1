# diskLIFE launch engine - shared infrastructure
# paths / output encoding / logging / error codes
# Dot-sourced by engine\launch.ps1, never executed on its own. Compatible with Windows PowerShell 5.1.

# Error code table: code -> one-line category (the detailed text is supplied by the caller)
$script:DPErrorCodes = [ordered]@{
    E01 = 'incomplete disc'
    E02 = 'pad.bin cannot be read'
    E03 = 'files were modified'
    E04 = 'dsh not found'
    E05 = 'unsupported environment'
    E06 = 'home is not writable'
    E07 = 'missing credentials'
    E08 = 'persona file cannot be parsed'
    E09 = 'startup timed out'
    E10 = 'already running'
    E11 = 'sealed persona cannot be unlocked'
    E12 = 'wrong passphrase or damaged sealed persona'
}

# Runtime state (set by launch.ps1)
$script:DPLogPath = $null
$script:DPPersonaHome = $null

$script:DPUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Initialize-DPConsole {
    # PS 5.1 decodes non-ASCII text in a UTF-8 script as ANSI, so force UTF-8 explicitly
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
      Write one log line (always to the file; whether it echoes to the console is up to -Echo).
      Returns the assembled line so callers can reuse it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Notice', 'Warn', 'Error')][string]$Level = 'Info',
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
            'Warn' { Write-Host $line -ForegroundColor Yellow }
            'Error' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line }
        }
    }
    # Returns nothing on purpose: callers often use this purely for logging, and a return value would pollute theirs.
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
      Single failure exit: one-line conclusion + one "what to do" line + error code, exit code 1.
      Every error must go through here so the wording stays consistent.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Hint
    )
    $kind = $script:DPErrorCodes[$Code]
    if (-not $kind) { $kind = 'unknown error' }
    if ($script:DPLogPath) {
        try {
            [System.IO.File]::AppendAllText($script:DPLogPath, ('[{0}] [ERROR] {1} {2}' -f (Format-DPTime), $Code, $Message) + "`r`n", $script:DPUtf8NoBom)
            if ($Hint) {
                [System.IO.File]::AppendAllText($script:DPLogPath, ('[{0}] [ERROR] What to do: {1}' -f (Format-DPTime), $Hint) + "`r`n", $script:DPUtf8NoBom)
            }
        } catch { }
    }
    Write-DPLine ''
    Write-DPLine ('  ERROR ' + $Code + ': ' + $Message) 'Red'
    if ($Hint) { Write-DPLine ('  What to do: ' + $Hint) 'Yellow' }
    Write-DPLine ('  Error code: ' + $Code + ' (' + $kind + ')') 'DarkGray'
    Write-DPLine ''
    exit 1
}

function Assert-DPPlatform {
    <#
      E05: not Windows, or PowerShell < 5.1.
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
            -Message ('diskLIFE cannot run here: it needs Windows + PowerShell 5.1 or newer (current system ' + [System.Environment]::OSVersion.VersionString + ', PowerShell ' + $v.ToString() + ').') `
            -Hint 'Use a Windows 10 / Windows 11 machine and double-click start.cmd in the disc root.'
    }
}

function Get-DPNormalizedPath {
    <#
      Normalize a path coming from the user/start.cmd: strip surrounding quotes, make it absolute, drop a trailing backslash.
      Returns $null on failure.
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
      Create the directory and write a probe file to prove it is really writable (used by E06).
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
      Tell whether pid (with its recorded process start time) is still alive.
      PIDs get reused, so a start time that does not match counts as exited.
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
      Read strictly as UTF-8 (skipping a BOM automatically), so non-ASCII YAML / JSON reads correctly.
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
    Clear the read-only attribute across a tree (or one file); returns how many were cleared.
    .DESCRIPTION
    Files on the disc carry the ReadOnly attribute, and Copy-Item -Recurse copies it along.
    Afterwards dsh writing settings (a temp file renamed over cordis.patch.yml) hits EPERM,
    and editing the room persona is refused by the editor. So everything copied from the disc is cleared.
    Note: Get-ChildItem -Recurse returns directories too, and DirectoryInfo has no IsReadOnly;
    under StrictMode that throws and aborts the whole loop, so take only -File and test directories via Attributes.
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
      Write UTF-8 (no BOM). YAML / JSON are always BOM-free so parsers do not read the BOM as content.
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
      Take the last lines of the log, used by the E09 report.
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
