#requires -Version 5.1
<#
  DiscPersona 一键刻录（IMAPI2）
  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Burn-Iso.ps1 -ListDrives
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Burn-Iso.ps1 -IsoPath build\aris-al1s.iso -DriveLetter F
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Burn-Iso.ps1 -IsoPath build\aris-al1s.iso -DriveLetter F -TestOnly

  成功最后一行：BURN_OK <drive> <bytes> bytes <seconds>s
  失败最后一行：BURN_FAIL <Bxx> <中文原因>
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$DriveLetter,
    [string]$VolumeLabel = 'DISCPERSONA',
    [switch]$Eject,
    [switch]$ListDrives,
    [switch]$TestOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:StartedAt = Get-Date
$script:MediaNames = @{
    0 = '未知'; 1 = 'CD-ROM'; 2 = 'CD-R'; 3 = 'CD-RW'; 4 = 'DVD-ROM'; 5 = 'DVD-RAM'
    6 = 'DVD+R'; 7 = 'DVD+RW'; 8 = 'DVD-R'; 9 = 'DVD-RW'; 10 = 'DVD+R DL'
    11 = 'DVD-R DL'; 12 = 'DVD+RW DL'; 13 = 'BD-ROM'; 14 = 'BD-R'; 15 = 'BD-R'
    16 = 'BD-RE'; 17 = 'HD DVD-R'; 18 = 'HD DVD-RW'; 19 = 'HD DVD-RAM'
}
$script:MediaSectors = @{
    2 = 359849; 3 = 359849; 5 = 2295104; 6 = 2295104; 7 = 2295104; 8 = 2298496
    9 = 2298496; 10 = 4173824; 11 = 4173824; 12 = 4173824; 13 = 12219392
    14 = 12219392; 15 = 12219392; 16 = 12219392
}

function Write-Step {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host ('  ' + $Text) -ForegroundColor $Color
}

function Get-MediaTypeName {
    param([int]$Type)
    if ($script:MediaNames.ContainsKey($Type)) { return [string]$script:MediaNames[$Type] }
    return ('未知(' + $Type + ')')
}

function Get-MediaTotalSectors {
    param([int]$Type)
    if ($script:MediaSectors.ContainsKey($Type)) { return [long]$script:MediaSectors[$Type] }
    return -1
}

function Fail-Burn {
    param([string]$Code, [string]$Reason, [string]$Hint)
    Write-Host ''
    Write-Host ('  [失败] ' + $Reason) -ForegroundColor Red
    if ($Hint) { Write-Host ('  怎么办：' + $Hint) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host ('BURN_FAIL ' + $Code + ' ' + $Reason)
    exit 1
}

function Complete-Burn {
    param([string]$Drive, [long]$Bytes, $Recorder)
    if ($Eject -and $Recorder) {
        try {
            $Recorder.EjectMedia()
            Write-Step '已弹出光盘。'
        } catch {
            Write-Step ('弹出光盘失败（不影响刻录结果）：' + $_.Exception.Message) 'Yellow'
        }
    }
    $seconds = [Math]::Round(((Get-Date) - $script:StartedAt).TotalSeconds, 1)
    Write-Host ''
    Write-Host ('BURN_OK ' + $Drive + ' ' + $Bytes + ' bytes ' + $seconds + 's')
    exit 0
}

function Get-DiscRecorders {
    $list = New-Object System.Collections.ArrayList
    $master = $null
    try {
        $master = New-Object -ComObject IMAPI2.MsftDiscMaster2
        $count = [int]$master.Count
        for ($i = 0; $i -lt $count; $i++) {
            $id = [string]$master.Item($i)
            $rec = New-Object -ComObject IMAPI2.MsftDiscRecorder2
            $rec.InitializeDiscRecorder($id)
            $paths = @()
            try { $paths = @($rec.VolumePathNames) } catch { $paths = @() }
            [void]$list.Add([pscustomobject]@{ Id = $id; Recorder = $rec; Paths = $paths })
        }
    } finally {
        if ($master) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($master) }
    }
    return , $list
}

function Get-DriveLetters {
    param($Paths)
    $letters = New-Object System.Collections.ArrayList
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace([string]$p)) { continue }
        $s = ([string]$p).TrimEnd('\')
        if ($s -match '^[A-Za-z]:$') { [void]$letters.Add($s.ToUpperInvariant()) }
    }
    if ($letters.Count -eq 0) { return '(无盘符)' }
    return ($letters -join ',')
}

function Get-MediaInfo {
    param($Recorder)
    $info = [pscustomobject]@{
        RecorderSupported = $true
        MediaSupported    = $true
        MediaType         = 0
        MediaName         = '未知'
        Blank             = $false
        FreeSectors       = -1
    }
    $data = $null
    try {
        $data = New-Object -ComObject IMAPI2.MsftDiscFormat2Data
        $data.Recorder = $Recorder
        try { $info.RecorderSupported = [bool]$data.IsRecorderSupported($Recorder) } catch { $info.RecorderSupported = $false }
        try { $info.MediaType = [int]$data.CurrentPhysicalMediaType } catch { $info.MediaType = 0 }
        $info.MediaName = Get-MediaTypeName -Type $info.MediaType
        try { $info.MediaSupported = [bool]$data.IsCurrentMediaSupported($Recorder) } catch { $info.MediaSupported = $false }
        try { $info.Blank = [bool]$data.MediaPhysicallyBlank } catch { $info.Blank = $false }
    } finally {
        if ($data) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($data) }
    }
    $erase = $null
    try {
        $erase = New-Object -ComObject IMAPI2.MsftDiscFormat2Erase
        $erase.Recorder = $Recorder
        $info.FreeSectors = [long]$erase.FreeSectorsOnMedia
    } catch {
        $info.FreeSectors = -1
    } finally {
        if ($erase) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($erase) }
    }
    return $info
}

function Resolve-TargetDrive {
    param([string]$Letter)
    $norm = $Letter.Trim()
    if ($norm -match '^[A-Za-z]$') { $norm = $norm + ':' }
    $norm = $norm.TrimEnd('\').ToUpperInvariant()
    if ($norm -notmatch '^[A-Za-z]:$') { return $null }
    $all = Get-DiscRecorders
    $hit = $null
    foreach ($item in $all) {
        if ($hit) { break }
        foreach ($p in $item.Paths) {
            if ([string]::IsNullOrWhiteSpace([string]$p)) { continue }
            $pp = ([string]$p).TrimEnd('\').ToUpperInvariant()
            if ($pp -eq $norm) { $hit = $item; break }
        }
    }
    foreach ($item in $all) {
        if ($hit -and $item.Id -eq $hit.Id) { continue }
        if ($item.Recorder) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($item.Recorder) }
    }
    if (-not $hit) { return $null }
    return [pscustomobject]@{ Drive = $norm; Recorder = $hit.Recorder }
}

function Close-MediaQuietly {
    param($Recorder)
    try { $Recorder.CloseMedia() } catch { }
}

function Test-Written {
    param($Recorder)
    $data = $null
    try {
        $data = New-Object -ComObject IMAPI2.MsftDiscFormat2Data
        $data.Recorder = $Recorder
        return -not [bool]$data.MediaPhysicallyBlank
    } catch {
        return $false
    } finally {
        if ($data) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($data) }
    }
}

if (-not ('DiscPersonaIsoStream' -as [type])) {
    $code = @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class DiscPersonaIsoStream
{
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, PreserveSig = false)]
    private static extern void SHCreateStreamOnFileEx(
        string pszFile, uint grfMode, uint dwAttributes, bool fCreate,
        IntPtr pstmTemplate, out IStream ppstm);

    public static IStream OpenRead(string path)
    {
        IStream stm;
        // STGM_READ = 0, FILE_ATTRIBUTE_NORMAL = 0x80
        SHCreateStreamOnFileEx(path, 0x00000000, 0x00000080, false, IntPtr.Zero, out stm);
        return stm;
    }
}
"@
    try {
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
    } catch {
        Fail-Burn 'B06' ('加载文件流组件失败：' + $_.Exception.Message) '请确认系统 shlwapi.dll 正常；重启后再试。'
    }
}

# ---------------------------------------------------------------- 列出光驱
if ($ListDrives) {
    Write-Host ''
    Write-Host '  本机光驱：' -ForegroundColor Cyan
    $recorders = Get-DiscRecorders
    $n = 0
    foreach ($item in $recorders) {
        $n++
        $info = Get-MediaInfo -Recorder $item.Recorder
        $drive = Get-DriveLetters -Paths $item.Paths
        $model = ''
        try {
            $model = (([string]$item.Recorder.VendorId) + ' ' + ([string]$item.Recorder.ProductId)).Trim()
            $model = [regex]::Replace($model, '\s+', ' ')
        } catch { $model = '(型号未知)' }
        $total = Get-MediaTotalSectors -Type $info.MediaType
        $capacityText = '总扇区=未知'
        if ($total -gt 0) {
            $capacityText = '总扇区=' + [string]$total + '（≈' + [Math]::Round($total * 2048 / 1MB, 1) + ' MiB）'
        } else {
            try {
                $wmiSize = [long](Get-WmiObject -Class Win32_CDROMDrive -Filter ('Drive=''' + $drive + '''') -ErrorAction Stop).Size
                if ($wmiSize -gt 0) {
                    $used = [long]($wmiSize / 2048)
                    $capacityText = '总扇区=未知  已用≈' + [string]$used + ' 扇区（≈' + [Math]::Round($wmiSize / 1MB, 2) + ' MiB）'
                }
            } catch { }
        }
        $freeText = '未知'
        if ($info.FreeSectors -ge 0) { $freeText = [string]$info.FreeSectors }
        $blankText = '未知'
        if ($info.MediaType -ne 0) {
            if ($info.Blank) { $blankText = '是' } else { $blankText = '否' }
        }
        Write-Host ('  ' + $drive + '  ' + $model + '  介质=' + $info.MediaName + '  空白=' + $blankText + '  ' + $capacityText + '  剩余扇区=' + $freeText)
        if (-not $info.RecorderSupported) { Write-Host '        （该设备不支持刻录）' -ForegroundColor Yellow }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($item.Recorder)
    }
    if ($n -eq 0) {
        Write-Host '  （没有找到任何光驱）' -ForegroundColor Yellow
    }
    Write-Host ''
    Complete-Burn -Drive 'LIST' -Bytes 0 -Recorder $null
}

# ---------------------------------------------------------------- 参数检查
if ([string]::IsNullOrWhiteSpace($IsoPath)) {
    Fail-Burn 'B05' '没有指定 ISO 文件（-IsoPath）。' '用法：-IsoPath build\aris-al1s.iso -DriveLetter F'
}
if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
    Fail-Burn 'B01' '没有指定光驱盘符（-DriveLetter）。' '用法：-DriveLetter F 或 -DriveLetter F:'
}

$isoFull = $null
try { $isoFull = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).ProviderPath } catch { $isoFull = $null }
if (-not $isoFull -or -not (Test-Path -LiteralPath $isoFull -PathType Leaf)) {
    Fail-Burn 'B05' ('ISO 文件不存在：' + $IsoPath) '请先运行 tools\New-Disc.ps1 生成 ISO，或检查路径。'
}
$isoInfo = Get-Item -LiteralPath $isoFull
$isoSize = [long]$isoInfo.Length
if ($isoSize -le 0) {
    Fail-Burn 'B05' ('ISO 文件是 0 字节：' + $isoFull) '请重新生成 ISO 后再刻录。'
}

$target = Resolve-TargetDrive -Letter $DriveLetter
if (-not $target) {
    Fail-Burn 'B01' ('找不到光驱：' + $DriveLetter) '先运行 -ListDrives 看看本机有哪些光驱盘符。'
}
$recorder = $target.Recorder
$drive = $target.Drive

try {
    $info = Get-MediaInfo -Recorder $recorder
    if (-not $info.RecorderSupported) {
        Fail-Burn 'B02' ('这个光驱不支持刻录：' + $drive) '换一个可刻录的 DVD/CD 刻录机，或检查驱动。'
    }
    if ($info.MediaType -eq 0) {
        Fail-Burn 'B03' ('光驱里没有介质：' + $drive) '请放入一张空白 CD-R / DVD-R。'
    }
    if ($info.Blank) {
        # 双保险：有些驱动对已终结的盘会误报「物理空白」，但有卷标就肯定不是空白盘。
        try {
            $probe = Get-WmiObject -Class Win32_CDROMDrive -Filter ('Drive=''' + $drive + '''') -ErrorAction Stop
            if ($probe -and $probe.VolumeName) {
                $info.Blank = $false
                $info.MediaName = [string]$info.MediaName + '（有卷标 ' + [string]$probe.VolumeName + '）'
            }
        } catch { }
    }
    if (-not $info.Blank) {
        if (-not $TestOnly) {
            Fail-Burn 'B04' ('这张光盘上已经有内容了（' + $info.MediaName + '）：' + $drive) '请换一张空白光盘；只做链路检测可加 -TestOnly。'
        }
        Write-Step ('注意：介质非空白（' + $info.MediaName + '），TestOnly 只验证链路，不会写入。') 'Yellow'
    }
    if (-not $info.MediaSupported -and $info.Blank) {
        Fail-Burn 'B03' ('光驱不支持这种介质：' + $drive) '换一张 CD-R / DVD-R 再试。'
    }
    $blankText = '否'
    if ($info.Blank) { $blankText = '是' }
    Write-Step ('目标光驱：' + $drive + '  介质：' + $info.MediaName + '  空白：' + $blankText)
    Write-Step ('ISO：' + $isoFull + '（' + $isoSize + ' 字节）')

    $stream = $null
    try {
        $stream = [DiscPersonaIsoStream]::OpenRead($isoFull)
    } catch {
        Fail-Burn 'B06' ('打开 ISO 文件流失败：' + $_.Exception.Message) '确认 ISO 没有被其他程序占用，且当前用户有读取权限。'
    }

    $data = $null
    $writeFailed = $false
    $writeError = ''
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $data = New-Object -ComObject IMAPI2.MsftDiscFormat2Data
        $data.Recorder = $recorder
        $data.ClientName = 'DiscPersona'
        $data.ForceMediaToBeClosed = $true
        if ($TestOnly) {
            Write-Step 'TestOnly：写会话已打开，链路正常，跳过实际写入。' 'Yellow'
        } else {
            Write-Step ('开始写入（卷标 ' + $VolumeLabel + '）……')
            try { $data.Write($stream) }
            catch { $writeFailed = $true; $writeError = [string]$_.Exception.Message }
        }
    } catch {
        $writeFailed = $true
        $writeError = [string]$_.Exception.Message
    } finally {
        $watch.Stop()
        if ($stream) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($stream) }
        if ($data) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($data) }
    }

    if ($writeFailed) {
        Close-MediaQuietly -Recorder $recorder
        if (-not $writeError) { $writeError = '（COM 未给出文字说明，只有 HRESULT）' }
        Fail-Burn 'B07' ('写入过程失败：' + $writeError) '换一张空白盘重试；若反复失败，检查光驱和盘片是否老化。'
    }

    if ($TestOnly) {
        Complete-Burn -Drive $drive -Bytes 0 -Recorder $recorder
    }

    Write-Step ('写入完成，用时 ' + [Math]::Round($watch.Elapsed.TotalSeconds, 1) + ' 秒，正在回读校验……')
    if (-not (Test-Written -Recorder $recorder)) {
        Close-MediaQuietly -Recorder $recorder
        Fail-Burn 'B08' '写完后光盘仍显示为空白，写会话可能没有终结。' '换一张盘重试；若仍失败，不要使用这张盘。'
    }
    Close-MediaQuietly -Recorder $recorder

    $volume = ''
    try {
        $wmi = Get-WmiObject -Class Win32_CDROMDrive -Filter ('Drive=''' + $drive + '''') -ErrorAction Stop
        if ($wmi -and $wmi.VolumeName) { $volume = [string]$wmi.VolumeName }
    } catch { $volume = '' }
    Write-Step ('回读校验：介质已非空白（' + $info.MediaName + '）')
    if ($volume) { Write-Step ('回读卷标：' + $volume) }

    Complete-Burn -Drive $drive -Bytes $isoSize -Recorder $recorder
} finally {
    if ($recorder) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($recorder) }
}
