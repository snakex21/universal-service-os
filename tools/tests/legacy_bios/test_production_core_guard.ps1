$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$out = Join-Path $root 'zig-out/production-core-guard'
$core = Join-Path $root 'zig-out/legacy-bios/core-slot.bin'
$builder = Join-Path $root 'tools/build_legacy_bios.ps1'
$generator = Join-Path $root 'tools/generate_legacy_boot_payload.ps1'
$before = (Get-FileHash -LiteralPath $core).Hash
foreach ($alias in @('zig-out/legacy-bios', 'zig-out/legacy-bios/.')) {
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -XpMenuAutoTest -OutputDirectory $alias 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0) { throw 'Autotest overwrote production output' }
    if ((Get-FileHash -LiteralPath $core).Hash -ne $before) { throw 'Rejected build changed production Core' }
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -XpMenuAutoTest -OutputDirectory $out
if ($LASTEXITCODE -ne 0) { throw 'Isolated test build failed' }
if ((Get-FileHash -LiteralPath $core).Hash -ne $before) { throw 'Isolated test build changed production Core' }
$generated = Join-Path $out 'must-stay-unchanged.go'
[IO.File]::WriteAllText($generated, 'sentinel')
$ErrorActionPreference = 'Continue'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $generator -CorePath (Join-Path $out 'core-slot.bin') -OutputPath $generated 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -eq 0) { throw 'Generator accepted autotest Core' }
if ([IO.File]::ReadAllText($generated) -ne 'sentinel') { throw 'Rejected generator changed output' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $generator -OutputPath (Join-Path $out 'production.go')
if ($LASTEXITCODE -ne 0) { throw 'Generator rejected production Core' }
Write-Host '[PASS] Autotest output isolation, production hash preservation and packaging rejection'
