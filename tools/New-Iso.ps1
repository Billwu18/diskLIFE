<#
.SYNOPSIS
    Pack a prepared disc tree into an ISO (ISO9660 + Joliet) for the one-click burn tool.

.DESCRIPTION
    Uses only the IMAPI2 (MsftFileSystemImage) that ships with Windows; no oscdimg / mkisofs.
    Joliet keeps long Chinese file names from being truncated - that matters: truncated
    names break every hash in the manifest, and the launcher then reports E03.

.PARAMETER Source
    Disc tree (the -Out of New-Disc.ps1), e.g. examples\demo-aris.

.PARAMETER Out
    Output ISO path; defaults to build\<dir name>.iso.

.PARAMETER VolumeLabel
    Volume label; defaults to something like ARIS_AL1S inferred from meta.json; max 32 chars.

.PARAMETER Force
    Overwrite the output if it already exists.

.EXAMPLE
    powershell -File tools\New-Iso.ps1 -Source examples\demo-aris -Out build\demo.iso
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
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { Fail 'I01' ('Source directory not found: ' + $Source) }
$Source = (Resolve-Path -LiteralPath $Source).Path

if (-not $Out) {
    $Out = Join-Path $workspaceRoot ('build\' + (Split-Path -Leaf $Source) + '.iso')
} elseif (-not [System.IO.Path]::IsPathRooted($Out)) {
    $Out = Join-Path $workspaceRoot $Out
}
if (Test-Path -LiteralPath $Out) {
    if (-not $Force) { Fail 'I02' ('ISO already exists: ' + $Out + ' (use -Force to overwrite)') }
    Remove-Item -LiteralPath $Out -Force
}
$outParent = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }

# Volume label: explicit parameter first, then meta.json name, then DISCPERSONA
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
# ISO9660 volume label: ASCII uppercase, <=32; IMAPI rejects non-ASCII, so fall back
if ($VolumeLabel -notmatch '^[\x20-\x7E]+$') { $VolumeLabel = 'DISCPERSONA' }
$VolumeLabel = $VolumeLabel.ToUpperInvariant()
if ($VolumeLabel.Length -gt 32) { $VolumeLabel = $VolumeLabel.Substring(0, 32) }

Write-Host ('==> Source: ' + $Source) -ForegroundColor Cyan
Write-Host ('==> Label: ' + $VolumeLabel) -ForegroundColor Cyan
Write-Host ('==> Output: ' + $Out) -ForegroundColor Cyan

# IMAPI2's ImageStream cannot be cast to IStream directly from PowerShell;
# the RCW must be passed to C# as object and then QueryInterface'd.
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
    $fsi.FileSystemsToCreate = 3          # 1=ISO9660, 2=Joliet -> 3 = both
    $fsi.VolumeName = $VolumeLabel
    $fsi.Root.AddTree($Source, $false)    # false: do not add the source dir itself as a level under root

    Write-Host '==> Building the image…' -ForegroundColor Cyan
    $result = $fsi.CreateResultImage()
    $bytes = [DiscIsoStream]::Save($result.ImageStream, $Out)
} finally {
    if ($fsi) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi) }
}

if (-not (Test-Path -LiteralPath $Out)) { Fail 'I03' 'The image was not created.' }
$size = (Get-Item -LiteralPath $Out).Length
if ($size -lt 32768) { Fail 'I04' ('Image too small (' + $size + ' bytes); it is probably empty.') }

Write-Host ''
Write-Host ('ISO_OK ' + $Out + ' ' + $size + ' bytes') -ForegroundColor Green
exit 0
