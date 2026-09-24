# Builds the WORK test disk for run_setup_virtio_qemu.py: a dynamic GPT VHD
# with a small FAT32 boot partition (USOS + its NTFS driver, see below) and an NTFS
# USOS_WORK laid out like a prepared WORK (Windows ISO extracted, EFI/BOOT
# moved to EFI/USOS-WORK, .usos-work marker) plus the given extra tree
# ($WinPEDriver$, Autounattend.xml, the probe script). Elevated shell
# (Mount-DiskImage); only ever touches the VHD it creates.
param(
    [Parameter(Mandatory = $true)][string]$Vhd,
    [Parameter(Mandatory = $true)][string]$Iso,
    [Parameter(Mandatory = $true)][string]$EspSource,
    [Parameter(Mandatory = $true)][string]$WorkExtra
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$qemuImg = Join-Path $root 'tools\qemu\qemu-img.exe'
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
$BasicDataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
$Vhd = [IO.Path]::GetFullPath($Vhd)
$mountRoot = "$Vhd.mount"
if (Test-Path -LiteralPath $Vhd) {
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $Vhd -Force
}
& $qemuImg create -f vpc $Vhd 14G | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed: $LASTEXITCODE" }
# qemu-img writes a sparse file; Windows refuses to attach sparse VHDs.
& fsutil.exe sparse setflag $Vhd 0 | Out-Null
Mount-DiskImage -ImagePath $Vhd -StorageType VHD -NoDriveLetter | Out-Null
Start-Sleep -Milliseconds 500
$disk = Get-DiskImage -ImagePath $Vhd | Get-Disk
if ($null -eq $disk -or $disk.BusType -ne 'File Backed Virtual') { throw 'Test VHD did not expose a file-backed disk' }
$paths = @()
try {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    # FAT32 with a Basic Data type, not the ESP type: OVMF still boots
    # \EFI\BOOT\BOOTX64.EFI from it, and Windows Setup (full install) does not
    # try to put its system partition on this disk ("No viable region to
    # allocate 209715200 bytes" with a 100 MB ESP here). See README.md.
    $esp = New-Partition -DiskNumber $disk.Number -Size 100MB -GptType $BasicDataType
    $work = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $BasicDataType
    # New-Partition without a letter sets GPT NoDefaultDriveLetter; WinPE then
    # gives WORK no letter and Setup cannot find its media (as on the stick,
    # tools/prepare_e2e_base.ps1).
    Set-Partition -InputObject $work -NoDefaultDriveLetter $false -Confirm:$false
    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'TEST_ESP' -Confirm:$false -Force | Out-Null
    $work | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_WORK' -Confirm:$false -Force | Out-Null
    $espPath = Join-Path $mountRoot 'esp'; $workPath = Join-Path $mountRoot 'work'
    foreach ($pair in @(@($esp, $espPath), @($work, $workPath))) {
        New-Item -ItemType Directory -Force -Path $pair[1] | Out-Null
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $pair[0].PartitionNumber -AccessPath $pair[1]
        $paths += , @($pair[0].PartitionNumber, $pair[1])
    }
    & robocopy.exe $EspSource $espPath /E /R:0 /W:0 /COPY:D /DCOPY:D /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy ESP failed: $LASTEXITCODE" }
    & $sevenZip x -y "-o$workPath" $Iso | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed: $LASTEXITCODE" }
    # What tools/work_boot_relocate.sh does on a prepared WORK.
    $efiBoot = Join-Path $workPath 'efi\boot'
    if (-not (Test-Path -LiteralPath $efiBoot)) { throw 'ISO has no efi\boot' }
    Rename-Item -LiteralPath $efiBoot -NewName 'USOS-WORK'
    [IO.File]::WriteAllText((Join-Path $workPath '.usos-work'), "nonce=virtio-e2e`n")
    & robocopy.exe $WorkExtra $workPath /E /R:0 /W:0 /COPY:D /DCOPY:D /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy WORK extra failed: $LASTEXITCODE" }
} finally {
    foreach ($entry in $paths) {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $entry[0] -AccessPath $entry[1] -Confirm:$false -ErrorAction SilentlyContinue
    }
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
}
Write-Host "[PASS] setup test disk $Vhd"
