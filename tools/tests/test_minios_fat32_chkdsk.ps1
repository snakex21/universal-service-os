#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# Read-only FAT32 gate for one explicit partition of a retained virtual VHD.
   No conversion, formatting, repair switches or physical-disk operations. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Vhd,
    [Parameter(Mandatory)][uint64]$ExpectedImageBytes,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedVhdSha256,
    [Parameter(Mandatory)][uint32]$PartitionNumber,
    [Parameter(Mandatory)][uint64]$ExpectedPartitionStart,
    [Parameter(Mandatory)][uint64]$ExpectedPartitionBytes,
    [ValidateSet(512,4096)][uint32]$ExpectedSectorBytes = 512,
    [Parameter(Mandatory)][string]$Out,
    [ValidateRange(60,3600)][int]$CheckTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$head = (& git -C $repo rev-parse HEAD).Trim()
$dirty = @(& git -C $repo status --porcelain=v1 -uall).Count
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$' -or $dirty -ne 0) { throw 'F3: clean repository HEAD required for final FAT32 evidence' }
$logHeader = "HEAD $head`nWORKTREE_DIRTY $dirty`n"
$workspace = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if (-not [IO.Path]::IsPathFullyQualified($Workspace) -or $workspace.Length -le 3 -or $workspace.StartsWith('\\')) { throw 'Explicit local owned workspace required' }
function Owned([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase) -or $full.IndexOfAny([char[]]",`r`n") -ge 0) { throw 'Path must belong to the explicit workspace' }
    $walk = $full
    while ($walk) {
        if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse point refused' }
        $walk = [IO.Path]::GetDirectoryName($walk)
    }
    return $full
}
function Hash-Image([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$vhdPath = Owned $Vhd
$outPath = Owned $Out
if ([IO.Path]::GetExtension($vhdPath) -notin @('.vhd','.vhdx') -or -not (Test-Path -LiteralPath $vhdPath -PathType Leaf)) { throw 'Explicit existing regular VHD/VHDX required' }
if (Test-Path -LiteralPath $outPath) { throw 'Fresh output directory required' }
if ($ExpectedImageBytes -lt 32MB -or $ExpectedPartitionStart % $ExpectedSectorBytes -or $ExpectedPartitionBytes % $ExpectedSectorBytes -or
    $ExpectedPartitionStart -gt $ExpectedImageBytes -or $ExpectedPartitionBytes -gt $ExpectedImageBytes - $ExpectedPartitionStart) { throw 'Invalid expected virtual geometry' }
if ((Hash-Image $vhdPath) -cne $ExpectedVhdSha256) { throw 'VHD container SHA256 differs before mount' }
$unsupportedAttributes = [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted
if ((Get-Item -LiteralPath $vhdPath -Force).Attributes -band $unsupportedAttributes) { throw 'VHD has unsupported host attributes; supply a verified ordinary file copy' }
if ((Get-DiskImage -ImagePath $vhdPath -ErrorAction Stop).Attached) { throw 'VHD is already attached; do not disturb an existing attachment' }
New-Item -ItemType Directory -Path $outPath | Out-Null
$record = [ordered]@{kind='windows-readonly-fat32-chkdsk'; passed=$false; vhd=$vhdPath; vhd_sha256_before=$ExpectedVhdSha256;
    head=$head; worktree_dirty=$dirty; expected_image_bytes=$ExpectedImageBytes; partition_number=$PartitionNumber; chkdsk_flags=@(); repair_flags_used=$false; access='ReadOnly'; chkdsk_issued=$false}
$mounted = $false
$alias = $null
$deviceTarget = $null
if (-not ('MiniOsFat32Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MiniOsFat32Native {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern IntPtr CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadFile(IntPtr handle,byte[] data,uint length,out uint done,IntPtr overlapped);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeviceIoControl(IntPtr handle,uint code,IntPtr input,uint inputLength,byte[] output,uint outputLength,out uint done,IntPtr overlapped);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint QueryDosDevice(string name,StringBuilder target,uint length);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool DefineDosDevice(uint flags,string name,string target);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool GetVolumeInformation(string root,IntPtr name,uint nameLength,out uint serial,out uint maximum,out uint flags,StringBuilder filesystem,uint filesystemLength);
 public static uint DiskNumber(string alias) {
   IntPtr h=CreateFile(@"\\.\"+alias,0,3,IntPtr.Zero,3,0,IntPtr.Zero);
   if(h==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
   try { byte[] bytes=new byte[12]; uint done;
     if(!DeviceIoControl(h,0x002D1080,IntPtr.Zero,0,bytes,12,out done,IntPtr.Zero)||done!=12||BitConverter.ToUInt32(bytes,0)!=7) throw new InvalidOperationException("Not the virtual disk alias");
     return BitConverter.ToUInt32(bytes,4);
   } finally { CloseHandle(h); }
 }
 public static byte[] ReadBoot(string alias,uint sector) {
   IntPtr h=CreateFile(@"\\.\"+alias,0x80000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
   if(h==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
   try {byte[] bytes=new byte[sector]; uint done;
     if(!ReadFile(h,bytes,sector,out done,IntPtr.Zero)||done!=sector) throw new System.ComponentModel.Win32Exception();
     return bytes;
   } finally {CloseHandle(h);}
 }
}
'@
}
try {
    $attachment = Mount-DiskImage -ImagePath $vhdPath -Access ReadOnly -NoDriveLetter -PassThru -ErrorAction Stop
    $mounted = $true
    Update-HostStorageCache -ErrorAction Stop
    $disk = $attachment | Get-Disk -ErrorAction Stop
    if ($null -eq $disk -or $disk.IsSystem -or $disk.IsBoot -or -not $disk.IsReadOnly -or $disk.Size -ne $ExpectedImageBytes -or
        $disk.LogicalSectorSize -ne $ExpectedSectorBytes -or ($disk.BusType.ToString() -replace ' ','') -ne 'FileBackedVirtual') { throw 'Image is not the exact read-only non-system virtual disk' }
    $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $PartitionNumber -ErrorAction Stop
    if ($partition.Offset -ne $ExpectedPartitionStart -or $partition.Size -ne $ExpectedPartitionBytes) { throw 'Virtual partition geometry differs' }
    $volume = $partition | Get-Volume -ErrorAction Stop
    if ($null -eq $volume -or $volume.Path -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$' -or $volume.DriveLetter -or $volume.FileSystem -cne 'FAT32') { throw 'Explicit virtual partition is not an unlettered FAT32 volume' }
    $target = [Text.StringBuilder]::new(32768)
    if (-not [MiniOsFat32Native]::QueryDosDevice($volume.Path.Substring(4).TrimEnd('\'),$target,$target.Capacity)) { throw 'Cannot resolve virtual FAT32 volume' }
    $deviceTarget = $target.ToString().Split([char]0)[0]
    foreach ($candidate in @('Z:','Y:','X:','W:','V:','U:','T:','S:','R:')) {
        $occupied = [Text.StringBuilder]::new(32768)
        if ([MiniOsFat32Native]::QueryDosDevice($candidate,$occupied,$occupied.Capacity)) { continue }
        if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 2) { continue }
        if (-not [MiniOsFat32Native]::DefineDosDevice(9,$candidate,$deviceTarget)) { throw 'Temporary no-broadcast alias failed' }
        $alias = $candidate
        break
    }
    if (-not $alias) { throw 'No available temporary DOS alias' }
    $boot = [MiniOsFat32Native]::ReadBoot($alias,$ExpectedSectorBytes)
    if ($boot[510] -ne 0x55 -or $boot[511] -ne 0xaa -or [Text.Encoding]::ASCII.GetString($boot,82,8) -cne 'FAT32   ' -or
        [BitConverter]::ToUInt16($boot,11) -ne $ExpectedSectorBytes -or [uint64][BitConverter]::ToUInt32($boot,32)*$ExpectedSectorBytes -ne $ExpectedPartitionBytes -or
        [uint64][BitConverter]::ToUInt32($boot,28)*$ExpectedSectorBytes -ne $ExpectedPartitionStart) { throw 'Actual alias FAT32 BPB differs from expected virtual geometry' }
    [uint32]$serial=0; [uint32]$maximum=0; [uint32]$flags=0
    $filesystem=[Text.StringBuilder]::new(64)
    if (-not [MiniOsFat32Native]::GetVolumeInformation($alias+'\',[IntPtr]::Zero,0,[ref]$serial,[ref]$maximum,[ref]$flags,$filesystem,$filesystem.Capacity) -or $filesystem.ToString() -cne 'FAT32') { throw 'Native Windows FAT32 read failed' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'chkdsk.exe'
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $start.StandardErrorEncoding=$start.StandardOutputEncoding
    $start.ArgumentList.Add($alias)
    # Re-resolve the exact chkdsk argument immediately before invoking it.
    $target.Clear() | Out-Null
    if (-not [MiniOsFat32Native]::QueryDosDevice($alias,$target,$target.Capacity) -or $target.ToString().Split([char]0)[0] -cne $deviceTarget) { throw 'FAT32 alias changed before chkdsk' }
    $aliasNumber=[MiniOsFat32Native]::DiskNumber($alias)
    $actualDisk=Get-Disk -Number $aliasNumber -ErrorAction Stop
    $actualImage=Get-DiskImage -ImagePath $vhdPath -ErrorAction Stop | Get-Disk -ErrorAction Stop
    if ($aliasNumber -ne $disk.Number -or $actualImage.Number -ne $aliasNumber -or $actualDisk.Size -ne $ExpectedImageBytes -or
        -not $actualDisk.IsReadOnly -or $actualDisk.IsSystem -or $actualDisk.IsBoot -or ($actualDisk.BusType.ToString() -replace ' ','') -ne 'FileBackedVirtual') { throw 'Actual chkdsk argument does not identify the exact read-only virtual image' }
    $record.target_guard=@{passed=$true;disk_number=$aliasNumber;image_bytes=$actualDisk.Size;partition_start=$partition.Offset;partition_bytes=$partition.Size;sector_bytes=$disk.LogicalSectorSize;alias=$alias;readonly=$actualDisk.IsReadOnly}
    $record.chkdsk_issued=$true
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    $finished=$process.WaitForExit($CheckTimeoutSeconds*1000)
    if (-not $finished) { $process.Kill(); $process.WaitForExit() }
    [IO.File]::WriteAllText((Join-Path $outPath 'chkdsk-stdout.txt'),$logHeader+$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $outPath 'chkdsk-stderr.txt'),$logHeader+$stderr.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    $record.chkdsk_exit=$process.ExitCode; $record.chkdsk_timeout=(-not $finished)
    $record.passed=$finished -and $process.ExitCode -eq 0
} catch { $record.error=$_.Exception.Message; throw }
finally {
    if ($alias -and -not [MiniOsFat32Native]::DefineDosDevice(15,$alias,$deviceTarget)) { $record.passed=$false; $record.alias_cleanup_error=[Runtime.InteropServices.Marshal]::GetLastWin32Error() }
    if ($mounted) {
        try { Dismount-DiskImage -ImagePath $vhdPath -ErrorAction Stop | Out-Null }
        catch { $record.passed=$false; $record.detach_error=$_.Exception.Message }
    }
    $record.vhd_sha256_after=Hash-Image $vhdPath
    if ($record.vhd_sha256_after -cne $ExpectedVhdSha256) { $record.passed=$false; $record.container_changed=$true }
    $record.head_after=(& git -C $repo rev-parse HEAD).Trim()
    $record.worktree_dirty_after=@(& git -C $repo status --porcelain=v1 -uall).Count
    if ($record.head_after -cne $head -or $record.worktree_dirty_after -ne 0) { $record.passed=$false; $record.tree_changed=$true }
    [IO.File]::WriteAllText((Join-Path $outPath 'result.json'),($record | ConvertTo-Json -Depth 6)+"`n",[Text.UTF8Encoding]::new($false))
}
$record | ConvertTo-Json -Depth 6
if (-not $record.passed) { exit 1 }
