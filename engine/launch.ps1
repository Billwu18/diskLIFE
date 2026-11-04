#requires -Version 5.1
<#
  DiscPersona 启动引擎
  用法（由光盘根目录 start.cmd 调用）：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<disc>\engine\launch.ps1" -DiscRoot "<disc>"

  可选参数（测试/排障用，正常使用不需要）：
    -DshPath <path>        指定 dsh.cmd 全路径（等价环境变量 DISCPERSONA_DSH）
    -HomeRoot <path>       指定人格 home 的父目录（默认跟着 dsh 安装位置：<安装根>\DiscPersona\personas）
    -StartTimeoutSec <n>   等就绪的最大秒数（默认 60）
    -NoBrowser             不自动打开浏览器
    -UpgradePersona        用盘上的人设覆盖房间人设（先备份成 persona.bak-<时间戳>）
    -NoWait                启动完成后立刻返回，不等按键（自动化 / 自测 / 光驱守望者用）
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DiscRoot,
    [string]$DshPath,
    [string]$HomeRoot,
    [int]$StartTimeoutSec = 60,
    [switch]$NoBrowser,
    [switch]$UpgradePersona,
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

# ---------------------------------------------------------------- 1. 光盘完整性
$disc = Get-DPNormalizedPath -Path $DiscRoot
if (-not $disc -or -not (Test-Path -LiteralPath $disc -PathType Container)) {
    Stop-DiscPersona -Code 'E01' `
        -Message ('找不到这张光盘的根目录：' + $DiscRoot) `
        -Hint '请从光盘根目录双击 start.cmd 运行，不要单独拷贝 engine 文件夹。'
}

$required = @(
    @{ Rel = 'persona\persona.yml'; Label = '人设文件' },
    @{ Rel = 'persona\meta.json'; Label = '人设元信息' },
    @{ Rel = 'pad.bin'; Label = '光盘指纹文件' }
)
$missing = New-Object System.Collections.ArrayList
foreach ($item in $required) {
    $full = Join-Path $disc $item.Rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        [void]$missing.Add($item.Rel + '（' + $item.Label + '）')
    }
}
if ($missing.Count -gt 0) {
    Stop-DiscPersona -Code 'E01' `
        -Message ('这张光盘不完整，缺少：' + ($missing -join '、')) `
        -Hint '请换一张光盘，或用 tools\New-Disc.ps1 重新制作一张。'
}

# ---------------------------------------------------------------- 2. discID + manifest
$padPath = Join-Path $disc 'pad.bin'
try {
    $padHash = Get-DPFileSha256 -Path $padPath
} catch {
    Stop-DiscPersona -Code 'E02' `
        -Message 'pad.bin 读不出来，没法确认这是哪一张光盘。' `
        -Hint '光盘可能磨损或光驱读盘失败：请擦净光盘、换光驱重试，或重新制作一张。'
}
$discID = $padHash.Substring(0, 16)

$manifestPath = Join-Path $disc '.discpersona\manifest.json'
$manifestChecked = 0
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifestResult = Assert-DPDiscManifest -DiscRoot $disc -ManifestPath $manifestPath
    $manifestChecked = $manifestResult.Checked
}

# ---------------------------------------------------------------- 3. home / 日志
# 房间放哪：优先跟着 dsh 的安装位置走（用户要求），找不到才退回用户目录。
$baseRootSource = ''
if (-not [string]::IsNullOrWhiteSpace($HomeRoot)) {
    $baseRoot = Get-DPNormalizedPath -Path $HomeRoot
    if (-not $baseRoot) { $baseRoot = $HomeRoot }
    $baseRootSource = '命令行 -HomeRoot'
} elseif (-not [string]::IsNullOrWhiteSpace($env:DISCPERSONA_HOME)) {
    $baseRoot = Get-DPNormalizedPath -Path $env:DISCPERSONA_HOME
    if (-not $baseRoot) { $baseRoot = $env:DISCPERSONA_HOME }
    $baseRootSource = '环境变量 DISCPERSONA_HOME'
} else {
    $baseRoot = $null
    $installRoot = Get-DPInstallRootFromDsh -DshPath $DshPath
    if ($installRoot) {
        $candidate = Join-Path $installRoot 'DiscPersona\personas'
        if (Test-DPDirectoryWritable -Path $candidate) {
            $baseRoot = $candidate
            $baseRootSource = '跟着 dsh 安装位置（' + $installRoot + '）'
        }
    }
    if (-not $baseRoot) {
        $baseRoot = Join-Path $env:LOCALAPPDATA 'DiscPersona\personas'
        $baseRootSource = '没有可用的 dsh 安装位置，退回用户目录'
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
        -Message ('这个孩子的房间写不进去：' + $personaRoot) `
        -Hint '请检查磁盘空间和文件夹权限，或设置环境变量 LOCALAPPDATA 到一个可写目录后重试。'
}
foreach ($dir in @($homeDir, $logsDir, $workspaceDir)) {
    if (-not (Test-DPDirectoryWritable -Path $dir)) {
        Stop-DiscPersona -Code 'E06' `
            -Message ('这个孩子的房间写不进去：' + $dir) `
            -Hint '请检查磁盘空间和文件夹权限后重试。'
    }
}

$stamp = Format-DPFileStamp
$script:DPLogPath = Join-Path $logsDir ('launch-' + $stamp + '.log')
$script:DPPersonaHome = $personaRoot
Add-DPLog -Message ('DiscPersona 启动：光盘 ' + $disc + '，discID ' + $discID)
Add-DPLog -Message ('人格目录：' + $personaRoot)
Add-DPLog -Message ('房间根目录：' + $baseRoot + '（' + $baseRootSource + '）')
if ($manifestChecked -gt 0) {
    Add-DPLog -Message ('完整性校验：' + $manifestChecked + ' 个文件通过。')
} else {
    Add-DPLog -Message '没有 .discpersona\manifest.json，跳过逐文件校验（只确认了三个必需文件存在）。' -Level '警告'
}

# 只保留最近 10 个 launch 日志
try {
    $oldLogs = @(Get-ChildItem -LiteralPath $logsDir -Filter 'launch-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -Skip 10)
    foreach ($f in $oldLogs) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
} catch { }

# ---------------------------------------------------------------- 4. 读人设（房间优先，盘上兜底）
function Sync-DPPersonaCard {
    <#
      把房间里的人设同步成 dsh-persona-dafeiyu 的一张卡，并让它成为当前选中项。

      为什么需要这一步：dafeiyu 的库为空时会默认注入它自带的「大肥鱼」，
      于是系统提示里同时出现「大肥鱼」和 AGENTS.md 里的身份，模型会精神分裂。
      这里写一份 personas.json：current = discpersona（就是我们的人设），
      disabled 里禁掉内置的 dafeiyu / acha，正文每次启动按房间 persona.yml 重写，
      保证跟 AGENTS.md 始终是同一份。插件不在时静默跳过。
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
                Add-DPLog -Message ('旧人设库读不出来，按新建处理：' + $_.Exception.Message) -Level '警告'
            }
        }

        $card = [ordered]@{
            id          = 'discpersona'
            name        = $Name
            source      = 'imported'
            description = '这张光盘上的人设，由启动器每次启动同步'
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
        Add-DPLog -Message ('已同步人设卡：' + $Name + '（禁用内置大肥鱼 / 阿茶）')
        return $true
    } catch {
        Add-DPLog -Message ('人设卡同步失败（不阻塞启动）：' + $_.Exception.Message) -Level '警告'
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
      把 lorebook.json 里的条目拼成一段「世界书」附录。
      DiscPersona 走的是 --patch 通道，没有关键词检索能力，所以默认「全部常驻」：
      先按 constant=true 的优先级排，再按 insertion_order，累计到 -MaxChars 为止。
      超出的条目会在日志里报「略过 N 条」，不会静默丢失。
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
        Add-DPLog -Message ('lorebook.json 解析失败，已忽略：' + $_.Exception.Message) -Level '警告'
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
    [void]$sb.Append("## 世界书（设定，不是台词）`n")
    [void]$sb.Append("下面这些是你所在世界的事实。它们始终成立，但不要主动背诵，也不要逐条复述。`n")
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
    Add-DPLog -Message ('世界书：并入 ' + $kept + ' 条（约 ' + $used + ' 字），上限 ' + $MaxChars + ' 字' + $(if ($skipped -gt 0) { '，略过 ' + $skipped + ' 条' } else { '' }))
    return $sb.ToString()
}

function Compare-DPVersionText {
    <# 语义化比较：返回 -1 / 0 / 1；非数字段按字符串比，缺失段按 0。 #>
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

# -UpgradePersona：先备份房间人设，再让下面的「固化」用盘上的版本重建
$backupDir = $null
if ($UpgradePersona -and (Test-Path -LiteralPath $roomPersonaDir -PathType Container)) {
    $backupDir = Join-Path $personaRoot ('persona.bak-' + $stamp)
    try {
        Copy-Item -LiteralPath $roomPersonaDir -Destination $backupDir -Recurse -Force -ErrorAction Stop
        Remove-Item -LiteralPath $roomPersonaDir -Recurse -Force -ErrorAction Stop
        Add-DPLog -Message ('-UpgradePersona：房间人设已备份到 ' + $backupDir + '，改用盘上的版本。') -Level '提示'
    } catch {
        Add-DPLog -Message ('-UpgradePersona 备份失败，放弃覆盖：' + $_.Exception.Message) -Level '错误'
        $backupDir = $null
    }
}

$roomHadPersona = Test-Path -LiteralPath $roomPersonaYml -PathType Leaf
if (-not $roomHadPersona) {
    # 首次运行：把盘上的人设整份固化进房间，之后以房间为准
    try {
        if (Test-Path -LiteralPath $roomPersonaDir) { Remove-Item -LiteralPath $roomPersonaDir -Recurse -Force }
        Copy-Item -LiteralPath $discPersonaDir -Destination $roomPersonaDir -Recurse -Force -ErrorAction Stop
        Clear-DPReadOnly -Path $roomPersonaDir
        Add-DPLog -Message ('已把盘上的人设固化到房间：' + $roomPersonaDir) -Level '提示'
    } catch {
        Add-DPLog -Message ('人设固化失败，本次直接用盘上的：' + $_.Exception.Message) -Level '警告'
    }
    $roomHadPersona = Test-Path -LiteralPath $roomPersonaYml -PathType Leaf
}

$personaDir = if ($roomHadPersona) { $roomPersonaDir } else { $discPersonaDir }
$personaSource = if ($roomHadPersona) { 'room' } else { 'disc' }
$personaYml = Join-Path $personaDir 'persona.yml'

$meta = Read-DPMetaFile -Path (Join-Path $personaDir 'meta.json')
if (-not $meta.Name) {
    Add-DPLog -Message '人设 meta.json 里没有 name 字段，使用默认名字。' -Level '警告'
}

# 盘上人设比房间里新时：不静默覆盖，只记一笔待升级
$pendingUpgrade = $null
if ($personaSource -eq 'room') {
    $roomVersion = $meta.Version
    $discVersion = $discMeta.Version
    if ($discVersion -and (Compare-DPVersionText -Left $discVersion -Right $roomVersion) -gt 0) {
        $pendingUpgrade = [ordered]@{ from = $roomVersion; to = $discVersion }
        Add-DPLog -Message ('这张盘上的人设比房间里的新（' + $discVersion + ' > ' + $roomVersion + '），已保留房间版本；要更新请加 -UpgradePersona。') -Level '提示'
    }
}

try {
    $personaDoc = Read-DPPersonaDocument -Path $personaYml
} catch {
    Stop-DiscPersona -Code 'E08' `
        -Message ('人设文件读不出来或格式不对：' + $personaYml) `
        -Hint '请确认 persona.yml 是 UTF-8 文本，并且 system_prompt 使用 | 块标量写法。'
}
if (-not $personaDoc.HasSystemPrompt -or [string]::IsNullOrWhiteSpace([string]$personaDoc.SystemPrompt)) {
    Stop-DiscPersona -Code 'E08' `
        -Message ('人设文件里找不到 system_prompt：' + $personaYml) `
        -Hint '请在人设文件里写一段 system_prompt: | 开头的人设文本，或换一张光盘。'
}
if ($null -eq $personaDoc.SystemPrompt) { $personaDoc.SystemPrompt = '' }

# 世界书：常驻条目拼在 system_prompt 末尾（盘上 / 房间里的 lorebook.json）
$lorebookPath = Join-Path $personaDir 'lorebook.json'
$lorebookText = Get-DPLorebookText -Path $lorebookPath
if ($lorebookText -ne '') {
    $personaDoc.SystemPrompt = $personaDoc.SystemPrompt.TrimEnd() + "`n`n" + $lorebookText
}

$personaName = '未命名'
if ($meta.Name) { $personaName = $meta.Name }
elseif ($personaDoc.Name) { $personaName = $personaDoc.Name }

$personaVersion = '1.0.0'
if ($meta.Version) { $personaVersion = $meta.Version }
elseif ($personaDoc.Version) { $personaVersion = $personaDoc.Version }

Add-DPLog -Message ('人设来源：' + $personaSource + '（' + $personaYml + '），版本 ' + $personaVersion)

# ---------------------------------------------------------------- 5. 单实例锁
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
    Add-DPLog -Message ('已有实例在运行（PID ' + $lockPid + '），不再重复启动。') -Level '提示'
    Write-DPLine ''
    if ($lastUrl) {
        Write-DPLine ('  这个孩子已经在醒着了：' + $lastUrl) 'Cyan'
        if (-not $NoBrowser) { Open-DPUrl -Url $lastUrl | Out-Null }
    } else {
        Write-DPLine '  这个孩子已经在醒着了，但没记下地址。' 'Cyan'
    }
    Write-DPLine '  错误码：E10（已在运行）' 'DarkGray'
    Write-DPLine ''
    exit 0
}
if ($lock) {
    Add-DPLog -Message '发现上次残留的锁（进程已退出），继续启动。' -Level '警告'
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}

# 尽早抢占单实例锁：payload 复制 + 冷启动 bootstrap 要几十秒，
# 这期间并发双击会起两个实例（锁等到最后才写就挡不住）。
try {
    Write-DPLock -Path $lockPath -ProcessId $PID -StartTicks 0 -StartedAt ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Port 0
} catch {
    Add-DPLog -Message ('提前写锁失败（不阻塞启动）：' + $_.Exception.Message) -Level '警告'
}

# ---------------------------------------------------------------- 6. 首启准备
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
      把 dsh 的默认工作区钉在这个孩子的房间里，而不是系统「文档」下的
      deepseek-harness\default-workspace。

      为什么必须改：dsh 首次打开网页时会把默认工作区建在「文档」下，
      人格实例和主实例于是共用同一个目录 —— 记忆、AGENTS.md、随手写的文件
      都会串在一起。这里直接写一份 storage v2 的 workspace.json，
      只保留房间这一个工作区并设为默认（JSON 手写，避免 ConvertTo-Json 的空数组坑）。
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
                Add-DPLog -Message ('旧工作区记录读不出来，按新建处理：' + $_.Exception.Message) -Level '警告'
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
        Add-DPLog -Message ('默认工作区：' + $WorkspaceDir)
        return $true
    } catch {
        Add-DPLog -Message ('工作区记录修正失败（不阻塞启动）：' + $_.Exception.Message) -Level '警告'
        return $false
    }
}

function Invoke-DPProfileBootstrap {
    <#
      首启时让 dsh 自己把 shipped profile web 落到 DSH_HOME\profiles\web。
      为什么不 `dsh --profile web --from-default-profile web`：dsh 会拒绝（见 docs\engine.md）。
      做法：用 --port 0 冷启一次，拿到 URL（等它写好 profile）后立刻杀掉。
    #>
    param([string]$DshPath, [string]$HomeDir, [string]$WorkspaceDir, [string]$LogsDir, [string]$Stamp)

    $stdout = Join-Path $LogsDir ('bootstrap-' + $Stamp + '.log')
    $stderr = Join-Path $LogsDir ('bootstrap-' + $Stamp + '.err.log')
    $inst = Start-DshInstance -DshPath $DshPath -HomeDir $HomeDir -WorkingDir $WorkspaceDir -Port 0 `
        -Patches @() -StdoutPath $stdout -StderrPath $stderr
    Add-DPLog -Message ('脚手架：冷启动 dsh 生成 shipped profile web（PID ' + $inst.Process.Id + '）。')
    $ready = Wait-DshUrl -Instance $inst -TimeoutSec 45
    if ($inst.Process -and -not $inst.Process.HasExited) { Stop-DPProcessTree -ProcessId $inst.Process.Id }
    if (-not $ready.Url) {
        $tail = Get-DPLogTail -Path $stdout -Lines 15
        Add-DPLog -Message '脚手架冷启动没有拿到就绪地址。' -Level '警告'
        foreach ($line in $tail) { Add-DPLog -Message ('  | ' + $line) -Level '警告' }
        return $false
    }
    # 只要 dsh 打印了就绪地址，就认为这一步成功；profiles\web 会在真正启动时补齐。
    return $true
}

function Initialize-DPPersonaAssets {
    <#
      凭据 / seed / AGENTS.md 的幂等补课。

      为什么单独成函数：这几步原来只在 firstBoot 里做一次，而 firstBoot 只看
      profiles\web 存不存在（payload 复制就会创建它）。首启一旦在凭据那步失败
      （E07、断电、Ctrl-C），下次会走 else 分支，凭据就永远补不回来。
      所以每次启动都调用一次，缺什么补什么。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HomeDir,
        [Parameter(Mandatory = $true)][string]$PersonaDir,
        [Parameter(Mandatory = $true)][string]$WorkspaceDir
    )

    # 1) 凭据：只搬三条 LLM 相关记录，不解析、不打印
    $targetCred = Join-Path $HomeDir '.credentials.yaml'
    if (-not (Test-DPCredentialHasLlm -Path $targetCred)) {
        $sourceHome = Get-DPSourceHome
        if (-not $sourceHome) {
            Stop-DiscPersona -Code 'E07' `
                -Message '这台电脑上找不到 DeepSeek Harness 的凭据目录。' `
                -Hint '请先在本机正常登录过一次 DSH，或设置环境变量 DISCPERSONA_SOURCE_HOME 指向主 home。'
        }
        $sourceCred = Join-Path $sourceHome '.credentials.yaml'
        if (-not (Test-DPCredentialHasLlm -Path $sourceCred)) {
            Stop-DiscPersona -Code 'E07' `
                -Message ('主 home（' + $sourceHome + '）里没有可用的 DeepSeek 凭据。') `
                -Hint '请先在本机正常登录过一次 DSH（打开 DSH 并用 DeepSeek 账号登录），再插入这张光盘。'
        }
        $import = Import-DPLlmCredentials -SourcePath $sourceCred -TargetPath $targetCred
        if (-not $import.Ok) {
            if ($import.Reason -eq 'write-failed') {
                Stop-DiscPersona -Code 'E06' `
                    -Message ('凭据写不进这个房间：' + $targetCred) `
                    -Hint '请检查磁盘空间和文件夹权限后重试。'
            }
            Stop-DiscPersona -Code 'E07' `
                -Message ('凭据搬运失败（' + $import.Reason + '）：' + $sourceCred) `
                -Hint '请先在本机正常登录过一次 DSH 后重试。'
        }
        Add-DPLog -Message '已导入 DeepSeek 凭据（只搬记录，不读取密钥内容）。'
    }

    # 2) seed：只在房间还空着时铺一次，避免覆盖用户改过的记忆
    $seedSrc = Join-Path $PersonaDir 'seed'
    $seedDst = Join-Path $WorkspaceDir 'memories'
    $seedMissing = -not (Test-Path -LiteralPath $seedDst -PathType Container) -or
        @(Get-ChildItem -LiteralPath $seedDst -Force -ErrorAction SilentlyContinue).Count -eq 0
    if ((Test-Path -LiteralPath $seedSrc -PathType Container) -and $seedMissing) {
        try {
            if (-not (Test-Path -LiteralPath $seedDst)) { New-Item -ItemType Directory -Force -Path $seedDst | Out-Null }
            Copy-Item -Path (Join-Path $seedSrc '*') -Destination $seedDst -Recurse -Force -ErrorAction Stop
            Clear-DPReadOnly -Path $seedDst
            Add-DPLog -Message ('已把 persona\seed 复制到：' + $seedDst)
        } catch {
            Add-DPLog -Message ('persona\seed 复制失败（不阻塞启动）：' + $_.Exception.Message) -Level '警告'
        }
    }

    # 3) AGENTS.md：只在缺失时写，之后不覆盖（保护用户改动）
    $agentsSrc = Join-Path $PersonaDir 'AGENTS.md'
    $agentsDst = Join-Path $HomeDir 'AGENTS.md'
    if ((Test-Path -LiteralPath $agentsSrc -PathType Leaf) -and -not (Test-Path -LiteralPath $agentsDst)) {
        try {
            Copy-Item -LiteralPath $agentsSrc -Destination $agentsDst -Force -ErrorAction Stop
            Clear-DPReadOnly -Path $agentsDst
            Add-DPLog -Message ('已写入 AGENTS.md：' + $agentsDst)
        } catch {
            Add-DPLog -Message ('AGENTS.md 复制失败（不阻塞启动）：' + $_.Exception.Message) -Level '警告'
        }
    }
}

if ($firstBoot) {
    Add-DPLog -Message '首次启动：准备 profile、凭据、seed。' -Level '提示'

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
        Add-DPLog -Message ('使用光盘预打包 profile：' + $payloadDir)
        try {
            $parent = Split-Path -Parent $profileDir
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            if (Test-Path -LiteralPath $profileDir) { Remove-Item -LiteralPath $profileDir -Recurse -Force }
            Copy-Item -LiteralPath $payloadDir -Destination $profileDir -Recurse -Force -ErrorAction Stop
        } catch {
            Stop-DiscPersona -Code 'E06' `
                -Message ('预打包 profile 复制失败：' + $profileDir) `
                -Hint '请检查磁盘空间和文件夹权限后重试。'
        }
        # 光盘上的文件带 ReadOnly，复制过来会让 dsh 写设置时 EPERM（临时文件 rename 覆盖 cordis.patch.yml）
        Add-DPLog -Message ('清除预打包 profile 的只读属性：' + (Clear-DPReadOnly -Path $profileDir) + ' 个文件')
        $payloadUsedNow = $true

        # payload.json：记录装了哪些插件、用哪个 dsh 版本打的包（解析失败不阻塞）
        $payloadManifest = Join-Path $payloadDir 'payload.json'
        if (Test-Path -LiteralPath $payloadManifest -PathType Leaf) {
            try {
                $pm = ConvertFrom-Json -InputObject (Read-DPTextFile -Path $payloadManifest) -ErrorAction Stop
                $names = @()
                foreach ($pl in @($pm.plugins)) { if ($pl) { $names += ([string]$pl.name + ' ' + [string]$pl.version) } }
                $payloadPluginNames = $names
                if ($pm.PSObject.Properties['preset'] -and $pm.preset) { $payloadPresetName = [string]$pm.preset }
                Add-DPLog -Message ('插件载荷：' + ($names -join '、') + '（打包时 dsh ' + [string]$pm.dshVersion + '，预设 ' + $payloadPresetName + '）')
            } catch {
                Add-DPLog -Message ('payload.json 解析失败（不阻塞启动）：' + $_.Exception.Message) -Level '警告'
            }
        }
    }

    $dshExe = Resolve-DshExecutable -Explicit $DshPath
    if (-not $dshExe) {
        Stop-DiscPersona -Code 'E04' `
            -Message '这台电脑上找不到 dsh（DeepSeek Harness）。' `
            -Hint '请先安装 DeepSeek Harness，或设置环境变量 DISCPERSONA_DSH 指向 dsh.cmd 的完整路径。'
    }
    Add-DPLog -Message ('dsh：' + $dshExe)

    if (-not $payloadDir) {
        $ok = Invoke-DPProfileBootstrap -DshPath $dshExe -HomeDir $homeDir -WorkspaceDir $workspaceDir -LogsDir $logsDir -Stamp $stamp
        if (-not $ok) {
            Stop-DiscPersona -Code 'E09' `
                -Message '首次启动时没能生成 dsh 的 web profile。' `
                -Hint '请确认 dsh 能单独运行（在终端执行 dsh --profile web --port 0 --no-open），或换一张带预打包 profile 的光盘。'
        }
    }

    Initialize-DPPersonaAssets -HomeDir $homeDir -PersonaDir $personaDir -WorkspaceDir $workspaceDir
} else {
    Add-DPLog -Message 'profile 已存在，跳过首启准备。'
    # 但凭据 / seed / AGENTS 仍然可能缺（首启中途失败过），这里补课
    Initialize-DPPersonaAssets -HomeDir $homeDir -PersonaDir $personaDir -WorkspaceDir $workspaceDir
}

# 人设卡：每次启动都同步（房间里的 persona.yml 改了，卡片也要跟着变）
[void](Sync-DPPersonaCard -HomeDir $homeDir -Name $personaName -Text $personaDoc.SystemPrompt)

# 工作区：把默认工作区钉在房间内，别和主实例共用「文档」下的那个
[void](Sync-DPWorkspace -HomeDir $homeDir -WorkspaceDir $workspaceDir -Title ($personaName + '的房间'))

# ---------------------------------------------------------------- 7. 生成 patch
$personaPatch = Join-Path $homeDir 'persona.patch.yml'
try {
    Write-DPTextFile -Path $personaPatch -Text (New-DPPersonaPatchText -SystemPrompt $personaDoc.SystemPrompt)
} catch {
    Stop-DiscPersona -Code 'E06' `
        -Message ('人设 patch 写不进去：' + $personaPatch) `
        -Hint '请检查磁盘空间和文件夹权限后重试。'
}
Add-DPLog -Message ('已生成 patch：' + $personaPatch)

$patchArgs = New-Object System.Collections.ArrayList
$userPatch = Join-Path $homeDir 'user.patch.yml'
if (Test-Path -LiteralPath $userPatch -PathType Leaf) {
    [void]$patchArgs.Add($userPatch)
    Add-DPLog -Message ('发现 user.patch.yml，先于 persona 应用：' + $userPatch)
}
[void]$patchArgs.Add($personaPatch)

# ---------------------------------------------------------------- 8. 启动
$dshExecutable = Resolve-DshExecutable -Explicit $DshPath
if (-not $dshExecutable) {
    Stop-DiscPersona -Code 'E04' `
        -Message '这台电脑上找不到 dsh（DeepSeek Harness）。' `
        -Hint '请先安装 DeepSeek Harness，或设置环境变量 DISCPERSONA_DSH 指向 dsh.cmd 的完整路径。'
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

# 插件载荷（.discpersona\payload）如果起不来，就删掉、退回纯人设，再试一次。
# 这样一张盘上的插件坏了，也不会让这个孩子彻底打不开。
$payloadRetryLeft = 0
if ($payloadUsedNow) { $payloadRetryLeft = 1 }

for ($pass = 1; $pass -le 2; $pass++) {
    $portsToTry = New-Object System.Collections.ArrayList
    if ($lastPort -gt 0 -and -not (Test-DPPortListening -Port $lastPort)) {
        [void]$portsToTry.Add($lastPort)
        Add-DPLog -Message ('优先使用上次的端口 ' + $lastPort + '。')
    } elseif ($lastPort -gt 0) {
        Add-DPLog -Message ('上次的端口 ' + $lastPort + ' 已被占用，改用自动分配。') -Level '警告'
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
            Add-DPLog -Message ('启动 dsh 失败（端口 ' + $port + '）：' + $_.Exception.Message) -Level '错误'
            [void]$attempts.Add($port)
            continue
        }
        $usedPort = $port
        Add-DPLog -Message ('已拉起 dsh（端口 ' + $port + '，包装进程 PID ' + $started.Process.Id + '，等待最多 ' + $StartTimeoutSec + ' 秒）。')
        $ready = Wait-DshUrl -Instance $started -TimeoutSec $StartTimeoutSec
        if ($ready.Url) {
            $readyUrl = $ready.Url
            break
        }
        Add-DPLog -Message ('本次没有就绪（端口 ' + $port + '，进程已退出=' + $ready.Exited + '）。') -Level '警告'
        if ($started.Process -and -not $started.Process.HasExited) { Stop-DPProcessTree -ProcessId $started.Process.Id }
        [void]$attempts.Add($port)
        if ($port -ne 0) { Add-DPLog -Message '回退到自动分配端口重试一次。' -Level '警告' }
        else { break }
    }

    if ($readyUrl) { break }
    if ($payloadRetryLeft -le 0) { break }

    # 走到这里：带着插件载荷没起来 -> 丢弃载荷，纯人设重试
    $payloadRetryLeft = 0
    Add-DPLog -Message '带插件载荷启动失败，丢弃预打包 profile，回退纯人设重试一次。' -Level '警告'
    Write-DPLine ''
    Write-DPLine '  插件载荷没能启动，正在退回纯人设重试……' 'Yellow'
    try {
        if (Test-Path -LiteralPath $profileDir) { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction Stop }
    } catch {
        Add-DPLog -Message ('删除预打包 profile 失败：' + $_.Exception.Message) -Level '错误'
        break
    }
    $payloadUsedNow = $false
    $okFallback = Invoke-DPProfileBootstrap -DshPath $dshExecutable -HomeDir $homeDir -WorkspaceDir $workspaceDir -LogsDir $logsDir -Stamp (Format-DPFileStamp)
    if (-not $okFallback) {
        Add-DPLog -Message '回退时冷启动也没能生成 profile。' -Level '错误'
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
    Write-DPLine '  [E09] dsh 在限定时间内没有启动完成。' 'Red'
    Write-DPLine ('  怎么办：请重试一次；仍然失败就把日志发给维护者：' + $script:DPLogPath) 'Yellow'
    if ($tail.Count -gt 0) {
        Write-DPLine '  —— dsh 输出最后 15 行 ——' 'DarkGray'
        foreach ($line in $tail) { Write-DPLine ('  | ' + $line) 'DarkGray' }
    }
    if ($errTail.Count -gt 0) {
        Write-DPLine '  —— stderr 最后若干行 ——' 'DarkGray'
        foreach ($line in $errTail) { Write-DPLine ('  | ' + $line) 'DarkGray' }
    }
    Write-DPLine '  错误码：E09（启动超时）' 'DarkGray'
    Write-DPLine ''
    Add-DPLog -Message '启动超时，已终止进程。' -Level '错误'
    exit 1
}

# ---------------------------------------------------------------- 9. 记录状态 / 锁
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
    Add-DPLog -Message ('state.json 写入失败（不阻塞）：' + $_.Exception.Message) -Level '警告'
}

$startTicks = Get-DPProcessStartTicks -ProcessId $started.Process.Id
Write-DPLock -Path $lockPath -ProcessId $started.Process.Id -StartTicks $startTicks -StartedAt $now -Port $state.lastPort
Add-DPLog -Message ('已记录锁：PID ' + $started.Process.Id + '，端口 ' + $state.lastPort)

# ---------------------------------------------------------------- 10. 收尾输出
if (-not $NoBrowser) { Open-DPUrl -Url $readyUrl | Out-Null }

Write-DPLine ''
Write-DPLine '  DiscPersona 已启动' 'Cyan'
$runNote = ''
if (-not $firstBoot) { $runNote = ' · 第 ' + $state.bootCount + ' 次运行' }
Write-DPLine ('  人格：' + $personaName + '（v' + $personaVersion + '）' + $runNote)
Write-DPLine ('  地址：' + $readyUrl)
Write-DPLine ('  房间：' + $personaRoot)
Write-DPLine ('  日志：' + $script:DPLogPath) 'DarkGray'
Write-DPLine ''
Add-DPLog -Message ('启动完成：' + $readyUrl + '（第 ' + $state.bootCount + ' 次运行）')

# 交互式窗口（双击 start.cmd）里等用户按键；输出被重定向（脚本 / 自动化）时直接返回，避免挂死
$interactive = $true
try {
    if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { $interactive = $false }
} catch { $interactive = $false }

if (-not $NoWait -and $interactive) {
    Write-DPLine '  按任意键关闭这个窗口；关掉窗口不会停止实例，实例仍在后台运行。' 'DarkGray'
    try {
        [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Start-Sleep -Seconds 1
    }
}
exit 0
