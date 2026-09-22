$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$disk=Get-Disk -Number (Get-Partition -DriveLetter M).DiskNumber
if($disk.FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk.Size -ne 120034123776 -or ([guid]$disk.Guid) -ne [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148' -or $disk.IsBoot -or $disk.IsSystem){throw 'Wrong target'}
$out=Join-Path $project ('artifacts\vista\kmdf-failure-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($out)|Out-Null
foreach($relative in @('USOS','Windows\Panther','Windows\System32\config\SYSTEM','Windows\System32\config\SOFTWARE','Windows\System32\config\COMPONENTS','Windows\winsxs\pending.xml','Windows\Logs\CBS')){
 $from=Join-Path 'M:\' $relative
 if(Test-Path -LiteralPath $from){$to=Join-Path $out $relative;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))|Out-Null;Copy-Item -LiteralPath $from -Destination $to -Recurse}
}
Copy-Item -LiteralPath 'J:\EFI\USOS\Logs\WinSetup-2026-9-21-16-35-31-1760' -Destination (Join-Path $out 'usb-logs') -Recurse
Get-Partition -DiskNumber $disk.Number|Select-Object PartitionNumber,Guid,GptType,Offset,Size|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $out 'layout.json')
[IO.File]::WriteAllText((Join-Path $project 'zig-out\vista\kmdf-failure-path.txt'),$out)
Write-Output "EVIDENCE_SAVED=$out"
& chkdsk.exe M: /f /x | Tee-Object -FilePath (Join-Path $out 'chkdsk.txt')
Write-Output "CHKDSK_EXIT=$LASTEXITCODE"
& fsutil.exe dirty query M:
