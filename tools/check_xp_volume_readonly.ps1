$ErrorActionPreference='Stop'
$disk=Get-Disk -Number (Get-Partition -DriveLetter M).DiskNumber
if($disk.FriendlyName -notlike '*INTEL*' -or $disk.Size -ne 120034123776 -or $disk.IsBoot -or $disk.IsSystem){throw 'Wrong disk'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out=Get-ChildItem -LiteralPath (Join-Path $project 'artifacts\xp-pae') -Directory -Filter 'lsass-*'|Sort-Object Name|Select-Object -Last 1
foreach($name in @('SAM','SAM.LOG','SECURITY','SECURITY.LOG','system.sav','software.sav')){
 $src=Join-Path 'M:\WINDOWS\system32\config' $name
 if(Test-Path -LiteralPath $src){[IO.File]::Copy($src,(Join-Path $out.FullName ('WINDOWS\System32\config\'+$name)),$false)}
}
& fsutil.exe dirty query M:
& chkdsk.exe M: 2>&1|Tee-Object -FilePath (Join-Path $out.FullName 'chkdsk-readonly.txt')
Write-Output "CHKDSK_READONLY_EXIT=$LASTEXITCODE"
