# diskLIFE launch engine - disc integrity (manifest check)
# Canonical shape (produced by the packer):
#   { "format": 1, "discID": "....", "files": { "persona/persona.yml": "<sha256>" } }
# For compatibility with other packers, this is accepted too:
#   { "files": [ { "path": "...", "sha256": "..." } ] }
#   { "entries": [ ... ] } / top-level array / values written as { "sha256": "..." }

function Get-DPManifestEntries {
    <#
      Normalize the manifest to @( @{ Path = '...'; Hash = '...' } ).
      Returns $null on a parse failure (the caller decides between a warning and an error).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $entries = New-Object System.Collections.ArrayList
    try {
        $text = Read-DPTextFile -Path $Path
        $json = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        return $null
    }

    $addEntry = {
        param($relPath, $hashValue)
        if ($null -eq $relPath -or $null -eq $hashValue) { return }
        $rel = [string]$relPath
        $hash = ''
        if ($hashValue -is [string]) {
            $hash = $hashValue
        } elseif ($hashValue -is [System.Management.Automation.PSCustomObject]) {
            foreach ($name in @('sha256', 'hash', 'digest', 'checksum')) {
                $prop = $hashValue.PSObject.Properties[$name]
                if ($prop -and $prop.Value) { $hash = [string]$prop.Value; break }
            }
        }
        if ([string]::IsNullOrWhiteSpace($rel) -or [string]::IsNullOrWhiteSpace($hash)) { return }
        $hash = $hash.Trim()
        if ($hash -match '^(?i)sha256:') { $hash = $hash.Substring(7) }
        [void]$entries.Add([pscustomobject]@{ Path = $rel.Trim(); Hash = $hash.ToLowerInvariant() })
    }

    $collections = New-Object System.Collections.ArrayList
    if ($json -is [System.Array]) {
        [void]$collections.Add($json)
    } else {
        if ($json.PSObject.Properties['files']) { [void]$collections.Add($json.files) }
        elseif ($json.PSObject.Properties['entries']) { [void]$collections.Add($json.entries) }
        elseif ($json.PSObject.Properties['manifest']) { [void]$collections.Add($json.manifest) }
    }

    foreach ($collection in $collections) {
        if ($null -eq $collection) { continue }
        if ($collection -is [System.Array]) {
            foreach ($item in $collection) {
                if ($null -eq $item) { continue }
                if ($item -is [string]) { continue }
                $rel = $null
                $hash = $null
                foreach ($name in @('path', 'file', 'name', 'relativePath')) {
                    $prop = $item.PSObject.Properties[$name]
                    if ($prop -and $prop.Value) { $rel = $prop.Value; break }
                }
                foreach ($name in @('sha256', 'hash', 'digest', 'checksum')) {
                    $prop = $item.PSObject.Properties[$name]
                    if ($prop -and $prop.Value) { $hash = $prop.Value; break }
                }
                & $addEntry $rel $hash
            }
        } else {
            # Mapping shape: { "rel/path": "hash" }
            foreach ($prop in $collection.PSObject.Properties) {
                & $addEntry $prop.Name $prop.Value
            }
        }
    }

    return @($entries)
}

function Assert-DPDiscManifest {
    <#
      Compare SHA-256 file by file. Any mismatch/missing file -> E03 (with the relative path).
      Returns @{ Checked = n }; not called when the manifest is absent (the caller only warns).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DiscRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $entries = Get-DPManifestEntries -Path $ManifestPath
    if ($null -eq $entries) {
        Stop-DiscPersona -Code 'E03' `
            -Message 'Cannot read the check manifest of this disc (.discpersona\manifest.json), so file integrity cannot be confirmed.' `
            -Hint 'Use another disc, or rebuild one with tools\New-Disc.ps1.'
    }
    if ($entries.Count -eq 0) {
        Add-DPLog -Message 'The check manifest has no file entries; skipping the per-file check.' -Level 'Warn'
        return [pscustomobject]@{ Checked = 0 }
    }

    $checked = 0
    foreach ($entry in $entries) {
        $rel = $entry.Path -replace '/', '\'
        if ($rel -match '(^|\\)\.\.(\\|$)') {
            Stop-DiscPersona -Code 'E03' `
                -Message ('Files on this disc were modified: ' + $entry.Path + ' (path escapes the manifest root)') `
                -Hint 'Use another disc, or rebuild one with tools\New-Disc.ps1.'
        }
        $full = Join-Path $DiscRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Stop-DiscPersona -Code 'E03' `
                -Message ('Files on this disc were modified: ' + $entry.Path + ' (file is missing)') `
                -Hint 'Use another disc, or rebuild one with tools\New-Disc.ps1.'
        }
        $actual = $null
        try {
            $actual = Get-DPFileSha256 -Path $full
        } catch {
            Stop-DiscPersona -Code 'E03' `
                -Message ('Files on this disc were modified: ' + $entry.Path + ' (cannot be read; it may be damaged)') `
                -Hint 'Use another disc, or rebuild one with tools\New-Disc.ps1.'
        }
        if ($actual -ne $entry.Hash) {
            Stop-DiscPersona -Code 'E03' `
                -Message ('Files on this disc were modified: ' + $entry.Path) `
                -Hint 'Use another disc, or rebuild one with tools\New-Disc.ps1.'
        }
        $checked++
    }
    Add-DPLog -Message ('Check manifest passed: all ' + $checked + ' files match their SHA-256.')
    return [pscustomobject]@{ Checked = $checked }
}
