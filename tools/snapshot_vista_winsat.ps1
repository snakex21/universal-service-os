$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$disk=Get-Disk -Number (Get-Partition -DriveLetter M).DiskNumber
if($disk.FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk.Size -ne 120034123776 -or ([guid]$disk.Guid) -ne [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148' -or $disk.IsBoot -or $disk.IsSystem){throw 'Wrong target'}
$out=Join-Path $project ('artifacts\vista\winsat-stall-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($out)|Out-Null
foreach($relative in @('USOS','Windows\Panther','Windows\Performance\WinSAT','Windows\System32\config','Windows\Logs\CBS')){
 $from=Join-Path 'M:\' $relative
 if(Test-Path -LiteralPath $from){$to=Join-Path $out $relative;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))|Out-Null;Copy-Item -LiteralPath $from -Destination $to -Recurse}
}
$layout=Get-Partition -DiskNumber $disk.Number|Select-Object PartitionNumber,Guid,GptType,Offset,Size|ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $out 'layout.json'),$layout)
[IO.File]::WriteAllText((Join-Path $project 'zig-out\vista\winsat-snapshot-path.txt'),$out)
Write-Output "EVIDENCE_SAVED=$out"
& chkdsk.exe M: /f /x | Tee-Object -FilePath (Join-Path $out 'chkdsk.txt')
$result=$LASTEXITCODE
Write-Output "CHKDSK_EXIT=$result"
& fsutil.exe dirty query M:
if($result -gt 1){throw 'Filesystem repair did not succeed'}
