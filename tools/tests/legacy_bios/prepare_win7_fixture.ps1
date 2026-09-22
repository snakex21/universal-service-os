param([string]$OutputDirectory = 'zig-out/win7-bios/fixture', [switch]$FinalizeOnly)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$out = [IO.Path]::GetFullPath((Join-Path $root $OutputDirectory))
if (-not $out.StartsWith((Join-Path $root 'zig-out') + '\')) { throw 'Fixture must remain under zig-out' }
if ((Test-Path -LiteralPath $out) -and -not $FinalizeOnly) { throw 'Use a new fixture directory' }
New-Item -ItemType Directory -Force -Path $out | Out-Null
$vhd = Join-Path $out 'usos.vhd'
if (-not $FinalizeOnly) {
$diskpart = Join-Path $out 'create.txt'
$spec = @"
create vdisk file="$vhd" maximum=12288 type=expandable
select vdisk file="$vhd"
attach vdisk
convert gpt
select partition 1
delete partition override
create partition efi size=1024 offset=1024
create partition primary size=4096
create partition primary
exit
"@
[IO.File]::WriteAllText($diskpart,$spec)
$mounted=$false
$mounts=@()
try {
    & diskpart.exe /s $diskpart
    if ($LASTEXITCODE) { throw 'Virtual fixture disk creation failed' }
    $mounted=$true
    $disk=Get-DiskImage -ImagePath $vhd | Get-Disk
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.Size -ne 12884901888) { throw 'Unexpected virtual disk identity' }
    $parts=@(Get-Partition -DiskNumber $disk.Number | Sort-Object Offset)
    if ($parts.Count -ne 3) { throw 'Expected ESP, DATA, WORK' }
    $labels=@('USOS_ESP','USOS_DATA','USOS_WORK')
    for ($i=0;$i -lt 3;$i++) {
        $fs=if($i -eq 0){'FAT32'}else{'NTFS'}
        $parts[$i] | Format-Volume -FileSystem $fs -NewFileSystemLabel $labels[$i] -Confirm:$false -Force | Out-Null
        $mount=Join-Path $out $labels[$i]
        New-Item -ItemType Directory -Path $mount | Out-Null
        $parts[$i] | Add-PartitionAccessPath -AccessPath $mount
        $mounts+=$mount
    }
    $usos=Join-Path $mounts[0] 'EFI/USOS'
    New-Item -ItemType Directory -Force -Path (Join-Path $usos 'micro-linux') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'zig-out/micro-linux/vmlinuz-virt') -Destination (Join-Path $usos 'micro-linux/vmlinuz-virt')
    Copy-Item -LiteralPath (Join-Path $root 'zig-out/micro-linux/initramfs-usos') -Destination (Join-Path $usos 'micro-linux/initramfs-usos')
    $images=Join-Path $mounts[1] 'Systems/Windows/Windows 7/Images'
    New-Item -ItemType Directory -Force -Path $images | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'WIN7X64.6in1.pl-PL.JULY2019.ISO') -Destination $images
    $espGuid=$parts[0].Guid.ToString().Trim('{}')
    $dataGuid=$parts[1].Guid.ToString().Trim('{}')
    $workGuid=$parts[2].Guid.ToString().Trim('{}')
    $diskGuid=$disk.Guid.ToString().Trim('{}')
    $nonce='win7-vm-fixture-20260910'
    $ini="version=1`nnonce=$nonce`ndisk_ptuuid=$diskGuid`nesp_partuuid=$espGuid`ndata_partuuid=$dataGuid`nwork_partuuid=$workGuid`n"
    [IO.File]::WriteAllText((Join-Path $usos 'usos-device.ini'),$ini)
    [IO.File]::WriteAllText((Join-Path $mounts[2] '.usos-work'),"nonce=$nonce`n")
    [IO.File]::WriteAllText((Join-Path $out 'esp-guid.txt'),$espGuid)
} finally {
    for($i=0;$i -lt $mounts.Count;$i++) {
        $parts[$i] | Remove-PartitionAccessPath -AccessPath ($mounts[$i] + '\') -ErrorAction Continue
    }
    if($mounted){ Dismount-DiskImage -ImagePath $vhd }
    foreach($mount in $mounts){ if(Test-Path -LiteralPath $mount){ Remove-Item -LiteralPath $mount -Force } }
}
}
if ((Get-DiskImage -ImagePath $vhd).Attached) { throw 'Detach fixture before converting' }
if (-not (Test-Path -LiteralPath (Join-Path $out 'esp-guid.txt'))) { throw 'Fixture preparation did not finish' }
& (Join-Path $root 'tools/qemu/qemu-img.exe') convert -f vpc -O raw -S 4k $vhd (Join-Path $out 'usos.raw')
if($LASTEXITCODE){throw 'Fixture conversion failed'}
& python.exe (Join-Path $PSScriptRoot 'patch_win7_fixture.py') (Join-Path $out 'usos.raw')
if($LASTEXITCODE){throw 'Fixture boot setup failed'}
& (Join-Path $root 'tools/qemu/qemu-img.exe') convert -f raw -O qcow2 (Join-Path $out 'usos.raw') (Join-Path $out 'usos.qcow2')
if($LASTEXITCODE){throw 'Fixture qcow2 conversion failed'}
Write-Host "PASS: $out"
