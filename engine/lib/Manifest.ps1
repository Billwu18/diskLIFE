# DiscPersona 启动引擎 · 光盘完整性（manifest 校验）
# 规范形状（packer 产出）：
#   { "format": 1, "discID": "....", "files": { "persona/persona.yml": "<sha256>" } }
# 为兼容其它打包器，同时接受：
#   { "files": [ { "path": "...", "sha256": "..." } ] }
#   { "entries": [ ... ] } / 顶层数组 / 值写成 { "sha256": "..." }

function Get-DPManifestEntries {
    <#
      把 manifest 归一到 @( @{ Path = '...'; Hash = '...' } )。
      解析失败返回 $null（调用方决定是警告还是报错）。
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
            # 映射形状：{ "rel/path": "hash" }
            foreach ($prop in $collection.PSObject.Properties) {
                & $addEntry $prop.Name $prop.Value
            }
        }
    }

    return @($entries)
}

function Assert-DPDiscManifest {
    <#
      逐文件比对 SHA-256。任何失配/缺失 -> E03（带相对路径）。
      返回 @{ Checked = n }；manifest 不存在时不调用本函数（调用方只警告）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DiscRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $entries = Get-DPManifestEntries -Path $ManifestPath
    if ($null -eq $entries) {
        Stop-DiscPersona -Code 'E03' `
            -Message '这张光盘的校验清单（.discpersona\manifest.json）读不出来，无法确认文件是否完整。' `
            -Hint '请换一张光盘，或用 tools\New-Disc.ps1 重新制作一张。'
    }
    if ($entries.Count -eq 0) {
        Add-DPLog -Message '校验清单里没有任何文件条目，跳过逐文件校验。' -Level '警告'
        return [pscustomobject]@{ Checked = 0 }
    }

    $checked = 0
    foreach ($entry in $entries) {
        $rel = $entry.Path -replace '/', '\'
        if ($rel -match '(^|\\)\.\.(\\|$)') {
            Stop-DiscPersona -Code 'E03' `
                -Message ('这张光盘的文件被改动过：' + $entry.Path + '（清单里出现了越界路径）') `
                -Hint '请换一张光盘，或用 tools\New-Disc.ps1 重新制作一张。'
        }
        $full = Join-Path $DiscRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Stop-DiscPersona -Code 'E03' `
                -Message ('这张光盘的文件被改动过：' + $entry.Path + '（文件不见了）') `
                -Hint '请换一张光盘，或用 tools\New-Disc.ps1 重新制作一张。'
        }
        $actual = $null
        try {
            $actual = Get-DPFileSha256 -Path $full
        } catch {
            Stop-DiscPersona -Code 'E03' `
                -Message ('这张光盘的文件被改动过：' + $entry.Path + '（读不出来，可能已经损坏）') `
                -Hint '请换一张光盘，或用 tools\New-Disc.ps1 重新制作一张。'
        }
        if ($actual -ne $entry.Hash) {
            Stop-DiscPersona -Code 'E03' `
                -Message ('这张光盘的文件被改动过：' + $entry.Path) `
                -Hint '请换一张光盘，或用 tools\New-Disc.ps1 重新制作一张。'
        }
        $checked++
    }
    Add-DPLog -Message ('校验清单通过：' + $checked + ' 个文件 SHA-256 全部一致。')
    return [pscustomobject]@{ Checked = $checked }
}
