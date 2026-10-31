#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# Compile-only ABI and refusal tests. Never calls VirtDisk, mount or bcdboot. #>
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$head=(& git -C $repo rev-parse HEAD).Trim();$dirty=@(& git -C $repo status --porcelain=v1 -uall).Count
Write-Output "HEAD $head`nWORKTREE_DIRTY $dirty"
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'minios_bcdboot_reference.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) {throw ($errors | Out-String)}
Add-Type -Path (Join-Path $repo 'tools/minios/bcdboot_reference_guard.cs')
if (-not [MiniOsBcdReference]::AbiValid()) {throw 'VirtDisk API structure layout differs'}
$count=0
foreach ($path in @('relative.vhd','\\server\share\disk.vhd','C:\test.vhd:alternate','C:\bad,filename.vhd',"C:\bad`nfilename.vhd")) {
    $failed=$false
    try {[void][MiniOsBcdReference]::Canonical($path)}catch{$failed=$true}
    if (-not $failed) {throw 'Unsafe native pathname was accepted'}
    $count++
}
$expected=[IO.Path]::GetFullPath((Join-Path $repo 'runtime/test.vhd'))
if ([MiniOsBcdReference]::Canonical($expected) -cne $expected -or [MiniOsBcdReference]::Canonical('\\?\'+$expected) -cne $expected) {throw 'Canonical ordinary pathname differs'}
foreach ($alias in @('C:','C:\','\\.\PhysicalDrive0','Z:\Windows')) {
    $failed=$false
    try {[void][MiniOsBcdReference]::VolumeIdentity($alias)}catch{$failed=$true}
    if (-not $failed) {throw 'Native alias guard accepted a non-private alias'}
    $count++
}
Write-Output "REFERENCE_COMPILE_ONLY PASS ($count refusals; ABI and PowerShell syntax; no disk API invoked)"
