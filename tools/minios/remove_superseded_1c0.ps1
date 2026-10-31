#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# Explicitly user-authorized superseded 1c0 images only. Evidence is kept.
   Plan is immutable; all candidate identities/hashes and retained evidence
   are checked before any image is removed. No discovery or recursive delete. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Workspace,
      [Parameter(Mandatory)][string]$Plan,
      [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$PlanSha256,
      [Parameter(Mandatory)][string]$Receipt)
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
[Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity=[IntPtr]12
$root=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if (-not [IO.Path]::IsPathFullyQualified($Workspace) -or $root.StartsWith('\\') -or $root.Length -le 3) { throw 'Explicit local workspace required' }
function Owned([string]$value) {
    $full=[IO.Path]::GetFullPath($value)
    if (-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Outside explicit workspace' }
    $walk=$full
    while ($walk) {
        if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse point refused' }
        $walk=[IO.Path]::GetDirectoryName($walk)
    }
    return $full
}
function Sha([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
$planPath=Owned $Plan; $receiptPath=Owned $Receipt
if ((Sha $planPath) -cne $PlanSha256 -or (Test-Path -LiteralPath $receiptPath)) { throw 'Pinned immutable plan and new receipt required' }
$value=[IO.File]::ReadAllText($planPath)|ConvertFrom-Json
if ($value.schema -cne 'minios-1c0-superseded-delete-v1' -or $value.authorization -cne 'user-2026-10-25-delete-old-build-only' -or $value.images.Count -gt 32) { throw 'Wrong authorized plan' }
$allowed=@('features-01','features-02','win11-x64-01','vista-x86-01','win7-x86-01')
$seen=@{}
foreach ($image in $value.images) {
    $path=Owned (Join-Path $root $image.path)
    $relative=[IO.Path]::GetRelativePath($root,$path)
    $parts=$relative.Split([IO.Path]::DirectorySeparatorChar)
    if ($parts.Count -lt 3 -or $parts[0] -cne '1c0' -or $parts[1] -cnotin $allowed -or [IO.Path]::GetExtension($path) -cnotin @('.raw','.vhd','.qcow2') -or $seen.ContainsKey($path)) { throw 'Not an explicitly superseded image' }
    $seen[$path]=$true
    $file=Get-Item -LiteralPath $path
    if ($file.PSIsContainer -or $file.Length -ne $image.bytes -or (Sha $path) -cne $image.sha256) { throw 'Closed image size/hash differs' }
}
foreach ($proof in $value.evidence) {
    $path=Owned (Join-Path $root $proof.path)
    if ((Get-Item -LiteralPath $path).Length -ne $proof.bytes -or (Sha $path) -cne $proof.sha256) { throw 'Retained evidence differs' }
}
$record=[ordered]@{schema='minios-1c0-superseded-deletion-receipt-v1';authorization=$value.authorization;plan_sha256=$PlanSha256;state='preflight-complete';deleted=@();evidence_retained=$true;recursive_delete=$false;physical_disks_opened=$false}
function Save { [IO.File]::WriteAllText($receiptPath,($record|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false)) }
Save
try {
    foreach ($image in $value.images) {
        $path=Owned (Join-Path $root $image.path)
        $file=Get-Item -LiteralPath $path
        if ($file.Length -ne $image.bytes -or (Sha $path) -cne $image.sha256) { throw 'Image changed after preflight' }
        if ($file.IsReadOnly) { $file.IsReadOnly=$false }
        Remove-Item -LiteralPath $path -ErrorAction Stop
        $record.deleted+=@{path=$image.path;bytes=$image.bytes;sha256=$image.sha256}
        $record.state='deleting';Save
    }
    $record.state='complete';Save
} catch { $record.state='partial-failure';$record.error=$_.Exception.Message;Save;throw }
$record|ConvertTo-Json -Depth 8
