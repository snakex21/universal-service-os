$ErrorActionPreference='Stop'
$disk=Get-Disk -Number (Get-Partition -DriveLetter M).DiskNumber
if($disk.Size -ne 120034123776 -or $disk.FriendlyName -notlike '*INTEL*' -or $disk.IsBoot -or $disk.IsSystem){throw 'Unexpected Vista disk'}
Get-Content -LiteralPath 'M:\USOS\Vista\firstboot-usb.log' -Tail 65
foreach($name in @('usbxhci.sys','usbhub3.sys','ucx01000.sys','usbd8.sys')){
 $p=Join-Path 'M:\Windows\System32\drivers' $name
 if(Test-Path -LiteralPath $p){
  $s=Get-AuthenticodeSignature -LiteralPath $p
  [pscustomobject]@{File=$p;SHA256=(Get-FileHash -LiteralPath $p).Hash;Status=$s.Status;Signer=$s.SignerCertificate.Subject;Issuer=$s.SignerCertificate.Issuer}|Format-List
 }
}
Get-ChildItem -LiteralPath 'M:\USOS\Vista\Drivers\LocalTestVista' -Filter '*.cat'|ForEach-Object {
 $s=Get-AuthenticodeSignature -LiteralPath $_.FullName
 [pscustomobject]@{Catalog=$_.FullName;Status=$s.Status;Signer=$s.SignerCertificate.Subject;Issuer=$s.SignerCertificate.Issuer}|Format-List
}
