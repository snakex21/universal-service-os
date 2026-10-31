#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# Host DISM executor prototype: real read-only identity observations.
   All mutating operations are hard-blocked: there is no switch or user-supplied
   flag that can assert the unproved VHDX host-file bound or TOCTOU safety.
   Do not use as a completed DISM installer. #>
[CmdletBinding()]
param([switch]$LibraryOnly)
$ErrorActionPreference='Stop'

function Initialize-HostDismNativeReaders {
    $repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    if (-not ('MiniOsHostDismFilePin' -as [type])) {
        Add-Type -Path (Join-Path $repo 'tools/minios/host_dism_file_identity.cs')
    }
    if (-not ('MiniOsBcdReference' -as [type])) {
        Add-Type -Path (Join-Path $repo 'tools/minios/bcdboot_reference_guard.cs')
    }
    if (-not [MiniOsBcdReference]::AbiValid()) {throw 'Unsupported host ABI'}
}

function Get-HostDismVerifiedDisk {
    param([Parameter(Mandatory)]$FilePin,[Parameter(Mandatory)][string]$ImagePath,
          [Parameter(Mandatory)][hashtable]$Expected)
    $FilePin.AssertUnchanged()
    $images=@(Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop)
    if ($images.Count -ne 1 -or -not $images[0].Attached -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$images[0].ImagePath),[IO.Path]::GetFullPath($ImagePath),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Attached image path is not the pinned image'
    }
    $disks=@($images[0] | Get-Disk -ErrorAction Stop)
    if ($disks.Count -ne 1) {throw 'Image does not map to one disk'}
    $disk=$disks[0]
    if ($disk.Number -ne $Expected.Number -or $disk.Path -cne $Expected.Path -or
        [string]::IsNullOrWhiteSpace([string]$disk.Path) -or
        $disk.UniqueId -cne $Expected.UniqueId -or [string]::IsNullOrWhiteSpace([string]$disk.UniqueId) -or
        $disk.Size -ne $Expected.Bytes -or $disk.LogicalSectorSize -ne 512 -or
        $disk.IsBoot -or $disk.IsSystem -or $disk.IsReadOnly -or
        (($disk.BusType.ToString() -replace ' ','') -ine 'FileBackedVirtual') -or
        $images[0].DevicePath -ine ('\\.\PHYSICALDRIVE'+$disk.Number)) {
        throw 'Exact attached virtual disk identity or geometry differs'
    }
    $again=@(Get-Disk -Number $disk.Number -ErrorAction Stop)
    if ($again.Count -ne 1 -or $again[0].Number -ne $disk.Number -or $again[0].Path -cne $disk.Path -or
        $again[0].UniqueId -cne $disk.UniqueId -or $again[0].Size -ne $disk.Size -or $again[0].LogicalSectorSize -ne 512 -or
        $again[0].IsBoot -or $again[0].IsSystem -or $again[0].IsReadOnly -or
        (($again[0].BusType.ToString() -replace ' ','') -ine 'FileBackedVirtual')) {
        throw 'Independent disk-number resolution differs'
    }
    $imagesAgain=@(Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop)
    if ($imagesAgain.Count -ne 1 -or -not $imagesAgain[0].Attached -or
        $imagesAgain[0].DevicePath -ine $images[0].DevicePath -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$imagesAgain[0].ImagePath),[IO.Path]::GetFullPath($ImagePath),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Image-to-device mapping changed during verification'
    }
    $FilePin.AssertUnchanged()
    return $disk
}

function Assert-HostDismPartition {
    param([Parameter(Mandatory)]$Disk,[Parameter(Mandatory)][hashtable]$Expected)
    # Windows creates this GPT reserved entry before the first data partition.
    # Only this exact reserved geometry is allowed below the 1 MiB boundary.
    $autoMsr=($Expected.GptType -ieq 'e3c9e316-0b5c-4db8-817d-f92df00215ae' -and
              $Expected.Offset -eq (34*512) -and $Expected.Bytes -eq ((32768-34)*512))
    $parts=@(Get-Partition -DiskNumber $Disk.Number -PartitionNumber $Expected.Number -ErrorAction Stop)
    if ($parts.Count -ne 1 -or $parts[0].DiskNumber -ne $Disk.Number -or
        $parts[0].Offset -ne $Expected.Offset -or $parts[0].Size -ne $Expected.Bytes -or
        ([string]$parts[0].Guid).Trim('{}') -ine $Expected.Guid -or
        ([string]$parts[0].GptType).Trim('{}') -ine $Expected.GptType -or
        (-not $autoMsr -and ($parts[0].Offset -lt 1MB -or $parts[0].Offset % 1MB -ne 0)) -or
        $parts[0].Size -le 0 -or $parts[0].Offset -gt $Disk.Size -or
        $parts[0].Size -gt ($Disk.Size-$parts[0].Offset)) {throw 'GPT partition identity differs'}
    return $parts[0]
}

function Get-HostDismInitialMsr {
    param([Parameter(Mandatory)]$Disk,[string]$RequiredGuid)
    $parts=@(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop)
    if($parts.Count -ne 1){throw 'Expected exactly one initial MSR partition'}
    $part=$parts[0];$guid=([string]$part.Guid).Trim('{}')
    if($guid -notmatch '^[0-9a-fA-F-]{36}$' -or
       ($RequiredGuid -and $guid -ine $RequiredGuid)) {throw 'Initial MSR GUID differs'}
    $expected=@{Number=$part.PartitionNumber;Offset=(34*512);Bytes=((32768-34)*512);
                Guid=$guid;GptType='e3c9e316-0b5c-4db8-817d-f92df00215ae'}
    $null=Assert-HostDismPartition -Disk $Disk -Expected $expected
    return $expected
}

function Assert-HostDismResumeRequest {
    param([Parameter(Mandatory)][string]$Case,[Parameter(Mandatory)][System.Collections.IDictionary]$Job)
    if ([IO.Path]::GetFileName($Case) -cne 'host-dism-538d709d-91fb-4e74-a43b-8a123e253760' -or
        $Job.mode -cne 'resume' -or
        $Job.resume_image_sha256 -cne 'f1e226959665d779a6fdc4a3229c57d8ec1211dd67f1376a3210f9a989e8f68b' -or
        $Job.resume_msr_guid -cne 'e5d9b44e-bcb0-48ef-a0d8-8e8d834c4e10' -or
        $Job.resume_name -notmatch '^resume-[0-9a-f-]+$') {throw 'Exact reviewed resume evidence required'}
}

function Assert-HostDismAlias {
    param([Parameter(Mandatory)][string]$Alias,[Parameter(Mandatory)][string]$ExpectedTarget,
          [Parameter(Mandatory)]$Disk,[Parameter(Mandatory)][hashtable]$Partition)
    $buffer=[Text.StringBuilder]::new(32768)
    if (-not [MiniOsBcdReference]::QueryDosDevice($Alias,$buffer,$buffer.Capacity) -or
        $buffer.ToString().Split([char]0)[0] -cne $ExpectedTarget) {throw 'Alias target changed'}
    $extent=[MiniOsBcdReference]::VolumeIdentity($Alias)
    if ($extent.DiskNumber -ne $Disk.Number -or $extent.Offset -ne $Partition.Offset -or $extent.Bytes -ne $Partition.Bytes) {
        throw 'Alias is not the exact single disk extent'
    }
}

function Assert-HostDismMutationAvailable {
    # The fixed-VHDX flag, current allocation and a permission receipt are NOT
    # an enforced future growth bound. This deliberate hard stop cannot be
    # bypassed through a CLI flag, mock receipt, environment variable or scope.
    throw 'HOST_DISM_MUTATION_BLOCKED: no verified enforced VHDX size bound or reviewed race-free executor'
}

function Invoke-HostDismMutation {
    param([ValidateSet('Create','Attach','Initialize','CreatePartition','Format','Alias','Apply','Bcdboot','Detach')][string]$Operation)
    if ($Operation -eq 'Bcdboot') {
        throw 'HOST_DISM_MUTATION_BLOCKED HOST_BCDBOOT_FORBIDDEN: permanently disabled; use offline REGF'
    }
    # No mutation implementation is reachable in this prototype. The identity
    # probes above are deliberately separate from this fail-closed dispatcher.
    Assert-HostDismMutationAvailable
}

if (-not $LibraryOnly) {Invoke-HostDismMutation -Operation 'Create'}
