param(
    [Parameter(Mandatory=$true)][string]$InstrumentedRaw,
    [switch]$Apply
)

$ErrorActionPreference='Stop'
$ExpectedModel='INTEL SS DSC2BW120A4'
$ExpectedSize=[uint64]120034123776
$ExpectedDiskId=[uint32]::Parse('AFF136E8',[Globalization.NumberStyles]::HexNumber)
$ExpectedOldMbr440='02688AF859520E7119C28C65881A7117BB217B7563A0B2B1143B90BE66BEF33A'
$ExpectedOldGap='BEA4E8F581BCB59DEC3006AAB68D06B9A21CF4161BD643C6B2EDE544D2CD9E6A'
$ExpectedOldVbrCode='C0F41AA02E69CE6B409BD9F473C186D30A2221A488E3930F81AFAE246F9AF75F'
$ExpectedOldStage2='2EB854A160BF7A65BBD24A8BEB76E841D14566F98467D5C18E847F06A5443070'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class XpDiagRaw {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sec, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool ReadFile(SafeFileHandle h, byte[] b, uint n, out uint r, IntPtr o);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool WriteFile(SafeFileHandle h, byte[] b, uint n, out uint w, IntPtr o);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool SetFilePointerEx(SafeFileHandle h, long d, out long p, uint m);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool FlushFileBuffers(SafeFileHandle h);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr ib, uint il, IntPtr ob, uint ol, out uint br, IntPtr ov);
}
'@

function ShaBytes([byte[]]$b){
    $s=[Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','') } finally { $s.Dispose() }
}
function Slice([byte[]]$b,[int]$o,[int]$n){ $x=New-Object byte[] $n; [Array]::Copy($b,$o,$x,0,$n); return $x }
function OpenRaw([string]$path,[bool]$write){
    $access=if($write){[Convert]::ToUInt32('C0000000',16)}else{[Convert]::ToUInt32('80000000',16)}
    $h=[XpDiagRaw]::CreateFile($path,$access,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0,[IntPtr]::Zero)
    if($h.IsInvalid){throw "CreateFile $path failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
    return $h
}
function ReadAt($h,[long]$off,[int]$n){
    if(($off % 512)-ne0 -or ($n % 512)-ne0){throw "unaligned raw read off=$off n=$n"}
    $p=0L; if(-not[XpDiagRaw]::SetFilePointerEx($h,$off,[ref]$p,0)){throw "seek read failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
    $b=New-Object byte[] $n; $r=[uint32]0
    if(-not[XpDiagRaw]::ReadFile($h,$b,[uint32]$n,[ref]$r,[IntPtr]::Zero) -or $r-ne$n){throw "raw read failed off=$off got=$r win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
    return $b
}
function WriteAt($h,[long]$off,[byte[]]$b){
    if(($off % 512)-ne0 -or ($b.Length % 512)-ne0){throw "unaligned raw write off=$off n=$($b.Length)"}
    $p=0L; if(-not[XpDiagRaw]::SetFilePointerEx($h,$off,[ref]$p,0)){throw "seek write failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
    $w=[uint32]0
    if(-not[XpDiagRaw]::WriteFile($h,$b,[uint32]$b.Length,[ref]$w,[IntPtr]::Zero) -or $w-ne$b.Length){throw "raw write failed off=$off got=$w win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
}
function U32([byte[]]$b,[int]$o){ return [BitConverter]::ToUInt32($b,$o) }
function AssertMetadata([byte[]]$m){
    if((U32 $m 440)-ne$ExpectedDiskId){throw ('Disk ID mismatch got=0x{0:X8}' -f (U32 $m 440))}
    if($m[510]-ne0x55 -or $m[511]-ne0xAA){throw 'MBR signature mismatch'}
    if($m[446]-ne0x80 -or $m[450]-ne0x0C -or (U32 $m 454)-ne2048 -or (U32 $m 458)-ne4194304){throw 'XPSETUP partition entry mismatch'}
    for($i=462;$i-lt510;$i++){if($m[$i]-ne0){throw "unexpected nonzero MBR partition-table byte $i"}}
}

$raw=[IO.Path]::GetFullPath($InstrumentedRaw)
if(-not(Test-Path -LiteralPath $raw -PathType Leaf)){throw "instrumented raw missing: $raw"}
if((Get-Item -LiteralPath $raw).Length-ne$ExpectedSize){throw 'instrumented raw exact-size gate failed'}
$matches=@(Get-Disk | Where-Object { $_.FriendlyName -eq $ExpectedModel -and [uint64]$_.Size -eq $ExpectedSize })
if($matches.Count-ne1){throw "physical Intel identity ambiguous count=$($matches.Count)"}
$disk=$matches[0]
if($disk.IsSystem -or $disk.IsBoot){throw 'refusing system/boot disk'}
$pd="\\.\PhysicalDrive$($disk.Number)"
Write-Host "TARGET=$pd model=$($disk.FriendlyName) size=$($disk.Size) health=$($disk.HealthStatus)"

# Read new diagnostic payload only from the local, already QEMU-tested image.
$src=[IO.File]::Open($raw,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $newMbr=New-Object byte[] 512; [void]$src.Read($newMbr,0,512)
    $src.Position=512; $newGap=New-Object byte[] 4096; [void]$src.Read($newGap,0,4096)
    $src.Position=2048L*512; $newVbr=New-Object byte[] 512; [void]$src.Read($newVbr,0,512)
    $src.Position=2060L*512; $newStage2=New-Object byte[] 512; [void]$src.Read($newStage2,0,512)
} finally {$src.Dispose()}

# First physical guard is read-only.
$h=OpenRaw $pd $false
try {
    $oldMbr=ReadAt $h 0 512; AssertMetadata $oldMbr
    $oldGap=ReadAt $h 512 4096
    $oldVbr=ReadAt $h (2048L*512) 512
    $oldStage2=ReadAt $h (2060L*512) 512
} finally {$h.Dispose()}
if((ShaBytes (Slice $oldMbr 0 440))-ne$ExpectedOldMbr440){throw 'old diagnostic MBR hash mismatch'}
if((ShaBytes $oldGap)-ne$ExpectedOldGap){throw 'old diagnostic LBA1..8 hash mismatch'}
if((ShaBytes (Slice $oldVbr 90 420))-ne$ExpectedOldVbrCode){throw 'old diagnostic VBR code hash mismatch'}
if((ShaBytes $oldStage2)-ne$ExpectedOldStage2){throw 'old diagnostic stage2 hash mismatch'}
if($newVbr[510]-ne0x55 -or $newVbr[511]-ne0xAA){throw 'new VBR signature invalid'}
# Local QEMU metadata/BPB are fixture-specific. Preserve the physical MBR tail,
# physical FAT32 BPB/EBPB, and physical 55AA exactly; take only diagnostic code.
[Array]::Copy($oldMbr,440,$newMbr,440,72)
[Array]::Copy($oldVbr,0,$newVbr,0,90)
$newVbr[510]=$oldVbr[510]; $newVbr[511]=$oldVbr[511]
AssertMetadata $newMbr
if(-not [Linq.Enumerable]::SequenceEqual([byte[]](Slice $oldVbr 0 90),[byte[]](Slice $newVbr 0 90))){throw 'physical BPB preservation failed in prepared write buffer'}
Write-Host 'PHYSICAL_OLD_DIAGNOSTIC_GUARD=PASS'
Write-Host "NEW_MBR440_SHA=$(ShaBytes (Slice $newMbr 0 440))"
Write-Host "NEW_GAP_SHA=$(ShaBytes $newGap)"
Write-Host "NEW_VBR_CODE_SHA=$(ShaBytes (Slice $newVbr 90 420))"
Write-Host "NEW_STAGE2_SHA=$(ShaBytes $newStage2)"
if(-not$Apply){Write-Host 'DRY_RUN=PASS no writes';exit 0}

# Lock/dismount J: only to stop filesystem cache while touching boot sectors.
$vol=[XpDiagRaw]::CreateFile('\\.\J:',[Convert]::ToUInt32('C0000000',16),[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0,[IntPtr]::Zero)
if($vol.IsInvalid){throw "open J: failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
try {
    $br=[uint32]0
    if(-not[XpDiagRaw]::DeviceIoControl($vol,[uint32]0x00090018,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$br,[IntPtr]::Zero)){throw "FSCTL_LOCK_VOLUME failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
    if(-not[XpDiagRaw]::DeviceIoControl($vol,[uint32]0x00090020,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$br,[IntPtr]::Zero)){throw "FSCTL_DISMOUNT_VOLUME failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
    Write-Host 'VOLUME_LOCK_DISMOUNT=PASS'

    $rw=OpenRaw $pd $true
    try {
        $check=ReadAt $rw 0 512; AssertMetadata $check
        if((ShaBytes (Slice $check 0 440))-ne$ExpectedOldMbr440){throw 'pre-write MBR changed since read-only guard'}
        # Defensive order: auxiliary prelude/runtime, stage2 hook, VBR hook, diagnostic MBR last.
        WriteAt $rw 512 $newGap; Write-Host 'WRITE LBA1..8=PASS'
        WriteAt $rw (2060L*512) $newStage2; Write-Host 'WRITE STAGE2=PASS'
        WriteAt $rw (2048L*512) $newVbr; Write-Host 'WRITE VBR=PASS'
        WriteAt $rw 0 $newMbr; Write-Host 'WRITE MBR=PASS'
        if(-not[XpDiagRaw]::FlushFileBuffers($rw)){throw "FlushFileBuffers failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}

        $rbMbr=ReadAt $rw 0 512; $rbGap=ReadAt $rw 512 4096; $rbVbr=ReadAt $rw (2048L*512) 512; $rbStage2=ReadAt $rw (2060L*512) 512
        AssertMetadata $rbMbr
        if((ShaBytes (Slice $rbMbr 0 440)) -ne (ShaBytes (Slice $newMbr 0 440))){throw 'MBR readback mismatch'}
        if((ShaBytes $rbGap) -ne (ShaBytes $newGap)){throw 'gap readback mismatch'}
        if((ShaBytes (Slice $rbVbr 90 420)) -ne (ShaBytes (Slice $newVbr 90 420))){throw 'VBR readback mismatch'}
        if((ShaBytes $rbStage2) -ne (ShaBytes $newStage2)){throw 'stage2 readback mismatch'}
        if(-not [Linq.Enumerable]::SequenceEqual([byte[]](Slice $rbVbr 0 90),[byte[]](Slice $oldVbr 0 90))){throw 'BPB changed after write'}
        Write-Host 'PHYSICAL_NEW_DIAGNOSTIC_READBACK=PASS'
    } finally {$rw.Dispose()}
} finally {$vol.Dispose()}
