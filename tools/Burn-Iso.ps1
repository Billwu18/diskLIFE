#requires -Version 5.1
<#
  DiscPersona one-click burn (IMAPI2)
  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Burn-Iso.ps1 -ListDrives
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Burn-Iso.ps1 -IsoPath build\aris-al1s.iso -DriveLetter F
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Burn-Iso.ps1 -IsoPath build\aris-al1s.iso -DriveLetter F -TestOnly

  Last line on success: BURN_OK <drive> <bytes> bytes <seconds>s
  Last line on failure: BURN_FAIL <Bxx> <reason>
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
    0 = 'Unknown'; 1 = 'CD-ROM'; 2 = 'CD-R'; 3 = 'CD-RW'; 4 = 'DVD-ROM'; 5 = 'DVD-RAM'
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
    return ('Unknown(' + $Type + ')')
}

function Get-MediaTotalSectors {
    param([int]$Type)
    if ($script:MediaSectors.ContainsKey($Type)) { return [long]$script:MediaSectors[$Type] }
    return -1
}

function Fail-Burn {
    param([string]$Code, [string]$Reason, [string]$Hint)
    Write-Host ''
    Write-Host ('  [failed] ' + $Reason) -ForegroundColor Red
    if ($Hint) { Write-Host ('  How to fix: ' + $Hint) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host ('BURN_FAIL ' + $Code + ' ' + $Reason)
    exit 1
}

function Complete-Burn {
    param([string]$Drive, [long]$Bytes, $Recorder)
    if ($Eject -and $Recorder) {
        try {
            $Recorder.EjectMedia()
            Write-Step 'Disc ejected.'
        } catch {
            Write-Step ('Eject failed (does not affect the burn result): ' + $_.Exception.Message) 'Yellow'
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
    if ($letters.Count -eq 0) { return '(no drive letter)' }
    return ($letters -join ',')
}

function Get-MediaInfo {
    param($Recorder)
    $info = [pscustomobject]@{
        RecorderSupported = $true
        MediaSupported    = $true
        MediaType         = 0
        MediaName         = 'Unknown'
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
        Fail-Burn 'B06' ('Failed to load the file-stream component: ' + $_.Exception.Message) 'Check that shlwapi.dll on this system is intact, reboot, then try again.'
    }
}

# ---------------------------------------------------------------- list drives
if ($ListDrives) {
    Write-Host ''
    Write-Host '  Drives on this machine:' -ForegroundColor Cyan
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
        } catch { $model = '(model unknown)' }
        $total = Get-MediaTotalSectors -Type $info.MediaType
        $capacityText = 'total sectors=unknown'
        if ($total -gt 0) {
            $capacityText = 'total sectors=' + [string]$total + ' (approx. ' + [Math]::Round($total * 2048 / 1MB, 1) + ' MiB)'
        } else {
            try {
                $wmiSize = [long](Get-WmiObject -Class Win32_CDROMDrive -Filter ('Drive=''' + $drive + '''') -ErrorAction Stop).Size
                if ($wmiSize -gt 0) {
                    $used = [long]($wmiSize / 2048)
                    $capacityText = 'total sectors=unknown  used approx. ' + [string]$used + ' sectors (approx. ' + [Math]::Round($wmiSize / 1MB, 2) + ' MiB)'
                }
            } catch { }
        }
        $freeText = 'unknown'
        if ($info.FreeSectors -ge 0) { $freeText = [string]$info.FreeSectors }
        $blankText = 'unknown'
        if ($info.MediaType -ne 0) {
            if ($info.Blank) { $blankText = 'yes' } else { $blankText = 'no' }
        }
        Write-Host ('  ' + $drive + '  ' + $model + '  media=' + $info.MediaName + '  blank=' + $blankText + '  ' + $capacityText + '  free sectors=' + $freeText)
        if (-not $info.RecorderSupported) { Write-Host '        (this device cannot burn)' -ForegroundColor Yellow }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($item.Recorder)
    }
    if ($n -eq 0) {
        Write-Host '  (no drives found)' -ForegroundColor Yellow
    }
    Write-Host ''
    Complete-Burn -Drive 'LIST' -Bytes 0 -Recorder $null
}

# ---------------------------------------------------------------- argument checks
if ([string]::IsNullOrWhiteSpace($IsoPath)) {
    Fail-Burn 'B05' 'No ISO file given (-IsoPath).' 'Usage: -IsoPath build\aris-al1s.iso -DriveLetter F'
}
if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
    Fail-Burn 'B01' 'No drive letter given (-DriveLetter).' 'Usage: -DriveLetter F or -DriveLetter F:'
}

$isoFull = $null
try { $isoFull = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).ProviderPath } catch { $isoFull = $null }
if (-not $isoFull -or -not (Test-Path -LiteralPath $isoFull -PathType Leaf)) {
    Fail-Burn 'B05' ('ISO file not found: ' + $IsoPath) 'Run tools\New-Disc.ps1 to build the ISO first, or check the path.'
}
$isoInfo = Get-Item -LiteralPath $isoFull
$isoSize = [long]$isoInfo.Length
if ($isoSize -le 0) {
    Fail-Burn 'B05' ('ISO file is 0 bytes: ' + $isoFull) 'Rebuild the ISO, then burn again.'
}

$target = Resolve-TargetDrive -Letter $DriveLetter
if (-not $target) {
    Fail-Burn 'B01' ('Drive not found: ' + $DriveLetter) 'Run -ListDrives to see which drive letters this machine has.'
}
$recorder = $target.Recorder
$drive = $target.Drive

try {
    $info = Get-MediaInfo -Recorder $recorder
    if (-not $info.RecorderSupported) {
        Fail-Burn 'B02' ('This drive cannot burn: ' + $drive) 'Use a recordable DVD/CD writer, or check the driver.'
    }
    if ($info.MediaType -eq 0) {
        Fail-Burn 'B03' ('No media in the drive: ' + $drive) 'Insert a blank CD-R / DVD-R.'
    }
    if ($info.Blank) {
        # Belt and braces: some drivers report a finalized disc as 'physically blank', but a volume label proves it is not.
        try {
            $probe = Get-WmiObject -Class Win32_CDROMDrive -Filter ('Drive=''' + $drive + '''') -ErrorAction Stop
            if ($probe -and $probe.VolumeName) {
                $info.Blank = $false
                $info.MediaName = [string]$info.MediaName + ' (volume label ' + [string]$probe.VolumeName + ')'
            }
        } catch { }
    }
    if (-not $info.Blank) {
        if (-not $TestOnly) {
            Fail-Burn 'B04' ('This disc already has content (' + $info.MediaName + '): ' + $drive) 'Insert a blank disc; add -TestOnly to check the link only.'
        }
        Write-Step ('Note: the media is not blank (' + $info.MediaName + '); TestOnly only checks the link and does not write.') 'Yellow'
    }
    if (-not $info.MediaSupported -and $info.Blank) {
        Fail-Burn 'B03' ('The drive does not support this media: ' + $drive) 'Try another CD-R / DVD-R.'
    }
    $blankText = 'no'
    if ($info.Blank) { $blankText = 'yes' }
    Write-Step ('Target drive: ' + $drive + '  media: ' + $info.MediaName + '  blank: ' + $blankText)
    Write-Step ('ISO: ' + $isoFull + ' (' + $isoSize + ' bytes)')

    $stream = $null
    try {
        $stream = [DiscPersonaIsoStream]::OpenRead($isoFull)
    } catch {
        Fail-Burn 'B06' ('Failed to open the ISO file stream: ' + $_.Exception.Message) 'Check that no other program holds the ISO and that you can read it.'
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
            Write-Step 'TestOnly: the write session opened, the link works, skipping the actual write.' 'Yellow'
        } else {
            Write-Step ('Starting to write (volume label ' + $VolumeLabel + ')…')
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
        if (-not $writeError) { $writeError = '(COM gave no text description, only an HRESULT)' }
        Fail-Burn 'B07' ('Write failed: ' + $writeError) 'Try another blank disc; if it keeps failing, check the drive and the media for wear.'
    }

    if ($TestOnly) {
        Complete-Burn -Drive $drive -Bytes 0 -Recorder $recorder
    }

    Write-Step ('Write complete in ' + [Math]::Round($watch.Elapsed.TotalSeconds, 1) + ' s; reading back for a check…')
    if (-not (Test-Written -Recorder $recorder)) {
        Close-MediaQuietly -Recorder $recorder
        Fail-Burn 'B08' 'The disc still looks blank after writing; the write session may not have been closed.' 'Try another disc; if it still fails, do not use this one.'
    }
    Close-MediaQuietly -Recorder $recorder

    $volume = ''
    try {
        $wmi = Get-WmiObject -Class Win32_CDROMDrive -Filter ('Drive=''' + $drive + '''') -ErrorAction Stop
        if ($wmi -and $wmi.VolumeName) { $volume = [string]$wmi.VolumeName }
    } catch { $volume = '' }
    Write-Step ('Read-back check: the media is no longer blank (' + $info.MediaName + ')')
    if ($volume) { Write-Step ('Read-back volume label: ' + $volume) }

    Complete-Burn -Drive $drive -Bytes $isoSize -Recorder $recorder
} finally {
    if ($recorder) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($recorder) }
}
