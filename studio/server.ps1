<#
.SYNOPSIS
    DiscPersona Studio —— 本地「人设创建上位机」的服务端。

.DESCRIPTION
    只监听 127.0.0.1，把 studio\web 里的静态页面发给浏览器，并提供几个本地 API：
      GET  /api/env       环境：dsh 版本、光驱、已有的人设、payload 状态
      POST /api/export    把前端渲染好的人设文件写到 persona\<slug>\
      POST /api/build     调 tools\New-Disc.ps1 打成光盘目录
      POST /api/iso       调 tools\New-Iso.ps1 生成 ISO
      POST /api/burn      调 tools\Burn-Iso.ps1 刻录
      POST /api/draft     可选：调 DeepSeek 起草人设（默认关闭，前端开关控制）
      POST /api/open      在资源管理器里打开目录
      GET  /api/personas  列出已有的人设包

    服务端不信任前端：所有写入都被限制在工作区与 %LOCALAPPDATA%\DiscPersona 之下。

.PARAMETER Port
    端口，0 = 自动挑一个空闲端口。

.PARAMETER NoBrowser
    不自动打开浏览器。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File studio\server.ps1
#>
[CmdletBinding()]
param(
    # 默认 4791：地址稳定，方便收藏。0 = 让系统随便挑一个。
    [int]$Port = 4791,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$serverPath = $MyInvocation.MyCommand.Path
$studioDir = Split-Path -Parent $serverPath
$workspaceRoot = Split-Path -Parent $studioDir
$webDir = Join-Path $studioDir 'web'
$personaRootDefault = Join-Path $workspaceRoot 'persona'
$localAppData = $env:LOCALAPPDATA
$discPersonaRoot = Join-Path $localAppData 'DiscPersona'

function Write-Studio { param([string]$Message) Write-Host ('  ' + $Message) }

# ---------------------------------------------------------------- 端口
function Test-StudioPortBusy {
    param([int]$TestPort)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $TestPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(400)) { $c.Close(); return $false }
        $c.EndConnect($iar)
        $c.Close()
        return $true
    } catch {
        try { $c.Close() } catch { }
        return $false
    }
}

function Get-ExistingStudio {
    param([int]$TestPort)
    # 已经有一个 Studio 在跑？返回它的地址（顺便看它服务的是不是同一个工作区）
    try {
        $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $TestPort + '/api/env') -UseBasicParsing -TimeoutSec 3
        if ($resp.StatusCode -ne 200) { return $null }
        $obj = $resp.Content | ConvertFrom-Json
        if (-not $obj.ok -or -not $obj.url) { return $null }
        return [pscustomobject]@{ Url = [string]$obj.url; Workspace = [string]$obj.workspace }
    } catch {
        return $null
    }
}

if ($Port -le 0) {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $Port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
    $l.Stop()
}
else {
    # 双击 start-studio.cmd 两次、或者上一份没关干净时，这里会撞端口。
    # 先看是不是「另一个 Studio 已经在跑」——那就直接把浏览器指过去，不再起第二个。
    $existing = Get-ExistingStudio -TestPort $Port
    if ($existing) {
        Write-Host ''
        Write-Host '  DiscPersona Studio 已经在运行了。' -ForegroundColor Yellow
        Write-Host ('  地址：' + $existing.Url) -ForegroundColor Green
        if ($existing.Workspace -and ($existing.Workspace.TrimEnd('') -ne $workspaceRoot.TrimEnd(''))) {
            Write-Host ('  注意：它服务的是另一个工作区：' + $existing.Workspace) -ForegroundColor Yellow
        }
        Write-Host '  要重启就先把它那个窗口关掉（Ctrl+C）。'
        if (-not $NoBrowser) { try { Start-Process $existing.Url | Out-Null } catch { } }
        return
    }
    # 端口被别的程序占了 → 往后找一个能用的
    if (Test-StudioPortBusy -TestPort $Port) {
        $picked = 0
        for ($p = $Port + 1; $p -le $Port + 20; $p++) {
            if (-not (Test-StudioPortBusy -TestPort $p)) { $picked = $p; break }
        }
        if (-not $picked) {
            Write-Host ('  端口 ' + $Port + ' 到 ' + ($Port + 20) + ' 都被占用了。') -ForegroundColor Red
            exit 1
        }
        Write-Host ''
        Write-Host ('  端口 ' + $Port + ' 已被别的程序占用，改用 ' + $picked + '。') -ForegroundColor Yellow
        $Port = $picked
    }
}

# HttpListener 还可能在「没人在听」的情况下报前缀冲突（残留的 http.sys 注册），所以绑定时也重试
$listener = $null
for ($attempt = 0; $attempt -le 20; $attempt++) {
    $candidate = New-Object System.Net.HttpListener
    $candidate.Prefixes.Add('http://127.0.0.1:' + $Port + '/')
    try {
        $candidate.Start()
        $listener = $candidate
        break
    } catch {
        $lastBindError = $_.Exception.Message
        try { $candidate.Close() } catch { }
        if ($attempt -eq 20) { break }
        $next = 0
        for ($p = $Port + 1; $p -le $Port + 21; $p++) {
            if (-not (Test-StudioPortBusy -TestPort $p)) { $next = $p; break }
        }
        if (-not $next) { break }
        Write-Host ('  端口 ' + $Port + ' 绑定失败，改用 ' + $next + '。') -ForegroundColor Yellow
        $Port = $next
    }
}
if (-not $listener) {
    Write-Host ''
    Write-Host '  Studio 启动失败：HttpListener 绑不上任何端口。' -ForegroundColor Red
    if ($lastBindError) { Write-Host ('  最后一次错误：' + $lastBindError) -ForegroundColor DarkGray }
    Write-Host '  常见原因：端口被占 / 需要管理员权限（换到 1024 以上一般就行）/ 系统 http.sys 残留注册。'
    exit 1
}

$url = 'http://127.0.0.1:' + $Port + '/'

# ---------------------------------------------------------------- 工具函数
# PowerShell 5.1 的 ConvertTo-Json 在 -Depth > 2 且字符串较长时会爆炸式膨胀
# （2000 字的人设文件能序列化出几十 MB），本机实测复现。所以这里自带一个编码器。
function Format-DpJsonString {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        switch ($c) {
            34 { [void]$sb.Append('\"'); continue }
            92 { [void]$sb.Append('\\'); continue }
            8 { [void]$sb.Append('\b'); continue }
            9 { [void]$sb.Append('\t'); continue }
            10 { [void]$sb.Append('\n'); continue }
            13 { [void]$sb.Append('\r'); continue }
            12 { [void]$sb.Append('\f'); continue }
            default {
                if ($c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-DpJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (Format-DpJsonString $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in $Value.Keys) { (Format-DpJsonString ([string]$k)) + ':' + (ConvertTo-DpJson $Value[$k]) }
        return '{' + (@($parts) -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) { ConvertTo-DpJson $item }
        return '[' + (@($parts) -join ',') + ']'
    }
    if ($Value -is [psobject]) {
        $parts = foreach ($p in $Value.PSObject.Properties) {
            if ($p.MemberType -eq 'NoteProperty' -or $p.MemberType -eq 'Property') {
                (Format-DpJsonString $p.Name) + ':' + (ConvertTo-DpJson $p.Value)
            }
        }
        return '{' + (@($parts) -join ',') + '}'
    }
    return (Format-DpJsonString ([string]$Value))
}

function Send-Json {
    param($Context, $Object, [int]$StatusCode = 200)
    $json = ConvertTo-DpJson $Object
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Send-Fail {
    param($Context, [string]$Message, [string]$Code = 'S01', [int]$StatusCode = 200)
    Send-Json -Context $Context -Object ([ordered]@{ ok = $false; code = $Code; error = $Message }) -StatusCode $StatusCode
}

function Read-JsonBody {
    param($Context)
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
    if (-not $text -or $text.Trim().Length -eq 0) { return $null }
    return $text | ConvertFrom-Json
}

function Send-File {
    param($Context, [string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $Context.Response.StatusCode = 404; $Context.Response.Close(); return }
    $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
    $map = @{
        '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'
        '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'
        '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2'; '.md' = 'text/markdown; charset=utf-8'
    }
    $ct = $map[$ext]
    if (-not $ct) { $ct = 'application/octet-stream' }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ct
    $Context.Response.Headers['Cache-Control'] = 'no-cache'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Test-UnderRoot {
    param([string]$Path, [string[]]$Roots)
    $full = [System.IO.Path]::GetFullPath($Path)
    foreach ($r in $Roots) {
        if (-not $r) { continue }
        $rootFull = [System.IO.Path]::GetFullPath($r).TrimEnd('\') + '\'
        if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Invoke-ChildScript {
    param([string]$Script, [string[]]$Arguments)
    # 走临时文件而不是直接 & 捕获：子进程的中文输出是系统代码页，直接捕获会被父进程按
    # 当前控制台编码二次解码成乱码。Read-JobText 会先试 UTF-8、不合法再退回系统代码页。
    $ps = 'powershell.exe'
    $tmpRoot = Join-Path $env:TEMP 'discpersona-studio-calls'
    if (-not (Test-Path -LiteralPath $tmpRoot)) { New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null }
    $stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $tmpRoot ($stamp + '.out.txt')
    $errFile = Join-Path $tmpRoot ($stamp + '.err.txt')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
    $proc = Start-Process -FilePath $ps -ArgumentList ($argList | ForEach-Object { if ($_ -match '^-') { $_ } elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $text = ((Read-JobText -Path $outFile) + "`n" + (Read-JobText -Path $errFile)).Trim()
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $text }
}

# ---------------------------------------------------------------- 异步任务
# 为什么需要：HttpListener 是单线程循环，刻录要 30–60 秒，同步跑会让整个界面假死。
$script:StudioJobs = @{}
$script:StudioJobRoot = Join-Path $env:TEMP 'discpersona-studio-jobs'

function New-StudioJobId {
    return ([guid]::NewGuid().ToString('N').Substring(0, 10))
}

function Start-StudioJob {
    param([string]$Script, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $script:StudioJobRoot)) {
        New-Item -ItemType Directory -Force -Path $script:StudioJobRoot | Out-Null
    }
    $id = New-StudioJobId
    $outFile = Join-Path $script:StudioJobRoot ($id + '.out.txt')
    $errFile = Join-Path $script:StudioJobRoot ($id + '.err.txt')
    # 注意：Start-Process 带 -RedirectStandard* 时 ExitCode 会读回空（PS 5.1 的坑）。
    # 所以写一个一次性的 wrapper 脚本：跑真正的工作脚本，再把退出码打一行 EXITCODE=<n>。
    # 用 wrapper 而不是 -Command，是为了绕开引号嵌套（路径里可能有空格、中文、单引号）。
    $wrapperFile = Join-Path $script:StudioJobRoot ($id + '.wrapper.ps1')
    # 参数名（-IsoPath 这种）必须裸写，加了引号 PowerShell 会当成位置字符串
    $quoted = (@($Arguments) | ForEach-Object {
        $s = [string]$_
        if ($s -match '^-[A-Za-z][A-Za-z0-9]*$') { $s } else { "'" + $s.Replace("'", "''") + "'" }
    }) -join ' '
    $wrapperText = "`$ErrorActionPreference = 'Continue'" + "`r`n" +
        "& '" + $Script.Replace("'", "''") + "' " + $quoted + "`r`n" +
        "Write-Output ('EXITCODE=' + `$LASTEXITCODE)`r`n"
    [System.IO.File]::WriteAllText($wrapperFile, $wrapperText, (New-Object System.Text.UTF8Encoding($true)))
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $wrapperFile + '"') `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -WindowStyle Hidden -PassThru
    $script:StudioJobs[$id] = [pscustomobject]@{
        Id = $id; Script = $Script; Process = $proc; OutFile = $outFile; ErrFile = $errFile; WrapperFile = $wrapperFile
        StartedAt = (Get-Date); ExitCode = $null
    }
    return $id
}

function Read-JobText {
    param([string]$Path)
    # 子进程的控制台输出是系统代码页（中文 Windows 上是 GBK），先试 UTF-8，不合法再退化
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($bytes)
    } catch {
        return [System.Text.Encoding]::Default.GetString($bytes)
    }
}

function Get-StudioJobState {
    param([string]$Id)
    $job = $script:StudioJobs[$Id]
    if (-not $job) { return $null }
    $proc = $job.Process
    $done = $false
    try { $done = $proc.HasExited } catch { $done = $true }
    $exit = $job.ExitCode
    if ($done -and ($null -eq $exit)) {
        try { $exit = $proc.ExitCode } catch { $exit = -1 }
        $job.ExitCode = $exit
    }
    $out = Read-JobText -Path $job.OutFile
    $err = Read-JobText -Path $job.ErrFile
    if ($err) { $out += ("`n" + $err) }
    # 没读到 ExitCode 就从输出里的 EXITCODE= 标记取（见 Start-StudioJob 的注释）
    if ($null -eq $exit) {
        $m = [regex]::Match($out, 'EXITCODE=(-?\d+)')
        if ($m.Success) { $exit = [int]$m.Groups[1].Value; $job.ExitCode = $exit }
    }
    $ok = $true
    if ($done -and ($exit -ne 0)) { $ok = $false }
    return [pscustomobject]@{ Id = $Id; Done = $done; ExitCode = $exit; Output = $out; Ok = $ok; StartedAt = $job.StartedAt }
}

function Get-StudioApiKey {
    # 只在本机服务端使用，永不返回给浏览器
    if ($env:DSH_STUDIO_KEY) { return $env:DSH_STUDIO_KEY }
    $sourceHome = $env:DISCPERSONA_SOURCE_HOME
    if (-not $sourceHome) {
        if ($env:DSH_HOME) { $sourceHome = $env:DSH_HOME }
        else { $sourceHome = Join-Path $env:USERPROFILE '.dsh' }
    }
    $cred = Join-Path $sourceHome '.credentials.yaml'
    if (-not (Test-Path -LiteralPath $cred -PathType Leaf)) { return $null }
    # YAML 里 key 可能被引号包着（"sk-..." / 'sk-...'），两种都要认
    $m = Select-String -LiteralPath $cred -Pattern 'DEEPSEEK_API_KEY:\s*["'']?(sk-[A-Za-z0-9_-]+)' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Get-DriveList {
    $items = @()
    try {
        $drives = Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction Stop
        foreach ($d in $drives) {
            $letter = ([string]$d.Drive).TrimEnd(':')
            $items += [ordered]@{
                letter = $letter
                model  = [string]$d.Caption
                media  = [string]$d.MediaType
                volume = [string]$d.VolumeName
                size   = [long]$d.Size
            }
        }
    } catch { }
    return $items
}

function Get-PayloadPresetList {
    $result = @()
    $noneItem = [ordered]@{
        preset    = 'none'
        label     = '不带插件'
        label_en  = 'No plugins'
        desc      = '最快最干净，人格 DSH 只带人设。适合只要「插盘就聊天」的人。'
        desc_en   = 'Fastest and cleanest: the persona instance ships with nothing but the persona.'
        ok        = $true
        sizeBytes = 0
        plugins   = @()
    }
    $result += [pscustomobject]$noneItem
    $labels = @{
        comfort = @('对话舒适包', '人设卡 + 文件式记忆 + 人设库，三档作用域、免重启切换。',
                    'Comfort pack', 'Persona card + file-based memory + a persona library with three scopes and no-restart switching.')
        token   = @('省 token 包', '软压缩历史、后台预备摘要、图片进上下文前先压小。聊得久也不容易顶到上限。',
                    'Token saver', 'Soft-compresses history, pre-writes summaries in the background, shrinks images before they enter context.')
        full    = @('全套', '舒适包 + 省 token 包，插件最多，首次启动稍慢一点。',
                    'Everything', 'Comfort pack plus token saver. Most plugins, slightly slower first boot.')
    }
    foreach ($preset in @('comfort', 'token', 'full')) {
        $dir = Join-Path $workspaceRoot ('payload\' + $preset + '\profile-web')
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'payload.json'))) {
            $dir = Join-Path $workspaceRoot ('build\payload\' + $preset + '\profile-web')
        }
        $ok = Test-Path -LiteralPath (Join-Path $dir 'payload.json')
        $plugins = @()
        $sizeBytes = 0
        if ($ok) {
            try {
                $pj = Get-Content -LiteralPath (Join-Path $dir 'payload.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($pl in @($pj.plugins)) { if ($pl) { $plugins += ([string]$pl.name + ' ' + [string]$pl.version) } }
            } catch { }
            try {
                $sizeBytes = (Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
            } catch { }
        }
        $lbl = $labels[$preset]
        $result += [pscustomobject][ordered]@{
            preset    = $preset
            label     = $lbl[0]
            label_en  = $lbl[2]
            desc      = $lbl[1]
            desc_en   = $lbl[3]
            ok        = $ok
            sizeBytes = [int64]$sizeBytes
            plugins   = @($plugins)
        }
    }
    return $result
}

function Get-PersonaList {
    $list = @()
    if (-not (Test-Path -LiteralPath $personaRootDefault)) { return $list }
    foreach ($dir in Get-ChildItem -LiteralPath $personaRootDefault -Directory) {
        $meta = Join-Path $dir.FullName 'meta.json'
        $name = $dir.Name; $version = ''
        if (Test-Path -LiteralPath $meta) {
            try { $m = Get-Content -LiteralPath $meta -Raw -Encoding UTF8 | ConvertFrom-Json; if ($m.name) { $name = [string]$m.name }; $version = [string]$m.version } catch { }
        }
        $list += [ordered]@{ slug = $dir.Name; name = $name; version = $version; path = $dir.FullName }
    }
    return $list
}

# ---------------------------------------------------------------- 启动提示
Write-Host ''
Write-Host '  DiscPersona Studio' -ForegroundColor Cyan
Write-Host ('  工作区：' + $workspaceRoot)
Write-Host ('  地址：' + $url) -ForegroundColor Green
Write-Host '  按 Ctrl+C 结束。'
Write-Host ''

if (-not $NoBrowser) {
    try { Start-Process $url | Out-Null } catch { }
}

# ---------------------------------------------------------------- 主循环
try {
    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $req = $ctx.Request
            $path = $req.Url.AbsolutePath
            $method = $req.HttpMethod

            # 只服务本机页面：挡 DNS rebinding 与跨站请求（本地端口也是攻击面）
            $hostHeader = ([string]$req.Headers['Host']).ToLowerInvariant()
            $hostOk = ($hostHeader -eq ('127.0.0.1:' + $Port)) -or ($hostHeader -eq ('localhost:' + $Port)) -or
                      ($hostHeader -eq '127.0.0.1') -or ($hostHeader -eq 'localhost')
            if (-not $hostOk) {
                Send-Fail -Context $ctx -Message '只接受本机访问。' -Code 'S90' -StatusCode 403
                continue
            }
            $origin = ([string]$req.Headers['Origin']).ToLowerInvariant().TrimEnd('/')
            if ($origin) {
                if (@(('http://127.0.0.1:' + $Port), ('http://localhost:' + $Port)) -notcontains $origin) {
                    Send-Fail -Context $ctx -Message '拒绝来自其他网页的请求。' -Code 'S91' -StatusCode 403
                    continue
                }
            }
            $fetchSite = ([string]$req.Headers['Sec-Fetch-Site']).ToLowerInvariant()
            if ($fetchSite -and $fetchSite -ne 'same-origin' -and $fetchSite -ne 'none') {
                Send-Fail -Context $ctx -Message '拒绝跨站请求。' -Code 'S91' -StatusCode 403
                continue
            }
            if ($method -eq 'POST' -and ($req.ContentLength64 -lt 0 -or $req.ContentLength64 -gt 12582912)) {
                Send-Fail -Context $ctx -Message '请求体太大（上限 12 MB）。' -Code 'S92' -StatusCode 413
                continue
            }

            if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                Send-File -Context $ctx -Path (Join-Path $webDir 'index.html')
                continue
            }

            if ($path.StartsWith('/api/')) {
                switch -Regex ($path) {
                    '^/api/env$' {
                        $payloadPresets = @(Get-PayloadPresetList)
                        $payloadInfo = $null
                        foreach ($pp in $payloadPresets) {
                            if ($pp.preset -eq 'comfort' -and $pp.ok) { $payloadInfo = $pp; break }
                        }
                        if (-not $payloadInfo) {
                            foreach ($pp in $payloadPresets) { if ($pp.ok) { $payloadInfo = $pp; break } }
                        }
                        $dshVersion = ''
                        try {
                            $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
                            if ($dshCmd) { $dshVersion = (& $dshCmd.Source --version 2>$null | Select-Object -First 1) }
                        } catch { }
                        Send-Json -Context $ctx -Object ([ordered]@{
                            ok         = $true
                            url        = $url
                            workspace  = $workspaceRoot
                            dshVersion = ([string]$dshVersion).Trim()
                            drives     = @(Get-DriveList)
                            personas   = @(Get-PersonaList)
                            payload    = if ($payloadInfo) { [ordered]@{ ok = $true; preset = [string]$payloadInfo.preset; plugins = @($payloadInfo.plugins); builtAt = [string]$payloadInfo.builtAt } } else { [ordered]@{ ok = $false } }
                            payloadPresets = $payloadPresets
                            hasKey     = [bool](Get-StudioApiKey)
                        })
                        continue
                    }
                    '^/api/personas$' {
                        Send-Json -Context $ctx -Object ([ordered]@{ ok = $true; items = @(Get-PersonaList) })
                        continue
                    }
                    '^/api/export$' {
                        $body = Read-JsonBody -Context $ctx
                        if (-not $body -or -not $body.slug) { Send-Fail -Context $ctx -Message '缺少 slug。' -Code 'S11'; continue }
                        $slug = [string]$body.slug
                        if ($slug -notmatch '^[a-z0-9][a-z0-9\-_]{1,40}$') { Send-Fail -Context $ctx -Message 'slug 只能是小写字母、数字、- 和 _（2–41 位）。' -Code 'S12'; continue }
                        $targetDir = Join-Path $personaRootDefault $slug
                        if ($body.dir) {
                            $targetDir = [System.IO.Path]::GetFullPath([string]$body.dir)
                            # 只允许写「人设目录」：persona\<slug>（或 DiscPersona 下的同名结构）
                            $expectA = [System.IO.Path]::GetFullPath((Join-Path $personaRootDefault $slug))
                            $expectB = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $discPersonaRoot 'personas') $slug))
                            $okDir = ($targetDir -ieq $expectA) -or ($targetDir -ieq $expectB)
                            if (-not $okDir) {
                                Send-Fail -Context $ctx -Message ('只允许导出到人设目录（persona\' + $slug + '）：' + $targetDir) -Code 'S13'; continue
                            }
                        }
                        if (Test-Path -LiteralPath $targetDir) {
                            if (-not $body.overwrite) { Send-Fail -Context $ctx -Message ('人设目录已存在：' + $targetDir) -Code 'S14'; continue }
                        }
                        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
                        $written = 0
                        foreach ($f in @($body.files)) {
                            if (-not $f -or -not $f.path) { continue }
                            $rel = ([string]$f.path) -replace '/', '\'
                            $dest = [System.IO.Path]::GetFullPath((Join-Path $targetDir $rel))
                            if (-not (Test-UnderRoot -Path $dest -Roots @($targetDir))) { Send-Fail -Context $ctx -Message ('非法路径：' + $rel) -Code 'S15'; continue }
                            $parent = Split-Path -Parent $dest
                            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                            if ($f.base64) {
                                [System.IO.File]::WriteAllBytes($dest, [Convert]::FromBase64String([string]$f.base64))
                            } else {
                                $text = [string]$f.text
                                $text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"
                                [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
                            }
                            $written++
                        }
                        Send-Json -Context $ctx -Object ([ordered]@{ ok = $true; dir = $targetDir; files = $written })
                        continue
                    }
                    '^/api/load$' {
                        $body = Read-JsonBody -Context $ctx
                        if (-not $body -or -not $body.dir) { Send-Fail -Context $ctx -Message '缺少 dir。' -Code 'S16'; continue }
                        $dir = [string]$body.dir
                        if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $workspaceRoot $dir }
                        if (-not (Test-UnderRoot -Path $dir -Roots @($workspaceRoot, $discPersonaRoot))) {
                            Send-Fail -Context $ctx -Message '只能读工作区或人格房间里的路径。' -Code 'S17'; continue
                        }
                        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Send-Fail -Context $ctx -Message ('目录不存在：' + $dir) -Code 'S18'; continue }
                        $ymlPath = Join-Path $dir 'persona.yml'
                        if (-not (Test-Path -LiteralPath $ymlPath)) { Send-Fail -Context $ctx -Message '这个目录里没有 persona.yml。' -Code 'S19'; continue }
                        $ymlText = Get-Content -LiteralPath $ymlPath -Raw -Encoding UTF8
                        # 从 persona.yml 里抠出 system_prompt 的块内容（缩进两格）
                        $prompt = ''
                        $lines = $ymlText -split "`r?`n"
                        $inBlock = $false
                        $buf = New-Object System.Collections.Generic.List[string]
                        foreach ($line in $lines) {
                            if (-not $inBlock) {
                                if ($line -match '^system_prompt:\s*[|>]') { $inBlock = $true }
                                continue
                            }
                            if ($line -match '^\s{2,}') { $buf.Add($line.Substring(2)) }
                            elseif ($line.Trim() -eq '') { $buf.Add('') }
                            else { break }
                        }
                        $prompt = ($buf -join "`n").Trim()
                        $metaObj = $null
                        $metaPath = Join-Path $dir 'meta.json'
                        if (Test-Path -LiteralPath $metaPath) {
                            try { $metaObj = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
                        }
                        $avatarB64 = $null
                        $avatarPath = Join-Path $dir 'avatar.png'
                        if (Test-Path -LiteralPath $avatarPath) {
                            $avatarB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($avatarPath))
                        }
                        Send-Json -Context $ctx -Object ([ordered]@{
                            ok     = $true
                            slug   = (Split-Path -Leaf $dir)
                            dir    = $dir
                            yml    = $ymlText
                            prompt = $prompt
                            meta   = $metaObj
                            avatar = $avatarB64
                        })
                        continue
                    }
                    '^/api/build$' {
                        $body = Read-JsonBody -Context $ctx
                        $personaDir = if ($body.persona) { [string]$body.persona } else { '' }
                        if (-not $personaDir) { Send-Fail -Context $ctx -Message '缺少 persona。' -Code 'S21'; continue }
                        if (-not [System.IO.Path]::IsPathRooted($personaDir)) { $personaDir = Join-Path $workspaceRoot $personaDir }
                        $outDir = if ($body.out) { [string]$body.out } else { Join-Path $workspaceRoot ('build\' + (Split-Path -Leaf $personaDir)) }
                        if (-not [System.IO.Path]::IsPathRooted($outDir)) { $outDir = Join-Path $workspaceRoot $outDir }
                        if (-not (Test-UnderRoot -Path $outDir -Roots @($workspaceRoot))) { Send-Fail -Context $ctx -Message '输出目录必须在本工作区内。' -Code 'S22'; continue }
                        $script = Join-Path $workspaceRoot 'tools\New-Disc.ps1'
                        $preset = if ($body.payload) { [string]$body.payload } else { 'comfort' }
                        if ($preset -notin @('none', 'comfort', 'token', 'full')) {
                            Send-Fail -Context $ctx -Message ('不认识的插件包预设：' + $preset) -Code 'S23'; continue
                        }
                        $args = @('-Persona', $personaDir, '-Out', $outDir, '-PayloadPreset', $preset)
                        if ($body.reusePad) { $args += '-ReusePad' }
                        if ($body.force) { $args += '-Force' }
                        $wantSeal = ($body.seal -eq $true)
                        $sealPassphrase = if ($null -ne $body.sealPassphrase) { [string]$body.sealPassphrase } else { '' }
                        if ($wantSeal) {
                            if ($sealPassphrase.Length -lt 8) {
                                Send-Fail -Context $ctx -Message '加密人设的口令至少 8 位。' -Code 'S24'; continue
                            }
                            $args += '-SealPersona'
                        }
                        $oldSealEnv = $env:DISKLIFE_PASSPHRASE
                        if ($wantSeal) { $env:DISKLIFE_PASSPHRASE = $sealPassphrase }
                        try {
                            $r = Invoke-ChildScript -Script $script -Arguments $args
                        } finally {
                            if ($null -eq $oldSealEnv) { Remove-Item Env:\DISKLIFE_PASSPHRASE -ErrorAction SilentlyContinue }
                            else { $env:DISKLIFE_PASSPHRASE = $oldSealEnv }
                            $sealPassphrase = $null
                        }
                        $discID = ''
                        $m = [regex]::Match($r.Output, 'DISC_OK\s+discID=([0-9a-f]+)')
                        if ($m.Success) { $discID = $m.Groups[1].Value }
                        # 打包完顺手跑一遍静态校验（36 项），别让界面上那句「会顺带校验」变成空话
                        $testOk = $false
                        $testOut = ''
                        if ($r.ExitCode -eq 0) {
                            $testScript = Join-Path $workspaceRoot 'tools\Test-Disc.ps1'
                            if (Test-Path -LiteralPath $testScript -PathType Leaf) {
                                $tr = Invoke-ChildScript -Script $testScript -Arguments @('-Disc', $outDir)
                                $testOk = ($tr.ExitCode -eq 0)
                                $testOut = $tr.Output
                            }
                        }
                        Send-Json -Context $ctx -Object ([ordered]@{
                            ok = ($r.ExitCode -eq 0); code = 'BUILD'; exitCode = $r.ExitCode
                            discID = $discID; outDir = $outDir; output = $r.Output; payloadPreset = $preset
                            sealed = $wantSeal
                            testOk = $testOk; testOutput = $testOut
                        })
                        continue
                    }
                    '^/api/iso$' {
                        $body = Read-JsonBody -Context $ctx
                        if (-not $body.disc) { Send-Fail -Context $ctx -Message '缺少 disc。' -Code 'S31'; continue }
                        $disc = [string]$body.disc
                        if (-not [System.IO.Path]::IsPathRooted($disc)) { $disc = Join-Path $workspaceRoot $disc }
                        $iso = if ($body.iso) { [string]$body.iso } else { Join-Path $workspaceRoot ('build\' + (Split-Path -Leaf $disc) + '.iso') }
                        if (-not [System.IO.Path]::IsPathRooted($iso)) { $iso = Join-Path $workspaceRoot $iso }
                        if (-not (Test-UnderRoot -Path $disc -Roots @($workspaceRoot, $discPersonaRoot))) {
                            Send-Fail -Context $ctx -Message '光盘目录必须在本工作区或 DiscPersona 数据目录内。' -Code 'S32'; continue
                        }
                        if (-not (Test-UnderRoot -Path $iso -Roots @($workspaceRoot))) {
                            Send-Fail -Context $ctx -Message 'ISO 输出路径必须在本工作区内。' -Code 'S33'; continue
                        }
                        if ([System.IO.Path]::GetExtension($iso) -ne '.iso') {
                            Send-Fail -Context $ctx -Message 'ISO 输出文件必须以 .iso 结尾。' -Code 'S34'; continue
                        }
                        $script = Join-Path $workspaceRoot 'tools\New-Iso.ps1'
                        $r = Invoke-ChildScript -Script $script -Arguments @('-Source', $disc, '-Out', $iso, '-Force')
                        Send-Json -Context $ctx -Object ([ordered]@{ ok = ($r.ExitCode -eq 0); code = 'ISO'; exitCode = $r.ExitCode; iso = $iso; output = $r.Output })
                        continue
                    }
                    '^/api/burn$' {
                        $body = Read-JsonBody -Context $ctx
                        if (-not $body.iso -or -not $body.drive) { Send-Fail -Context $ctx -Message '缺少 iso 或 drive。' -Code 'S41'; continue }
                        $iso = [string]$body.iso
                        if (-not [System.IO.Path]::IsPathRooted($iso)) { $iso = Join-Path $workspaceRoot $iso }
                        $script = Join-Path $workspaceRoot 'tools\Burn-Iso.ps1'
                        $burnArgs = @('-IsoPath', $iso, '-DriveLetter', ([string]$body.drive))
                        if ($body.async -eq $true) {
                            # 异步：立刻返回 jobId，前端轮询 /api/job，界面不会假死
                            $jobId = Start-StudioJob -Script $script -Arguments $burnArgs
                            Send-Json -Context $ctx -Object ([ordered]@{ ok = $true; code = 'BURN'; jobId = $jobId })
                            continue
                        }
                        $r = Invoke-ChildScript -Script $script -Arguments $burnArgs
                        Send-Json -Context $ctx -Object ([ordered]@{ ok = ($r.ExitCode -eq 0); code = 'BURN'; exitCode = $r.ExitCode; output = $r.Output })
                        continue
                    }
                    '^/api/job$' {
                        # 不引 System.Web：手写解析，少一个组件依赖
                        $id = ''
                        $qMatch = [regex]::Match([string]$req.Url.Query, '[?&]id=([^&]+)')
                        if ($qMatch.Success) { $id = [System.Uri]::UnescapeDataString($qMatch.Groups[1].Value) }
                        if (-not $id) { Send-Fail -Context $ctx -Message '缺少 id。' -Code 'S61'; continue }
                        $st = Get-StudioJobState -Id $id
                        if (-not $st) { Send-Fail -Context $ctx -Message ('找不到这个任务：' + $id) -Code 'S62'; continue }
                        Send-Json -Context $ctx -Object ([ordered]@{
                            ok = $true; id = $st.Id; done = $st.Done; exitCode = $st.ExitCode; output = $st.Output
                        })
                        continue
                    }
                    '^/api/open$' {
                        $body = Read-JsonBody -Context $ctx
                        $target = [string]$body.path
                        if (-not $target) { Send-Fail -Context $ctx -Message '缺少 path。' -Code 'S51'; continue }
                        if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $workspaceRoot $target }
                        if (-not (Test-UnderRoot -Path $target -Roots @($workspaceRoot, $discPersonaRoot))) { Send-Fail -Context $ctx -Message '只能打开工作区或人格房间里的路径。' -Code 'S52'; continue }
                        if (Test-Path -LiteralPath $target) { Start-Process explorer.exe -ArgumentList ('"' + $target + '"') | Out-Null }
                        Send-Json -Context $ctx -Object ([ordered]@{ ok = $true })
                        continue
                    }
                    '^/api/draft$' {
                        $body = Read-JsonBody -Context $ctx
                        $key = Get-StudioApiKey
                        if (-not $key) { Send-Fail -Context $ctx -Message '这台电脑上没有可用的 DeepSeek 凭据，AI 起草不可用（可以纯手填）。' -Code 'S61'; continue }
                        $prompt = [string]$body.prompt
                        if (-not $prompt) { Send-Fail -Context $ctx -Message '缺少 prompt。' -Code 'S62'; continue }
                        $payload = [ordered]@{
                            model = 'deepseek-chat'
                            temperature = 0.9
                            messages = @(
                                [ordered]@{ role = 'system'; content = '你是人物设定编辑。根据用户的简短设定，写出可用于角色扮演系统提示词的中文段落。只输出正文，不要解释、不要 markdown 标题以外的多余内容。' },
                                [ordered]@{ role = 'user'; content = $prompt }
                            )
                        } | ConvertTo-Json -Depth 6
                        try {
                            $resp = Invoke-RestMethod -Uri 'https://api.deepseek.com/chat/completions' -Method Post -TimeoutSec 120 `
                                -Headers @{ Authorization = ('Bearer ' + $key) } -ContentType 'application/json; charset=utf-8' `
                                -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))
                            $content = [string]$resp.choices[0].message.content
                            Send-Json -Context $ctx -Object ([ordered]@{ ok = $true; text = $content })
                        } catch {
                            Send-Fail -Context $ctx -Message ('调用 DeepSeek 失败：' + $_.Exception.Message) -Code 'S63'
                        }
                        continue
                    }
                }
                Send-Fail -Context $ctx -Message ('未知接口：' + $path) -Code 'S99' -StatusCode 404
                continue
            }

            # 静态文件
            $rel = $path.TrimStart('/')
            if ($rel -eq '') { $rel = 'index.html' }
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $webDir ($rel -replace '/', '\')))
            if (-not (Test-UnderRoot -Path $candidate -Roots @($webDir))) {
                $ctx.Response.StatusCode = 403; $ctx.Response.Close(); continue
            }
            Send-File -Context $ctx -Path $candidate
        } catch {
            try { Send-Fail -Context $ctx -Message ('服务器内部错误：' + $_.Exception.Message) -Code 'S00' -StatusCode 500 } catch { }
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    Write-Host '  Studio 已停止。'
}
