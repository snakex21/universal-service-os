$ErrorActionPreference='Stop'
Get-Disk | Select-Object Number,FriendlyName,SerialNumber,Guid,Size,BusType,IsBoot,IsSystem | Format-Table -AutoSize
$intel=@(Get-Disk | Where-Object {$_.FriendlyName -like '*INTEL*' -and $_.Size -eq 120034123776 -and !$_.IsBoot -and !$_.IsSystem})
foreach($disk in $intel){
 Get-Partition -DiskNumber $disk.Number | Select-Object PartitionNumber,DriveLetter,Guid,GptType,Offset,Size,AccessPaths | Format-List
 foreach($partition in @(Get-Partition -DiskNumber $disk.Number)){
  if(!$partition.DriveLetter){continue}
  $root=$partition.DriveLetter+':\'
  foreach($relative in @('USOS\Vista','USOS','Windows\Panther','Windows\inf')){
   $path=Join-Path $root $relative
   if(Test-Path -LiteralPath $path){Get-ChildItem -LiteralPath $path -File | Where-Object {$_.Extension -eq '.log' -or $_.Name -like '*.flag'} | Select-Object FullName,Length,LastWriteTime | Format-Table -AutoSize}
  }
 }
}
