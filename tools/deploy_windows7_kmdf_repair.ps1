# Deploy the updated WinPE payload and arm one repair for the known Intel disk.
# File copies only; no partition, boot sector, BCD, or host registry writes.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$usb=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'31c644bf-74dd-4807-9cb2-46745adeadd4'})
$intel=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($usb.Count -ne 1 -or $usb[0].FriendlyName -ne 'Kingston DataTraveler 3.0' -or $usb[0].Size -ne 61991813632 -or $usb[0].IsBoot -or $usb[0].IsSystem){throw 'USB identity mismatch'}
if($intel.Count -ne 1 -or $intel[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $intel[0].Size -ne 120034123776 -or $intel[0].IsBoot -or $intel[0].IsSystem){throw 'Intel identity mismatch'}
$parts=@(Get-Partition -DiskNumber $usb[0].Number)
$esp=@($parts | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'0257e175-1685-4311-91aa-5a83d8eb41e5'})
$windows=@(Get-Partition -DiskNumber $intel[0].Number | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
if($esp.Count -ne 1 -or -not $esp[0].DriveLetter -or $esp[0].Offset -ne 1048576 -or $esp[0].Size -ne 1073741824){throw 'ESP identity mismatch'}
if($windows.Count -ne 1 -or $windows[0].Offset -ne 240123904 -or $windows[0].Size -ne 119793516544){throw 'Intel Windows identity mismatch'}
$root="$($esp[0].DriveLetter):\"
$target=Join-Path $root 'EFI\USOS\windows-native\win7-support.cpio'
$source=Join-Path $project 'zig-out\windows-native\win7-support.cpio'
$request=Join-Path $root 'EFI\USOS\win7-kmdf-repair.request'
$stage=$target+'.kmdf-stage'
foreach($path in @($request,$request+'.running',$request+'.done',$request+'.stage',$stage)){
 if(Test-Path -LiteralPath $path){throw "Existing repair state/staging file: $path"}
}
if((Get-Item -LiteralPath $source).Length -ge 67108864){throw 'Win7 payload exceeds Core limit'}
$boot=Join-Path $root 'EFI\BOOT\BOOTX64.EFI'
$bootHash=(Get-FileHash -LiteralPath $boot).Hash
if($bootHash -ne '3008d265b13343fc694bd6fff3985b1d67884a79c684472be39a767f8f2a5b5d'){throw 'Unexpected USB boot path; refusing blind update'}
$backup=Join-Path $project ('zig-out\win7-universal-work\kingston-before-kmdf-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup | Out-Null
[IO.File]::Copy($target,(Join-Path $backup 'win7-support.cpio'),$false)
$oldHash=(Get-FileHash -LiteralPath $target).Hash
if((Get-FileHash -LiteralPath (Join-Path $backup 'win7-support.cpio')).Hash -ne $oldHash){throw 'Backup checksum mismatch'}
$stream=[IO.MemoryStream]::new()
$writer=[IO.BinaryWriter]::new($stream)
$writer.Write([Text.Encoding]::ASCII.GetBytes('USOSKMD1'))
$writer.Write(([guid]$intel[0].Guid).ToByteArray())
$writer.Write(([guid]$windows[0].Guid).ToByteArray())
$writer.Write([uint64]$windows[0].Offset)
$writer.Write([uint64]$windows[0].Size)
$writer.Write([uint64]$intel[0].Size)
$writer.Flush();$config=$stream.ToArray();$writer.Dispose();$stream.Dispose()
if($config.Length -ne 64){throw 'Invalid request size'}
$published=$false
try {
 [IO.File]::Copy($source,$stage,$false)
 $hash=(Get-FileHash -LiteralPath $source).Hash
 if((Get-FileHash -LiteralPath $stage).Hash -ne $hash){throw 'Staged payload checksum mismatch'}
 $published=$true
 [IO.File]::Copy($stage,$target,$true)
 if((Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'USB payload checksum mismatch'}
 [IO.File]::WriteAllBytes($request+'.stage',$config)
 if([Convert]::ToBase64String([IO.File]::ReadAllBytes($request+'.stage')) -ne [Convert]::ToBase64String($config)){throw 'Request readback mismatch'}
 [IO.File]::Move($request+'.stage',$request)
 Remove-Item -LiteralPath $stage
} catch {
 if($published){[IO.File]::Copy((Join-Path $backup 'win7-support.cpio'),$target,$true)}
 if(Test-Path -LiteralPath $request){Remove-Item -LiteralPath $request}
 throw
}
$after=@(Get-Partition -DiskNumber $usb[0].Number)
if(($parts | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress) -ne ($after | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress)){throw 'Partition layout changed'}
if((Get-FileHash -LiteralPath $boot).Hash -ne $bootHash){throw 'USB bootloader changed unexpectedly'}
Write-Output "VERIFIED win7-support.cpio SHA256=$hash"
Write-Output "ARMED $request (64 bytes; Intel GPT identity only)"
Write-Output "BACKUP $backup"
Write-Output 'PASS: USB file update verified; Intel not written; package awaits execution in WinPE.'
