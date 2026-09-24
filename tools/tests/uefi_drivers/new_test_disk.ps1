# Builds a small file-backed GPT test disk (VHD) laid out like a USOS stick:
# USOS_ESP (FAT32) with -EspSource copied in, USOS_DATA (NTFS) with
# -DataSource copied in, and an empty USOS_WORK. Used by
# run_qemu_uefi_drivers.py. Needs an elevated shell (Mount-DiskImage); it
# only ever touches the VHD file it creates.
param(
    [Parameter(Mandatory = $true)][string]$Vhd,
    [Parameter(Mandatory = $true)][string]$EspSource,
    [Parameter(Mandatory = $true)][string]$DataSource
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$qemuImg = Join-Path $root 'tools\qemu\qemu-img.exe'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$EspType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$BasicDataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
$Vhd = [IO.Path]::GetFullPath($Vhd)
$mountRoot = "$Vhd.mount"

if (Test-Path -LiteralPath $Vhd) {
    # A run that was stopped may have left this test VHD attached.
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $Vhd -Force
}
& $qemuImg create -f vpc -o subformat=fixed $Vhd 1G | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $Vhd 0 | Out-Null

Mount-DiskImage -ImagePath $Vhd -StorageType VHD -NoDriveLetter | Out-Null
Start-Sleep -Milliseconds 500
$disk = Get-DiskImage -ImagePath $Vhd | Get-Disk
if ($null -eq $disk -or $disk.BusType -ne 'File Backed Virtual') { throw 'Test VHD did not expose a file-backed disk' }
$paths = @()
try {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $esp = New-Partition -DiskNumber $disk.Number -Size 200MB -GptType $EspType
    $data = New-Partition -DiskNumber $disk.Number -Size 600MB -GptType $BasicDataType
    $work = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $BasicDataType
    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    $data | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
    $work | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_WORK' -Confirm:$false -Force | Out-Null
    foreach ($pair in @(@('esp', $esp, $EspSource), @('data', $data, $DataSource))) {
        $path = Join-Path $mountRoot $pair[0]
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $pair[1].PartitionNumber -AccessPath $path
        $paths += , @($pair[1].PartitionNumber, $path)
        # robocopy keeps long and non-ASCII names; exit codes < 8 are success.
        & robocopy.exe $pair[2] $path /E /R:0 /W:0 /COPY:D /DCOPY:D /NP /LOG:"$Vhd.$($pair[0]).robocopy.log" | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy into $($pair[0]) failed: $LASTEXITCODE" }
    }
} finally {
    foreach ($entry in $paths) {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $entry[0] -AccessPath $entry[1] -Confirm:$false -ErrorAction SilentlyContinue
    }
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
}
& $python (Join-Path $root 'tools\boot_ui_screens.py') --name-gpt --disk $Vhd
if ($LASTEXITCODE -ne 0) { throw 'setting GPT partition names failed' }
Write-Host "[PASS] test disk $Vhd"
