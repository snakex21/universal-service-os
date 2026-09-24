# Mounts the WORK partition of the run_setup_virtio_qemu.py test VHD and
#   -Reset:        removes an old usos-proof result folder;
#   -Drivers on|off: renames $WinPEDriver$ <-> usos-off-$WinPEDriver$ (negative control);
#   -CopyOut <dir>: copies usos-proof\ out.
# Elevated shell; only touches the given VHD.
param(
    [Parameter(Mandatory = $true)][string]$Vhd,
    [switch]$Reset,
    [ValidateSet('', 'on', 'off')][string]$Drivers = '',
    [string]$CopyOut = '',
    # Replaces WORK\Autounattend.xml (the full-install run uses usos-e2e-virtio.xml).
    [string]$Autounattend = ''
)
$ErrorActionPreference = 'Stop'
$Vhd = [IO.Path]::GetFullPath($Vhd)
$mount = "$Vhd.io"
Mount-DiskImage -ImagePath $Vhd -StorageType VHD -NoDriveLetter | Out-Null
Start-Sleep -Milliseconds 500
$disk = Get-DiskImage -ImagePath $Vhd | Get-Disk
$part = Get-Partition -DiskNumber $disk.Number | Where-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel -eq 'USOS_WORK' } | Select-Object -First 1
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath $mount
# By file system: the full-install run gives the ESP a Basic Data type (see README).
$espPart = Get-Partition -DiskNumber $disk.Number | Where-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystem -eq 'FAT32' } | Select-Object -First 1
$espMount = "$Vhd.esp"
New-Item -ItemType Directory -Force -Path $espMount | Out-Null
Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $espPart.PartitionNumber -AccessPath $espMount
try {
    $proof = Join-Path $mount 'usos-proof'
    if ($Reset -and (Test-Path -LiteralPath $proof)) { Remove-Item -LiteralPath $proof -Recurse -Force }
    # USOS resumes a prepared WORK exactly like after micro-Linux: NTFS driver,
    # WORK by .usos-work, EFI\USOS-WORK\BOOTX64.EFI (e2e_flow.handoffWindows).
    if ($Reset) { [IO.File]::WriteAllText((Join-Path $espMount 'EFI\USOS\install-state.ini'), "phase=prepared`r`nselected_method=iso`r`n") }
    $on = Join-Path $mount '$WinPEDriver$'; $off = Join-Path $mount 'usos-off-$WinPEDriver$'
    if ($Drivers -eq 'off' -and (Test-Path -LiteralPath $on)) { Rename-Item -LiteralPath $on -NewName 'usos-off-$WinPEDriver$' }
    if ($Drivers -eq 'on' -and (Test-Path -LiteralPath $off)) { Rename-Item -LiteralPath $off -NewName '$WinPEDriver$' }
    if ($Autounattend) { Copy-Item -LiteralPath $Autounattend -Destination (Join-Path $mount 'Autounattend.xml') -Force }
    if ($CopyOut) {
        New-Item -ItemType Directory -Force -Path $CopyOut | Out-Null
        if (Test-Path -LiteralPath $proof) { Copy-Item -Path (Join-Path $proof '*') -Destination $CopyOut -Recurse -Force }
    }
    Write-Host ("[WORK] drivers=" + $(if (Test-Path -LiteralPath $on) { 'on' } else { 'off' }) + " proof=" + (Test-Path -LiteralPath $proof))
} finally {
    Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath $mount -Confirm:$false -ErrorAction SilentlyContinue
    Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $espPart.PartitionNumber -AccessPath $espMount -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $espMount -Force -ErrorAction SilentlyContinue
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $mount -Force -ErrorAction SilentlyContinue
}
