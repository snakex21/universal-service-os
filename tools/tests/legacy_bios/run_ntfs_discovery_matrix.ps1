$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$hostMatrix = Full 'tools/tests/legacy_bios/run_ntfs_host_matrix.ps1'
$legacy = Full 'tools/tests/legacy_bios/run_seabios_ntfs_catalog.ps1'
$uefi = Full 'tools/tests/legacy_bios/run_ovmf_ntfs_catalog.ps1'

Write-Host '[NTFS DISCOVERY] 1/3 host parser matrix' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hostMatrix
if ($LASTEXITCODE -ne 0) { throw "NTFS host matrix failed: $LASTEXITCODE" }

Write-Host '[NTFS DISCOVERY] 2/3 SeaBIOS direct DATA discovery' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $legacy
if ($LASTEXITCODE -ne 0) { throw "Legacy NTFS discovery failed: $LASTEXITCODE" }

Write-Host '[NTFS DISCOVERY] 3/3 OVMF BlockIo direct DATA discovery' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uefi
if ($LASTEXITCODE -ne 0) { throw "UEFI NTFS discovery failed: $LASTEXITCODE" }

Write-Host '[PASS] NTFS discovery matrix complete: host -> SeaBIOS -> OVMF.' -ForegroundColor Green
