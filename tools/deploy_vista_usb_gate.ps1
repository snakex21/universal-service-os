# Apply only to the identified experimental Intel Vista installation.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$disk=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem){throw 'Intel identity mismatch'}
$parts=@(Get-Partition -DiskNumber $disk[0].Number)
$os=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
$esp=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
if($os.Count -ne 1 -or $os[0].DriveLetter -ne 'M' -or $os[0].Offset -ne 240123904 -or $os[0].Size -ne 119793516544 -or $os[0].IsBoot -or $os[0].IsSystem -or $esp.Count -ne 1 -or $esp[0].Size -ne 100MB){throw 'Partition mismatch'}
$work=Join-Path $project ('zig-out\vista\usb-gate-v4-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($work)|Out-Null
# Check the existing target-only test-signing switch without changing any BCD.
$part=$esp[0];$assigned=$false
try {
 if(-not $part.DriveLetter){$part|Add-PartitionAccessPath -AssignDriveLetter;$assigned=$true}
 $part=Get-Partition -DiskNumber $disk[0].Number -PartitionNumber $part.PartitionNumber
 $espRoot="$($part.DriveLetter):\"
 $bcd=Join-Path $espRoot 'EFI\Microsoft\Boot\BCD'
 $bcdText=(& bcdedit.exe /store $bcd /enum '{default}' /v | Out-String)
 if($LASTEXITCODE -ne 0 -or $bcdText -notmatch '(?im)testsigning\s+(Yes|Tak)'){throw 'Offline Vista loader is not test-signed'}
 $bcdText|Set-Content -LiteralPath (Join-Path $work 'bcd-readonly.txt')
} finally {if($assigned){$part|Remove-PartitionAccessPath -AccessPath $espRoot}}
# Interrupted hardware boots leave NTFS dirty. Repair before copying hives.
& chkdsk.exe M: /f /x *> (Join-Path $work 'chkdsk.log')
Write-Output "CHKDSK_EXIT=$LASTEXITCODE";if($LASTEXITCODE -gt 1){throw 'NTFS repair failed'}
$backup=Join-Path $work 'backup';[IO.Directory]::CreateDirectory($backup)|Out-Null
Copy-Item -LiteralPath 'M:\Windows\Panther' -Destination $backup -Recurse
Copy-Item -LiteralPath 'M:\USOS' -Destination $backup -Recurse
Copy-Item -LiteralPath 'M:\Windows\inf\setupapi.dev.log' -Destination $backup
$system='M:\Windows\System32\config\SYSTEM'
Copy-Item -LiteralPath $system -Destination $backup
$prepared=Join-Path $work 'prepared'
& python (Join-Path $project 'tools\prepare_vista_early_usb.py') $system $prepared
if($LASTEXITCODE -ne 0){throw 'Offline Setup state preparation failed'}
$manifest=(Get-Content -LiteralPath (Join-Path $prepared 'repair.json') -Raw|ConvertFrom-Json).SYSTEM
if((Hash $system) -ne $manifest.original_sha256){throw 'SYSTEM changed before deployment'}
$files=@(
 @((Join-Path $project 'zig-out\vista\firstboot\usb.exe'),'M:\USOS\usb.exe'),
 @((Join-Path $project 'zig-out\vista\firstboot\usos-vista-firstboot.exe'),'M:\USOS\Vista\usos-vista-firstboot.exe')
)
$pkg=Join-Path $project 'zig-out\vista\xhci98'
foreach($name in @('xhci98.sys','xhci98.inf','xhci98.cat')){$files+=,@((Join-Path $pkg "package\$name"),"M:\USOS\Vista\Drivers\XHCI98\$name")}
foreach($name in @('LICENSE','README.md')){$files+=,@((Join-Path $pkg "upstream\$name"),"M:\USOS\Vista\Drivers\XHCI98\$name")}
$files+=,@((Join-Path $pkg 'manifest.json'),'M:\USOS\Vista\Drivers\XHCI98\manifest.json')
foreach($f in $files){if(-not (Test-Path -LiteralPath $f[0] -PathType Leaf)){throw "Missing payload: $($f[0])"}}
$restore=@();$moved=@();$writing=$false
try {
 $writing=$true
 foreach($f in $files){
  $dst=[IO.Path]::GetFullPath($f[1]);if(-not $dst.StartsWith('M:\USOS\',[StringComparison]::OrdinalIgnoreCase)){throw 'Payload escaped target'}
  $saved=Join-Path $backup ('payload-'+$restore.Count)
  $exists=Test-Path -LiteralPath $dst
  if($exists){Copy-Item -LiteralPath $dst -Destination $saved}
  $restore+=,@($dst,$saved,$exists)
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))|Out-Null
  Copy-Item -LiteralPath $f[0] -Destination $dst -Force
  if((Hash $f[0]) -ne (Hash $dst)){throw 'Payload readback mismatch'}
 }
 # Remove our obsolete specialize command, not Windows' installation phases.
 # This answer file contains only that command; refuse to discard other settings.
 $answer='M:\Windows\Panther\unattend.xml'
 [xml]$xml=Get-Content -LiteralPath $answer -Raw
 $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
 $components=@($xml.SelectNodes('//u:component',$ns));$commands=@($xml.SelectNodes('//u:RunSynchronousCommand',$ns))
 if($components.Count -ne 1 -or $components[0].name -ne 'Microsoft-Windows-Deployment' -or $commands.Count -ne 1 -or $commands[0].Path -ne '%SystemDrive%\USOS\Vista\usos-vista-firstboot.exe'){throw 'Unexpected answer file; preserve it'}
 foreach($name in @('unattend.xml','setupinfo','setupinfo.4d53424c4b425244.spl')){
  $src=[IO.Path]::GetFullPath((Join-Path 'M:\Windows\Panther' $name))
  if(-not $src.StartsWith('M:\Windows\Panther\',[StringComparison]::OrdinalIgnoreCase)){throw 'Setup state path mismatch'}
  if(Test-Path -LiteralPath $src){$saved=Join-Path $backup ($name+'.removed');Move-Item -LiteralPath $src -Destination $saved;$moved+=,@($src,$saved)}
 }
 [IO.File]::Copy((Join-Path $prepared 'SYSTEM'),$system,$true)
 Write-VolumeCache -DriveLetter M
 if((Hash $system) -ne $manifest.patched_sha256){throw 'SYSTEM readback failed'}
 foreach($f in $files){if((Hash $f[0]) -ne (Hash $f[1])){throw 'Final payload readback failed'}}
 Write-Output "VISTA_USB_BEFORE_SETUP_DEPLOYED; FILE_HASH_READBACK=PASS; BACKUP=$backup; HARDWARE_NOT_TESTED"
} catch {
 if($writing){
  [IO.File]::Copy((Join-Path $backup 'SYSTEM'),$system,$true)
  foreach($f in $restore){if($f[2]){[IO.File]::Copy($f[1],$f[0],$true)}elseif(Test-Path -LiteralPath $f[0]){Remove-Item -LiteralPath $f[0]}}
  foreach($f in $moved){[IO.File]::Copy($f[1],$f[0],$true)}
  Write-VolumeCache -DriveLetter M
 }
 throw
}
& fsutil.exe dirty query M:
