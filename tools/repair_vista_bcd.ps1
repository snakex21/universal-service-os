$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$disk=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem){throw 'Wrong Intel disk'}
$parts=@(Get-Partition -DiskNumber $disk[0].Number)
$esp=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
$os=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
if($esp.Count -ne 1 -or $esp[0].Size -ne 100MB -or $os.Count -ne 1 -or -not $os[0].DriveLetter){throw 'Wrong Intel partitions'}
$base="$($os[0].DriveLetter):\"
$out=Join-Path $project ('zig-out\vista\bcdboot-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($out)|Out-Null
$assigned=$false;$part=$esp[0]
try {
 if(-not $part.DriveLetter){$part|Add-PartitionAccessPath -AssignDriveLetter;$assigned=$true}
 $part=Get-Partition -DiskNumber $disk[0].Number -PartitionNumber $part.PartitionNumber
 $espRoot="$($part.DriveLetter):\"
 Copy-Item -LiteralPath (Join-Path $espRoot 'EFI') -Destination $out -Recurse
 $proc=Start-Process -FilePath 'bcdboot.exe' -ArgumentList @((Join-Path $base 'Windows'),'/s',"$($part.DriveLetter):",'/f','UEFI','/c','/l','pl-PL','/v') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $out 'bcdboot.log') -RedirectStandardError (Join-Path $out 'bcdboot-error.log')
 $code=$proc.ExitCode
 Get-Content -LiteralPath (Join-Path $out 'bcdboot-error.log') -Tail 12
 Get-Content -LiteralPath (Join-Path $out 'bcdboot.log') -Tail 22
 Write-Output "BCDBOOT_EXIT=$code; BACKUP=$out"
 if($code -ne 0){
  Copy-Item -Path (Join-Path $out 'EFI\*') -Destination (Join-Path $espRoot 'EFI') -Recurse -Force
  throw 'BCDBOOT failed; original EFI files restored'
 }
 $bcd=Join-Path $espRoot 'EFI\Microsoft\Boot\BCD'
 foreach($pair in @(@('bootlog','Yes'),@('sos','No'),@('nocrashautoreboot','Yes'))){
  & bcdedit.exe /store $bcd /set '{default}' $pair[0] $pair[1] | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Diagnostic setting failed'}
 }
 & bcdedit.exe /store $bcd /timeout 0 | Out-Null
 if($LASTEXITCODE -ne 0){throw 'BCD timeout failed'}
 & bcdedit.exe /store $bcd /enum all /v *> (Join-Path $out 'bcd-after.txt')
 if($LASTEXITCODE -ne 0){throw 'BCD verification failed'}
 Copy-Item -LiteralPath $bcd -Destination (Join-Path $out 'BCD-after')
 Write-VolumeCache -DriveLetter $part.DriveLetter
 Write-Output "VISTA_BCD_REBUILT; READBACK=$out\bcd-after.txt"
} finally {if($assigned){$part | Remove-PartitionAccessPath -AccessPath $espRoot}}
