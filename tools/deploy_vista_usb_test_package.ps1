$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$prepared=Join-Path $project 'zig-out\vista\early-usb-v3'
$package=Join-Path $project 'zig-out\vista\usb-test-package'
$manifest=(Get-Content -LiteralPath (Join-Path $prepared 'repair.json') -Raw|ConvertFrom-Json).SYSTEM
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$disk=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem){throw 'Intel identity mismatch'}
$parts=@(Get-Partition -DiskNumber $disk[0].Number)
$os=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
$esp=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
if($os.Count -ne 1 -or $os[0].DriveLetter -ne 'M' -or $os[0].Offset -ne 240123904 -or $os[0].Size -ne 119793516544 -or $os[0].IsBoot -or $os[0].IsSystem -or $esp.Count -ne 1 -or $esp[0].Size -ne 100MB){throw 'Partition mismatch'}
$base='M:\';$system='M:\Windows\System32\config\SYSTEM'
if((Hash $system) -ne $manifest.original_sha256 -or (Hash (Join-Path $prepared 'SYSTEM')) -ne $manifest.patched_sha256){throw 'SYSTEM hash precondition failed'}
$backup=Join-Path $prepared ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss));[IO.Directory]::CreateDirectory($backup)|Out-Null
foreach($f in Get-ChildItem -LiteralPath 'M:\Windows\System32\config' -File|Where-Object {$_.Name -eq 'SYSTEM' -or $_.Name.StartsWith('SYSTEM.')}){Copy-Item -LiteralPath $f.FullName -Destination $backup}
& chkdsk.exe M: /f /x *> (Join-Path $backup 'chkdsk.log')
$code=$LASTEXITCODE;Write-Output "CHKDSK_EXIT=$code";if($code -gt 1){throw 'Filesystem repair failed'}
if((Hash $system) -ne $manifest.original_sha256){throw 'SYSTEM changed during filesystem repair'}
Copy-Item -LiteralPath 'M:\Windows\Panther' -Destination $backup -Recurse
Copy-Item -LiteralPath 'M:\USOS' -Destination $backup -Recurse
Copy-Item -LiteralPath 'M:\Windows\inf\setupapi.dev.log' -Destination $backup
$part=$esp[0];$assigned=$false;$writing=$false
try {
 if(-not $part.DriveLetter){$part|Add-PartitionAccessPath -AssignDriveLetter;$assigned=$true}
 $part=Get-Partition -DiskNumber $disk[0].Number -PartitionNumber $part.PartitionNumber
 $espRoot="$($part.DriveLetter):\";$bcd=Join-Path $espRoot 'EFI\Microsoft\Boot\BCD'
 Copy-Item -LiteralPath $bcd -Destination (Join-Path $backup 'BCD-before')
 $newBcd=Join-Path $prepared 'BCD';Copy-Item -LiteralPath $bcd -Destination $newBcd
 & bcdedit.exe /store $newBcd /set '{default}' testsigning on | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Cannot enable test signing for offline Vista loader'}
 & bcdedit.exe /store $newBcd /enum all /v | Set-Content -LiteralPath (Join-Path $backup 'bcd-new.txt')
 if($LASTEXITCODE -ne 0){throw 'BCD validation failed'}
 $writing=$true
 foreach($folder in @('Hub','Host')){
  $stem=if($folder -eq 'Hub'){'amdhub31'}else{'amdxhc31'}
  foreach($rel in @("$stem.inf","$stem.cat","x64\$stem.sys")){
   $src=Join-Path $package "AMD_USB31_PT\$folder\$rel"
   $dst=Join-Path $base "USOS\Vista\Drivers\AMD_USB31_PT\$folder\$rel"
   Copy-Item -LiteralPath $src -Destination $dst -Force
   if((Hash $src) -ne (Hash $dst)){throw 'Driver readback mismatch'}
  }
 }
 Copy-Item -LiteralPath (Join-Path $project 'zig-out\vista\firstboot\usos-vista-firstboot.exe') -Destination 'M:\USOS\Vista\usos-vista-firstboot.exe' -Force
 # The public certificate is diagnostic; the private key stays in the project.
 Copy-Item -LiteralPath (Join-Path $package 'usos-vista-usb-test.cer') -Destination 'M:\USOS\Vista\usos-vista-usb-test.cer'
 # Restart the incomplete setup queue. Preserve both failed-state files;
 # never claim completion by setting ChildCompletion=3 or bypassing OOBE.
 foreach($name in @('setupinfo','setupinfo.4d53424c4b425244.spl')){
  $src=[IO.Path]::GetFullPath((Join-Path 'M:\Windows\Panther' $name))
  if(-not $src.StartsWith('M:\Windows\Panther\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected setup state path'}
  if(Test-Path -LiteralPath $src){Move-Item -LiteralPath $src -Destination (Join-Path $backup ($name+'.failed-state'))}
 }
 [IO.File]::Copy($newBcd,$bcd,$true)
 [IO.File]::Copy((Join-Path $prepared 'SYSTEM'),$system,$true)
 Write-VolumeCache -DriveLetter M;Write-VolumeCache -DriveLetter $part.DriveLetter
 if((Hash $system) -ne $manifest.patched_sha256 -or (Hash $bcd) -ne (Hash $newBcd)){throw 'Registry/BCD readback mismatch'}
 if((Hash 'M:\USOS\Vista\usos-vista-firstboot.exe') -ne (Hash (Join-Path $project 'zig-out\vista\firstboot\usos-vista-firstboot.exe'))){throw 'Helper readback mismatch'}
 Write-Output "VISTA_TEST_PACKAGE_DEPLOYED; SHA256_READBACK=PASS; BACKUP=$backup; HARDWARE_PENDING"
} catch {
 if($writing){
  [IO.File]::Copy((Join-Path $backup 'SYSTEM'),$system,$true)
  [IO.File]::Copy((Join-Path $backup 'BCD-before'),$bcd,$true)
  foreach($folder in @('Hub','Host')){
   $stem=if($folder -eq 'Hub'){'amdhub31'}else{'amdxhc31'}
   foreach($rel in @("$stem.inf","$stem.cat","x64\$stem.sys")){[IO.File]::Copy((Join-Path $backup "USOS\Vista\Drivers\AMD_USB31_PT\$folder\$rel"),(Join-Path $base "USOS\Vista\Drivers\AMD_USB31_PT\$folder\$rel"),$true)}
  }
  [IO.File]::Copy((Join-Path $backup 'USOS\Vista\usos-vista-firstboot.exe'),'M:\USOS\Vista\usos-vista-firstboot.exe',$true)
  foreach($name in @('setupinfo','setupinfo.4d53424c4b425244.spl')){$saved=Join-Path $backup ('Panther\'+$name);if(Test-Path -LiteralPath $saved){[IO.File]::Copy($saved,('M:\Windows\Panther\'+$name),$true)}}
  Write-VolumeCache -DriveLetter M;Write-VolumeCache -DriveLetter $part.DriveLetter
 }
 throw
} finally {if($assigned){$part|Remove-PartitionAccessPath -AccessPath $espRoot}}
& fsutil.exe dirty query M:
