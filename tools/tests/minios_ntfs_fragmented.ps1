#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# Creates ONE fresh, owned VHD. Windows copies and relocates a small ISO.
   Every volume operation is guarded by the exact image identity and size.
   Native defragmentation API: learn.microsoft.com/windows/win32/fileio/defragmenting-files
   No physical disks, persistent letters, repair flags or image cleanup. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Iso,
    [Parameter(Mandatory)][string]$QemuImg,
    [Parameter(Mandatory)][string]$Out,
    [string]$BlankVhd,
    [string]$VerifyFixture,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$VerifyReceiptSha256
)
$ErrorActionPreference='Stop'
$workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if (-not [IO.Path]::IsPathFullyQualified($Workspace) -or $workspaceFull.StartsWith('\\') -or $workspaceFull.Length -le 3) { throw 'An explicit local owned workspace is required' }
function Owned([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($workspaceFull+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture must be inside the owned workspace' }
    $walk=$full
    while ($walk) {
        if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse paths are forbidden' }
        $walk=[IO.Path]::GetDirectoryName($walk)
    }
    return $full
}
$outFull=Owned $Out; $isoFull=Owned $Iso
if (Test-Path -LiteralPath $outFull) { throw 'Output must be a fresh directory' }
if ((Get-Item -LiteralPath $isoFull).Length -ne 2MB) { throw 'Only the bounded own 2 MiB ISO fixture is accepted' }
[void][IO.Directory]::CreateDirectory($outFull)
$vhd=Owned (Join-Path $outFull 'windows-fragmented.vhd')
$head=(& git rev-parse HEAD).Trim()
$dirty=@(& git status --porcelain=v1 -uall).Count
Write-Output "HEAD $head"
Write-Output "WORKTREE_DIRTY $dirty"
$record=@{ schema='usos-ntfs-windows-fragmented-v1'; head=$head; dirty=$dirty; image_bytes=512MB; source_iso_sha256=(Get-FileHash -LiteralPath $isoFull -Algorithm SHA256).Hash.ToLowerInvariant(); copy_api='Windows CopyFileW'; fragment_api='Windows FSCTL_MOVE_FILE'; physical_disks_used=$false; retained=$true }
if ($VerifyFixture) {
    if (-not $VerifyReceiptSha256 -or $BlankVhd) { throw 'Readonly verification requires exactly one pinned closed fixture' }
    $previousPath=Owned (Join-Path $VerifyFixture 'receipt.json')
    if ((Get-FileHash -LiteralPath $previousPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $VerifyReceiptSha256) { throw 'Closed fixture receipt pin differs' }
    $previous=Get-Content -LiteralPath $previousPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if (-not $previous.passed -or -not $previous.dismounted -or $previous.chkdsk_exit -ne 0 -or $previous.image_bytes -ne 512MB -or $previous.source_iso_sha256 -cne $record.source_iso_sha256 -or $previous.runs_after -le 128) { throw 'Closed fixture receipt is incomplete' }
    $vhd=Owned (Join-Path $VerifyFixture 'windows-fragmented.vhd')
    if ((Get-Item -LiteralPath $vhd).Length -ne (512MB+512) -or -not (Get-Item -LiteralPath $vhd).IsReadOnly -or (Get-FileHash -LiteralPath $vhd -Algorithm SHA256).Hash.ToLowerInvariant() -cne $previous.vhd_sha256) { throw 'Closed readonly VHD identity differs' }
    foreach ($name in @('partition_start','partition_bytes','runs_before','runs_after','file_record')) { $record[$name]=$previous[$name] }
    $record.fixture_receipt_sha256=$VerifyReceiptSha256
    $record.verify_only=$true
} else {
if ($BlankVhd) { $blank=Owned $BlankVhd }
else {
    $blank=Owned (Join-Path $outFull 'blank.vhd')
    & $QemuImg create -f vpc -o subformat=fixed,force_size=on $blank 512M
    if ($LASTEXITCODE -ne 0) { throw 'Fresh blank VHD creation failed' }
}
if ((Get-Item -LiteralPath $blank).Length -ne (512MB+512)) { throw 'Blank fixed VHD size differs' }
Add-Type -TypeDefinition 'public static class MiniOsBlankCheck { public static bool IsZero(byte[] bytes,int count) { for(int i=0;i<count;i++)if(bytes[i]!=0)return false;return true; } }'
# QEMU marks even a fixed VHD sparse. Stream its empty bytes to an ordinary
# fresh file, without changing any attribute or byte of the blank input.
$from=[IO.File]::OpenRead($blank)
$to=[IO.File]::Open($vhd,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    $buffer=[byte[]]::new(1MB); [long]$left=512MB
    while ($left -gt 0) {
        $n=[int][Math]::Min($buffer.Length,$left)
        $from.ReadExactly($buffer,0,$n)
        if (-not [MiniOsBlankCheck]::IsZero($buffer,$n)) { throw 'Blank input contains existing disk data' }
        $to.Write($buffer,0,$n);$left-=$n
    }
    $footer=[byte[]]::new(512);$from.ReadExactly($footer,0,512)
    if ([Text.Encoding]::ASCII.GetString($footer,0,8) -cne 'conectix' -or [BitConverter]::ToUInt32($footer,60) -ne 0x02000000) { throw 'Unsupported fixed VHD footer' }
    $to.Write($footer,0,512);$to.Flush($true)
} finally { $to.Dispose();$from.Dispose() }
$unsupported=[IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted
if ((Get-Item -LiteralPath $vhd).Attributes -band $unsupported) { throw 'Ordinary VHD copy has unsupported host attributes' }
$record.blank_sha256=(Get-FileHash -LiteralPath $blank -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-FileHash -LiteralPath $vhd -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.blank_sha256) { throw 'Ordinary blank copy differs' }
}
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using System.ComponentModel;
public static class MiniOsNtfsFragment {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string p,uint a,uint s,IntPtr sec,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(IntPtr h,uint c,byte[] i,uint n,byte[] o,uint m,out uint r,IntPtr p);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint QueryDosDevice(string n,StringBuilder b,uint l);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool DefineDosDevice(uint f,string n,string t);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CopyFile(string a,string b,bool fail);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr h,[Out]byte[] information);
 static IntPtr Open(string path,uint access) {
   IntPtr h=CreateFile(path,access,3,IntPtr.Zero,3,0,IntPtr.Zero);
   if(h==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
   return h;
 }
 static byte[] Io(IntPtr h,uint code,byte[] input,int size) {
   byte[] output=new byte[size];uint returned;
   if(!DeviceIoControl(h,code,input,(uint)input.Length,output,(uint)size,out returned,IntPtr.Zero))
     throw new Win32Exception(Marshal.GetLastWin32Error());
   Array.Resize(ref output,(int)returned);return output;
 }
 public static uint DiskNumber(string alias) {
   IntPtr h=Open(@"\\.\"+alias,0);
   try { byte[] b=Io(h,0x002D1080,new byte[0],12);if(b.Length!=12||BitConverter.ToUInt32(b,0)!=7)throw new InvalidOperationException("Not a disk");return BitConverter.ToUInt32(b,4); }
   finally{CloseHandle(h);}
 }
 public static ulong FileRecord(string path) {
   IntPtr h=Open(path,0);
   try{byte[] b=new byte[52];if(!GetFileInformationByHandle(h,b))throw new Win32Exception(Marshal.GetLastWin32Error());return (((ulong)BitConverter.ToUInt32(b,44)<<32)|BitConverter.ToUInt32(b,48))&0x0000ffffffffffff;}
   finally{CloseHandle(h);}
 }
 public static int RunCount(string path) {
   IntPtr h=Open(path,0);
   try {byte[] b=Io(h,0x90073,new byte[8],1024*1024);return checked((int)BitConverter.ToUInt32(b,0));}
   finally{CloseHandle(h);}
 }
 public static int Fragment(string alias,string file,uint diskNumber) {
   if(DiskNumber(alias)!=diskNumber)throw new InvalidOperationException("Volume identity mismatch");
   IntPtr volume=Open(@"\\.\"+alias,0xC0000000), data=Open(file,0x80000000);
   try {
     long next=32768;
     for(long vcn=0;vcn<512;vcn++) {
       byte[] start=BitConverter.GetBytes(0L);
       byte[] bitmap=Io(volume,0x9006f,start,1024*1024);
       if(bitmap.Length<16)throw new InvalidOperationException("Truncated volume bitmap");
       long first=BitConverter.ToInt64(bitmap,0),count=BitConverter.ToInt64(bitmap,8);
       if(first<0||count<=0||count>(bitmap.Length-16)*8L)throw new InvalidOperationException("Invalid volume bitmap geometry");
       for(;;next+=2) {
         long bit=next-first;
         if(bit<0||bit>=count)throw new InvalidOperationException("No bounded free target cluster");
         if((bitmap[16+bit/8]&(1<<(int)(bit%8)))==0)break;
       }
       // MOVE_FILE_DATA: HANDLE, VCN, LCN, DWORD count; native x64 alignment.
       if(IntPtr.Size!=8)throw new InvalidOperationException("Fixture writer requires host x64");
       byte[] move=new byte[32];
       Array.Copy(BitConverter.GetBytes(data.ToInt64()),0,move,0,8);
       Array.Copy(BitConverter.GetBytes(vcn),0,move,8,8);
       Array.Copy(BitConverter.GetBytes(next),0,move,16,8);
       Array.Copy(BitConverter.GetBytes(1),0,move,24,4);
       Io(volume,0x90074,move,0);next+=2;
     }
   } finally{CloseHandle(data);CloseHandle(volume);}
   return RunCount(file);
 }
}
'@
$mounted=$false; $alias=$null; $nativeTarget=$null
function Guard-Disk([bool]$Readonly) {
    $image=Get-DiskImage -ImagePath $vhd -ErrorAction Stop
    $disk=$image | Get-Disk -ErrorAction Stop
    if (-not $image.Attached -or [IO.Path]::GetFullPath($image.ImagePath) -cne $vhd -or $disk.Size -ne 512MB -or $disk.IsBoot -or $disk.IsSystem -or ($disk.BusType.ToString() -replace ' ','') -ne 'FileBackedVirtual' -or $disk.IsReadOnly -ne $Readonly) { throw 'Exact virtual image/size/readonly guard failed' }
    return $disk
}
function Add-Alias($Volume) {
    if ($Volume.DriveLetter -or $Volume.Path -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') { throw 'Unexpected volume path or persistent letter' }
    $b=[Text.StringBuilder]::new(32768)
    if (-not [MiniOsNtfsFragment]::QueryDosDevice($Volume.Path.Substring(4).TrimEnd('\'),$b,$b.Capacity)) { throw 'Cannot resolve owned volume' }
    $script:nativeTarget=$b.ToString().Split([char]0)[0]
    foreach ($name in @('Z:','Y:','X:','W:','V:','U:','T:','S:','R:')) {
        $existing=[Text.StringBuilder]::new(32768)
        if ([MiniOsNtfsFragment]::QueryDosDevice($name,$existing,$existing.Capacity)) { continue }
        if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 2) { continue }
        if (-not [MiniOsNtfsFragment]::DefineDosDevice(9,$name,$script:nativeTarget)) { throw 'Temporary no-broadcast alias failed' }
        $script:alias=$name; return
    }
    throw 'No unused DOS alias'
}
function Remove-Alias {
    if ($script:alias) {
        if (-not [MiniOsNtfsFragment]::DefineDosDevice(15,$script:alias,$script:nativeTarget)) { throw 'Exact alias removal failed' }
        $script:alias=$null
    }
}
function Hash-Stream([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    $hash=[Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($hash.ComputeHash($stream)).ToLowerInvariant() }
    finally { $hash.Dispose(); $stream.Dispose() }
}
try {
    if (-not $VerifyFixture) {
    Mount-DiskImage -ImagePath $vhd -Access ReadWrite -NoDriveLetter -ErrorAction Stop | Out-Null
    $mounted=$true; Update-HostStorageCache
    $disk=Guard-Disk $false
    if ($disk.PartitionStyle.ToString() -ne 'RAW') { throw 'New image is unexpectedly initialized' }
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction Stop | Out-Null
    $disk=Guard-Disk $false
    $partition=New-Partition -DiskNumber $disk.Number -Offset 1MB -Size (510MB) -MbrType IFS -ErrorAction Stop
    $disk=Guard-Disk $false
    $partition | Format-Volume -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel 'OWNISO' -Confirm:$false -ErrorAction Stop | Out-Null
    $volume=$partition | Get-Volume -ErrorAction Stop
    Add-Alias $volume
    if ([MiniOsNtfsFragment]::DiskNumber($alias) -ne $disk.Number) { throw 'Alias is not the image' }
    $copied=$alias+'\INSTALL.ISO'
    if (-not [MiniOsNtfsFragment]::CopyFile($isoFull,$copied,$true)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
    $record.runs_before=[MiniOsNtfsFragment]::RunCount($copied)
    $record.runs_after=[MiniOsNtfsFragment]::Fragment($alias,$copied,$disk.Number)
    $record.file_record=[MiniOsNtfsFragment]::FileRecord($copied)
    if ($record.runs_after -le 128) { throw 'Windows did not create the required fragmentation' }
    if ((Hash-Stream $copied) -cne $record.source_iso_sha256) { throw 'Windows copy/relocation changed ISO bytes' }
    $record.partition_start=[uint64]$partition.Offset; $record.partition_bytes=[uint64]$partition.Size
    Remove-Alias
    Dismount-DiskImage -ImagePath $vhd -ErrorAction Stop; $mounted=$false
    (Get-Item -LiteralPath $vhd).IsReadOnly=$true
    }
    Mount-DiskImage -ImagePath $vhd -Access ReadOnly -NoDriveLetter -ErrorAction Stop | Out-Null
    $mounted=$true; Update-HostStorageCache
    $disk=Guard-Disk $true
    $partitions=@(Get-Partition -DiskNumber $disk.Number)
    if ($partitions.Count -ne 1 -or $partitions[0].Offset -ne $record.partition_start -or $partitions[0].Size -ne $record.partition_bytes) { throw 'Readonly remount layout differs' }
    Add-Alias ($partitions[0] | Get-Volume)
    if ([MiniOsNtfsFragment]::DiskNumber($alias) -ne $disk.Number) { throw 'Readonly alias guard failed' }
    $record.readonly_iso_sha256=Hash-Stream ($alias+'\INSTALL.ISO')
    "HEAD $head`nWORKTREE_DIRTY $dirty" | Set-Content -LiteralPath (Join-Path $outFull 'chkdsk.txt') -Encoding utf8
    & "$env:SystemRoot\System32\chkdsk.exe" $alias | Tee-Object -FilePath (Join-Path $outFull 'chkdsk.txt') -Append
    $record.chkdsk_exit=$LASTEXITCODE
    if ($record.chkdsk_exit -ne 0 -or $record.readonly_iso_sha256 -cne $record.source_iso_sha256) { throw 'Readonly native gate failed' }
    $record.passed=$true
} finally {
    try { Remove-Alias } finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $vhd -ErrorAction Stop; $mounted=$false }
        $record.dismounted=-not $mounted
        $record.vhd_sha256=(Get-FileHash -LiteralPath $vhd -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($VerifyFixture -and $record.vhd_sha256 -cne $previous.vhd_sha256) { throw 'Readonly VHD changed during native verification' }
        $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outFull 'receipt.json') -Encoding utf8
    }
}
Write-Output ('NTFS_FRAGMENTED_COMPLETE '+($record | ConvertTo-Json -Compress -Depth 8))
