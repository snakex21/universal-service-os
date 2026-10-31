#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# One selected NTFS partition of an exact read-only multipartition VHD.
   Reuses the accepted native WIM tree/SD/ADS/hash comparator. No conversion,
   formatting, repair, persistent drive letter or physical-device selection. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$InstallVhd,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$InstallVhdSha256,
    [Parameter(Mandatory)][uint64]$InstallImageBytes,
    [Parameter(Mandatory)][string]$LayoutJson,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$LayoutSha256,
    [Parameter(Mandatory)][uint32]$PartitionNumber,
    [string]$ExpectedTree,
    [string]$ExpectedSecurity,
    [string]$RawSecurityProof,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$RawSecurityProofSha256,
    [Parameter(Mandatory)][string]$InstallOut,
    [ValidateRange(60,3600)][int]$InstallTimeoutSeconds=3600
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$head=(& git -C $repo rev-parse HEAD).Trim()
$dirty=@(& git -C $repo status --porcelain=v1 -uall).Count
if ($dirty -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') { throw 'F3: clean frozen HEAD required' }
$stamp="HEAD $head`nWORKTREE_DIRTY 0`n"
# Parameter names deliberately differ from the imported raw-only command's
# parameters: dot-sourcing may initialize its unbound parameters in this scope.
. (Join-Path $PSScriptRoot 'minios_chkdsk_readonly.ps1') -Workspace $Workspace -LibraryOnly
$vhd=Assert-Owned $InstallVhd
$outDir=Assert-Owned $InstallOut
$layoutPath=Assert-Owned $LayoutJson
if ((Test-Path -LiteralPath $outDir) -or [IO.Path]::GetExtension($vhd) -cne '.vhd' -or -not (Test-Path -LiteralPath $vhd -PathType Leaf)) { throw 'New output and existing exact VHD required' }
$badAttrs=[IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted
$vhdInfo=Get-Item -LiteralPath $vhd -Force
if (-not $vhdInfo.IsReadOnly -or ($vhdInfo.Attributes -band $badAttrs) -or (Hash-File $vhd) -cne $InstallVhdSha256 -or
    (Hash-File $layoutPath) -cne $LayoutSha256 -or (Get-Item -LiteralPath $layoutPath).Length -gt 65536) { throw 'Readonly ordinary VHD/layout pin differs' }
if ((Get-DiskImage -ImagePath $vhd -ErrorAction Stop).Attached) { throw 'Refuse an already attached image' }
$layout=[IO.File]::ReadAllText($layoutPath) | ConvertFrom-Json -AsHashtable
if ($layout.schema -cne 'minios-install-layout-v1' -or $layout.image_bytes -ne $InstallImageBytes -or $layout.sector_bytes -ne 512 -or
    $layout.partitions.Count -notin @(2,3) -or $layout.style -notin @('GPT','MBR')) { throw 'Explicit independent installation layout required' }
$selected=@($layout.partitions | Where-Object {$_.number -eq $PartitionNumber})
if ($selected.Count -ne 1 -or $selected[0].filesystem -cne 'NTFS') { throw 'Select exactly one declared NTFS partition' }
$expectedWim=$null; $expectedSecurityTable=$null; $rawProof=$null
if ($ExpectedTree) {
    if (-not $ExpectedSecurity -or -not $RawSecurityProof -or -not $RawSecurityProofSha256 -or $PartitionNumber -ne $layout.windows_number) { throw 'Windows acceptance requires exact tree/security/raw-SDS proof' }
    $expectedWim=Read-WimManifest $ExpectedTree
    $expectedSecurityTable=Read-WimSecurity $ExpectedSecurity
    $rawProofPath=Assert-Owned $RawSecurityProof
    if ((Hash-File $rawProofPath) -cne $RawSecurityProofSha256) { throw 'Raw SDS receipt pin differs' }
    $rawProof=[IO.File]::ReadAllText($rawProofPath) | ConvertFrom-Json -AsHashtable
    if (-not $rawProof.passed -or -not $rawProof.source_unchanged -or -not $rawProof.expected_metadata_unchanged -or
        $rawProof.source_kind -cne 'dynamic-vhd' -or $rawProof.source_sha256 -cne $InstallVhdSha256 -or
        $rawProof.partition_start -ne $selected[0].start -or $rawProof.partition_bytes -ne $selected[0].bytes -or
        $rawProof.expected_tree_sha256 -cne $expectedWim.sha256 -or $rawProof.expected_security_sha256 -cne $expectedSecurityTable.sha256) { throw 'Raw SDS proof does not bind exact VHD/partition/manifests' }
} elseif ($ExpectedSecurity -or $RawSecurityProof -or $RawSecurityProofSha256) { throw 'Unpaired tree/security inputs' }
[void][IO.Directory]::CreateDirectory($outDir)
$record=[ordered]@{kind='multipartition-windows-readonly';passed=$false;head=$head;worktree_dirty=0;vhd=$vhd;vhd_sha256_before=$InstallVhdSha256;
    image_bytes=$InstallImageBytes;layout_sha256=$LayoutSha256;partition_number=$PartitionNumber;access='ReadOnly';chkdsk_flags=@();repair_flags_used=$false}
$mounted=$false; $alias=$null; $target=$null
if (-not ('MiniOsInstallNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MiniOsInstallNative {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string p,uint a,uint s,IntPtr sec,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(IntPtr h,byte[] b,uint n,out uint done,IntPtr over);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(IntPtr h,uint c,IntPtr i,uint n,byte[] b,uint m,out uint done,IntPtr over);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint QueryDosDevice(string n,StringBuilder b,uint m);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool DefineDosDevice(uint f,string n,string t);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool GetVolumeInformation(string r,IntPtr n,uint m,out uint s,out uint c,out uint f,StringBuilder fs,uint z);
 public static uint DiskNumber(string alias) {
  IntPtr h=CreateFile(@"\\.\"+alias,0,3,IntPtr.Zero,3,0,IntPtr.Zero);
  if(h==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
  try {byte[] b=new byte[12];uint done;
   if(!DeviceIoControl(h,0x002D1080,IntPtr.Zero,0,b,12,out done,IntPtr.Zero)||done!=12||BitConverter.ToUInt32(b,0)!=7) throw new InvalidOperationException("Not an exact virtual disk alias");
   return BitConverter.ToUInt32(b,4);
  } finally {CloseHandle(h);}
 }
 public static byte[] Boot(string alias) {
  IntPtr h=CreateFile(@"\\.\"+alias,0x80000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
  if(h==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
  try {byte[] b=new byte[512];uint done;if(!ReadFile(h,b,512,out done,IntPtr.Zero)||done!=512)throw new System.ComponentModel.Win32Exception();return b;}
  finally {CloseHandle(h);}
 }
}
'@
}
try {
    $attachment=Mount-DiskImage -ImagePath $vhd -Access ReadOnly -NoDriveLetter -PassThru -ErrorAction Stop
    $mounted=$true
    Update-HostStorageCache -ErrorAction Stop
    $disk=$attachment | Get-Disk -ErrorAction Stop
    if ($null -eq $disk -or $disk.IsSystem -or $disk.IsBoot -or -not $disk.IsReadOnly -or $disk.Size -ne $InstallImageBytes -or $disk.LogicalSectorSize -ne 512 -or
        ($disk.BusType.ToString() -replace ' ','') -cne 'FileBackedVirtual' -or $disk.PartitionStyle.ToString() -cne $layout.style) { throw 'Exact readonly non-system virtual disk identity/geometry/style differs' }
    $parts=@(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
    if ($parts.Count -ne $layout.partitions.Count) { throw 'Virtual partition count differs' }
    foreach ($wanted in $layout.partitions) {
        $actual=@($parts | Where-Object {$_.PartitionNumber -eq $wanted.number})
        if ($actual.Count -ne 1 -or $actual[0].Offset -ne $wanted.start -or $actual[0].Size -ne $wanted.bytes) { throw 'Native partition table differs from independently parsed VHD' }
        if ($layout.style -ceq 'GPT' -and (([string]$actual[0].GptType).Trim('{}') -ine $wanted.gpt_type -or ([string]$actual[0].Guid).Trim('{}') -ine $wanted.guid)) { throw 'Native GPT type/GUID differs' }
        if ($layout.style -ceq 'MBR' -and ($actual[0].MbrType -ne $wanted.mbr_type -or [bool]$actual[0].IsActive -ne [bool]$wanted.active)) { throw 'Native MBR type/active state differs' }
    }
    if (($layout.style -ceq 'GPT' -and ([string]$disk.Guid).Trim('{}') -ine $layout.disk_guid) -or ($layout.style -ceq 'MBR' -and $disk.Signature -ne $layout.mbr_signature)) { throw 'Native disk GUID/signature differs' }
    $part=$parts | Where-Object {$_.PartitionNumber -eq $PartitionNumber}
    $volume=$part | Get-Volume -ErrorAction Stop
    if ($null -eq $volume -or $volume.DriveLetter -or $volume.Path -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') { throw 'Unlettered exact virtual volume required' }
    $buffer=[Text.StringBuilder]::new(32768)
    if (-not [MiniOsInstallNative]::QueryDosDevice($volume.Path.Substring(4).TrimEnd('\'),$buffer,$buffer.Capacity)) { throw 'Virtual volume device lookup failed' }
    $target=$buffer.ToString().Split([char]0)[0]
    foreach ($candidate in @('Z:','Y:','X:','W:','V:','U:','T:','S:','R:')) {
        $occupied=[Text.StringBuilder]::new(32768)
        if ([MiniOsInstallNative]::QueryDosDevice($candidate,$occupied,$occupied.Capacity)) {continue}
        if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 2) {continue}
        if (-not [MiniOsInstallNative]::DefineDosDevice(9,$candidate,$target)) {throw 'No-broadcast alias failed'}
        $alias=$candidate;break
    }
    if (-not $alias) {throw 'No available temporary DOS alias'}
    $boot=[MiniOsInstallNative]::Boot($alias)
    if ([Text.Encoding]::ASCII.GetString($boot,3,8) -cne 'NTFS    ' -or $boot[510] -ne 0x55 -or $boot[511] -ne 0xaa -or [BitConverter]::ToUInt16($boot,11) -ne 512 -or
        [uint64][BitConverter]::ToUInt32($boot,28)*512 -ne $selected[0].start) {throw 'Actual alias NTFS BPB/partition offset invalid'}
    function Assert-CurrentAlias {
        $buffer.Clear() | Out-Null
        if (-not [MiniOsInstallNative]::QueryDosDevice($alias,$buffer,$buffer.Capacity) -or $buffer.ToString().Split([char]0)[0] -cne $target) {throw 'Virtual alias changed'}
        $number=[MiniOsInstallNative]::DiskNumber($alias)
        $checked=Get-Disk -Number $number -ErrorAction Stop
        $imageDisk=Get-DiskImage -ImagePath $vhd -ErrorAction Stop | Get-Disk -ErrorAction Stop
        if ($number -ne $disk.Number -or $imageDisk.Number -ne $number -or $checked.Size -ne $InstallImageBytes -or -not $checked.IsReadOnly -or $checked.IsSystem -or $checked.IsBoot -or
            ($checked.BusType.ToString() -replace ' ','') -cne 'FileBackedVirtual') {throw 'Actual chkdsk/tree alias is not the exact read-only virtual image'}
    }
    Assert-CurrentAlias
    $record.target_guard=@{passed=$true;disk_number=$disk.Number;image_bytes=$disk.Size;partition_start=$part.Offset;partition_bytes=$part.Size;alias=$alias;readonly=$disk.IsReadOnly}
    if ($expectedWim) {
        [uint32]$serial=0;[uint32]$maximum=0;[uint32]$flags=0;$fs=[Text.StringBuilder]::new(64)
        if (-not [MiniOsInstallNative]::GetVolumeInformation($alias+'\',[IntPtr]::Zero,0,[ref]$serial,[ref]$maximum,[ref]$flags,$fs,$fs.Capacity) -or $fs.ToString() -cne 'NTFS') {throw 'Native NTFS file-tree read unavailable'}
        $record.wim_tree=Compare-WimTree ($alias+'\') $expectedWim (Join-Path $outDir 'wim-native-metadata.jsonl') $expectedSecurityTable $rawProof
        $record.readonly_wim_tree_pass=$record.wim_tree.passed
    }
    Assert-CurrentAlias
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path ([Environment]::GetFolderPath('System')) 'chkdsk.exe'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage);$start.StandardErrorEncoding=$start.StandardOutputEncoding
    $start.ArgumentList.Add($alias)
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $finished=$process.WaitForExit($InstallTimeoutSeconds*1000)
    if (-not $finished) {$process.Kill();$process.WaitForExit()}
    [IO.File]::WriteAllText((Join-Path $outDir 'chkdsk-stdout.txt'),$stamp+$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $outDir 'chkdsk-stderr.txt'),$stamp+$stderr.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    $record.chkdsk_exit=$process.ExitCode;$record.chkdsk_timeout=(-not $finished)
    $record.passed=$finished -and $process.ExitCode -eq 0 -and (-not $expectedWim -or $record.readonly_wim_tree_pass)
} catch {$record.passed=$false;$record.error=$_.Exception.Message}
finally {
    if ($alias) {
        if (-not [MiniOsInstallNative]::DefineDosDevice(15,$alias,$target)) {$record.passed=$false;$record.alias_cleanup_failed=$true}
        else {$record.alias_removed=$true}
    }
    if ($mounted) {
        try {Dismount-DiskImage -ImagePath $vhd -ErrorAction Stop | Out-Null;$record.dismounted=$true}
        catch {$record.passed=$false;$record.detach_error=$_.Exception.Message}
    }
    $record.vhd_sha256_after=Hash-File $vhd
    if ($record.vhd_sha256_after -cne $InstallVhdSha256 -or (Hash-File $layoutPath) -cne $LayoutSha256) {$record.passed=$false;$record.input_changed=$true}
    if ($expectedWim -and ((Hash-File $expectedWim.path) -cne $expectedWim.sha256 -or (Hash-File $expectedSecurityTable.path) -cne $expectedSecurityTable.sha256 -or
        (Hash-File $rawProofPath) -cne $RawSecurityProofSha256)) {$record.passed=$false;$record.expected_input_changed=$true}
    $record.head_after=(& git -C $repo rev-parse HEAD).Trim();$record.worktree_dirty_after=@(& git -C $repo status --porcelain=v1 -uall).Count
    if ($record.head_after -cne $head -or $record.worktree_dirty_after -ne 0) {$record.passed=$false;$record.tree_changed=$true}
    [IO.File]::WriteAllText((Join-Path $outDir 'result.json'),($record | ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
}
$record | ConvertTo-Json -Depth 8
if (-not $record.passed) {exit 1}
