# SPDX-License-Identifier: GPL-3.0-or-later
param([Parameter(Mandatory=$true)][string]$Store,
      [Parameter(Mandatory=$true)][ValidateSet('GPT','MBR')][string]$Style,
      [Parameter(Mandatory=$true)][string]$Disk,
      [Parameter(Mandatory=$true)][string]$Partition)
$ErrorActionPreference='Stop'
if (-not [IO.Path]::IsPathFullyQualified($Store) -or $Store.StartsWith('\\') -or (Test-Path -LiteralPath $Store)) { throw 'New regular file required' }
# A synthetic offline store, no volume access and no changes to the host store.
$made=Invoke-CimMethod -Namespace root/wmi -ClassName BcdStore -MethodName CreateStore -Arguments @{File=$Store}
if (-not $made.ReturnValue) { throw 'CreateStore failed' }
$created=Invoke-CimMethod -InputObject $made.Store -MethodName CreateObject -Arguments @{Id='{9dea862c-5cdd-4e70-acc1-f32b344d4795}';Type=[uint32]0x10100002}
if (-not $created.ReturnValue) { throw 'CreateObject failed' }
$set=Invoke-CimMethod -InputObject $created.Object -MethodName SetQualifiedPartitionDeviceElement -Arguments @{Type=[uint32]0x11000001;PartitionStyle=[uint32]$(if($Style -eq 'GPT'){1}else{0});DiskSignature=$Disk;PartitionIdentifier=$Partition}
if (-not $set.ReturnValue) { throw 'SetQualifiedPartitionDeviceElement failed' }
Write-Output 'NATIVE_QUALIFIED_PARTITION PASS'
