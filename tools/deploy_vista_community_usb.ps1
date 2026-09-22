$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$disk=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem){throw 'Intel identity mismatch'}
$os=@(Get-Partition -DiskNumber $disk[0].Number|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
if($os.Count -ne 1 -or $os[0].DriveLetter -ne 'M' -or $os[0].Offset -ne 240123904 -or $os[0].Size -ne 119793516544 -or $os[0].IsBoot -or $os[0].IsSystem){throw 'Partition mismatch'}
$pkg=Join-Path $project 'zig-out\vista\community-usb'
$manifest=Get-Content -LiteralPath (Join-Path $pkg 'deployment-manifest.json') -Raw|ConvertFrom-Json
$cab=Join-Path $pkg 'kb\Windows6.0-KB2864202-x64.cab'
if((Hash $cab) -ne $manifest.cab_sha256){throw 'Microsoft CAB hash mismatch'}
foreach($prop in $manifest.driver_files.PSObject.Properties){if((Hash (Join-Path $pkg $prop.Name)) -ne $prop.Value){throw 'Driver changed since signature verification'}}
# Pure read-only hive parsing verifies the current pre-Setup gate remains armed.
& python (Join-Path $project 'tools\verify_vista_usb_gate.py')
if($LASTEXITCODE -ne 0){throw 'Vista startup gate precondition failed'}
$work=Join-Path $project ('zig-out\vista\community-deploy-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($work)|Out-Null
Copy-Item -LiteralPath 'M:\USOS' -Destination $work -Recurse
Copy-Item -LiteralPath 'M:\Windows\Panther' -Destination $work -Recurse
$config=Join-Path $work 'config';[IO.Directory]::CreateDirectory($config)|Out-Null
foreach($name in @('SYSTEM','SOFTWARE','COMPONENTS')){Copy-Item -LiteralPath "M:\Windows\System32\config\$name" -Destination $config}
foreach($name in @('Wdf01000.sys','WdfLdr.sys')){Copy-Item -LiteralPath "M:\Windows\System32\drivers\$name" -Destination $work}
$files=,@((Join-Path $project 'zig-out\vista\firstboot\usb.exe'),'M:\USOS\usb.exe')
foreach($name in @('usos-vista-firstboot.exe','usos-vista-kmdf.exe')){$files+=,@((Join-Path $project "zig-out\vista\firstboot\$name"),"M:\USOS\Vista\$name")}
foreach($f in Get-ChildItem -LiteralPath (Join-Path $pkg 'driver') -File){$files+=,@($f.FullName,("M:\USOS\Vista\Drivers\GenericVista\"+$f.Name))}
$files+=,@($cab,'M:\USOS\Vista\Updates\Windows6.0-KB2864202-x64.cab')
$files+=,@((Join-Path $pkg 'deployment-manifest.json'),'M:\USOS\Vista\community-driver-manifest.json')
if(Test-Path -LiteralPath 'M:\USOS\Vista\kmdf-install-attempted.flag'){throw 'Previous native servicing attempt requires inspection; not resetting it'}
$restore=@()
try {
 foreach($f in $files){
  $dst=[IO.Path]::GetFullPath($f[1]);if(-not $dst.StartsWith('M:\USOS\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected target path'}
  $exists=Test-Path -LiteralPath $dst;$save=Join-Path $work ('payload-'+$restore.Count)
  if($exists){Copy-Item -LiteralPath $dst -Destination $save}
  $restore+=,@($dst,$save,$exists)
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))|Out-Null
  Copy-Item -LiteralPath $f[0] -Destination $dst -Force
 }
 Write-VolumeCache -DriveLetter M
 foreach($f in $files){if((Hash $f[0]) -ne (Hash $f[1])){throw "Readback mismatch: $($f[1])"}}
 foreach($name in @('SYSTEM','SOFTWARE','COMPONENTS')){if((Hash "M:\Windows\System32\config\$name") -ne (Hash (Join-Path $config $name))){throw 'Target registry unexpectedly changed'}}
 Write-Output "COMMUNITY_USB_SEQUENCE_STAGED; READBACK_SHA256=PASS; BACKUP=$work"
 Write-Output 'KB2864202 not yet installed: native Vista Pkgmgr runs on the next hardware boot, then reboots before USB installation.'
} catch {
 foreach($f in $restore){if($f[2]){[IO.File]::Copy($f[1],$f[0],$true)}elseif(Test-Path -LiteralPath $f[0]){Remove-Item -LiteralPath $f[0]}}
 Write-VolumeCache -DriveLetter M
 throw
}
& fsutil.exe dirty query M:
