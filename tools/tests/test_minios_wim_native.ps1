#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# A few self-generated own files only. No Windows apply, device, mount or
   physical disk access. Keep fixture + receipt as evidence until final report. #>
param([Parameter(Mandatory)][string]$Workspace,
      [Parameter(Mandatory)][string]$Runtime,
      [Parameter(Mandatory)][ValidatePattern('^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$')][string]$VolumeGuid)
$ErrorActionPreference='Stop'
$allowed=[IO.Path]::GetFullPath($Runtime).TrimEnd('\')+'\'
$full=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if (-not [IO.Path]::IsPathFullyQualified($Runtime) -or $allowed.StartsWith('\\') -or $allowed.Length -le 3 -or -not [IO.Path]::IsPathFullyQualified($Workspace) -or -not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $full)) { throw 'A new child of the explicit local WIM runtime is required' }
$walk=[IO.Path]::GetDirectoryName($full)
while ($walk) {
    if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse ancestor refused' }
    $walk=[IO.Path]::GetDirectoryName($walk)
}
$root=[IO.Path]::GetPathRoot($full)
if ($root -notmatch '^[a-zA-Z]:\\$') { throw 'Local drive-rooted runtime required' }
if ([IO.DriveInfo]::new($root).AvailableFreeSpace -lt 100GB+1MB) { throw '100 GiB reserve required' }
if ((Get-Volume -DriveLetter $root.Substring(0,1) -ErrorAction Stop).UniqueId -ine $VolumeGuid) { throw 'Unexpected runtime volume identity' }
[IO.Directory]::CreateDirectory($full) | Out-Null
$runtime=Join-Path $full 'host-runtime'; [IO.Directory]::CreateDirectory($runtime) | Out-Null
$saved=@{}
foreach ($name in @('APPDATA','LOCALAPPDATA','TEMP','TMP')) {
    $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
    [Environment]::SetEnvironmentVariable($name,$runtime,'Process')
}
$record=[ordered]@{kind='own-small-native-NTFS-metadata-test';passed=$false;windows_payload_applied=$false;physical_device_opened=$false;mounted_image=$false;tests=@()}
$scope=$null
function Check([bool]$Pass,[string]$Name) { if (-not $Pass) { throw "FAILED: $Name" }; $record.tests+= $Name }
try {
    Add-Type -LiteralPath (Join-Path $PSScriptRoot '../minios/wim_ntfs_metadata.cs')
    # Public, self-generated formatter fixture bytes, not a Windows payload.
    $rawHex='010004805c0000006c0000000000000014000000020048000300000000031400ff011f0001010000000000051200000000031800ff011f000102000000000005200000002002000000031400a90012000101000000000001000000000102000000000005200000002002000001020000000000052000000020020000'
    $apiHex='0100048014000000240000000000000034000000'+$rawHex.Substring(184,32)+$rawHex.Substring(216,32)+$rawHex.Substring(40,144)
    $comparison=[MiniOsWimMetadata]::CompareSecurityHex($rawHex,$apiHex)
    Check ($comparison.Passed -and $comparison.ApiReorderedSd -and -not $comparison.RawBytesEqual -and $comparison.ExpectedSha256 -ceq 'fad9d84f4bf8e3934696b419e32db665a7e519ce3043a300dce6f9554638d0d9' -and $comparison.NativeSha256 -ceq '405e5a6992f06e338514ab9b0f03a37dbf855a46a9062af866548fd1b857108b') 'SD-only-section-offsets-allowed-both-known-SHA256-retained'
    foreach ($kind in @('ACE','SID','control','RMcontrol','overlap','ACE-order','padding')) {
        $bad=[Convert]::FromHexString($apiHex)
        switch ($kind) {
            'ACE' { $bad[64]=$bad[64] -bxor 1 }
            'SID' { $bad[32]=$bad[32] -bxor 1 }
            'control' { $bad[3]=$bad[3] -bxor 0x20 }
            'RMcontrol' { $bad[1]=7 }
            'overlap' { [BitConverter]::GetBytes([uint32]68).CopyTo($bad,4) }
            'ACE-order' { $first=$bad[60..79]; $second=$bad[80..103]; $second.CopyTo($bad,60); $first.CopyTo($bad,84) }
            'padding' { $bad=$bad+[byte[]](1,0,0,0) }
        }
        $negativeSd=[MiniOsWimMetadata]::CompareSecurityHex($rawHex,[Convert]::ToHexString($bad))
        Check (-not $negativeSd.Passed -and -not $negativeSd.ApiReorderedSd) ('SD-reject-'+$kind)
    }
    # These setters exist only in this test. Never in the read oracle.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MiniOsOwnFixtureTimes {
 [StructLayout(LayoutKind.Sequential)] struct Basic { public long Creation,Access,Write,Change; public uint Attr; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string p,uint a,uint s,IntPtr sa,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int k,ref Basic b,uint n);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetFileSecurity(string path,uint fields,byte[] buffer,uint size,out uint needed);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s,uint r,out IntPtr sd,out uint bytes);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetSecurityDescriptorSacl(IntPtr sd,out bool present,out IntPtr sacl,out bool defaulted);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern uint SetNamedSecurityInfo(string p,uint type,uint flags,IntPtr owner,IntPtr group,IntPtr dacl,IntPtr sacl);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
 public static byte[] RawSecurity(string path) {
  return RawSecurityFields(path,0x10000);
 }
 public static byte[] RawSecurityFields(string path,uint fields) {
  uint size; GetFileSecurity(path,fields,null,0,out size);
  if(size<20 || size>1048576) throw new InvalidOperationException("Independent GetFileSecurity size");
  byte[] bytes=new byte[size];uint returned;
  if(!GetFileSecurity(path,fields,bytes,size,out returned) || returned!=size) throw new System.ComponentModel.Win32Exception();
  return bytes;
 }
 public static byte[] SetOwnLabelResource(string path) {
  IntPtr sd;uint bytes;
  if(!ConvertStringSecurityDescriptorToSecurityDescriptor("S:(ML;;NW;;;LW)(RA;;;;;WD;(\"USOS\",TU,0x0,42))",1,out sd,out bytes)) throw new System.ComponentModel.Win32Exception();
  try {
   bool present,defaulted;IntPtr sacl;
   if(!GetSecurityDescriptorSacl(sd,out present,out sacl,out defaulted) || !present || sacl==IntPtr.Zero) throw new InvalidOperationException("Own SACL absent");
   byte[] expected=new byte[(ushort)Marshal.ReadInt16(sacl,2)];Marshal.Copy(sacl,expected,0,expected.Length);
   uint error=SetNamedSecurityInfo(path,1,0x30,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,sacl);
   if(error!=0) throw new System.ComponentModel.Win32Exception((int)error);
   return expected;
  } finally {LocalFree(sd);}
 }
 public static void Set(string path,uint attr,long changed) {
  Basic value=new Basic {Creation=133000000000000001,Access=133000000000000002,Write=133000000000000003,Change=changed,Attr=attr};
  using(SafeFileHandle h=CreateFile(path,0x100,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
   if(h.IsInvalid || !SetFileInformationByHandle(h,0,ref value,(uint)Marshal.SizeOf<Basic>())) throw new System.ComponentModel.Win32Exception();
  }
 }
}
'@
    $scope=[MiniOsWimMetadata+SecurityPrivilege]::new()
    $fixture=Join-Path $full 'fixture'; [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $alpha=Join-Path $fixture 'alpha.bin'; [IO.File]::WriteAllBytes($alpha,[Text.Encoding]::ASCII.GetBytes('abc'))
    [IO.File]::WriteAllBytes($alpha+':proof',[Text.Encoding]::ASCII.GetBytes('own-ADS'))
    $beta=Join-Path $fixture 'beta.bin'; New-Item -ItemType HardLink -Path $beta -Target $alpha | Out-Null
    $empty=Join-Path $fixture 'empty.bin'; [IO.File]::WriteAllBytes($empty,[byte[]]::new(0))
    $link=Join-Path $fixture 'relative-link'; New-Item -ItemType SymbolicLink -Path $link -Target 'alpha.bin' | Out-Null
    [MiniOsOwnFixtureTimes]::Set($alpha,0x20,133000000000000004)
    [MiniOsOwnFixtureTimes]::Set($empty,0x20,133000000000000004)
    [MiniOsOwnFixtureTimes]::Set($link,0x420,133000000000000004)
    [MiniOsOwnFixtureTimes]::Set($fixture,0x10,133000000000000004)
    $a=[MiniOsWimMetadata]::Read($fixture,'alpha.bin')
    $b=[MiniOsWimMetadata]::Read($fixture,'beta.bin')
    Check ($a.FileId -ceq $b.FileId -and $a.Links -eq 2 -and $b.Links -eq 2) 'actual-two-name-hardlink-fileid-count'
    Check ($a.Streams[0].Sha1 -ceq 'a9993e364706816aba3e25717850c26c9cd0d89d' -and $a.Streams[0].Size -eq 3) 'known-abc-default-stream-SHA1'
    $ads=@($a.Streams | Where-Object Name -CEQ 'proof')
    $adsSha=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::ASCII.GetBytes('own-ADS'))).ToLowerInvariant()
    Check ($ads.Count -eq 1 -and $ads[0].Sha1 -ceq $adsSha -and $ads[0].Size -eq 7) 'native-ADS-enumeration-and-known-content-SHA1'
    $sd=[MiniOsOwnFixtureTimes]::RawSecurity($alpha)
    Check ($a.SecurityHex -ceq [Convert]::ToHexString($sd).ToLowerInvariant()) 'raw-owner-group-DACL-SACL-matches-independent-GetFileSecurityW'
    Check ($a.Created -eq 133000000000000001 -and $a.Accessed -eq 133000000000000002 -and $a.Modified -eq 133000000000000003 -and $a.Changed -eq 133000000000000004) 'four-distinct-raw-100ns-times'
    $rp=[MiniOsWimMetadata]::Read($fixture,'relative-link')
    $rpData=[Convert]::FromHexString($rp.ReparseDataHex)
    Check ($rp.ReparseTag -eq [uint32]2684354572 -and $rp.Streams[0].Kind -ceq 'reparse' -and $rpData.Length -gt 12 -and ([BitConverter]::ToUInt32($rpData,8) -band 1)) 'actual-relative-reparse-data-without-header-or-target-follow'
    $offset=[BitConverter]::ToUInt16($rpData,0); $length=[BitConverter]::ToUInt16($rpData,2)
    Check ([Text.Encoding]::Unicode.GetString($rpData,12+$offset,$length) -ceq 'alpha.bin') 'reparse-target-raw-Unicode-unchanged'
    $refused=$false
    try { [void][MiniOsWimMetadata]::Read($fixture,'relative-link/outside') } catch { $refused=$true }
    Check $refused 'refuse-traversal-through-reparse'
    $refused=$false
    try { [void][MiniOsWimMetadata]::Read('\\.\PhysicalDrive0','') } catch { $refused=$true }
    Check $refused 'refuse-physical-device-root-before-open'

    # The WIM transform intentionally supplies changedTime=modifiedTime.
    [MiniOsOwnFixtureTimes]::Set($alpha,0x20,133000000000000003)
    [MiniOsOwnFixtureTimes]::Set($empty,0x20,133000000000000003)
    [MiniOsOwnFixtureTimes]::Set($link,0x420,133000000000000003)
    [MiniOsOwnFixtureTimes]::Set($fixture,0x10,133000000000000003)

    # Load just the trusted function definitions, never the mounting main body.
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'minios_chkdsk_readonly.ps1'),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'actual-readonly-helper-PowerShell-parser'
    foreach ($fn in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { Invoke-Expression $fn.Extent.Text }
    $expected=Join-Path $full 'expected-tree.jsonl'
    $security=Join-Path $full 'expected-security.jsonl'
    $securityRows=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $lines=[Collections.Generic.List[string]]::new()
    foreach ($name in @('','alpha.bin','beta.bin','empty.bin','relative-link')) {
        $n=[MiniOsWimMetadata]::Read($fixture,$name)
        $securityRows[$n.SecuritySha256]=@{sha256=$n.SecuritySha256;hex=$n.SecurityHex;bytes=$n.SecurityHex.Length/2}
        $streams=@($n.Streams | ForEach-Object { @{name=$_.Name;size=$_.Size;sha1=$_.Sha1} })
        $row=@{path=$name;directory=[bool]($n.Attributes-band 0x10);attributes=$n.Attributes;creation_filetime=$n.Created;modified_filetime=$n.Modified;accessed_filetime=$n.Accessed;hardlink_group_id=$(if ($n.Links -gt 1) {7} else {0});link_count=$n.Links;reparse_tag=$n.ReparseTag;security_sha256=$n.SecuritySha256;streams=$streams;short_name=$null}
        $lines.Add(($row | ConvertTo-Json -Depth 5 -Compress))
    }
    [IO.File]::WriteAllLines($expected,$lines,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($security,@($securityRows.Values | ForEach-Object {$_ | ConvertTo-Json -Compress}),[Text.UTF8Encoding]::new($false))
    $manifest=Read-WimManifest $expected
    $securityTable=Read-WimSecurity $security
    $positive=Compare-WimTree $fixture $manifest (Join-Path $full 'actual-positive.jsonl') $securityTable
    Check $positive.passed 'exact-own-tree-native-metadata-comparison'
    $badLines=@($lines)
    $badRow=$badLines[1] | ConvertFrom-Json -AsHashtable
    $badRow.streams[0].sha1='0'*40
    $badLines[1]=$badRow | ConvertTo-Json -Compress -Depth 5
    $badManifest=Join-Path $full 'bad-SHA1-tree.jsonl'
    [IO.File]::WriteAllLines($badManifest,$badLines,[Text.UTF8Encoding]::new($false))
    $negative=Compare-WimTree $fixture (Read-WimManifest $badManifest) (Join-Path $full 'actual-negative.jsonl') $securityTable
    Check (-not $negative.passed -and $negative.different_count -eq 1) 'corrupt-nonempty-SHA1-refused-despite-correct-other-metadata'
    [MiniOsOwnFixtureTimes]::Set($alpha,0x20,133000000000000004)
    [MiniOsOwnFixtureTimes]::Set($empty,0x20,133000000000000004)
    [MiniOsOwnFixtureTimes]::Set($link,0x420,133000000000000004)
    [MiniOsOwnFixtureTimes]::Set($fixture,0x10,133000000000000004)
    $featureLines=@($lines | ForEach-Object { $r=$_ | ConvertFrom-Json -AsHashtable; $r.changed_filetime=133000000000000004; $r | ConvertTo-Json -Compress -Depth 5 })
    $featureManifest=Join-Path $full 'explicit-four-time-tree.jsonl'
    [IO.File]::WriteAllLines($featureManifest,$featureLines,[Text.UTF8Encoding]::new($false))
    $feature=Compare-WimTree $fixture (Read-WimManifest $featureManifest) (Join-Path $full 'actual-four-time.jsonl') $securityTable
    Check $feature.passed 'explicit-feature-four-distinct-FILETIME-comparison'
    $record.explicit_four_times=$feature
    $record.positive=$positive; $record.negative=$negative
    # API NORMAL is accepted only with a matching independent raw-zero proof.
    # This self-generated fixture tests the comparator contract; it is not raw
    # proof for any WIM or target. The production caller obtains that separately.
    [MiniOsOwnFixtureTimes]::Set($empty,0x80,133000000000000004)
    $zeroLines=@($featureLines | ForEach-Object { $r=$_ | ConvertFrom-Json -AsHashtable; if($r.path -ceq 'empty.bin') {$r.attributes=0}; $r | ConvertTo-Json -Compress -Depth 5 })
    $zeroManifest=Join-Path $full 'own-zero-attribute-tree.jsonl';[IO.File]::WriteAllLines($zeroManifest,$zeroLines,[Text.UTF8Encoding]::new($false))
    $zeroExpected=Read-WimManifest $zeroManifest
    $zeroProof=@{passed=$true;raw_zero_attributes_pass=$true;expected_tree_sha256=$zeroExpected.sha256;zero_attribute_paths=@('empty.bin')}
    $zeroPositive=Compare-WimTree $fixture $zeroExpected (Join-Path $full 'actual-zero-with-proof.jsonl') $securityTable $zeroProof
    Check ($zeroPositive.passed -and $zeroPositive.api_synthesized_normal_count -eq 1 -and $zeroPositive.api_synthesized_normal_paths[0] -ceq 'empty.bin') 'API-NORMAL-only-with-explicit-pinned-per-path-raw-zero-proof'
    foreach ($kind in @('absent','failed','wrong-tree','wrong-path')) {
        $proof=$zeroProof.Clone()
        switch($kind) { 'absent' {$proof=$null}; 'failed' {$proof.passed=$false}; 'wrong-tree' {$proof.expected_tree_sha256='0'*64}; 'wrong-path' {$proof.zero_attribute_paths=@('alpha.bin')} }
        $zeroNegative=Compare-WimTree $fixture $zeroExpected (Join-Path $full ('actual-zero-'+$kind+'.jsonl')) $securityTable $proof
        Check (-not $zeroNegative.passed -and $zeroNegative.different_count -eq 1 -and $zeroNegative.api_synthesized_normal_count -eq 0) ('API-NORMAL-refused-when-raw-proof-'+$kind)
    }
    # Declared root-only reserved metadata policy. No WIM row is rewritten.
    [MiniOsOwnFixtureTimes]::Set($fixture,0x16,133000000000000004)
    $rootProof=$zeroProof.Clone()
    $rootProof.root_reserved_metadata=@{passed=$true;path='';record=5;directory=$true;source_attributes=16;root_reserved_metadata_flags=6;raw_si_attributes=6;raw_filename_attributes=@(268435462)}
    $rootPositive=Compare-WimTree $fixture $zeroExpected (Join-Path $full 'actual-root-reserved.jsonl') $securityTable $rootProof
    Check ($rootPositive.passed -and $rootPositive.root_reserved_metadata_applied -and $rootPositive.root_reserved_metadata_flags -eq 6) 'root-only-reserved6-policy-with-matching-tree-and-raw-MFT5-proof'
    foreach ($kind in @('missing','wrong-record','wrong-SI','wrong-FN','wrong-source')) {
        $proof=$rootProof.Clone();$proof.root_reserved_metadata=$rootProof.root_reserved_metadata.Clone()
        switch($kind) { 'missing' {$proof.root_reserved_metadata=$null}; 'wrong-record' {$proof.root_reserved_metadata.record=27}; 'wrong-SI' {$proof.root_reserved_metadata.raw_si_attributes=0}; 'wrong-FN' {$proof.root_reserved_metadata.raw_filename_attributes=@(268435456)}; 'wrong-source' {$proof.root_reserved_metadata.source_attributes=32} }
        $rootNegative=Compare-WimTree $fixture $zeroExpected (Join-Path $full ('actual-root-'+$kind+'.jsonl')) $securityTable $proof
        Check (-not $rootNegative.passed -and $rootNegative.different_count -eq 1 -and -not $rootNegative.root_reserved_metadata_applied) ('root-reserved6-refused-when-proof-'+$kind)
    }
    $record.root_reserved_metadata=$rootPositive
    $labelFile=Join-Path $full 'own-label-resource.bin'; [IO.File]::WriteAllBytes($labelFile,[Text.Encoding]::ASCII.GetBytes('abc'))
    $expectedSacl=[MiniOsOwnFixtureTimes]::SetOwnLabelResource($labelFile)
    $fullLabel=[MiniOsWimMetadata]::Read($full,'own-label-resource.bin')
    $labelSd=[Convert]::FromHexString($fullLabel.SecurityHex)
    $labelParts=[Security.AccessControl.RawSecurityDescriptor]::new($labelSd,0)
    $actualSacl=[byte[]]::new($labelParts.SystemAcl.BinaryLength);$labelParts.SystemAcl.GetBinaryForm($actualSacl,0)
    Check ([Convert]::ToHexString($actualSacl) -ceq [Convert]::ToHexString($expectedSacl)) 'BACKUP-security-retains-own-mandatory-label-and-resource-attribute-ACE-bytes'
    Check ($fullLabel.SecurityHex -ceq [Convert]::ToHexString([MiniOsOwnFixtureTimes]::RawSecurity($labelFile)).ToLowerInvariant()) 'full-BACKUP-security-matches-independent-path-API'
    $filtered=[Convert]::ToHexString([MiniOsOwnFixtureTimes]::RawSecurityFields($labelFile,15)).ToLowerInvariant()
    Check (-not [MiniOsWimMetadata]::CompareSecurityHex($fullLabel.SecurityHex,$filtered).Passed) 'old-fifteen-bit-request-demonstrably-omits-SACL-ACE-sections'
    $record.full_sacl=@{expected_acl_hex=[Convert]::ToHexString($expectedSacl).ToLowerInvariant();native_sd_sha256=$fullLabel.SecuritySha256;filtered_sd_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Convert]::FromHexString($filtered))).ToLowerInvariant()}
    $scope.Dispose();$scope=$null
    $restricted=Join-Path $full 'system-only';[IO.Directory]::CreateDirectory($restricted) | Out-Null
    $restrictedFile=Join-Path $restricted 'own.bin';[IO.File]::WriteAllBytes($restrictedFile,[Text.Encoding]::ASCII.GetBytes('abc'))
    $directoryInfo=[IO.DirectoryInfo]::new($restricted);$fileInfo=[IO.FileInfo]::new($restrictedFile)
    $oldDirectoryAcl=[IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
    $oldFileAcl=[IO.FileSystemAclExtensions]::GetAccessControl($fileInfo)
    $system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $directoryAcl=[Security.AccessControl.DirectorySecurity]::new();$directoryAcl.SetAccessRuleProtection($true,$false)
    $directoryAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
    $fileAcl=[Security.AccessControl.FileSecurity]::new();$fileAcl.SetAccessRuleProtection($true,$false)
    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
    $backupScope=$null
    try {
        # This changes only fresh own test fixtures, never the image/real WIM.
        [IO.FileSystemAclExtensions]::SetAccessControl($fileInfo,$fileAcl)
        [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo,$directoryAcl)
        $denied=$false;try {[void]@([IO.Directory]::EnumerateFileSystemEntries($restricted))} catch {$denied=$true}
        Check $denied 'own-SYSTEM-only-directory-negative-without-backup-privilege'
        $backupScope=[MiniOsWimMetadata+SecurityPrivilege]::new()
        $names=@([IO.Directory]::EnumerateFileSystemEntries($restricted))
        Check ($names.Count -eq 1 -and $names[0] -ceq $restrictedFile) 'backup-intent-native-directory-enumeration-without-ACL-change'
        $nativeRestricted=[MiniOsWimMetadata]::Read($restricted,'own.bin')
        Check ([uint32][IO.File]::GetAttributes($restrictedFile) -eq $nativeRestricted.Attributes) 'native-attributes-read-of-SYSTEM-only-entry'
        Check ($nativeRestricted.Streams[0].Sha1 -ceq 'a9993e364706816aba3e25717850c26c9cd0d89d') 'backup-intent-read-SYSTEM-only-file-and-streams-without-ACL-change'
        $backupScope.Dispose();$backupScope=$null
        $denied=$false;try {[void]@([IO.Directory]::EnumerateFileSystemEntries($restricted))} catch {$denied=$true}
        Check $denied 'backup-privilege-restored-after-read-scope'
    } finally {
        if ($backupScope) {$backupScope.Dispose()}
        # Mark the captured DACL as modified; an untouched snapshot can make
        # .NET SetAccessControl a no-op. Only these fresh own fixtures change.
        $oldDirectoryAcl.SetSecurityDescriptorBinaryForm($oldDirectoryAcl.GetSecurityDescriptorBinaryForm(),[Security.AccessControl.AccessControlSections]::Access)
        $oldFileAcl.SetSecurityDescriptorBinaryForm($oldFileAcl.GetSecurityDescriptorBinaryForm(),[Security.AccessControl.AccessControlSections]::Access)
        [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo,$oldDirectoryAcl)
        [IO.FileSystemAclExtensions]::SetAccessControl($fileInfo,$oldFileAcl)
    }
    Check (@([IO.Directory]::EnumerateFileSystemEntries($restricted)).Count -eq 1) 'own-restricted-fixture-DACL-restored-and-enumerable-without-backup-privilege'
    $record.passed=$true
} catch { $record.error=$_.Exception.ToString(); $record.passed=$false }
finally {
    if ($scope) { $scope.Dispose() }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    [IO.File]::WriteAllText((Join-Path $full 'result.json'),($record | ConvertTo-Json -Depth 7)+"`n",[Text.UTF8Encoding]::new($false))
}
$record | ConvertTo-Json -Depth 7
if ($record.passed) {exit 0} else {exit 1}
