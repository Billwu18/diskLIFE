#requires -Version 5.1
# DiscPersona 启动引擎自测：造一张假光盘 + 假 dsh，跑通首启/单实例/各错误码。
# 用法：powershell.exe -NoProfile -ExecutionPolicy Bypass -File engine\_selftest\run-tests.ps1
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
# 自测用假人设（DiscPersona selftest）
# 这段注释应当被忽略
name: 蓝色大肥鱼
version: 1.2.3
system_prompt: |
  你是蓝色大肥鱼，住在光盘里的那条鱼。
  你说话轻快、偶尔用「咕噜」当口头禅。

  你喜欢把复杂的事讲得很简单。
"@
    if ($NoSystemPrompt) {
        $personaYml = "# 故意缺少 system_prompt`nname: 蓝色大肥鱼`nversion: 1.2.3`n"
    }
    Save-Text -Path (Join-Path $Dir 'persona\persona.yml') -Text $personaYml
    Save-Text -Path (Join-Path $Dir 'persona\meta.json') -Text ('{"name":"蓝色大肥鱼","personaVersion":"1.2.3","format":1}')
    Save-Text -Path (Join-Path $Dir 'persona\seed\README.md') -Text '这是 seed 里的一颗种子。'
    Save-Text -Path (Join-Path $Dir 'persona\AGENTS.md') -Text '这是光盘上的 AGENTS.md（首启写一次）。'

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
    # 自测必须 -NoWait：否则引擎会在「按任意键」处等输入，测试挂死
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

# ---------------------------------------------------------------- 公共素材
$srcHome = Join-Path $root 'source-home'
New-SourceHome -Dir $srcHome
$srcHomeNoCred = Join-Path $root 'source-home-nocred'
New-SourceHome -Dir $srcHomeNoCred -NoCreds

$discBase = Join-Path $root 'disc-base'
New-TestDisc -Dir $discBase

# ---------------------------------------------------------------- T1 首启成功
Write-Case 'T1' '首启成功路径（打印启动文案 + URL + patch 内容正确）'
$homeRoot1 = Join-Path $root 'homes-t1'
$t1 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '20')
Show-Output $t1.Output
Add-Result 'T1' '首启' ($t1.Code -eq 0 -and $t1.Output -match '已启动' -and $t1.Output -match '34567') ('exit=' + $t1.Code)

$personaRoot1 = @(Get-ChildItem -LiteralPath $homeRoot1 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
$patchPath = if ($personaRoot1) { Join-Path $personaRoot1.FullName 'home\persona.patch.yml' } else { $null }
$patchOk = $false
if ($patchPath -and (Test-Path -LiteralPath $patchPath)) {
    $patchText = [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8)
    Write-Host '  —— persona.patch.yml ——' -ForegroundColor DarkGray
    foreach ($line in ($patchText -split "`r?`n")) { if ($line.Length -gt 0) { Write-Host ('  | ' + $line) -ForegroundColor DarkGray } }
    $patchOk = ($patchText -match '(?m)^- id: system-prompt') -and ($patchText -match 'personaPrefix: \|') -and
               ($patchText -match '你是蓝色大肥鱼') -and ($patchText -match '咕噜') -and
               ($patchText -notmatch '这段注释应当被忽略')
}
Add-Result 'T1-patch' 'patch 结构与内容' $patchOk '检查 - id: system-prompt / personaPrefix: | / 正文两行均在内'

$stateOk = $false
$statePath1 = if ($personaRoot1) { Join-Path $personaRoot1.FullName 'state.json' } else { $null }
if ($statePath1 -and (Test-Path -LiteralPath $statePath1)) {
    $st = Get-Content -LiteralPath $statePath1 -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('  state.json: ' + ($st | ConvertTo-Json -Compress)) -ForegroundColor DarkGray
    $stateOk = ($st.bootCount -eq 1) -and $st.discID -and $st.name -eq '蓝色大肥鱼' -and $st.personaVersion -eq '1.2.3' -and $st.lastPort -eq 34567
}
Add-Result 'T1-state' 'state.json 字段' $stateOk 'discID/name/personaVersion/bootCount=1/lastPort=34567'

$seedOk = $false
$agentsOk = $false
if ($personaRoot1) {
    $seedOk = Test-Path -LiteralPath (Join-Path $personaRoot1.FullName 'workspace\memories\README.md')
    $agentsOk = Test-Path -LiteralPath (Join-Path $personaRoot1.FullName 'home\AGENTS.md')
}
Add-Result 'T1-seed' 'seed 与 AGENTS.md 落地' ($seedOk -and $agentsOk) ('seed=' + $seedOk + ' agents=' + $agentsOk)

# ---------------------------------------------------------------- T2 第二次运行 -> E10
Write-Case 'T2' '进程仍在运行时再启动一次 -> E10（已在运行，退出码 0）'
# 先用长命 stub（打印地址后 sleep 60）起一个实例，再立刻起第二次
if ($statePath1) { Stop-LockProcess -LockPath (Join-Path (Split-Path -Parent $statePath1) 'home\.lock') }
$t2a = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stubAlive, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '20')
Write-Host '  —— 第一次（长命 stub）——' -ForegroundColor DarkGray
Show-Output $t2a.Output
$t2 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stubAlive, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '20')
Write-Host '  —— 第二次（应当 E10）——' -ForegroundColor DarkGray
Show-Output $t2.Output
$e10ok = ($t2a.Code -eq 0) -and ($t2.Code -eq 0) -and ($t2.Output -match '已经在醒着') -and ($t2.Output -match 'E10') -and ($t2.Output -match '34568')
Add-Result 'T2' 'E10 已在运行' $e10ok ('first=' + $t2a.Code + ' second=' + $t2.Code)

if ($statePath1) { Stop-LockProcess -LockPath (Join-Path (Split-Path -Parent $statePath1) 'home\.lock') }

# ---------------------------------------------------------------- T3 缺 pad.bin -> E01
Write-Case 'T3' '删掉 pad.bin -> E01 光盘不完整'
$disc3 = Join-Path $root 'disc-no-pad'
Copy-Item -LiteralPath $discBase -Destination $disc3 -Recurse -Force
Remove-Item -LiteralPath (Join-Path $disc3 'pad.bin') -Force
$t3 = Invoke-Launch @('-DiscRoot', $disc3, '-DshPath', $stub, '-HomeRoot', (Join-Path $root 'homes-t3'), '-NoBrowser')
Show-Output $t3.Output
$ok3 = ($t3.Code -eq 1) -and ($t3.Output -match 'E01') -and ($t3.Output -match 'pad\.bin')
Add-Result 'T3' 'E01 光盘不完整' $ok3 ('exit=' + $t3.Code)

# ---------------------------------------------------------------- T4 manifest 失配 -> E03
Write-Case 'T4' '改动 persona.yml -> E03 文件被改动过'
$disc4 = Join-Path $root 'disc-tampered'
Copy-Item -LiteralPath $discBase -Destination $disc4 -Recurse -Force
Add-Content -LiteralPath (Join-Path $disc4 'persona\persona.yml') -Value '# 偷偷加一行'
$t4 = Invoke-Launch @('-DiscRoot', $disc4, '-DshPath', $stub, '-HomeRoot', (Join-Path $root 'homes-t4'), '-NoBrowser')
Show-Output $t4.Output
$ok4 = ($t4.Code -eq 1) -and ($t4.Output -match 'E03') -and ($t4.Output -match 'persona/persona\.yml')
Add-Result 'T4' 'E03 文件被改动' $ok4 ('exit=' + $t4.Code)

# ---------------------------------------------------------------- T5 无凭据 -> E07
Write-Case 'T5' '主 home 没有 LLM 凭据 -> E07'
$savedSrc = $env:DISCPERSONA_SOURCE_HOME
$env:DISCPERSONA_SOURCE_HOME = $srcHomeNoCred
$t5 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', (Join-Path $root 'homes-t5'), '-NoBrowser', '-StartTimeoutSec', '20')
if ($null -eq $savedSrc) { Remove-Item Env:\DISCPERSONA_SOURCE_HOME -ErrorAction SilentlyContinue } else { $env:DISCPERSONA_SOURCE_HOME = $savedSrc }
Show-Output $t5.Output
$ok5 = ($t5.Code -eq 1) -and ($t5.Output -match 'E07') -and ($t5.Output -match '登录')
Add-Result 'T5' 'E07 凭据缺失' $ok5 ('exit=' + $t5.Code)

# ---------------------------------------------------------------- T6 缺 system_prompt -> E08
Write-Case 'T6' 'persona.yml 没有 system_prompt -> E08'
$disc6 = Join-Path $root 'disc-no-prompt'
New-TestDisc -Dir $disc6 -NoSystemPrompt
$t6 = Invoke-Launch @('-DiscRoot', $disc6, '-DshPath', $stub, '-HomeRoot', (Join-Path $root 'homes-t6'), '-NoBrowser')
Show-Output $t6.Output
$ok6 = ($t6.Code -eq 1) -and ($t6.Output -match 'E08')
Add-Result 'T6' 'E08 人设解析失败' $ok6 ('exit=' + $t6.Code)

# ---------------------------------------------------------------- T7 找不到 dsh -> E04
Write-Case 'T7' 'PATH 上没有 dsh -> E04'
$savedPath = $env:PATH
$env:PATH = (Join-Path $env:SystemRoot 'System32')
$t7 = Invoke-Launch @('-DiscRoot', $discBase, '-HomeRoot', (Join-Path $root 'homes-t7'), '-NoBrowser', '-StartTimeoutSec', '5')
$env:PATH = $savedPath
Show-Output $t7.Output
$ok7 = ($t7.Code -eq 1) -and ($t7.Output -match 'E04') -and ($t7.Output -match 'DISCPERSONA_DSH')
Add-Result 'T7' 'E04 找不到 dsh' $ok7 ('exit=' + $t7.Code)

# ---------------------------------------------------------------- T8 启动超时 -> E09
Write-Case 'T8' '哑火 dsh + 3 秒超时 -> E09（附最后 15 行）'
$t8 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $silent, '-HomeRoot', $homeRoot1, '-NoBrowser', '-StartTimeoutSec', '3')
Show-Output $t8.Output
$ok8 = ($t8.Code -eq 1) -and ($t8.Output -match 'E09')
Add-Result 'T8' 'E09 启动超时' $ok8 ('exit=' + $t8.Code)

# ---------------------------------------------------------------- T9 目录不可写 -> E06
Write-Case 'T9' '人格目录指到一个文件上 -> E06'
$blocker = Join-Path $root 'blocker.txt'
Save-Text -Path $blocker -Text 'not a directory'
$t9 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $blocker, '-NoBrowser')
Show-Output $t9.Output
$ok9 = ($t9.Code -eq 1) -and ($t9.Output -match 'E06')
Add-Result 'T9' 'E06 home 写不进去' $ok9 ('exit=' + $t9.Code)

# ---------------------------------------------------------------- T10 首次运行即固化
Write-Case 'T10' '首启把盘上人设固化进房间（state.personaSource=room）'
$roomPersona = $null
$solidOk = $false
if ($personaRoot1) { $roomPersona = Join-Path $personaRoot1.FullName 'persona\persona.yml' }
if ($roomPersona -and (Test-Path -LiteralPath $roomPersona) -and $statePath1) {
    $roomText = [System.IO.File]::ReadAllText($roomPersona, [System.Text.Encoding]::UTF8)
    $st10 = Get-Content -LiteralPath $statePath1 -Raw -Encoding UTF8 | ConvertFrom-Json
    $solidOk = ($roomText -match '咕噜') -and ($st10.personaSource -eq 'room')
    Write-Host ('  personaSource=' + $st10.personaSource + '  personaVersion=' + $st10.personaVersion) -ForegroundColor DarkGray
}
Add-Result 'T10' '首次运行即固化' $solidOk '房间 persona\persona.yml 有正文，state.personaSource=room'

# ---------------------------------------------------------------- T11 房间优先 + pending
Write-Case 'T11' '改房间人设生效；盘上版本更高时只记 pendingPersonaUpgrade，不覆盖'
if ($roomPersona -and (Test-Path -LiteralPath $roomPersona)) {
    $roomText = [System.IO.File]::ReadAllText($roomPersona, [System.Text.Encoding]::UTF8)
    $roomText = $roomText.Replace('你是蓝色大肥鱼，住在光盘里的那条鱼。', '你是房间里改过的人设。')
    Save-Text -Path $roomPersona -Text $roomText
}

# 同 pad.bin 的另一张盘（同一 discID），人设版本 1.3.0
$disc11 = Join-Path $root 'disc-new-version'
Copy-Item -LiteralPath $discBase -Destination $disc11 -Recurse -Force
$yml11 = Join-Path $disc11 'persona\persona.yml'
$ymlText = [System.IO.File]::ReadAllText($yml11, [System.Text.Encoding]::UTF8)
$ymlText = $ymlText.Replace('你是蓝色大肥鱼，住在光盘里的那条鱼。', '你是盘上的一版新人设。')
Save-Text -Path $yml11 -Text $ymlText
Save-Text -Path (Join-Path $disc11 'persona\meta.json') -Text '{"name":"蓝色大肥鱼","personaVersion":"1.3.0","format":1}'
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
    $pendingOk = ($patch11 -match '房间里改过的人设') -and ($patch11 -notmatch '盘上的一版新人设') -and
                 $pending11 -and ($pending11.to -eq '1.3.0') -and ($st11.personaVersion -eq '1.2.3')
}
Add-Result 'T11' '房间优先 + pending' $pendingOk 'patch 用房间正文；state 记 pendingPersonaUpgrade.to=1.3.0，personaVersion 仍 1.2.3'

# ---------------------------------------------------------------- T12 -UpgradePersona
Write-Case 'T12' '-UpgradePersona 先备份再覆盖，pending 清空'
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
            if ($oldText -match '房间里改过的人设') { $backupHasOld = $true }
        }
    }
    Write-Host ('  备份目录数=' + $backups.Count + '  personaVersion=' + $st12.personaVersion) -ForegroundColor DarkGray
    $upgradeOk = ($t12.Code -eq 0) -and ($patch12 -match '盘上的一版新人设') -and
                 ($backups.Count -ge 1) -and $backupHasOld -and
                 ($st12.personaVersion -eq '1.3.0') -and (-not $st12.PSObject.Properties['pendingPersonaUpgrade'])
}
Add-Result 'T12' '-UpgradePersona' $upgradeOk 'patch 换成盘上正文；persona.bak-* 内含旧正文；state 版本 1.3.0 且无 pending'

# ---------------------------------------------------------------- T13 首启 E07 后自愈
Write-Case 'T13' '首启 E07 失败、profile 已被建出来后，重跑能补齐凭据'
$home13 = Join-Path $root 'homes-t13'
$savedSrc13 = $env:DISCPERSONA_SOURCE_HOME
$env:DISCPERSONA_SOURCE_HOME = $srcHomeNoCred
$t13a = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $home13, '-NoBrowser', '-StartTimeoutSec', '20')
# 模拟「payload 复制 / 冷启动 bootstrap 已经把 profiles\web 建出来」——
# 这正是 firstBoot 判断失效、凭据永远补不回来的那个现场
New-Item -ItemType Directory -Force -Path (Join-Path $home13 'profiles\web') | Out-Null
$env:DISCPERSONA_SOURCE_HOME = $srcHome
$t13 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $home13, '-NoBrowser', '-StartTimeoutSec', '20')
if ($null -eq $savedSrc13) { Remove-Item Env:\DISCPERSONA_SOURCE_HOME -ErrorAction SilentlyContinue } else { $env:DISCPERSONA_SOURCE_HOME = $savedSrc13 }
Show-Output $t13.Output
# -HomeRoot 下面是 <discID>\home，真正的房间在这一层
$home13Home = ''
$home13Child = @(Get-ChildItem -LiteralPath $home13 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($home13Child.Count -gt 0) { $home13Home = Join-Path $home13Child[0].FullName 'home' }
$cred13 = Join-Path $home13Home '.credentials.yaml'
$cred13Text = ''
if (Test-Path -LiteralPath $cred13) { $cred13Text = [System.IO.File]::ReadAllText($cred13, [System.Text.Encoding]::UTF8) }
Write-Host ('  第一次 exit=' + $t13a.Code + ' / 第二次 exit=' + $t13.Code + ' / 有凭据=' + ($cred13Text -ne '')) -ForegroundColor DarkGray
$ok13 = ($t13a.Code -eq 1) -and ($t13a.Output -match 'E07') -and
        ($t13.Code -eq 0) -and ($cred13Text -match 'DEEPSEEK_API_KEY') -and ($cred13Text -match 'deepseek-account-platform/default')
Add-Result 'T13' 'E07 后自愈' $ok13 'profile 已存在时仍会补导凭据并启动成功'

# ---------------------------------------------------------------- T14 工作区不会被 pin 清空
Write-Case 'T14' '重跑保留 pinnedSessionIds / archivedSessionIds'
$wsPath = Join-Path $home13Home 'storages\workspace.json'
$pinnedOk = $false
if (Test-Path -LiteralPath $wsPath) {
    $ws = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($wsPath, [System.Text.Encoding]::UTF8))
    # 手动塞一条 pin，再启动一次，看它是否被写回
    $json = [System.IO.File]::ReadAllText($wsPath, [System.Text.Encoding]::UTF8).Replace('"pinnedSessionIds":[]', '"pinnedSessionIds":["sess-keep-me"]')
    [System.IO.File]::WriteAllText($wsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $t14 = Invoke-Launch @('-DiscRoot', $discBase, '-DshPath', $stub, '-HomeRoot', $home13, '-NoBrowser', '-StartTimeoutSec', '20')
    $ws2 = [System.IO.File]::ReadAllText($wsPath, [System.Text.Encoding]::UTF8)
    $pinnedOk = ($t14.Code -eq 0) -and ($ws2 -match 'sess-keep-me')
    Write-Host ('  pinned 保留=' + ($ws2 -match 'sess-keep-me')) -ForegroundColor DarkGray
}
Add-Result 'T14' 'pin 不被清空' $pinnedOk '启动不会把 pinnedSessionIds 重置为空数组'

if ($statePath1) { Stop-LockProcess -LockPath (Join-Path (Split-Path -Parent $statePath1) 'home\.lock') }

# ---------------------------------------------------------------- 汇总
Write-Host ''
Write-Host '================ 自测汇总 ================' -ForegroundColor Cyan
foreach ($r in $results) {
    $mark = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ('  [' + $mark + '] ' + $r.Id.PadRight(12) + ' ' + $r.Title)
}
$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ('  通过 ' + ($results.Count - $failed.Count) + '/' + $results.Count)
Write-Host ('  临时目录：' + $root)
Write-Host ''
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
