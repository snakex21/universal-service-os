# Destructive only with -ReplaceIntel. This tool is intentionally scoped to the
# user's identified disposable Intel SSD, never an arbitrary drive letter.
param([switch]$ReplaceIntel)
$ErrorActionPreference='Stop'
if($ReplaceIntel){throw 'Raw Vista deployment disabled after physical boot exposed D:/C: image path mismatch. Preserve/fix image drive mapping before another deployment; use the existing Intel repair, not a reinstall.'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out=Join-Path $project 'zig-out\vista'
$sourceImage=Join-Path $out 'image'
$helper=Join-Path $out 'firstboot\usos-vista-firstboot.exe'
$drivers=Join-Path $project 'media\Systems\Windows\Windows Vista\Drivers\x64\AMD_USB31_PT'
$wimlib=Join-Path $project 'tools\vendor\wimlib\1.14.5\wimlib-imagex.exe'
function Intel {
 $d=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
 if($d.Count -ne 1 -or $d[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $d[0].Size -ne 120034123776 -or $d[0].IsBoot -or $d[0].IsSystem -or $d[0].PartitionStyle -ne 'GPT'){throw 'Intel disk identity mismatch'}
 return $d[0]
}
function TargetParts($disk) {
 $p=@(Get-Partition -DiskNumber $disk.Number)
 $esp=@($p | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
 $os=@($p | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
 if($p.Count -ne 3 -or $esp.Count -ne 1 -or $os.Count -ne 1){throw 'Intel partition identity mismatch'}
 if($esp[0].Offset -ne 1048576 -or $esp[0].Size -ne 104857600 -or ([guid]$esp[0].GptType) -ne [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'){throw 'ESP geometry mismatch'}
 if($os[0].Offset -ne 240123904 -or $os[0].Size -ne 119793516544 -or -not $os[0].DriveLetter -or $os[0].IsBoot -or $os[0].IsSystem){throw 'Windows partition geometry mismatch'}
 return @{Esp=$esp[0];Os=$os[0];All=$p}
}
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
function Bcd([string[]]$Arguments){
 $text=& bcdedit.exe /store $script:bcd @Arguments
 if($LASTEXITCODE -ne 0){throw "BCD operation failed: $Arguments : $text"}
 $text | Add-Content -LiteralPath (Join-Path $run 'bcd-operations.txt')
}
$disk=Intel;$parts=TargetParts $disk
$target="$($parts.Os.DriveLetter):\"
if($target -eq "$env:SystemDrive\"){throw 'Refusing host volume'}
foreach($p in @($helper,$wimlib,(Join-Path $drivers 'Host\amdxhc31.inf'),(Join-Path $drivers 'Hub\amdhub31.inf'))){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing $p"}}
$version=(Get-Item -LiteralPath (Join-Path $sourceImage 'Windows\System32\ntoskrnl.exe')).VersionInfo
if($version.FileMajorPart -ne 6 -or $version.FileMinorPart -ne 0 -or $version.FileBuildPart -ne 6002){throw 'Expected Vista SP2 staged image'}
$usb=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'31c644bf-74dd-4807-9cb2-46745adeadd4'})
if($usb.Count -ne 1 -or $usb[0].Size -ne 61991813632 -or $usb[0].IsBoot -or $usb[0].IsSystem){throw 'Kingston identity mismatch'}
$data=@(Get-Partition -DiskNumber $usb[0].Number | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'deb596cd-0d5b-464d-9780-3d7bbec3935a'})
if($data.Count -ne 1 -or -not $data[0].DriveLetter){throw 'ISO partition missing'}
# Exact Polish Vista SP2 media supplied by the user.
$iso=Join-Path "$($data[0].DriveLetter):\" 'Systems\Windows\Windows Vista\Images\pl_windows_vista_with_sp2_x64_dvd_x15-36359.iso'
if((Get-Item -LiteralPath $iso).Length -ne 3702233088){throw 'Vista ISO size mismatch'}
$mounted=Get-DiskImage -ImagePath $iso
if(-not $mounted.Attached){$mounted=Mount-DiskImage -ImagePath $iso -Access ReadOnly -PassThru}
$isoVolume=@($mounted | Get-Volume)
if($isoVolume.Count -ne 1 -or -not $isoVolume[0].DriveLetter){throw 'ISO mount missing'}
$wim="$($isoVolume[0].DriveLetter):\sources\install.wim"
if(-not(Test-Path -LiteralPath $wim)){throw 'Source WIM missing'}
$run=Join-Path $out ('deploy-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($run)|Out-Null
$env:TEMP=Join-Path $out 'scratch';$env:TMP=$env:TEMP
$layoutBefore=$parts.All | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress
$layoutBefore | Set-Content -LiteralPath (Join-Path $run 'intel-layout.json')
$disk | Select-Object Number,FriendlyName,Guid,Size,IsBoot,IsSystem | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'intel-disk.json')
$payload=Join-Path $run 'payload'
$app=Join-Path $payload 'USOS\Vista'
[IO.Directory]::CreateDirectory((Join-Path $app 'Drivers'))|Out-Null
Copy-Item -LiteralPath $helper -Destination $app
Copy-Item -LiteralPath $drivers -Destination (Join-Path $app 'Drivers') -Recurse
$panther=Join-Path $payload 'Windows\Panther'
[IO.Directory]::CreateDirectory($panther)|Out-Null
$answer=@'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous><RunSynchronousCommand wcm:action="add">
        <Order>1</Order><Description>USOS Vista AMD chipset USB</Description>
        <Path>%SystemDrive%\USOS\Vista\usos-vista-firstboot.exe</Path>
        <WillReboot>OnRequest</WillReboot>
      </RunSynchronousCommand></RunSynchronous>
    </component>
  </settings>
</unattend>
'@
[xml]$parsed=$answer
[IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'),$answer,(New-Object Text.UTF8Encoding $false))
$script:bcd=Join-Path $run 'BCD-vista'
& bcdedit.exe /createstore $bcd | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not create isolated BCD'}
$loader='{2f440ca0-89f4-4e4f-a8df-1a4706bad600}'
Bcd @('/create','{bootmgr}','/d','Windows Boot Manager')
Bcd @('/create',$loader,'/d','Windows Vista Ultimate SP2','/application','osloader')
Bcd @('/set',$loader,'device',"partition=$($parts.Os.DriveLetter):")
Bcd @('/set',$loader,'osdevice',"partition=$($parts.Os.DriveLetter):")
Bcd @('/set',$loader,'path','\Windows\system32\winload.efi')
Bcd @('/set',$loader,'systemroot','\Windows')
Bcd @('/set',$loader,'locale','pl-PL')
Bcd @('/set',$loader,'detecthal','Yes')
Bcd @('/set',$loader,'bootlog','Yes')
Bcd @('/set',$loader,'sos','No')
Bcd @('/set',$loader,'nocrashautoreboot','Yes')
Bcd @('/set','{bootmgr}','default',$loader)
Bcd @('/set','{bootmgr}','displayorder',$loader)
Bcd @('/set','{bootmgr}','timeout','0')
Bcd @('/enum','all','/v')
Write-Output "PREPARED=$run; TARGET_DISK=$($disk.Number); TARGET=$target; NO_TARGET_WRITES_YET"
if(-not $ReplaceIntel){exit 0}
$assigned=$false;$esp=$parts.Esp
try {
 if(-not $esp.DriveLetter){$esp | Add-PartitionAccessPath -AssignDriveLetter;$assigned=$true}
 $esp=Get-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber
 $espRoot="$($esp.DriveLetter):\"
 $backup=Join-Path $run 'intel-before-vista'
 [IO.Directory]::CreateDirectory($backup)|Out-Null
 Copy-Item -LiteralPath (Join-Path $espRoot 'EFI') -Destination $backup -Recurse
 foreach($name in @('SYSTEM','SOFTWARE')){
  [IO.File]::Copy((Join-Path $target "Windows\System32\config\$name"),(Join-Path $backup "Win7-$name"),$false)
 }
 $originalBcd=Join-Path $espRoot 'EFI\Microsoft\Boot\BCD'
 if((Hash $originalBcd) -ne (Hash (Join-Path $backup 'EFI\Microsoft\Boot\BCD'))){throw 'ESP backup verification failed'}
 Bcd @('/set','{bootmgr}','device',"partition=$($esp.DriveLetter):")
 Bcd @('/set','{bootmgr}','path','\EFI\Microsoft\Boot\bootmgfw.efi')
 $fresh=Intel;$freshParts=TargetParts $fresh
 if($fresh.Number -ne $disk.Number -or $freshParts.Os.DriveLetter -ne $parts.Os.DriveLetter){throw 'Target changed before format'}
 Write-Output "REPLACING_AUTHORIZED_INTEL_WINDOWS_PARTITION=$target"
 $freshParts.Os | Format-Volume -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel 'USOS_VISTA' -Force -Confirm:$false | Out-Null
 & $wimlib apply $wim 4 $target --check *> (Join-Path $run 'apply-vista.log')
 if($LASTEXITCODE -ne 0){throw "Vista apply failed: $LASTEXITCODE"}
 Copy-Item -Path (Join-Path $payload '*') -Destination $target -Recurse -Force
 $targetKernel=Join-Path $target 'Windows\System32\ntoskrnl.exe'
 if((Hash $targetKernel) -ne (Hash (Join-Path $sourceImage 'Windows\System32\ntoskrnl.exe'))){throw 'Vista kernel verification failed'}
 if((Hash (Join-Path $target 'USOS\Vista\usos-vista-firstboot.exe')) -ne (Hash $helper)){throw 'Helper verification failed'}
 $boot=Join-Path $espRoot 'EFI\Microsoft\Boot'
 $fallback=Join-Path $espRoot 'EFI\Boot'
 [IO.Directory]::CreateDirectory($boot)|Out-Null
 [IO.Directory]::CreateDirectory($fallback)|Out-Null
 Copy-Item -Path (Join-Path $target 'Windows\Boot\EFI\*') -Destination $boot -Recurse -Force
 $fonts=Join-Path $target 'Windows\Boot\Fonts'
 if(Test-Path -LiteralPath $fonts){Copy-Item -LiteralPath $fonts -Destination $boot -Recurse -Force}
 [IO.File]::Copy((Join-Path $target 'Windows\Boot\EFI\bootmgfw.efi'),(Join-Path $fallback 'bootx64.efi'),$true)
 [IO.File]::Copy($bcd,(Join-Path $boot 'BCD'),$true)
 foreach($file in @((Join-Path $boot 'bootmgfw.efi'),(Join-Path $fallback 'bootx64.efi'))){if((Hash $file) -ne (Hash (Join-Path $target 'Windows\Boot\EFI\bootmgfw.efi'))){throw 'Vista EFI readback mismatch'}}
 if((Hash (Join-Path $boot 'BCD')) -ne (Hash $bcd)){throw 'BCD readback mismatch'}
 $after=TargetParts (Intel)
 if($layoutBefore -ne ($after.All | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress)){throw 'Partition layout changed'}
 & bcdedit.exe /store (Join-Path $boot 'BCD') /enum all /v | Set-Content -LiteralPath (Join-Path $run 'bcd-final.txt')
 if($LASTEXITCODE -ne 0){throw 'Final BCD read failed'}
 @('SOURCE=Polish Vista Ultimate SP2 x64, original ISO WIM index 4','BOOT=original Vista EFI; CSM enabled required for first hardware attempt','USB=candidate AMD 43D0, installed by specialize firstboot helper; CPU 149C unsupported','HARDWARE_BOOT=NOT_RUN',"RUN=$run") | Set-Content -LiteralPath (Join-Path $target 'USOS\Vista\deployment.txt')
 Write-Output "VISTA_DEPLOYED_AND_READBACK_VERIFIED; RUN=$run; FIRST_HARDWARE_BOOT_PENDING"
} finally {if($assigned){$esp | Remove-PartitionAccessPath -AccessPath $espRoot}}
