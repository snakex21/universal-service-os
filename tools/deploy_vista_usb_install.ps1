# Targeted file update of the user's identified Kingston. No partition changes.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Hash($file){(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()}
function Kingston {
 $found=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'31c644bf-74dd-4807-9cb2-46745adeadd4'})
 if($found.Count -ne 1 -or $found[0].Size -ne 61991813632 -or $found[0].IsBoot -or $found[0].IsSystem -or $found[0].BusType -ne 'USB'){throw 'Kingston identity mismatch'}
 return $found[0]
}
$disk=Kingston
$parts=@(Get-Partition -DiskNumber $disk.Number)
$esp=@($parts|Where-Object {$_.GptType -and ([guid]$_.GptType) -eq [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'})
$data=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'deb596cd-0d5b-464d-9780-3d7bbec3935a'})
if($parts.Count -ne 3 -or $esp.Count -ne 1 -or $data.Count -ne 1 -or !$esp[0].DriveLetter -or !$data[0].DriveLetter){throw 'USB partition identity mismatch'}
$espRoot=$esp[0].DriveLetter+':\';$dataRoot=$data[0].DriveLetter+':\'
$espVolume=$esp[0]|Get-Volume
if($espVolume.FileSystem -ne 'FAT32' -or $espVolume.FileSystemLabel -ne 'USOS_ESP' -or $espVolume.SizeRemaining -lt 8MB){throw 'Unexpected/full ESP'}
$source=Join-Path $dataRoot 'Systems\Windows\Windows Vista\Images\pl_windows_vista_with_sp2_x64_dvd_x15-36359.iso'
$donor=Join-Path $dataRoot 'Systems\Windows\Windows 10\Images\PE10_x64_19041_USOS.iso'
if((Get-Item -LiteralPath $source).Length -ne 3702233088 -or !(Test-Path -LiteralPath $donor -PathType Leaf)){throw 'Expected Vista ISO / PE10 donor missing'}
& python (Join-Path $project 'tools\tests\check_vista_usb_support.py')
if($LASTEXITCODE -ne 0){throw 'Support archive verification failed'}
$backup=Join-Path $project ('artifacts\vista\usb-install-update-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($backup)|Out-Null
$layout=$parts|Select-Object PartitionNumber,Guid,Offset,Size|ConvertTo-Json -Compress
$layout|Set-Content -LiteralPath (Join-Path $backup 'partition-layout.json')
$files=@(
 @{Source='zig-out\windows-native\vista-support.cpio';Relative='EFI\USOS\windows-native\vista-support.cpio'},
 @{Source='zig-out\windows-native\support.cpio';Relative='EFI\USOS\windows-native\support.cpio'},
 @{Source='zig-out\usb\EFI\BOOT\BOOTX64.EFI';Relative='EFI\BOOT\BOOTX64.EFI'}
)
foreach($item in $files){
 $item.Source=Join-Path $project $item.Source;$item.Target=Join-Path $espRoot $item.Relative
 $item.Hash=Hash $item.Source;$item.Existed=Test-Path -LiteralPath $item.Target -PathType Leaf
 $item.Backup=Join-Path $backup $item.Relative
 if($item.Existed){
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($item.Backup))|Out-Null
  Copy-Item -LiteralPath $item.Target -Destination $item.Backup
  if((Hash $item.Backup) -ne (Hash $item.Target)){throw 'Backup mismatch'}
 } elseif($item.Relative -ne 'EFI\USOS\windows-native\vista-support.cpio'){throw 'Existing USOS boot files missing'}
}
if((Kingston).Number -ne $disk.Number -or (Get-Partition -DriveLetter $esp[0].DriveLetter).Guid -ne $esp[0].Guid){throw 'USB identity changed'}
try {
 foreach($item in $files){[IO.File]::Copy($item.Source,$item.Target,$true)}
 Write-VolumeCache -DriveLetter $esp[0].DriveLetter
 foreach($item in $files){if((Hash $item.Target) -ne $item.Hash){throw 'USB readback mismatch'}}
 $after=Get-Partition -DiskNumber $disk.Number|Select-Object PartitionNumber,Guid,Offset,Size|ConvertTo-Json -Compress
 if($after -ne $layout){throw 'Partition layout changed'}
 $files|ConvertTo-Json -Depth 3|Set-Content -LiteralPath (Join-Path $backup 'update-files.json')
 Write-Output "VISTA_USB_INSTALL_DEPLOYED; READBACK=PASS; PARTITION_LAYOUT_UNCHANGED; BACKUP=$backup"
 foreach($item in $files){Write-Output ($item.Relative+' SHA256='+$item.Hash)}
} catch {
 foreach($item in $files){
  if($item.Existed){[IO.File]::Copy($item.Backup,$item.Target,$true)}
  elseif($item.Relative -eq 'EFI\USOS\windows-native\vista-support.cpio' -and (Test-Path -LiteralPath $item.Target)){Remove-Item -LiteralPath $item.Target}
 }
 Write-VolumeCache -DriveLetter $esp[0].DriveLetter
 throw
}
