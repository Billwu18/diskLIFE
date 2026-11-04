<#
.SYNOPSIS
    为一个 Persona 光盘准备「对话舒适包」：把挑好的 DSH 插件装进一个干净的
    profile，打包成可以随盘分发的 payload（离线可用，别人首次启动不需要联网）。

.DESCRIPTION
    DiscPersona 的启动器会把光盘上的 .discpersona\payload\profile-web 整个复制到
    这个孩子的房间，代替 dsh 自己冷启动生成 profile。所以 payload 里必须同时有：
      package.json（dsh.profile.bundles 列出插件）
      node_modules（插件本体和它们的依赖）
      payload.json（给启动器看的元信息：dsh 版本、插件清单）

    本脚本在一个临时 DSH_HOME 里用 dsh 自己的 plugin 命令安装插件，把生成的
    profiles\web 复制到 -Out，再写 payload.json。可选 -Verify 会拿这份 payload
    真起一次 dsh，确认插件不会拖垮启动。

.PARAMETER Plugins
    要装的 npm 包名。默认是「对话舒适包」：dsh-soul-md（人设卡 + 文件式记忆）
    + dsh-persona-dafeiyu（人设库 + 免重启切换）。

.PARAMETER Out
    输出目录，默认 build\payload\profile-web（打包器会自动捡这个路径）。

.PARAMETER Force
    输出目录已存在时删掉重建。

.PARAMETER SkipVerify
    跳过最后的真启动验证（只想快速产出时用）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\New-ProfilePayload.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\New-ProfilePayload.ps1 -Plugins dsh-soul-md -Out build\payload\profile-web -Force
#>
[CmdletBinding()]
param(
    [string[]]$Plugins = @('dsh-soul-md', 'dsh-persona-dafeiyu'),
    [string]$Out = '',
    [switch]$Force,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptPath = $MyInvocation.MyCommand.Path
$toolsDir = Split-Path -Parent $scriptPath
$workspaceRoot = Split-Path -Parent $toolsDir
if (-not $Out) { $Out = Join-Path $workspaceRoot 'build\payload\profile-web' }
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
    # 护栏：只有工作区 / %LOCALAPPDATA%\DiscPersona 之下的目录才允许整棵删除
    if (-not (Test-UnderAllowedRoot -Path $Path)) {
        throw ('拒绝删除工作区之外的目录：' + $Path)
    }
    # 长路径 + 只读文件：robocopy 镜像空目录比 Remove-Item 稳
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
    if ($LASTEXITCODE -ge 8) { throw ('robocopy 失败（exit ' + $LASTEXITCODE + '）：' + $Source + ' -> ' + $Destination) }
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

# 护栏：-Out 必须落在工作区或 %LOCALAPPDATA%\DiscPersona 之下。
# 这个目录会被整体清空重铺（见 Remove-Tree），指错一次就是删用户的东西。
if (-not (Test-UnderAllowedRoot -Path $Out)) {
    Fail 'PL00' ('输出目录必须在工作区或 %LOCALAPPDATA%\DiscPersona 之下：' + $Out)
}

Write-Step ('输出：' + $Out)
if (Test-Path -LiteralPath $Out) {
    if (-not $Force) { Fail 'PL01' ('输出目录已存在：' + $Out + '（加 -Force 覆盖）') }
    $looksPayload = (Test-Path -LiteralPath (Join-Path $Out 'payload.json')) -or
                    (Test-Path -LiteralPath (Join-Path $Out 'profiles\web'))
    if (-not $looksPayload) {
        Write-Host ('  警告：这个目录里没有 payload.json / profiles\web，看起来不像插件载荷，仍按 -Force 覆盖。') -ForegroundColor Yellow
    }
    Remove-Tree -Path $Out
}

$dshExe = Resolve-DshExe
if (-not $dshExe) { Fail 'PL02' '找不到 dsh 命令，无法安装插件。' }
Write-Ok ('dsh：' + $dshExe)

$dshVersion = 'unknown'
try {
    $v = & $dshExe --version 2>$null | Select-Object -First 1
    if ($v) { $dshVersion = ($v -replace '^.*?(\d+\.\d+\.\d+[^\s]*)', '$1').Trim() }
} catch { }
Write-Ok ('dsh 版本：' + $dshVersion)

# ---------- 1. 在临时 home 里装插件 ----------
Write-Step ('在临时 home 安装插件：' + ($Plugins -join ', '))
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
    if ($code -ne 0) { Fail 'PL03' ('插件安装失败（exit ' + $code + '）：' + ($text -split "`n" | Select-Object -Last 3)) }
} finally {
    if ($null -eq $oldHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $oldHome }
}

$profileSrc = Join-Path $tempHome 'profiles\web'
if (-not (Test-Path -LiteralPath (Join-Path $profileSrc 'package.json'))) { Fail 'PL04' '安装后没有生成 profiles\web\package.json。' }

$pkg = Get-Content -LiteralPath (Join-Path $profileSrc 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$bundles = @($pkg.dsh.profile.bundles)
Write-Ok ('bundles：' + ($bundles -join ', '))

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

# ---------- 2. 复制到输出 ----------
Write-Step ('复制 profile 到 ' + $Out)
Copy-Tree -Source $profileSrc -Destination $Out
# 临时 home 里的本机痕迹不要带出去
foreach ($junk in @('node_modules\.cache', '.pnpm-store')) {
    $p = Join-Path $Out $junk
    if (Test-Path -LiteralPath $p) { Remove-Tree -Path $p }
}

$stats = Get-TreeStats -Path $Out
Write-Ok ('payload 文件数：' + $stats.FileCount + '，体积：' + [math]::Round($stats.Bytes / 1MB, 2) + ' MB')

# ---------- 3. payload.json ----------
$manifest = [ordered]@{
    format     = 1
    kind       = 'discpersona/profile-payload'
    builtAt    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    dshVersion = $dshVersion
    plugins    = $pluginInfo
    bundles    = $bundles
    fileCount  = $stats.FileCount
    bytes      = $stats.Bytes
    note       = '由 tools/New-ProfilePayload.ps1 生成；启动器复制到人格 home 的 profiles\web。'
}
$manifestPath = Join-Path $Out 'payload.json'
$json = $manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($manifestPath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Ok ('payload.json：' + $manifestPath)

# ---------- 4. 真启动验证 ----------
if (-not $SkipVerify) {
    Write-Step '验证：把 payload 当作 profile 真启动一次 dsh'
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
            Fail 'PL05' ('payload 起不来（90 秒没有就绪地址）：' + $tail)
        }
        Write-Ok ('payload 启动成功：' + $url)
    } finally {
        if ($proc -and -not $proc.HasExited) {
            & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
        }
        if ($null -eq $oldHome2) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $oldHome2 }
    }
    Remove-Tree -Path $verifyHome
}

Write-Host ''
Write-Host ('PAYLOAD_OK ' + [math]::Round($stats.Bytes / 1MB, 2) + 'MB files=' + $stats.FileCount + ' plugins=' + $Plugins.Count + ' out=' + $Out) -ForegroundColor Green
Write-Host '下一步：用 tools\New-Disc.ps1 打包时它会自动把 build\payload\profile-web 放进光盘。'
