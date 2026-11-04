# DiscPersona 启动引擎 · 极简 YAML 子集
# 只做两件事：
#   1) 从 persona\persona.yml 里取出 system_prompt 块标量（支持 | 与 >，保留缩进与换行）
#   2) 生成 dsh 的 system-prompt --patch 文件
# 不实现完整 YAML（锚点/标签/多文档/流式集合都不支持），边界见 docs\engine.md。

function ConvertFrom-DPYamlScalar {
    <#
      处理单行标量：去引号、还原常见转义。非引号值按原样返回（去掉行尾注释）。
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return '' }
    if ($t.StartsWith('"') -and $t.EndsWith('"') -and $t.Length -ge 2) {
        $inner = $t.Substring(1, $t.Length - 2)
        $inner = $inner -replace '\\n', "`n" -replace '\\r', "`r" -replace '\\t', "`t" -replace '\\"', '"' -replace '\\\\', '\'
        return $inner
    }
    if ($t.StartsWith("'") -and $t.EndsWith("'") -and $t.Length -ge 2) {
        return ($t.Substring(1, $t.Length - 2) -replace "''", "'")
    }
    # 未加引号：去掉行尾 " #注释"
    $idx = $t.IndexOf(' #')
    if ($idx -ge 0) { $t = $t.Substring(0, $idx).TrimEnd() }
    return $t
}

function Join-DPYamlFoldedLines {
    <#
      > 折叠标量：单个换行变空格，空行变真换行。
    #>
    param($Lines)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ln in @($Lines)) {
        if ($ln -eq '') {
            [void]$sb.Append("`n")
            continue
        }
        if ($sb.Length -gt 0 -and -not $sb.ToString().EndsWith("`n")) { [void]$sb.Append(' ') }
        [void]$sb.Append($ln)
    }
    return $sb.ToString()
}

function Read-DPPersonaDocument {
    <#
      解析 persona.yml。
      返回对象：
        HasSystemPrompt : 是否出现 system_prompt 键
        SystemPrompt    : 正文（LF 换行，不含块尾多余空行）
        Name            : 顶层 name:（可能为 $null）
        Version         : 顶层 version: / persona_version:（可能为 $null）
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $doc = [pscustomobject]@{
        HasSystemPrompt = $false
        SystemPrompt    = $null
        Name            = $null
        Version         = $null
    }

    $text = Read-DPTextFile -Path $Path
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $text.Split("`n")

    foreach ($line in $lines) {
        if (-not $doc.Name -and $line -match '^name\s*:\s*(.+?)\s*$') {
            $doc.Name = ConvertFrom-DPYamlScalar -Text $Matches[1]
            continue
        }
        if (-not $doc.Version -and $line -match '^(?:persona_)?version\s*:\s*(.+?)\s*$') {
            $doc.Version = ConvertFrom-DPYamlScalar -Text $Matches[1]
        }
    }

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $m = [regex]::Match($lines[$i], '^([ \t]*)system_prompt[ \t]*:[ \t]*(.*)$')
        if (-not $m.Success) { continue }

        $keyIndent = $m.Groups[1].Value.Length
        $rest = $m.Groups[2].Value.TrimEnd()
        $doc.HasSystemPrompt = $true

        $style = 'inline'
        if ($rest.StartsWith('|')) { $style = 'literal' }
        elseif ($rest.StartsWith('>')) { $style = 'folded' }
        elseif ($rest.Length -eq 0) { $style = 'plain' }

        if ($style -eq 'inline') {
            $doc.SystemPrompt = ConvertFrom-DPYamlScalar -Text $rest
            return $doc
        }

        $body = New-Object System.Collections.ArrayList
        $contentIndent = -1
        for ($j = $i + 1; $j -lt $lines.Length; $j++) {
            $ln = $lines[$j]
            if ($ln.Trim().Length -eq 0) { [void]$body.Add(''); continue }
            $ind = [regex]::Match($ln, '^[ \t]*').Length
            if ($contentIndent -lt 0) { $contentIndent = $ind }
            if ($ind -le $keyIndent) { break }
            if ($ind -lt $contentIndent) { break }
            [void]$body.Add($ln.Substring($contentIndent))
        }
        while ($body.Count -gt 0 -and $body[$body.Count - 1] -eq '') { $body.RemoveAt($body.Count - 1) }

        if ($style -eq 'folded') {
            $doc.SystemPrompt = Join-DPYamlFoldedLines -Lines $body
        } else {
            $doc.SystemPrompt = (@($body) -join "`n")
        }
        return $doc
    }

    return $doc
}

function New-DPPersonaPatchText {
    <#
      生成 system-prompt 的 patch（整段替换该 id 的 config）。
      形状（已用 dsh --dump-config 验证）：
        - id: system-prompt
          config:
            personaPrefix: |
              <正文>
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$SystemPrompt)

    $normalized = ($SystemPrompt -replace "`r`n", "`n" -replace "`r", "`n")
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# DiscPersona：由 engine\launch.ps1 依据光盘上的 persona\persona.yml 生成，每次启动都会重写。`n")
    [void]$sb.Append("- id: system-prompt`n")
    [void]$sb.Append("  config:`n")
    [void]$sb.Append("    personaPrefix: |`n")
    foreach ($ln in $normalized.Split("`n")) {
        if ($ln.Length -eq 0) {
            [void]$sb.Append("`n")
        } else {
            [void]$sb.Append('      ' + $ln + "`n")
        }
    }
    return $sb.ToString()
}

function New-DPUserPatchTemplate {
    <#
      给用户看的 user.patch.yml 模板说明（只在 docs 里引用，实际由用户自行创建）。
    #>
    return @'
# 可选：把你自己想加的 loader patch 写在这里（dsh --patch 格式，顶层数组）。
# 启动器会先应用本文件，再应用 persona.patch.yml，所以人设始终最后生效。
- id: system-prompt
  config:
    personaSuffix: |
      （这里可以追加你自己的补充说明）
'@
}
