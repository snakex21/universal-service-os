# Add the separate experiment to the identified Kingston; preserve production BIOS.
param([switch]$DriversOnly,[switch]$LaunchersOnly,[switch]$UnifiedMenu,[string]$SourceIso,[string]$Language)
$ErrorActionPreference='Stop'
if(([int]$DriversOnly.IsPresent+[int]$LaunchersOnly.IsPresent+[int]$UnifiedMenu.IsPresent) -gt 1){throw 'Choose one targeted deployment mode'}
if($SourceIso -and !$DriversOnly){throw 'Source ISO deployment requires DriversOnly mode'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$package=Join-Path $project 'zig-out\xp-uefi-csm'
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$disks=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'31c644bf-74dd-4807-9cb2-46745adeadd4'})
if($disks.Count -ne 1){throw 'Expected Kingston not connected'}
$disk=$disks[0]
if($disk.Size -ne 61991813632 -or $disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem){throw 'Kingston identity mismatch'}
$parts=@(Get-Partition -DiskNumber $disk.Number)
$esp=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'0257e175-1685-4311-91aa-5a83d8eb41e5'})
$data=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'deb596cd-0d5b-464d-9780-3d7bbec3935a'})
if($parts.Count -ne 3 -or $esp.Count -ne 1 -or $data.Count -ne 1 -or !$esp[0].DriveLetter -or !$data[0].DriveLetter){throw 'USB partition identity mismatch'}
$espRoot=$esp[0].DriveLetter+':\';$dataRoot=$data[0].DriveLetter+':\'
$volume=$esp[0]|Get-Volume
if($volume.FileSystem -ne 'FAT32' -or $volume.SizeRemaining -lt 70MB){throw 'Unexpected/full ESP'}
$manifest=Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw|ConvertFrom-Json
foreach($p in $manifest.sha256.PSObject.Properties){if((Hash (Join-Path $package $p.Name)) -ne $p.Value){throw ('Package hash mismatch: '+$p.Name)}}
$protected=@('EFI\USOS\micro-linux\initramfs-usos','EFI\USOS\micro-linux\vmlinuz-virt','EFI\USOS\windows-native\vista-support.cpio','EFI\USOS\windows-native\support.cpio')
$protectedHashes=@{}
foreach($p in $protected){$protectedHashes[$p]=Hash (Join-Path $espRoot $p)}
if($protectedHashes['EFI\USOS\micro-linux\initramfs-usos'] -ne $manifest.base_initramfs_sha256 -or $protectedHashes['EFI\USOS\micro-linux\vmlinuz-virt'] -ne $manifest.base_kernel_sha256){throw 'Production base changed after trial build'}
$layout=$parts|Select-Object PartitionNumber,Guid,Offset,Size|ConvertTo-Json -Compress
$backup=Join-Path $project ('artifacts\xp-pae\deploy-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($backup)|Out-Null
$layout|Set-Content -LiteralPath (Join-Path $backup 'partitions.json')
$files=@()
if($SourceIso){
 $source=Get-Item -LiteralPath $SourceIso
 $info=@($manifest.driver_sources|Where-Object {$_.name -eq $source.Name})[0]
 if(!$info){$info=$manifest.added_source}
 if(!$info -or $source.Name -ne $info.name -or $source.Length -ne $info.size -or (Hash $source.FullName) -ne $info.sha256){throw 'Source ISO differs from prepared overlay'}
 $isoTarget=Join-Path $dataRoot ('Systems\Windows\Windows XP\Images\'+$source.Name)
 if(Test-Path -LiteralPath $isoTarget){
  if((Hash $isoTarget) -ne $info.sha256){throw 'Different ISO already exists at destination'}
 }else{
  if(($data[0]|Get-Volume).SizeRemaining -lt ($source.Length+64MB)){throw 'Insufficient DATA space for ISO'}
  $files+=@{Source=$source.FullName;Target=$isoTarget}
 }
}
$payloadNames=@('initramfs-xp','vmlinuz.efi','manifest.json')
if($DriversOnly -or $UnifiedMenu){
 if((Hash (Join-Path $espRoot 'EFI\USOS-XP\vmlinuz.efi')) -ne $manifest.base_kernel_sha256){throw 'Existing XP kernel does not match driver build'}
 $payloadNames=@('initramfs-xp','manifest.json')
}
if($LaunchersOnly){
 foreach($name in @('initramfs-xp','vmlinuz.efi')){
  if((Hash (Join-Path $espRoot ('EFI\USOS-XP\'+$name))) -ne $manifest.sha256.$name){throw 'Existing XP payload does not match launcher build'}
 }
 $payloadNames=@('manifest.json')
 $protectedHashes['EFI\BOOT\BOOTX64.EFI']=Hash (Join-Path $espRoot 'EFI\BOOT\BOOTX64.EFI')
 $protected+= 'EFI\BOOT\BOOTX64.EFI'
}
foreach($name in $payloadNames){
 $files+=@{Source=(Join-Path $package $name);Target=(Join-Path $espRoot ('EFI\USOS-XP\'+$name))}
}
if(!$DriversOnly -and !$UnifiedMenu){foreach($name in $manifest.launchers){
 if($name -notmatch '^XP-SP[23](-NiKKA)?-UEFI-CSM-PAE\.efi$'){throw 'Unexpected launcher name'}
 foreach($drive in @($espRoot,$dataRoot)){$files+=@{Source=(Join-Path $package $name);Target=(Join-Path $drive ('Systems\Windows\Windows XP UEFI-CSM PAE\Images\'+$name))}}
}
if(!$LaunchersOnly){$files+=@{Source=(Join-Path $project 'zig-out\usb\EFI\BOOT\BOOTX64.EFI');Target=(Join-Path $espRoot 'EFI\BOOT\BOOTX64.EFI')}}
}
if($UnifiedMenu){
 $files+=@{Source=(Join-Path $project 'zig-out\usb\EFI\BOOT\BOOTX64.EFI');Target=(Join-Path $espRoot 'EFI\BOOT\BOOTX64.EFI')}
 foreach($name in @('legacy-xp-staging-status.txt','legacy-xp-disk-enumeration.txt','legacy-xp-staging-last-error.txt','menu-events.log','menu-hardware.txt','uefi-start.txt')){
  $log=Join-Path $espRoot ('EFI\USOS-XP\'+$name)
  if(Test-Path -LiteralPath $log){[IO.File]::Copy($log,(Join-Path $backup $name),$false)}
 }
}
# Optional: the per-language ESP files the installer writes (only this language;
# the EFI and pae.exe keep English built in), generated from the same catalog.
if($Language){
 if($Language -notmatch '^[a-z]{2}$'){throw 'Language must be a two-letter catalog code'}
 $langOut=Join-Path $backup 'lang-export'
 Push-Location (Join-Path $project 'installer')
 try{& go run ./cmd/usos-i18n-gen -root .. -export $Language -out $langOut|Out-Null;if($LASTEXITCODE -ne 0){throw 'Language export failed'}}finally{Pop-Location}
 foreach($name in @('usos-settings.ini','lang.bin','lang-xp.ini','lang-winpe.ini')){
  $source=Join-Path $langOut ('EFI\USOS\'+$name);if(!(Test-Path -LiteralPath $source -PathType Leaf)){throw ('Missing exported '+$name)}
  # Keep the drive's other settings (wheel_invert, touch_rotation...): only set language.
  $current=Join-Path $espRoot ('EFI\USOS\'+$name)
  if($name -eq 'usos-settings.ini' -and (Test-Path -LiteralPath $current -PathType Leaf)){
   $text=[IO.File]::ReadAllText($current)
   if($text -match '(?im)^\s*language\s*='){$text=[regex]::Replace($text,'(?im)^[ \t]*language[ \t]*=.*$',('language='+$Language),1)}
   elseif($text -match '(?im)^\s*\[ui\]\s*$'){$text=[regex]::Replace($text,'(?im)^(\s*\[ui\]\s*)$',('$1'+"`r`nlanguage="+$Language),1)}
   else{$text="[ui]`r`nlanguage=$Language`r`n"+$text}
   [IO.File]::WriteAllText($source,$text,(New-Object Text.UTF8Encoding($false)))
  }
  $files+=@{Source=$source;Target=(Join-Path $espRoot ('EFI\USOS\'+$name))}
 }
}
$index=0
foreach($f in $files){
 $f.Hash=Hash $f.Source;$f.Existed=Test-Path -LiteralPath $f.Target -PathType Leaf
 $f.Backup=Join-Path $backup ($index.ToString()+'.bin');$index++
 if($f.Existed){[IO.File]::Copy($f.Target,$f.Backup,$false);if((Hash $f.Target) -ne (Hash $f.Backup)){throw 'Backup mismatch'}}
}
if((Get-Partition -DriveLetter $esp[0].DriveLetter).Guid -ne $esp[0].Guid -or (Get-Partition -DriveLetter $data[0].DriveLetter).Guid -ne $data[0].Guid){throw 'USB identity changed'}
try {
 foreach($f in $files){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($f.Target))|Out-Null;[IO.File]::Copy($f.Source,$f.Target,$true)}
 Write-VolumeCache -DriveLetter $esp[0].DriveLetter
 Write-VolumeCache -DriveLetter $data[0].DriveLetter
 foreach($f in $files){if((Hash $f.Target) -ne $f.Hash){throw 'Deployment readback mismatch'}}
 foreach($p in $protected){if((Hash (Join-Path $espRoot $p)) -ne $protectedHashes[$p]){throw 'Protected production payload changed'}}
 $after=Get-Partition -DiskNumber $disk.Number|Select-Object PartitionNumber,Guid,Offset,Size|ConvertTo-Json -Compress
 if($after -ne $layout){throw 'Partition layout changed'}
 $files|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $backup 'files.json')
 Write-Output "XP_EXPERIMENT_DEPLOYED; HASH_READBACK=PASS; PRODUCTION_BIOS_AND_VISTA_PAYLOADS_UNCHANGED; PARTITION_LAYOUT_UNCHANGED; BACKUP=$backup"
} catch {
 foreach($f in $files){if($f.Existed){[IO.File]::Copy($f.Backup,$f.Target,$true)}elseif(Test-Path -LiteralPath $f.Target){Remove-Item -LiteralPath $f.Target}}
 throw
}
