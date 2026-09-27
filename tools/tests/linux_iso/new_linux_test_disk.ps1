# Builds the Linux ISO test disk: a fixed VHD laid out like a USOS
# stick (USOS_ESP FAT32 with -EspSource, USOS_DATA NTFS) with the verified
# test ISOs (tools/linux_test_assets.py) copied to
# DATA\Systems\Linux\<Folder>\Images. Writes <Vhd>.extents.json: per ISO the
# disk LBAs of its NTFS extents (fsutil file queryextents), the input for
# run_linux_iso_direct.py (QEMU -kernel/-initrd without the menu).
# Needs an elevated shell (Mount-DiskImage); touches only the VHD it creates.
param(
    [string]$Vhd = "",
    [string]$EspSource = "",
    [int]$SizeGB = 40
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$qemuImg = Join-Path $root 'tools\qemu\qemu-img.exe'
# Mount-DiskImage refused files under %LOCALAPPDATA% here ("path not found"),
# so the VHD lives in the git-ignored artifacts folder; the ISOs are copied
# from the asset folder.
if (-not $Vhd) { $Vhd = Join-Path $root 'tools\tests\artifacts\linux-iso\usos-linux-test.vhd' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Vhd) | Out-Null
$assets = Join-Path $env:LOCALAPPDATA 'USOS\test-assets\linux'
$manifest = Get-Content (Join-Path $assets 'manifest.json') -Raw | ConvertFrom-Json
# test asset name -> DATA folder under Systems\Linux
$folders = @{
    'ubuntu-desktop' = 'Ubuntu'; 'ubuntu-server' = 'Ubuntu'; 'mint' = 'Linux Mint';
    'debian13-netinst' = 'Debian'; 'debian12-netinst' = 'Debian'; 'debian13-live' = 'Debian';
    'fedora' = 'Fedora'; 'systemrescue' = 'SystemRescue'; 'gparted' = 'GParted Live'; 'clonezilla' = 'Clonezilla'
}
$EspType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$BasicDataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
if (Test-Path -LiteralPath $Vhd) {
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $Vhd -Force
}
& $qemuImg create -f vpc -o subformat=fixed $Vhd "$($SizeGB)G" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed" }
& fsutil.exe sparse setflag $Vhd 0 | Out-Null
Mount-DiskImage -ImagePath $Vhd -StorageType VHD -NoDriveLetter | Out-Null
Start-Sleep -Milliseconds 500
$disk = Get-DiskImage -ImagePath $Vhd | Get-Disk
if ($null -eq $disk -or $disk.BusType -ne 'File Backed Virtual') { throw 'Test VHD did not expose a file-backed disk' }
$mountRoot = "$Vhd.mount"
$paths = @()
$result = [ordered]@{}
try {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $esp = New-Partition -DiskNumber $disk.Number -Size 300MB -GptType $EspType
    $data = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $BasicDataType
    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    $data | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
    $espPath = Join-Path $mountRoot 'esp'; $dataPath = Join-Path $mountRoot 'data'
    foreach ($pair in @(@($esp, $espPath), @($data, $dataPath))) {
        New-Item -ItemType Directory -Force -Path $pair[1] | Out-Null
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $pair[0].PartitionNumber -AccessPath $pair[1]
        $paths += , @($pair[0].PartitionNumber, $pair[1])
    }
    if ($EspSource) {
        & robocopy.exe $EspSource $espPath /E /R:0 /W:0 /COPY:D /DCOPY:D /NP /NFL /NDL | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy ESP failed: $LASTEXITCODE" }
    }
    $cluster = [uint64]((Get-Volume -Partition $data | Select-Object -First 1).AllocationUnitSize)
    $partStart = [uint64](($data | Select-Object -First 1).Offset)
    Write-Host "DATA offset $partStart cluster $cluster"
    foreach ($prop in $manifest.PSObject.Properties) {
        $name = $prop.Name; $file = $prop.Value.file
        $folder = $folders[$name]
        if (-not $folder) { continue }
        $dir = Join-Path $dataPath "Systems\Linux\$folder\Images"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-Host "copy $file -> $folder"
        # robocopy (unbuffered, retries): Copy-Item lost the access path on
        # large files once.
        & robocopy.exe $assets $dir $file /J /R:3 /W:2 /NP /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy $file failed: $LASTEXITCODE" }
        $target = Join-Path $dir $file
        $extents = @()
        foreach ($line in (& fsutil.exe file queryextents $target)) {
            if ($line -match 'VCN:\s*0x([0-9a-fA-F]+)\s+Clusters:\s*0x([0-9a-fA-F]+)\s+LCN:\s*0x([0-9a-fA-F]+)') {
                $lcn = [Convert]::ToUInt64($Matches[3], 16); $count = [Convert]::ToUInt64($Matches[2], 16)
                $extents += , @([uint64](($partStart + $lcn * $cluster) / 512), [uint64]($count * $cluster / 512))
            }
        }
        $result[$name] = [ordered]@{ folder = $folder; file = $file; size = $prop.Value.size; extents = $extents }
    }
} finally {
    foreach ($entry in $paths) {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $entry[0] -AccessPath $entry[1] -Confirm:$false -ErrorAction SilentlyContinue
    }
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
}
$result | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 "$Vhd.extents.json"
& python (Join-Path $root 'tools\boot_ui_screens.py') --name-gpt --disk $Vhd
Write-Host "[PASS] Linux test disk $Vhd"
