# Update the pre-Setup trust/install sequence on the identified Intel Vista installation.
param([switch]$LocalSignature)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Hash($path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
$part=Get-Partition -DriveLetter M;$disk=$part|Get-Disk
if(([guid]$disk.Guid) -ne [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148' -or $disk.FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk.Size -ne 120034123776 -or $disk.IsBoot -or $disk.IsSystem){throw 'Wrong disk'}
if(([guid]$part.Guid) -ne [guid]'73dbde99-8026-4759-a19a-fd943e891d09' -or $part.Offset -ne 240123904 -or $part.Size -ne 119793516544 -or $part.IsBoot -or $part.IsSystem){throw 'Wrong partition'}
& python (Join-Path $project 'tools\verify_vista_usb_gate.py')
if($LASTEXITCODE -ne 0){throw 'Pre-Setup hook is not armed'}
$preserve=@{}
foreach($f in @('M:\Windows\System32\config\SYSTEM','M:\Windows\System32\config\SOFTWARE','M:\Windows\System32\config\COMPONENTS','M:\Windows\System32\drivers\Wdf01000.sys','M:\Windows\System32\drivers\WdfLdr.sys','M:\USOS\Vista\usos-vista-kmdf.exe')){$preserve[$f]=Hash $f}
foreach($f in Get-ChildItem -LiteralPath 'M:\USOS\Vista\Drivers\GenericVista' -File){$preserve[$f.FullName]=Hash $f.FullName}
$variant=if($LocalSignature){'direct-usb-v11'}else{'direct-usb-v11-community'}
$backup=Join-Path $project ('zig-out\vista\'+$variant+'-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($backup)|Out-Null
Copy-Item -LiteralPath 'M:\USOS' -Destination $backup -Recurse
$pairs=@(
 @{Source=(Join-Path $project 'zig-out\vista\firstboot\usos-vista-trust.exe');Target='M:\USOS\Vista\usos-vista-trust.exe'},
 @{Source=(Join-Path $project 'zig-out\vista\firstboot\usos-vista-firstboot.exe');Target='M:\USOS\Vista\usos-vista-firstboot.exe'},
 @{Source=(Join-Path $project 'zig-out\vista\community-usb\deployment-manifest.json');Target='M:\USOS\Vista\community-driver-manifest.json'},
 @{Source=(Join-Path $project 'zig-out\vista\firstboot\usb.exe');Target='M:\USOS\usb.exe'}
)
$allowedNew=@('M:\USOS\Vista\usos-vista-trust.exe')
foreach($name in @('usos-vista-firstboot.exe','usos-vista-trust.exe')){
 $binary=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $project ('zig-out\vista\firstboot\'+$name))))
 if($binary.Contains('V10 LOCAL TEST CATALOG') -ne [bool]$LocalSignature){throw 'Helper signature mode does not match deployment'}
 if($name -eq 'usos-vista-firstboot.exe' -and !$binary.Contains('V11 direct pre-Setup USB device installation')){throw 'Expected v11 direct device installer'}
}
if($LocalSignature){
 $localPackage=Join-Path $project 'zig-out\vista\local-catalog'
 $manifest=Get-Content -LiteralPath (Join-Path $localPackage 'manifest.json') -Raw|ConvertFrom-Json
 if($manifest.version -ne 10 -or $manifest.publisher_ca -ne $false){throw 'Expected v10 end-entity publisher'}
 $driverPairs=@()
 foreach($name in @('USBXHCI.inf','USBXHCI.cat','usbxhci.sys','usbhub3.sys','ucx01000.sys','usbd8.sys')){
  $source=Join-Path $localPackage ('driver\'+$name)
  if((Hash $source) -ne $manifest.files.$name){throw 'Local driver package hash mismatch'}
  if($name -ne 'USBXHCI.cat' -and (Hash $source) -ne (Hash (Join-Path 'M:\USOS\Vista\Drivers\GenericVista' $name))){throw 'INF/SYS changed'}
  $target=Join-Path 'M:\USOS\Vista\Drivers\LocalTestVista' $name
  $driverPairs+=@{Source=$source;Target=$target};$allowedNew+=$target
 }
 $driverPairs+=@{Source=(Join-Path $localPackage 'manifest.json');Target='M:\USOS\Vista\local-driver-manifest.json'}
 $allowedNew+='M:\USOS\Vista\local-driver-manifest.json'
 $pairs=$driverPairs+$pairs
}
foreach($item in $pairs){
 if(!(Test-Path -LiteralPath $item.Source -PathType Leaf)){throw 'Expected source missing'}
 $item.Existed=Test-Path -LiteralPath $item.Target -PathType Leaf
 if(!$item.Existed -and $item.Target -notin $allowedNew){throw 'Expected old target missing'}
 $item.Backup=Join-Path $backup $item.Target.Substring(3)
 if($item.Existed -and (Hash $item.Backup) -ne (Hash $item.Target)){throw 'Backup mismatch'}
 $item.Expected=Hash $item.Source
}
try {
 if($LocalSignature){[IO.Directory]::CreateDirectory('M:\USOS\Vista\Drivers\LocalTestVista')|Out-Null}
 foreach($item in $pairs){[IO.File]::Copy($item.Source,$item.Target,$true)}
 Write-VolumeCache -DriveLetter M
 foreach($item in $pairs){if((Hash $item.Target) -ne $item.Expected){throw 'Readback mismatch'}}
 foreach($f in $preserve.Keys){if((Hash $f) -ne $preserve[$f]){throw "Unexpected change: $f"}}
 & python (Join-Path $project 'tools\verify_vista_usb_gate.py')
 if($LASTEXITCODE -ne 0){throw 'Post-deployment hook validation failed'}
 Write-Output "VISTA_DEPLOYED=$variant; READBACK=PASS; HIVES_KMDF_ORIGINAL_DRIVERS_UNCHANGED; BACKUP=$backup"
 foreach($item in $pairs){Write-Output ($item.Target+' SHA256='+$item.Expected)}
} catch {
 foreach($item in $pairs){
  if($item.Existed){[IO.File]::Copy($item.Backup,$item.Target,$true)}
  elseif($item.Target -in $allowedNew -and (Test-Path -LiteralPath $item.Target)){Remove-Item -LiteralPath $item.Target}
 }
 Write-VolumeCache -DriveLetter M
 throw
}
