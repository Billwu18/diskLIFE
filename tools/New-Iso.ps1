<#
.SYNOPSIS
    把打包好的光盘目录做成 ISO（ISO9660 + Joliet），给「上位机一键刻录」用。

.DESCRIPTION
    只用 Windows 自带的 IMAPI2（MsftFileSystemImage），不需要 oscdimg / mkisofs。
    Joliet 保证中文长文件名不被截断——这点很关键：文件名被截断会让 manifest 里的
    哈希全部对不上，启动器会报 E03。

.PARAMETER Source
    光盘目录（New-Disc.ps1 的 -Out），例如 examples\sample-disc。

.PARAMETER Out
    输出 ISO 路径，默认 build\<目录名>.iso。

.PARAMETER VolumeLabel
    卷标，默认 ARIS_AL1S 之类的由 meta.json 推断；最长 32 字符。

.PARAMETER Force
    输出已存在时覆盖。

.EXAMPLE
    powershell -File tools\New-Iso.ps1 -Source examples\sample-disc -Out build\demo.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Out = '',
    [string]$VolumeLabel = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Split-Path -Parent $toolsDir

function Fail { param([string]$Code, [string]$Message)
    Write-Host ('ISO_FAIL ' + $Code + ' ' + $Message) -ForegroundColor Red
    exit 1
}

if (-not [System.IO.Path]::IsPathRooted($Source)) { $Source = Join-Path $workspaceRoot $Source }
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { Fail 'I01' ('源目录不存在：' + $Source) }
$Source = (Resolve-Path -LiteralPath $Source).Path

if (-not $Out) {
    $Out = Join-Path $workspaceRoot ('build\' + (Split-Path -Leaf $Source) + '.iso')
} elseif (-not [System.IO.Path]::IsPathRooted($Out)) {
    $Out = Join-Path $workspaceRoot $Out
}
if (Test-Path -LiteralPath $Out) {
    if (-not $Force) { Fail 'I02' ('ISO 已存在：' + $Out + '（加 -Force 覆盖）') }
    Remove-Item -LiteralPath $Out -Force
}
$outParent = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }

# 卷标：优先显式参数，其次 meta.json 的 name，最后 DISCPERSONA
if (-not $VolumeLabel) {
    $VolumeLabel = 'DISCPERSONA'
    $metaPath = Join-Path $Source 'persona\meta.json'
    if (Test-Path -LiteralPath $metaPath) {
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($meta.nameJp) { $VolumeLabel = [string]$meta.nameJp }
            elseif ($meta.name) { $VolumeLabel = [string]$meta.name }
        } catch { }
    }
}
# ISO9660 卷标：ASCII 大写、<=32；非 ASCII 会被 IMAPI 拒绝，退回安全值
if ($VolumeLabel -notmatch '^[\x20-\x7E]+$') { $VolumeLabel = 'DISCPERSONA' }
$VolumeLabel = $VolumeLabel.ToUpperInvariant()
if ($VolumeLabel.Length -gt 32) { $VolumeLabel = $VolumeLabel.Substring(0, 32) }

Write-Host ('==> 源：' + $Source) -ForegroundColor Cyan
Write-Host ('==> 卷标：' + $VolumeLabel) -ForegroundColor Cyan
Write-Host ('==> 输出：' + $Out) -ForegroundColor Cyan

# IMAPI2 的 ImageStream 在 PowerShell 里不能直接 cast 成 IStream，
# 必须把 RCW 当 object 传进 C# 再 QueryInterface。
$cs = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class DiscIsoStream
{
    public static long Save(object comStream, string path)
    {
        IStream stream = (IStream)comStream;
        stream.Seek(0, 0, IntPtr.Zero);
        byte[] buffer = new byte[1 << 20];
        IntPtr pcbRead = Marshal.AllocHGlobal(4);
        long total = 0;
        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
            {
                while (true)
                {
                    stream.Read(buffer, buffer.Length, pcbRead);
                    int read = Marshal.ReadInt32(pcbRead);
                    if (read <= 0) break;
                    fs.Write(buffer, 0, read);
                    total += read;
                }
            }
        }
        finally
        {
            Marshal.FreeHGlobal(pcbRead);
            Marshal.ReleaseComObject(stream);
        }
        return total;
    }
}
'@
if (-not ('DiscIsoStream' -as [type])) {
    Add-Type -TypeDefinition $cs -Language CSharp | Out-Null
}

$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
try {
    $fsi.FileSystemsToCreate = 3          # 1=ISO9660, 2=Joliet -> 3 = 两者
    $fsi.VolumeName = $VolumeLabel
    $fsi.Root.AddTree($Source, $false)    # false：不把源目录本身当成根下的一层

    Write-Host '==> 构建镜像…' -ForegroundColor Cyan
    $result = $fsi.CreateResultImage()
    $bytes = [DiscIsoStream]::Save($result.ImageStream, $Out)
} finally {
    if ($fsi) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi) }
}

if (-not (Test-Path -LiteralPath $Out)) { Fail 'I03' '镜像没有生成出来。' }
$size = (Get-Item -LiteralPath $Out).Length
if ($size -lt 32768) { Fail 'I04' ('镜像太小（' + $size + ' 字节），多半是空的。') }

Write-Host ''
Write-Host ('ISO_OK ' + $Out + ' ' + $size + ' bytes') -ForegroundColor Green
exit 0
