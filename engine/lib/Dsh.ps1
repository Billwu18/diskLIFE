# diskLIFE launch engine - dsh process management
# Responsible for: finding dsh, probing ports, starting the process, waiting for the ready URL, the single-instance lock.
# Reuses Test-DPProcessIdentity / Stop-DPProcessTree / Open-DPUrl from Common.ps1.

$script:DPDshReadyRegex = 'http://127\.0\.0\.1:\d+/\?token=[^\s"''<>]+'

function Resolve-DshExecutable {
    <#
      Find the dsh executable. Priority:
        -DshPath > DISCPERSONA_DSH > dsh.cmd / dsh.exe / dsh.bat / dsh on PATH
      Returns the full path, or $null when nothing is found.
      Note: a globally npm-installed dsh is a .cmd shim; the extension-less `dsh` on PATH is a bash script that Windows cannot start.
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
      Use TcpClient to probe whether a local port is already listening (no netstat, so localized output cannot differ).
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
      Return a "probably free" port for logging only; the real port still comes from --port 0, which lets dsh pick one.
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
      Start dsh web with DSH_HOME = $HomeDir and working directory = $WorkingDir.
      Redirect stdout/stderr to files (PS 5.1 Start-Process cannot redirect to a file, so this wraps cmd /d /s /c).
      Returns @{ Process = <the wrapper cmd.exe>; CommandLine = '...' ; Stdout; Stderr }
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

    # cmd one-line syntax: /d /s /c ""<exe>" <args> > "<out>" 2> "<err>"" (the outer pair of quotes is stripped by /s)
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
      Read a file another process is writing (cmd's > redirect grants only a write handle, so a normal read hits a sharing violation).
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
      Poll the stdout log for the ready line and return the URL; $null if the process exits early or the wait times out.
      Also tells the caller whether the process has exited (Exited / ExitCode).
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
            # Read once more so a "printed then exited" case is not missed
            if (Test-Path -LiteralPath $Instance.Stdout) {
                $text = Read-DPSharedText -Path $Instance.Stdout
                $m = [regex]::Match($text, $script:DPDshReadyRegex)
                if ($m.Success) { $url = $m.Value }
            }
            if ($url) { break }
            # The process has exited and there is no ready URL: waiting longer is pointless
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
      Read home\.lock (JSON). Returns $null when missing or corrupt.
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
      Tell whether a directory can anchor "where dsh is installed":
      Exclude system directories, user AppData and Program Files (unsuitable for a room), and require write access.
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
      Infer "where dsh is installed" as the default location for persona rooms (keep the room where dsh itself lives).

        1. Find the dsh executable (-DshPath / DISCPERSONA_DSH / PATH).
        2. If its directory is named npm-global / node_modules / .bin / npm,
           it is a package-manager directory, so go one level up and use that as the install root.
        3. That directory must be a "suitable root" (not system/AppData/Program Files, and writable).

      Returns $null when nothing suitable is found, and the caller falls back to %LOCALAPPDATA%.
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
