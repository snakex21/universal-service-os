<#
.SYNOPSIS
  Test-only target disk with a fake ABORTED Windows installation (QEMU).

.DESCRIPTION
  Creates a dynamic VHD (GPT, one 16 GiB NTFS partition, the rest left
  unallocated for the new install), writes the traces of an install that
  stopped in specialize (Windows\Setup\State\State.ini at
  IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE, Panther logs, UnattendGC,
  System/Setup.evtx stand-ins, a minidump and a leftover $WINDOWS.~BT) and
  converts it to qcow2 for tools/tests/windows_native/qemu_native.py --target.
  Nothing outside tools/tests/artifacts is written.
#>
param(
    [Parameter(Mandatory = $true)][string]$Qcow2Path,
    [int]$SizeGB = 64
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$artifacts = [IO.Path]::GetFullPath((Join-Path $root 'tools\tests\artifacts'))
$Qcow2Path = [IO.Path]::GetFullPath($Qcow2Path)
if (-not $Qcow2Path.StartsWith($artifacts, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing image path outside tools/tests/artifacts: $Qcow2Path" }
$vhd = [IO.Path]::ChangeExtension($Qcow2Path, '.build.vhd')
$qemuImg = Join-Path $root 'tools\qemu\qemu-img.exe'
foreach ($old in @($vhd, $Qcow2Path)) { if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force } }
& $qemuImg create -f vpc $vhd "$($SizeGB)G" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img VHD create failed: $LASTEXITCODE" }
# Windows refuses to attach a sparse VHD file (0xC03A001A).
& fsutil.exe sparse setflag $vhd 0 | Out-Null
$mount = "$vhd.mount"
$mounted = $false
$part = $null
try {
    Mount-DiskImage -ImagePath $vhd -StorageType VHD -NoDriveLetter | Out-Null
    $mounted = $true
    Start-Sleep -Milliseconds 500
    $disk = Get-DiskImage -ImagePath $vhd | Get-Disk
    if ($disk.PartitionStyle -ne 'RAW' -or $disk.FriendlyName -notmatch 'Virtual') { throw "unexpected disk: $($disk.FriendlyName) $($disk.PartitionStyle)" }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $part = New-Partition -DiskNumber $disk.Number -Size 16GB -GptType '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
    $part | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'OLDWIN' -Confirm:$false -Force | Out-Null
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath $mount
    function Put([string]$Relative, [byte[]]$Bytes) {
        $path = Join-Path $mount $Relative
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        [IO.File]::WriteAllBytes($path, $Bytes)
    }
    $ascii = [Text.Encoding]::ASCII
    Put 'Windows\Setup\State\State.ini' ($ascii.GetBytes("[State]`r`nImageState=IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE`r`n"))
    Put 'Windows\Panther\setupact.log' ($ascii.GetBytes("USOS-FAKE-ABORTED setupact: specialize started`r`n"))
    Put 'Windows\Panther\setuperr.log' ($ascii.GetBytes("USOS-FAKE-ABORTED setuperr: The computer restarted unexpectedly`r`n"))
    Put 'Windows\Panther\UnattendGC\setupact.log' ($ascii.GetBytes("USOS-FAKE-ABORTED unattendgc`r`n"))
    Put 'Windows\System32\winevt\Logs\System.evtx' ($ascii.GetBytes('ElfFile' + ('x' * 4096)))
    Put 'Windows\System32\winevt\Logs\Setup.evtx' ($ascii.GetBytes('ElfFile' + ('y' * 4096)))
    Put 'Windows\Minidump\092526-01.dmp' ($ascii.GetBytes('PAGEDU64' + ('z' * 2048)))
    Put '$WINDOWS.~BT\Sources\Panther\setupact.log' ($ascii.GetBytes("USOS-FAKE-ABORTED bt setupact`r`n"))
    Write-Host "[PASS] fake aborted install written to OLDWIN (16 GiB), rest unallocated"
} finally {
    if ($mounted) {
        if ($part) { Remove-PartitionAccessPath -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -AccessPath $mount -ErrorAction SilentlyContinue }
        Dismount-DiskImage -ImagePath $vhd | Out-Null
    }
    if (Test-Path -LiteralPath $mount) { Remove-Item -LiteralPath $mount -Recurse -Force }
}
& $qemuImg convert -f vpc -O qcow2 $vhd $Qcow2Path
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert failed: $LASTEXITCODE" }
Remove-Item -LiteralPath $vhd -Force
Write-Host "[PASS] target $Qcow2Path"
