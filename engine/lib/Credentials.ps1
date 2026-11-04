# diskLIFE launch engine - credential import
# Block-level copy only: move the three LLM entries of the source home .credentials.yaml into the persona home as-is,
# without parsing, decoding, or printing any key value. Any browser-session grant already in the target file is kept as-is.

$script:DPCredentialRecordIds = @(
    'deepseek-account-platform/default',
    'deepseek-account-platform/device'
)
$script:DPCredentialRefKeys = @('DEEPSEEK_API_KEY')

function Get-DPCredentialDocument {
    <#
      Split .credentials.yaml into:
        VersionLine : 'version: 1'
        Records     : ordered dictionary record id -> the original lines of that record (including the "  <id>:" header line)
        RefLines    : original lines under the refs section (shaped like "  KEY: value")
      Block only by indentation/key name; values are kept as-is.
    #>
    param([string]$Path)

    $doc = [pscustomobject]@{
        VersionLine = 'version: 1'
        Records     = [ordered]@{}
        RefLines    = New-Object System.Collections.ArrayList
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $doc }

    $text = Read-DPTextFile -Path $Path
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $text.Split("`n")

    $mode = 'other'
    $currentId = $null
    $buffer = $null

    foreach ($line in $lines) {
        $raw = $line.TrimEnd()
        if ($raw.Length -eq 0) { continue }

        if ($raw -notmatch '^[ \t]') {
            # Top-level key: ends the current record
            if ($currentId -and $buffer) { $doc.Records[$currentId] = @($buffer) }
            $currentId = $null
            $buffer = $null
            if ($raw -match '^version\s*:') { $doc.VersionLine = $raw; $mode = 'version'; continue }
            if ($raw -match '^records\s*:') { $mode = 'records'; continue }
            if ($raw -match '^refs\s*:') { $mode = 'refs'; continue }
            $mode = 'other'
            continue
        }

        if ($mode -eq 'records') {
            if ($raw -match '^ {2}(\S.*?):\s*$') {
                if ($currentId -and $buffer) { $doc.Records[$currentId] = @($buffer) }
                $currentId = $Matches[1]
                $buffer = New-Object System.Collections.ArrayList
                [void]$buffer.Add($raw)
                continue
            }
            if ($currentId) { [void]$buffer.Add($raw) }
            continue
        }

        if ($mode -eq 'refs') {
            if ($raw -match '^ {2}\S') { [void]$doc.RefLines.Add($raw) }
            continue
        }
    }
    if ($currentId -and $buffer) { $doc.Records[$currentId] = @($buffer) }
    return $doc
}

function Write-DPCredentialDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Document
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("version: 1`n")
    if ($Document.Records.Count -eq 0) {
        [void]$sb.Append("records: {}`n")
    } else {
        [void]$sb.Append("records:`n")
        foreach ($id in $Document.Records.Keys) {
            foreach ($line in @($Document.Records[$id])) {
                [void]$sb.Append($line + "`n")
            }
        }
    }
    if ($Document.RefLines.Count -gt 0) {
        [void]$sb.Append("refs:`n")
        foreach ($line in $Document.RefLines) { [void]$sb.Append($line + "`n") }
    }
    Write-DPTextFile -Path $Path -Text $sb.ToString()
}

function Test-DPCredentialHasLlm {
    <#
      Tell whether a .credentials.yaml holds usable LLM credentials (checks that the keys exist, never reads values).
    #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $doc = Get-DPCredentialDocument -Path $Path
    foreach ($id in $script:DPCredentialRecordIds) {
        if (-not $doc.Records.Contains($id)) { return $false }
    }
    $hasRef = $false
    foreach ($line in $doc.RefLines) {
        if ($line -match '^\s*DEEPSEEK_API_KEY\s*:') { $hasRef = $true; break }
    }
    return $hasRef
}

function Import-DPLlmCredentials {
    <#
      Copy the LLM credentials of the source home into the persona home.
      Returns @{ Ok = bool; Reason = 'ok' | 'missing-source' | 'no-llm' | 'write-failed'; Count = n }
      - Copies only the deepseek-account-platform/default and .../device record blocks + refs.DEEPSEEK_API_KEY.
      - Other entries in the target file (such as the client-connection/browser-session that DSH creates) stay untouched.
      - No key content is ever printed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'missing-source'; Count = 0 }
    }
    try {
        $src = Get-DPCredentialDocument -Path $SourcePath
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = 'missing-source'; Count = 0 }
    }

    $imported = New-Object System.Collections.ArrayList
    foreach ($id in $script:DPCredentialRecordIds) {
        if ($src.Records.Contains($id)) { [void]$imported.Add($id) }
    }
    $srcRefLines = @()
    foreach ($line in $src.RefLines) {
        if ($line -match '^\s*DEEPSEEK_API_KEY\s*:') { $srcRefLines += $line }
    }
    if ($imported.Count -lt $script:DPCredentialRecordIds.Count -or $srcRefLines.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'no-llm'; Count = 0 }
    }

    try {
        $dst = Get-DPCredentialDocument -Path $TargetPath
        foreach ($id in $imported) { $dst.Records[$id] = @($src.Records[$id]) }
        # refs: replace a key with the same name, otherwise append
        $refs = New-Object System.Collections.ArrayList
        $replaced = @{}
        foreach ($line in $dst.RefLines) {
            $isTarget = $false
            foreach ($key in $script:DPCredentialRefKeys) {
                if ($line -match ('^\s*' + [regex]::Escape($key) + '\s*:')) {
                    $isTarget = $true
                    if (-not $replaced.ContainsKey($key)) {
                        [void]$refs.Add($srcRefLines[0])
                        $replaced[$key] = $true
                    }
                }
            }
            if (-not $isTarget) { [void]$refs.Add($line) }
        }
        foreach ($key in $script:DPCredentialRefKeys) {
            if (-not $replaced.ContainsKey($key)) {
                foreach ($line in $srcRefLines) { [void]$refs.Add($line) }
                $replaced[$key] = $true
            }
        }
        $dst.RefLines = $refs

        $parent = Split-Path -Parent $TargetPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop | Out-Null
        }
        Write-DPCredentialDocument -Path $TargetPath -Document $dst
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = 'write-failed'; Count = 0 }
    }

    return [pscustomobject]@{ Ok = $true; Reason = 'ok'; Count = $imported.Count + $srcRefLines.Count }
}

function Get-DPSourceHome {
    <#
      Source home resolution: DISCPERSONA_SOURCE_HOME > DSH_HOME > %USERPROFILE%\.dsh > %LOCALAPPDATA%\dsh
      Returns the first candidate directory that has .credentials.yaml; $null when none does.
    #>
    param([string]$Explicit)
    $candidates = New-Object System.Collections.ArrayList
    if ($Explicit) { [void]$candidates.Add($Explicit) }
    if ($env:DISCPERSONA_SOURCE_HOME) { [void]$candidates.Add($env:DISCPERSONA_SOURCE_HOME) }
    if ($env:DSH_HOME) { [void]$candidates.Add($env:DSH_HOME) }
    if ($env:USERPROFILE) { [void]$candidates.Add([System.IO.Path]::Combine($env:USERPROFILE, '.dsh')) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add([System.IO.Path]::Combine($env:LOCALAPPDATA, 'dsh')) }

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $full = Get-DPNormalizedPath -Path $c
        if (-not $full) { continue }
        # [System.IO.Path]::Combine does not validate the drive letter; Join-Path does and
        # throws "Cannot find drive" on machines where the candidate path does not exist.
        $credPath = [System.IO.Path]::Combine($full, '.credentials.yaml')
        try {
            if (Test-Path -LiteralPath $credPath) { return $full }
        } catch {
            continue
        }
    }
    return $null
}
