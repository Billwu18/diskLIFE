# DiscPersona 启动引擎 · 凭据搬运
# 只做「块级搬运」：把主 home .credentials.yaml 里三条与 LLM 有关的条目原样搬进人格 home，
# 不解析、不解码、不打印任何密钥值。目标文件里已有的 browser-session grant 原样保留。

$script:DPCredentialRecordIds = @(
    'deepseek-account-platform/default',
    'deepseek-account-platform/device'
)
$script:DPCredentialRefKeys = @('DEEPSEEK_API_KEY')

function Get-DPCredentialDocument {
    <#
      把 .credentials.yaml 拆成：
        VersionLine : 'version: 1'
        Records     : 有序字典 记录 id -> 该记录的原始行（含 "  <id>:" 表头行）
        RefLines    : refs 段下的原始行（形如 "  KEY: value"）
      只按缩进/键名切块，值原样保留。
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
            # 顶层键：结束当前记录
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
      判断一个 .credentials.yaml 是否含可用的 LLM 凭据（只检查键是否存在，不读值）。
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
      把主 home 的 LLM 凭据搬进人格 home。
      返回 @{ Ok = bool; Reason = 'ok' | 'missing-source' | 'no-llm' | 'write-failed'; Count = n }
      - 只搬 deepseek-account-platform/default、.../device 两个 record 块 + refs.DEEPSEEK_API_KEY。
      - 目标文件里其它条目（例如 DSH 自己生成的 client-connection/browser-session）保持不动。
      - 全程不输出任何密钥内容。
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
        # refs：同名键替换，没有就追加
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
      主 home 定位：DISCPERSONA_SOURCE_HOME > E:\dsh\dsh-data > %USERPROFILE%\.dsh
      返回候选列表里第一个存在 .credentials.yaml 的目录；都不存在返回 $null。
    #>
    param([string]$Explicit)
    $candidates = New-Object System.Collections.ArrayList
    if ($Explicit) { [void]$candidates.Add($Explicit) }
    if ($env:DISCPERSONA_SOURCE_HOME) { [void]$candidates.Add($env:DISCPERSONA_SOURCE_HOME) }
    [void]$candidates.Add('E:\dsh\dsh-data')
    if ($env:USERPROFILE) { [void]$candidates.Add((Join-Path $env:USERPROFILE '.dsh')) }

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $full = Get-DPNormalizedPath -Path $c
        if (-not $full) { continue }
        if (Test-Path -LiteralPath (Join-Path $full '.credentials.yaml')) { return $full }
    }
    return $null
}
