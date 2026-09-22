# Reversible physical XP diagnostic. Only boot.ini on the identified Intel.
param([ValidateSet('SingleCpu','Memory2GB','RemoveMemoryLimit')][string]$Trial='SingleCpu')
$ErrorActionPreference='Stop'
$part=Get-Partition -DriveLetter M
$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -notlike '*INTEL*' -or $disk.Size -ne 120034123776 -or $disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'MBR' -or $part.Offset -ne 1048576 -or $disk.Signature -ne 2225656991){throw 'Unexpected XP target'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$path='M:\boot.ini'
$original=[IO.File]::ReadAllBytes($path)
$text=[Text.Encoding]::ASCII.GetString($original)
$arc='multi(0)disk(0)rdisk(0)partition(1)\WINDOWS'
$lines=@($text -split '\r?\n'|Where-Object {$_ -match '^multi\('})
$base=$arc+'="Microsoft Windows XP Professional" /noexecute=optin /fastdetect'
$expected=switch($Trial){'Memory2GB'{$base+' /NUMPROC=1 /BOOTLOG /SOS'} 'RemoveMemoryLimit'{$base+' /MAXMEM=2048 /BOOTLOG /SOS'} default{$base}}
$newLine=switch($Trial){'Memory2GB'{$base+' /MAXMEM=2048 /BOOTLOG /SOS'} 'RemoveMemoryLimit'{$base+' /BOOTLOG /SOS'} default{$base+' /NUMPROC=1 /BOOTLOG /SOS'}}
if($lines.Count -ne 1 -or $lines[0] -ne $expected){throw 'Unexpected boot entry; refusing blind edit'}
if($text -notmatch ('(?m)^default='+[regex]::Escape($arc)+'\r?$')){throw 'Unexpected default boot path'}
$changed=$text.Replace($lines[0],$newLine)
if($changed.Replace($newLine,$expected) -cne $text){throw 'Unexpected change'}
$bytes=[Text.Encoding]::ASCII.GetBytes($changed)
$out=Join-Path $project ('artifacts\xp-pae\boot-'+$Trial+'-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($out)|Out-Null
[IO.File]::WriteAllBytes((Join-Path $out 'boot.ini.original'),$original)
[IO.File]::WriteAllBytes((Join-Path $out 'boot.ini.trial'),$bytes)
$attrs=[IO.File]::GetAttributes($path)
$disk|Select-Object Number,FriendlyName,Signature,Size|ConvertTo-Json|Set-Content (Join-Path $out 'disk.json')
function Write-ExistingBootFile([byte[]]$content){
 # OPEN_EXISTING also works for hidden/system boot.ini; CREATE_ALWAYS does not.
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$stream.Write($content,0,$content.Length);$stream.SetLength($content.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
try{
 [IO.File]::SetAttributes($path,($attrs -band (-bnot [IO.FileAttributes]::ReadOnly)))
 Write-ExistingBootFile $bytes
 if([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [Convert]::ToBase64String($bytes)){throw 'Readback mismatch'}
}catch{
 Write-ExistingBootFile $original
 throw
}finally{[IO.File]::SetAttributes($path,$attrs)}
Write-Output "BACKUP=$out\boot.ini.original"
if([IO.File]::GetAttributes($path) -ne $attrs){throw 'Attribute restore mismatch'}
Write-Output "BOOT_ENTRY=$newLine"
Write-Output 'PASS: disk identity checked; backup saved; only expected boot switches changed; bytes and attributes verified'
