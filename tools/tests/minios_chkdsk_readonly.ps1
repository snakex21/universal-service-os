#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# Host-only check of a new VHD COPY. Never mount the tested qcow2/raw source
   read/write, never assign a permanent letter and never use repair flags.
   A temporary DOS-device alias suppresses media broadcasts/AutoPlay. #>
[CmdletBinding(DefaultParameterSetName='Raw')]
param(
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory,ParameterSetName='Raw')][string]$RawCopy,
    [Parameter(Mandatory,ParameterSetName='Raw')][uint64]$ExpectedImageBytes,
    [Parameter(Mandatory,ParameterSetName='Raw')][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory,ParameterSetName='Raw')][string]$QemuImg,
    [Parameter(Mandatory,ParameterSetName='Raw')][string]$Out,
    [Parameter(Mandatory,ParameterSetName='Library')][switch]$LibraryOnly,
    [string]$ExpectedManifest,
    [string]$ExpectedWimTreeJsonl,
    [string]$ExpectedWimSecurityJsonl,
    [string]$PreparedVhdResult,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$PreparedVhdResultSha256,
    [ValidateRange(60,3600)][int]$CheckTimeoutSeconds = 300,
    [switch]$FilesOnly
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if (-not [IO.Path]::IsPathFullyQualified($Workspace) -or $workspace.StartsWith('\\') -or $workspace.Length -le 3) {
    throw 'Workspace must be an explicit local application directory, never a drive root or device path'
}
function Assert-Owned([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase) -or $full.Contains(',') -or $full.Contains("`n") -or $full.Contains("`r")) {
        throw 'Only a file below the explicitly selected oracle directory is permitted'
    }
    $walk = $full
    while ($walk) {
        if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point forbidden: $walk"
        }
        $walk = [IO.Path]::GetDirectoryName($walk)
    }
    return $full
}
function Hash-File([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $digest = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($digest.ComputeHash($stream)).ToLowerInvariant() }
    finally { $digest.Dispose(); $stream.Dispose() }
}
function Read-ExpectedManifest([string]$Path) {
    if (-not $Path) { throw '-FilesOnly requires -ExpectedManifest' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\') -or [IO.Path]::GetExtension($full) -ne '.json' -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'A local regular JSON manifest is required' }
    $walk = $full
    while ($walk) {
        if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse point in manifest path' }
        $walk = [IO.Path]::GetDirectoryName($walk)
    }
    # The 1b-1 gate contains150000 files. This is a HOST-only oracle bound,
    # independent of the formatter's measured <=16MiB working set.
    if ((Get-Item -LiteralPath $full).Length -gt 64MB) { throw 'Manifest exceeds the bounded 64 MiB limit' }
    $value = [IO.File]::ReadAllText($full) | ConvertFrom-Json -AsHashtable
    if (-not ($value.files -is [Collections.IDictionary]) -or -not ($value.directories -is [array])) { throw 'Manifest requires files and directories' }
    if ($value.files.Count -gt 200000 -or $value.directories.Count -gt 20000) { throw 'Manifest entry bound exceeded' }
    foreach ($path in @($value.files.Keys) + @($value.directories)) {
        if (-not ($path -is [string]) -or $path.StartsWith('/') -or $path.Contains('\') -or $path.Contains(':') -or $path.Contains([char]0) -or $path.Contains("`r") -or $path.Contains("`n")) { throw 'Invalid relative manifest path' }
        foreach ($segment in $path.Split('/')) {
            if (-not $segment -or $segment -eq '.' -or $segment -eq '..' -or $segment.Length -gt 255) { throw 'Invalid manifest path segment' }
        }
    }
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($directory in $value.directories) {
        if (-not $directories.Add($directory)) { throw 'Duplicate expected directory' }
    }
    foreach ($path in $value.files.Keys) {
        if ($directories.Contains($path) -or $value.files[$path].sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid expected file or SHA-256' }
        [uint64]$size = 0
        if (-not [uint64]::TryParse([string]$value.files[$path].size, [ref]$size)) { throw 'Invalid expected file size' }
    }
    return @{ path=$full; sha256=(Hash-File $full); value=$value }
}
function Compare-ReadonlyTree([string]$Root, $Manifest) {
    # Extended paths retain 255-unit names and paths beyond MAX_PATH.
    $rootPath = '\\?\' + $Root.TrimEnd('\') + '\'
    $options = [IO.EnumerationOptions]::new()
    $options.AttributesToSkip = [IO.FileAttributes]0
    $options.IgnoreInaccessible = $false
    $options.RecurseSubdirectories = $false
    $options.ReturnSpecialDirectories = $false
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $files = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    while ($pending.Count) {
        $current = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current, '*', $options)) {
            $relative = $entry.Substring($rootPath.Length).Replace('\','/')
            $attributes = [IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unexpected reparse point in readonly tree: $relative" }
            if ($attributes -band [IO.FileAttributes]::Directory) {
                if (-not $directories.Add($relative) -or $directories.Count -gt 20000) { throw 'Directory enumeration bound or duplicate exceeded' }
                $pending.Push($entry)
            } else {
                if ($files.ContainsKey($relative) -or $files.Count -ge 200000) { throw 'File enumeration bound or duplicate exceeded' }
                $info = [IO.FileInfo]::new($entry)
                $files.Add($relative, @{ path=$relative; size=[uint64]$info.Length; sha256=(Hash-File $entry) })
            }
        }
    }
    $expectedFiles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($name in $Manifest.files.Keys) { $expectedFiles.Add($name, $Manifest.files[$name]) }
    $expectedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Manifest.directories) { [void]$expectedDirectories.Add($name) }
    $missing = [Collections.Generic.List[string]]::new()
    $extra = [Collections.Generic.List[string]]::new()
    $different = [Collections.Generic.List[string]]::new()
    foreach ($name in $expectedFiles.Keys) {
        if (-not $files.ContainsKey($name)) { $missing.Add('file:' + $name); continue }
        $actual = $files[$name]; $expected = $expectedFiles[$name]
        if ($actual.size -ne [uint64]$expected.size -or $actual.sha256 -cne ([string]$expected.sha256).ToLowerInvariant()) { $different.Add($name) }
    }
    foreach ($name in $files.Keys) { if (-not $expectedFiles.ContainsKey($name)) { $extra.Add('file:' + $name) } }
    foreach ($name in $expectedDirectories) { if (-not $directories.Contains($name)) { $missing.Add('dir:' + $name) } }
    foreach ($name in $directories) { if (-not $expectedDirectories.Contains($name)) { $extra.Add('dir:' + $name) } }
    $orderedFiles = @($files.Keys); [Array]::Sort($orderedFiles, [StringComparer]::Ordinal)
    $orderedDirectories = @($directories); [Array]::Sort($orderedDirectories, [StringComparer]::Ordinal)
    return @{ passed=($missing.Count -eq 0 -and $extra.Count -eq 0 -and $different.Count -eq 0); file_count=$files.Count; directory_count=$directories.Count; missing=@($missing); extra=@($extra); different=@($different); files=@($orderedFiles | ForEach-Object { $files[$_] }); directories=$orderedDirectories; comparison='exact case-sensitive UTF-16 paths, file sizes and streamed SHA-256'; writes_to_volume=$false }
}
function Assert-WimRow($Row) {
    if (-not ($Row -is [Collections.IDictionary]) -or -not ($Row.path -is [string]) -or -not ($Row.directory -is [bool]) -or -not ($Row.streams -is [array])) { throw 'Malformed WIM tree row' }
    $name = $Row.path
    if ($name.StartsWith('/') -or $name.Contains('\') -or $name.Contains(':') -or $name.Contains([char]0) -or $name.Contains("`r") -or $name.Contains("`n")) { throw 'Unsafe WIM tree path' }
    if ($name) { foreach ($part in $name.Split('/')) { if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part.Length -gt 255) { throw 'Unsafe WIM path component' } } }
    foreach ($field in @('creation_filetime','modified_filetime','accessed_filetime','hardlink_group_id')) {
        [uint64]$number = 0
        if (-not [uint64]::TryParse([string]$Row[$field], [ref]$number)) { throw "Invalid WIM integer: $field" }
    }
    if ($null -ne $Row.changed_filetime) {
        [uint64]$changed=0
        if (-not [uint64]::TryParse([string]$Row.changed_filetime,[ref]$changed)) { throw 'Invalid explicit changed FILETIME' }
    }
    [uint32]$attribute = 0; [uint32]$links = 0; [uint32]$tag = 0
    if (-not [uint32]::TryParse([string]$Row.attributes,[ref]$attribute) -or -not [uint32]::TryParse([string]$Row.link_count,[ref]$links) -or $links -eq 0 -or -not [uint32]::TryParse([string]$Row.reparse_tag,[ref]$tag)) { throw 'Invalid WIM attribute/link/tag' }
    if ($Row.security_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'WIM security descriptor SHA256 required' }
    if ($Row.streams.Count -eq 0 -or $Row.streams.Count -gt 1025) { throw 'WIM stream bound exceeded' }
    $streamNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($i=0; $i -lt $Row.streams.Count; $i++) {
        $stream=$Row.streams[$i]; [uint64]$length=0
        if ($stream.sha1 -notmatch '^[0-9a-f]{40}$' -or -not [uint64]::TryParse([string]$stream.size,[ref]$length) -or $length -gt 100GB) { throw 'Invalid/bounded WIM stream size/hash' }
        if ($i -eq 0) { if ($null -ne $stream.name) { throw 'First WIM stream must be unnamed' }; continue }
        if (-not ($stream.name -is [string]) -or -not $stream.name -or $stream.name.IndexOfAny([char[]]":/\`0`r`n") -ge 0 -or -not $streamNames.Add($stream.name)) { throw 'Invalid or duplicated WIM ADS name' }
    }
}
function Read-WimManifest([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $full.StartsWith('\\') -or [IO.Path]::GetExtension($full) -ne '.jsonl' -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'A local regular WIM JSONL manifest is required' }
    $walk=$full
    while ($walk) {
        if ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in WIM manifest path' }
        $walk=[IO.Path]::GetDirectoryName($walk)
    }
    if ((Get-Item -LiteralPath $full).Length -gt 512MB) { throw 'WIM manifest exceeds bounded host size' }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $reader=[IO.File]::OpenText($full)
    try {
        while ($null -ne ($line=$reader.ReadLine())) {
            if ($line.Length -gt 2MB -or $seen.Count -ge 1000000) { throw 'WIM metadata bound exceeded' }
            $row=ConvertFrom-Json -AsHashtable $line
            Assert-WimRow $row
            if (-not $seen.Add($row.path)) { throw 'Duplicate WIM manifest path' }
        }
    } finally { $reader.Dispose() }
    if (-not $seen.Contains('')) { throw 'WIM manifest must include the root' }
    return @{ path=$full; sha256=(Hash-File $full); count=$seen.Count }
}
function Read-WimSecurity([string]$Path) {
    if (-not $Path) { throw 'WIM tree acceptance requires -ExpectedWimSecurityJsonl and the independent raw SD gate' }
    $full=[IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $full.StartsWith('\\') -or [IO.Path]::GetExtension($full) -ne '.jsonl' -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'A local regular security JSONL manifest is required' }
    $walk=$full
    while ($walk) {
        if ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in security manifest path' }
        $walk=[IO.Path]::GetDirectoryName($walk)
    }
    if ((Get-Item -LiteralPath $full).Length -gt 64MB) { throw 'Security manifest exceeds bounded host size' }
    $values=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $reader=[IO.File]::OpenText($full)
    try {
        while ($null -ne ($line=$reader.ReadLine())) {
            if ($line.Length -gt 2MB -or $values.Count -ge 200000) { throw 'Security descriptor count/size bound exceeded' }
            $row=ConvertFrom-Json -AsHashtable $line
            [uint32]$size=0
            if ($row.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $row.hex -cnotmatch '^([0-9a-f]{2}){20,1048576}$' -or -not [uint32]::TryParse([string]$row.bytes,[ref]$size) -or $size*2 -ne $row.hex.Length -or $values.ContainsKey($row.sha256)) { throw 'Invalid or duplicate expected raw SD' }
            $raw=[Convert]::FromHexString($row.hex)
            $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
            if ($hash -cne $row.sha256) { throw 'Expected raw SD SHA256 differs' }
            $values.Add($hash,$row.hex)
        }
    } finally { $reader.Dispose() }
    if ($values.Count -eq 0) { throw 'Security manifest is empty' }
    return @{path=$full; sha256=(Hash-File $full); values=$values}
}
function Compare-WimTree([string]$Root, $Manifest, [string]$Evidence, $SecurityTable=$null, $RawAttributeProof=$null) {
    if (-not ('MiniOsWimMetadata' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot '../minios/wim_ntfs_metadata.cs')
    }
    # .NET enumeration opens with BACKUP_SEMANTICS; enable backup read before
    # even the first directory open, and restore both token privileges on errors.
    $privilege=[MiniOsWimMetadata+SecurityPrivilege]::new()
    try {
    $rootPath='\\?\'+$Root.TrimEnd('\')+'\'
    $options=[IO.EnumerationOptions]::new()
    $options.AttributesToSkip=[IO.FileAttributes]0; $options.IgnoreInaccessible=$false
    $options.RecurseSubdirectories=$false; $options.ReturnSpecialDirectories=$false
    $pending=[Collections.Generic.Stack[string]]::new(); $pending.Push($rootPath)
    $actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); [void]$actual.Add('')
    while ($pending.Count) {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop(),'*',$options)) {
            $name=$entry.Substring($rootPath.Length).Replace('\','/')
            if ($actual.Count -ge 1000000 -or -not $actual.Add($name)) { throw 'Actual WIM target tree bound/duplicate' }
            $attrs=[IO.File]::GetAttributes($entry)
            # Never traverse reparse targets, including absolute/root-relative junctions.
            if (($attrs -band [IO.FileAttributes]::Directory) -and -not ($attrs -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($entry) }
        }
    }
    $actualCount=$actual.Count; $checked=0; $shortNames=0; $secondaryShortNames=0; $differences=0; $missing=0; $readErrors=0; $reorderedSd=0
    $normalPaths=[Collections.Generic.List[string]]::new()
    $rawZeroPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rawRoot=$null; $rootPolicyApplied=$false
    if ($RawAttributeProof -and $RawAttributeProof.passed -eq $true -and $RawAttributeProof.raw_zero_attributes_pass -eq $true -and $RawAttributeProof.expected_tree_sha256 -ceq $Manifest.sha256) {
        foreach ($rawPath in $RawAttributeProof.zero_attribute_paths) { [void]$rawZeroPaths.Add([string]$rawPath) }
        $rawRoot=$RawAttributeProof.root_reserved_metadata
    }
    $samples=[Collections.Generic.List[string]]::new()
    $groups=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $reverse=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $reader=[IO.File]::OpenText($Manifest.path)
    $writer=[IO.StreamWriter]::new([IO.File]::Open($Evidence,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read),[Text.UTF8Encoding]::new($false))
    try {
        while ($null -ne ($line=$reader.ReadLine())) {
            $row=ConvertFrom-Json -AsHashtable $line; Assert-WimRow $row
            $name=[string]$row.path
            if (-not $actual.Remove($name)) { $missing++; if ($samples.Count -lt 100) { $samples.Add('missing:'+ $name) }; continue }
            try { $native=[MiniOsWimMetadata]::Read($Root,$name) }
            catch {
                # An unreadable file is a failed comparison, not permission to
                # skip metadata or declare success from chkdsk alone. Continue
                # only independent RO reads so the same completed case supplies
                # the remaining feature errors and actual chkdsk result.
                $reason=$_.Exception.Message
                $readErrors++; $differences++; $checked++
                if ($samples.Count -lt 100) { $samples.Add($name+':read-error:'+ $reason) }
                $writer.WriteLine((@{path=$name; read_error=$reason; passed=$false} | ConvertTo-Json -Compress))
                continue
            }
            $bad=[Collections.Generic.List[string]]::new()
            $rootReserved=($name -ceq '' -and $row.directory -eq $true -and $rawRoot -and $rawRoot.passed -eq $true -and $rawRoot.path -ceq '' -and $rawRoot.record -eq 5 -and $rawRoot.directory -eq $true -and $rawRoot.source_attributes -eq [uint32]$row.attributes -and $rawRoot.root_reserved_metadata_flags -eq 6 -and $rawRoot.raw_si_attributes -eq (([uint32]$row.attributes -band [uint32]4294967279) -bor 6) -and @($rawRoot.raw_filename_attributes).Count -eq 1 -and $rawRoot.raw_filename_attributes[0] -eq (([uint32]$row.attributes -band [uint32]4294967279) -bor [uint32]268435462))
            $expectedNativeAttrs=if ($rootReserved) { [uint32]$row.attributes -bor 6 } else { [uint32]$row.attributes }
            if ($rootReserved) { $rootPolicyApplied=$true }
            $normalSynthesized=([uint32]$row.attributes -eq 0 -and $row.directory -eq $false -and [uint32]$native.Attributes -eq 0x80 -and $rawZeroPaths.Contains($name))
            if ($normalSynthesized) { $normalPaths.Add($name) }
            elseif ([uint32]$native.Attributes -ne $expectedNativeAttrs) { $bad.Add('attributes') }
            $changed=if ($null -ne $row.changed_filetime) { [uint64]$row.changed_filetime } else { [uint64]$row.modified_filetime }
            if ($native.Created -ne [uint64]$row.creation_filetime -or $native.Modified -ne [uint64]$row.modified_filetime -or $native.Accessed -ne [uint64]$row.accessed_filetime -or $native.Changed -ne $changed) { $bad.Add('FILETIME') }
            $securityDifferent=$native.SecuritySha256 -cne $row.security_sha256
            $sdComparison=$null
            if ($SecurityTable) {
                if (-not $SecurityTable.values.ContainsKey($row.security_sha256)) { throw 'Tree SD absent from independently pinned security manifest' }
                $sdComparison=[MiniOsWimMetadata]::CompareSecurityHex($SecurityTable.values[$row.security_sha256],$native.SecurityHex)
                if (-not $sdComparison.Passed) { $bad.Add('security-sections:'+ $sdComparison.Reason) }
                elseif ($sdComparison.ApiReorderedSd) { $reorderedSd++ }
            } elseif ($securityDifferent) { $bad.Add('raw-security-descriptor') }
            if ($native.Links -ne [uint32]$row.link_count) { $bad.Add('link-count') }
            if ($native.ReparseTag -ne [uint32]$row.reparse_tag) { $bad.Add('reparse-tag') }
            $group=if ([uint64]$row.link_count -gt 1) { 'group:'+ [string]$row.hardlink_group_id } else { 'single:'+ $name }
            if ($groups.ContainsKey($group)) { if ($groups[$group] -cne $native.FileId) { $bad.Add('hardlink-split') } } else { $groups.Add($group,$native.FileId) }
            if ($reverse.ContainsKey($native.FileId)) { if ($reverse[$native.FileId] -cne $group) { $bad.Add('unexpected-hardlink') } } else { $reverse.Add($native.FileId,$group) }
            $streams=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
            foreach ($stream in $native.Streams) { $streams.Add([string]$stream.Name,$stream) }
            if ($streams.Count -ne $row.streams.Count) { $bad.Add('stream-count') }
            foreach ($expected in $row.streams) {
                $streamName=[string]$expected.name
                if (-not $streams.ContainsKey($streamName)) { $bad.Add('stream-missing:'+ $streamName); continue }
                $stream=$streams[$streamName]
                $zeroSentinel=([uint64]$expected.size -eq 0 -and $expected.sha1 -ceq ('0'*40))
                if ($stream.Size -ne [uint64]$expected.size -or (-not $zeroSentinel -and $stream.Sha1 -cne $expected.sha1)) { $bad.Add('stream-content:'+ $streamName) }
            }
            if ($row.short_name) {
                $shortNames++
                try { if ([MiniOsWimMetadata]::ShortName($Root,$name) -ine $row.short_name) { $bad.Add('short-name') } }
                catch { $bad.Add('short-name-read:'+ $_.Exception.Message) }
            }
            if ($row.source_short_name -and $row.short_name_index_created -eq $false) {
                $secondaryShortNames++
                try { if ($null -ne [MiniOsWimMetadata]::ShortName($Root,$name)) { $bad.Add('secondary-short-name-not-absent') } }
                catch { $bad.Add('secondary-short-name-read:'+$_.Exception.Message) }
            }
            if ($row.object_id_hex) {
                try { if ([MiniOsWimMetadata]::ObjectId($Root,$name) -cne $row.object_id_hex) { $bad.Add('object-id') } }
                catch { $bad.Add('object-id-read:'+ $_.Exception.Message) }
            }
            if ($row.ea_wim_hex) {
                try { if ([MiniOsWimMetadata]::ExtendedAttributes($Root,$name) -cne [MiniOsWimMetadata]::ExpectedEa($row.ea_wim_hex)) { $bad.Add('extended-attributes') } }
                catch { $bad.Add('extended-attributes-read:'+ $_.Exception.Message) }
            }
            if ($bad.Count) { $differences++; if ($samples.Count -lt 100) { $samples.Add($name+':'+($bad -join ',')) } }
            $writer.WriteLine((@{ path=$name; attributes=$native.Attributes; expected_attributes=$row.attributes; expected_native_attributes=$expectedNativeAttrs; root_reserved_metadata_flags=$(if ($rootReserved) {6} else {0}); root_reserved_metadata_proven=$rootReserved; api_synthesized_normal=$normalSynthesized; raw_zero_attributes_proven=$rawZeroPaths.Contains($name); creation_filetime=$native.Created; modified_filetime=$native.Modified; accessed_filetime=$native.Accessed; changed_filetime=$native.Changed; security_sha256=$native.SecuritySha256; expected_security_sha256=$row.security_sha256; api_reordered_sd=[bool]($sdComparison -and $sdComparison.ApiReorderedSd); api_security_sections_exact=$(if ($sdComparison) {$sdComparison.Passed} else {-not $securityDifferent}); security_hex_if_different=$(if ($securityDifferent) {$native.SecurityHex} else {$null}); file_id=$native.FileId; link_count=$native.Links; reparse_tag=$native.ReparseTag; streams=$native.Streams; different=@($bad) } | ConvertTo-Json -Compress -Depth 6))
            $checked++
        }
    } finally { $writer.Dispose(); $reader.Dispose() }
    return @{ passed=($missing -eq 0 -and $actual.Count -eq 0 -and $differences -eq 0 -and $checked -eq $Manifest.count); expected_entries=$Manifest.count; actual_entries=$actualCount; checked_entries=$checked; missing_count=$missing; extra_count=$actual.Count; different_count=$differences; read_error_count=$readErrors; api_reordered_sd_count=$reorderedSd; root_reserved_metadata_applied=$rootPolicyApplied; root_reserved_metadata_flags=$(if ($rootPolicyApplied) {6} else {0}); api_synthesized_normal_count=$normalPaths.Count; api_synthesized_normal_paths=@($normalPaths); attribute_comparison='root path empty/MFT5 only: source attrs OR reserved6 under exact raw SI/FN proof; other paths exact, with independently raw-proven regular0/API128 NORMAL separately logged'; difference_samples=@($samples); actual_metadata_jsonl=$Evidence; short_8_3_names_checked=$shortNames; short_8_3_secondary_absences_checked=$secondaryShortNames; short_8_3_creation_claim=$true; reparse_comparison='independent expected post-RP_FIX data SHA1/tag; no target traversal'; changed_time_policy='explicit fixture changedTime if present; otherwise WIM modifiedTime'; security_comparison=$(if ($SecurityTable) {'validated revision/control/RMcontrol and exact SID/ACL sections; raw on-disk SD gate required separately'} else {'native full raw self-relative descriptor SHA256 including SACL'}); writes_to_volume=$false }
    } finally { $privilege.Dispose() }
}
if ($LibraryOnly) { return }
$expectedTree = if ($ExpectedManifest) { Read-ExpectedManifest $ExpectedManifest } else { $null }
$expectedWim = if ($ExpectedWimTreeJsonl) { Read-WimManifest $ExpectedWimTreeJsonl } else { $null }
$expectedSecurity = if ($expectedWim) { Read-WimSecurity $ExpectedWimSecurityJsonl } else { $null }
if ($ExpectedWimSecurityJsonl -and -not $expectedWim) { throw 'Security sidecar requires the WIM tree' }
if ($expectedTree -and $expectedWim) { throw 'Select one independent tree oracle' }
if ($FilesOnly -and -not ($expectedTree -or $expectedWim)) { throw '-FilesOnly requires -ExpectedManifest or -ExpectedWimTreeJsonl' }
$RawCopy = Assert-Owned $RawCopy
$Out = Assert-Owned $Out
if ([IO.Path]::GetExtension($RawCopy) -ne '.raw' -or -not (Test-Path -LiteralPath $RawCopy -PathType Leaf)) { throw 'A raw test COPY is required' }
if ($ExpectedImageBytes -lt 64MB -or $ExpectedImageBytes % 512 -ne 0 -or (Get-Item -LiteralPath $RawCopy).Length -ne $ExpectedImageBytes) { throw 'Exact expected image size differs or is invalid' }
if (-not ((Get-Item -LiteralPath $RawCopy).Attributes -band [IO.FileAttributes]::ReadOnly)) { throw 'The source copy must carry the read-only attribute' }
if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($RawCopy)).AvailableFreeSpace -lt (100GB + 2 * $ExpectedImageBytes + 1MB)) { throw 'VHD copies would violate the 100 GiB workspace volume reserve' }
if (Test-Path -LiteralPath $Out) { throw 'Never overwrite a previous scan run' }
if ((Hash-File $RawCopy) -ne $ExpectedSha256) { throw 'Raw copy SHA-256 differs' }
if ([bool]$PreparedVhdResult -ne [bool]$PreparedVhdResultSha256) { throw 'Prepared VHD requires both immutable prior result and SHA256' }
$prepared=$null
if ($PreparedVhdResult) {
    $priorPath=Assert-Owned $PreparedVhdResult
    if ([IO.Path]::GetExtension($priorPath) -ne '.json' -or -not (Test-Path -LiteralPath $priorPath -PathType Leaf) -or (Get-Item -LiteralPath $priorPath).Length -gt 1MB -or (Hash-File $priorPath) -cne $PreparedVhdResultSha256) { throw 'Prepared VHD result path/hash/size differs' }
    $prior=[IO.File]::ReadAllText($priorPath) | ConvertFrom-Json -AsHashtable
    if (-not [string]::Equals($prior.source,$RawCopy,[StringComparison]::OrdinalIgnoreCase) -or $prior.image_bytes -ne $ExpectedImageBytes -or $prior.source_sha256_before -cne $ExpectedSha256 -or $prior.source_sha256_after -cne $ExpectedSha256 -or $prior.convert_exit -ne 0 -or $prior.dismounted -ne $true -or ($prior.drive_letter_assigned -eq $true -and $prior.temporary_dos_alias_removed -ne $true)) { throw 'Prepared VHD receipt does not prove this exact closed source/closure' }
    $priorVhd=Assert-Owned ([string]$prior.vhd)
    if ([IO.Path]::GetExtension($priorVhd) -ne '.vhd' -or -not (Test-Path -LiteralPath $priorVhd -PathType Leaf) -or $prior.vhd_sha256_before -cnotmatch '^[0-9a-f]{64}$' -or $prior.vhd_sha256_before -cne $prior.vhd_sha256_after -or $prior.intermediate_sha256 -cne $prior.vhd_sha256_before) { throw 'Prepared VHD pin does not match completed conversion/copy' }
    $info=Get-Item -LiteralPath $priorVhd -Force
    $badAttrs=[IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted
    if ($info.Length -ne $ExpectedImageBytes+512 -or -not ($info.Attributes -band [IO.FileAttributes]::ReadOnly) -or ($info.Attributes -band $badAttrs) -or (Hash-File $priorVhd) -cne $prior.vhd_sha256_before) { throw 'Prepared VHD actual bytes/hash/readonly/ordinary attributes differ' }
    $footer=[byte[]]::new(512);$check=[IO.File]::OpenRead($priorVhd)
    try {[void]$check.Seek(-512,[IO.SeekOrigin]::End);$check.ReadExactly($footer,0,512)} finally {$check.Dispose()}
    if ([Text.Encoding]::ASCII.GetString($footer,0,8) -cne 'conectix' -or [Convert]::ToHexString([byte[]]($footer[60..63])) -cne '00000002') { throw 'Prepared VHD must remain fixed format' }
    $prepared=@{path=$priorPath;sha256=$PreparedVhdResultSha256;vhd=$priorVhd;vhd_sha256=$prior.vhd_sha256_before}
}
[IO.Directory]::CreateDirectory($Out) | Out-Null
$vhd = Join-Path $Out 'readonly-copy.vhd'
if ($prepared) {$vhd=$prepared.vhd}
$intermediate = Join-Path $Out 'converted-fixed.vhd'
$record = [ordered]@{ kind='windows-readonly-chkdsk'; passed=$false; source=$RawCopy; source_sha256_before=$ExpectedSha256; image_bytes=$ExpectedImageBytes; vhd=$vhd; access='ReadOnly'; drive_letter_assigned=$false; chkdsk_flags=@(); repair_flags_used=$false }
$record.chkdsk_issued = $false
$record.readonly_chkdsk_pass = $false
if ($FilesOnly) { $record.kind = 'windows-readonly-file-read' }
if ($expectedTree) {
    $record.manifest = $expectedTree.path
    $record.manifest_sha256_before = $expectedTree.sha256
    $record.readonly_file_tree_pass = $false
}
if ($expectedWim) {
    $record.wim_manifest = $expectedWim.path
    $record.wim_manifest_sha256_before = $expectedWim.sha256
    $record.readonly_wim_tree_pass = $false
    $record.wim_security_manifest=$expectedSecurity.path
    $record.wim_security_manifest_sha256_before=$expectedSecurity.sha256
    $record.raw_security_pass=$false
}
$mounted = $false
$preparedVhdLock=$null;$priorResultLock=$null
$driveAlias = $null
$driveTarget = $null
$runtime = Join-Path $Out 'host-runtime'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$savedEnvironment = @{}
foreach ($name in @('APPDATA','LOCALAPPDATA','TMP','TEMP')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $runtime, 'Process')
}
try {
    if ($prepared) {
        $priorResultLock=[IO.File]::Open($prepared.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $preparedVhdLock=[IO.File]::Open($vhd,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ((Hash-File $prepared.path) -cne $prepared.sha256 -or (Hash-File $vhd) -cne $prepared.vhd_sha256) {throw 'Prepared VHD/result changed before locked reuse'}
        $record.prepared_vhd_result=$prepared.path;$record.prepared_vhd_result_sha256_before=$prepared.sha256
        $record.prepared_vhd_reused=$true;$record.no_new_vhd_created=$true
    }
    if ($expectedWim) {
        # Separate read-only parser of the closed raw bytes. It never mounts,
        # imports the writer or rewrites expected SDs. Completion is blocking.
        $securityOut=Join-Path $Out 'raw-security.json'
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=(Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach ($arg in @('-I','-B',(Join-Path $PSScriptRoot '../minios/wim_security_readonly.py'),'--raw',$RawCopy,'--sha256',$ExpectedSha256,'--expected-security',$expectedSecurity.path,'--tree',$expectedWim.path,'--out',$securityOut)) { $start.ArgumentList.Add($arg) }
        $child=[Diagnostics.Process]::Start($start)
        try {
            $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(3600000)) { $child.Kill(); $child.WaitForExit(); throw 'Independent raw security oracle exceeded one hour' }
            [IO.File]::WriteAllText((Join-Path $Out 'raw-security-stdout.txt'),$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Out 'raw-security-stderr.txt'),$stderr.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
            if (-not (Test-Path -LiteralPath $securityOut -PathType Leaf)) { throw 'Independent raw security oracle did not complete' }
            $rawProof=[IO.File]::ReadAllText($securityOut) | ConvertFrom-Json -AsHashtable
            if ($rawProof.source_sha256 -cne $ExpectedSha256 -or $rawProof.expected_tree_sha256 -cne $expectedWim.sha256 -or $rawProof.expected_security_sha256 -cne $expectedSecurity.sha256) { throw 'Raw security receipt does not bind these exact inputs' }
            $record.raw_security_pass=$child.ExitCode -eq 0 -and $rawProof.passed -eq $true -and $rawProof.source_unchanged -eq $true -and $rawProof.expected_metadata_unchanged -eq $true
            $record.raw_security_receipt=$securityOut
        } finally { $child.Dispose() }
    }
    if (-not $prepared) {
    $convertOutput = & $QemuImg convert -f raw -O vpc -o subformat=fixed,force_size=on $RawCopy $intermediate 2>&1
    $convertExit = $LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $Out 'convert.txt'), ($convertOutput -join "`n"), [Text.UTF8Encoding]::new($false))
    $record.convert_exit = $convertExit
    if ($convertExit -ne 0 -or -not (Test-Path -LiteralPath $intermediate -PathType Leaf)) { throw 'qemu-img conversion failed' }
    # The Windows QEMU file backend marks even fixed VHDs SparseFile.
    # Stream to a freshly created ordinary file; do not change filesystem
    # attributes or sparse state on any existing source image.
    $from = [IO.File]::OpenRead($intermediate)
    $to = [IO.File]::Open($vhd, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $buffer = [byte[]]::new(1MB)
        while (($count = $from.Read($buffer, 0, $buffer.Length)) -gt 0) { $to.Write($buffer, 0, $count) }
        $to.Flush($true)
    } finally { $to.Dispose(); $from.Dispose() }
    $record.intermediate_sha256 = Hash-File $intermediate
    $record.vhd_sha256_before = Hash-File $vhd
    if ($record.intermediate_sha256 -ne $record.vhd_sha256_before) { throw 'Ordinary VHD copy differs' }
    $unsupported = [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted
    if ((Get-Item -LiteralPath $vhd).Attributes -band $unsupported) { throw 'VHD destination has unsupported host filesystem attributes' }
    (Get-Item -LiteralPath $vhd).IsReadOnly = $true
    } else {$record.vhd_sha256_before=Hash-File $vhd}
    $image = Mount-DiskImage -ImagePath $vhd -Access ReadOnly -NoDriveLetter -PassThru -ErrorAction Stop
    if ($null -eq $image) { throw 'Mount-DiskImage returned no image' }
    $mounted = $true
    # Synchronize the Storage provider's enumeration after attachment; no
    # retry/status loop and no modification of any physical disk.
    Update-HostStorageCache -ErrorAction Stop
    $disk = $image | Get-Disk -ErrorAction Stop
    if ($null -eq $disk) { throw 'No disk belongs to the attached image' }
    $record.disk_number = $disk.Number
    $record.bus_type = $disk.BusType.ToString()
    $record.disk_is_readonly = $disk.IsReadOnly
    $record.disk_is_offline = $disk.IsOffline
    if ($disk.IsSystem -or $disk.IsBoot -or -not $disk.IsReadOnly -or $disk.Size -ne (Get-Item -LiteralPath $RawCopy).Length -or ($disk.BusType.ToString() -replace ' ', '') -ne 'FileBackedVirtual') {
        throw 'Mounted image did not satisfy the read-only file-backed non-system guard'
    }
    $partitions = @(Get-Partition -DiskNumber $disk.Number)
    $record.partitions = @($partitions | Select-Object PartitionNumber,Type,GptType,Offset,Size)
    $volumes = @($partitions | Get-Volume)
    if ($volumes.Count -ne 1) { throw 'Exactly one volume must belong to this image' }
    $volume = $volumes[0]
    $record.filesystem = $volume.FileSystem
    $record.filesystem_type = $volume.FileSystemType.ToString()
    if ($volume.DriveLetter) { throw 'Unexpected drive letter assigned to the image' }
    if ($volume.Path -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') { throw 'Unexpected volume GUID path' }
    $record.volume = $volume.Path
    if ($partitions.Count -ne 1) { throw 'A single target partition is required' }
    $sourceStream = [IO.File]::OpenRead($RawCopy)
    try {
        $boot = [byte[]]::new(512)
        if ($partitions[0].Offset + 512 -gt $ExpectedImageBytes) { throw 'Partition boot sector lies outside the image' }
        [void]$sourceStream.Seek([long]$partitions[0].Offset, [IO.SeekOrigin]::Begin)
        $sourceStream.ReadExactly($boot, 0, $boot.Length)
        if ([Text.Encoding]::ASCII.GetString($boot,3,8) -cne 'NTFS    ' -or $boot[510] -ne 0x55 -or $boot[511] -ne 0xaa) { throw 'The target image partition lacks the NTFS boot signature' }
        $record.source_ntfs_boot_signature = $true
    } finally { $sourceStream.Dispose() }
    if (-not ('MiniOsOracleDos' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MiniOsOracleDos {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern IntPtr CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
 [DllImport("kernel32.dll", SetLastError=true)]
 static extern bool DeviceIoControl(IntPtr handle, uint code, IntPtr input, uint inputLength, byte[] output, uint outputLength, out uint returned, IntPtr overlapped);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 public static uint DiskNumber(string alias) {
   IntPtr h=CreateFile(@"\\.\"+alias, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
   if(h==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   try {
     byte[] b=new byte[12]; uint returned;
     if(!DeviceIoControl(h,0x002D1080,IntPtr.Zero,0,b,12,out returned,IntPtr.Zero) || returned!=12)
       throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
     if(BitConverter.ToUInt32(b,0)!=7) throw new InvalidOperationException("Alias is not a disk device");
     return BitConverter.ToUInt32(b,4);
   } finally { CloseHandle(h); }
 }
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern uint QueryDosDevice(string name, StringBuilder target, uint length);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern bool DefineDosDevice(uint flags, string name, string target);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern bool GetVolumeInformation(string root, IntPtr name, uint nameLength,
   out uint serial, out uint maximum, out uint flags, StringBuilder filesystem, uint filesystemLength);
}
'@
    }
    $buffer = [Text.StringBuilder]::new(32768)
    $dosVolumeName = $volume.Path.Substring(4).TrimEnd('\')
    if (-not [MiniOsOracleDos]::QueryDosDevice($dosVolumeName, $buffer, $buffer.Capacity)) { throw 'Cannot resolve this image volume to its native device' }
    $driveTarget = $buffer.ToString().Split([char]0)[0]
    foreach ($letter in @('Z:','Y:','X:','W:','V:','U:','T:','S:','R:')) {
        $existing = [Text.StringBuilder]::new(32768)
        if ([MiniOsOracleDos]::QueryDosDevice($letter, $existing, $existing.Capacity)) { continue }
        if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 2) { continue }
        # RAW_TARGET_PATH | NO_BROADCAST_SYSTEM: no persistent MountManager
        # letter, registry configuration or media/AutoPlay broadcast.
        if (-not [MiniOsOracleDos]::DefineDosDevice(9, $letter, $driveTarget)) { throw 'Temporary DOS alias creation failed' }
        $driveAlias = $letter
        break
    }
    if (-not $driveAlias) { throw 'No unused temporary DOS drive name is available' }
    $verifiedAlias = [Text.StringBuilder]::new(32768)
    if (-not [MiniOsOracleDos]::QueryDosDevice($driveAlias, $verifiedAlias, $verifiedAlias.Capacity) -or $verifiedAlias.ToString().Split([char]0)[0] -ne $driveTarget) { throw 'Temporary alias does not resolve to this image volume' }
    $record.drive_letter_assigned = $true
    $record.temporary_dos_alias = $driveAlias
    $record.no_media_broadcast = $true
    if (-not (Get-Disk -Number $disk.Number).IsReadOnly) { throw 'Virtual disk lost its read-only state' }
    $fsName = [Text.StringBuilder]::new(64)
    [uint32]$serial = 0; [uint32]$maximum = 0; [uint32]$flags = 0
    $nativeInfo = [MiniOsOracleDos]::GetVolumeInformation($driveAlias + '\', [IntPtr]::Zero, 0, [ref]$serial, [ref]$maximum, [ref]$flags, $fsName, $fsName.Capacity)
    $record.native_filesystem = $fsName.ToString()
    if (-not $nativeInfo) { $record.native_volume_error = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
    if ($expectedTree) {
        if (-not $nativeInfo -or $fsName.ToString() -cne 'NTFS') { throw 'Native Windows volume information did not identify NTFS; refusing file-tree acceptance' }
        $verifiedAlias.Clear() | Out-Null
        if (-not [MiniOsOracleDos]::QueryDosDevice($driveAlias, $verifiedAlias, $verifiedAlias.Capacity) -or $verifiedAlias.ToString().Split([char]0)[0] -ne $driveTarget) { throw 'Temporary alias changed before readonly tree enumeration' }
        $record.file_tree = Compare-ReadonlyTree ($driveAlias + '\') $expectedTree.value
        $record.readonly_file_tree_pass = $record.file_tree.passed
        $record.passed = $record.file_tree.passed
    }
    if ($expectedWim) {
        if (-not $nativeInfo -or $fsName.ToString() -cne 'NTFS') { throw 'Native Windows volume information did not identify NTFS; refusing WIM acceptance' }
        $verifiedAlias.Clear() | Out-Null
        if (-not [MiniOsOracleDos]::QueryDosDevice($driveAlias, $verifiedAlias, $verifiedAlias.Capacity) -or $verifiedAlias.ToString().Split([char]0)[0] -ne $driveTarget) { throw 'Temporary alias changed before readonly WIM metadata enumeration' }
        try { $record.wim_tree = Compare-WimTree ($driveAlias + '\') $expectedWim (Join-Path $Out 'wim-native-metadata.jsonl') $expectedSecurity $rawProof }
        catch { $record.wim_tree=@{passed=$false;enumeration_or_metadata_error=$_.Exception.Message;writes_to_volume=$false} }
        $record.readonly_wim_tree_pass = $record.wim_tree.passed
        $record.passed = $record.wim_tree.passed -and $record.raw_security_pass
    }
    if (-not $FilesOnly) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'chkdsk.exe'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $start.StandardErrorEncoding = $start.StandardOutputEncoding
    $start.ArgumentList.Add($driveAlias)
    $verifiedAlias.Clear() | Out-Null
    if (-not [MiniOsOracleDos]::QueryDosDevice($driveAlias, $verifiedAlias, $verifiedAlias.Capacity) -or $verifiedAlias.ToString().Split([char]0)[0] -ne $driveTarget) { throw 'Temporary alias changed before chkdsk' }
    # Resolve the ACTUAL drive argument through a read-only IOCTL immediately
    # before chkdsk. Checking an unrelated mounted image is insufficient.
    $aliasDiskNumber = [MiniOsOracleDos]::DiskNumber($driveAlias)
    $aliasDisk = Get-Disk -Number $aliasDiskNumber -ErrorAction Stop
    $imageDisk = Get-DiskImage -ImagePath $vhd -ErrorAction Stop | Get-Disk -ErrorAction Stop
    if ($aliasDiskNumber -ne $disk.Number -or $imageDisk.Number -ne $aliasDiskNumber -or
        $aliasDisk.Size -ne $ExpectedImageBytes -or $aliasDisk.IsSystem -or $aliasDisk.IsBoot -or
        -not $aliasDisk.IsReadOnly -or ($aliasDisk.BusType.ToString() -replace ' ', '') -ne 'FileBackedVirtual') {
        throw 'The chkdsk drive argument is not the exact read-only virtual image disk'
    }
    $record.chkdsk_target_guard = @{ passed=$true; alias=$driveAlias; disk_number=$aliasDiskNumber; expected_image_bytes=$ExpectedImageBytes; actual_disk_bytes=$aliasDisk.Size; bus_type=$aliasDisk.BusType.ToString(); readonly=$aliasDisk.IsReadOnly; system=$aliasDisk.IsSystem; boot=$aliasDisk.IsBoot }
    $record.chkdsk_issued = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($CheckTimeoutSeconds * 1000)
    if (-not $finished) { $process.Kill(); $process.WaitForExit() }
    [IO.File]::WriteAllText((Join-Path $Out 'chkdsk-stdout.txt'), $stdout.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Out 'chkdsk-stderr.txt'), $stderr.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    $record.chkdsk_exit = $process.ExitCode
    $record.chkdsk_timeout = -not $finished
    # A control mkntfs volume can decline native filesystem mounting on a
    # write-protected disk (ERROR_WRITE_PROTECT); chkdsk still checks it
    # directly. File-bearing MiniOS cases additionally require exact tree IO.
    $record.readonly_chkdsk_pass = $finished -and $process.ExitCode -eq 0 -and $record.source_ntfs_boot_signature
    $record.passed = $record.readonly_chkdsk_pass
    if ($expectedTree) { $record.passed = $record.passed -and $record.readonly_file_tree_pass }
    if ($expectedWim) { $record.passed = $record.passed -and $record.readonly_wim_tree_pass -and $record.raw_security_pass }
    $process.Dispose()
    }
} catch {
    $record.error = $_.Exception.Message
    $record.passed = $false
} finally {
    if ($driveAlias) {
        try {
            # Remove only our exact target from the alias stack, never another
            # device's definition even if something else changed concurrently.
            if (-not [MiniOsOracleDos]::DefineDosDevice(15, $driveAlias, $driveTarget)) { throw 'Exact temporary DOS alias removal failed' }
            $record.temporary_dos_alias_removed = $true
        } catch { $record.temporary_dos_alias_removed = $false; $record.alias_cleanup_error = $_.Exception.Message; $record.passed = $false }
    }
    if ($mounted) {
        try { Dismount-DiskImage -ImagePath $vhd -ErrorAction Stop | Out-Null; $record.dismounted = $true }
        catch { $record.dismounted = $false; $record.cleanup_error = $_.Exception.Message; $record.passed = $false }
    }
    $record.source_sha256_after = Hash-File $RawCopy
    if ($record.source_sha256_after -ne $ExpectedSha256) { $record.passed = $false }
    if ($expectedTree) {
        $record.manifest_sha256_after = Hash-File $expectedTree.path
        if ($record.manifest_sha256_after -ne $expectedTree.sha256) { $record.passed = $false }
    }
    if ($expectedWim) {
        $record.wim_manifest_sha256_after = Hash-File $expectedWim.path
        if ($record.wim_manifest_sha256_after -ne $expectedWim.sha256) { $record.passed = $false }
        $record.wim_security_manifest_sha256_after=Hash-File $expectedSecurity.path
        if ($record.wim_security_manifest_sha256_after -cne $expectedSecurity.sha256) { $record.passed=$false }
    }
    if (Test-Path -LiteralPath $vhd) {
        $record.vhd_sha256_after = Hash-File $vhd
        if ($record.Contains('vhd_sha256_before') -and $record.vhd_sha256_after -ne $record.vhd_sha256_before) { $record.passed = $false }
    }
    if ($prepared) {
        $record.prepared_vhd_result_sha256_after=Hash-File $prepared.path
        if ($record.prepared_vhd_result_sha256_after -cne $prepared.sha256) {$record.passed=$false}
    }
    if ($preparedVhdLock) {$preparedVhdLock.Dispose()}
    if ($priorResultLock) {$priorResultLock.Dispose()}
    $record.readonly_chkdsk_pass = (-not $FilesOnly) -and $record.passed
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    [IO.File]::WriteAllText((Join-Path $Out 'result.json'), ($record | ConvertTo-Json -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
}
[ordered]@{ kind = $record.kind; passed = $record.passed; readonly_chkdsk_pass = $record.readonly_chkdsk_pass; result = (Join-Path $Out 'result.json') } | ConvertTo-Json -Depth 3
if ($record.passed) { exit 0 } else { exit 1 }
