$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$fixturePrep = Full 'tools/tests/legacy_bios/prepare_fat32_fixture.ps1'
$zig = Full 'tools/zig/zig.exe'
$fatDir = Full 'zig-out/legacy-bios/fat32-fixture'
$probe = Full 'zig-out/bin/usos-legacy-fat32-probe.exe'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixturePrep
if ($LASTEXITCODE -ne 0) { throw "FAT32 fixture preparation failed with exit code $LASTEXITCODE" }
& $zig build legacy-fat32-probe
if ($LASTEXITCODE -ne 0) { throw "Legacy FAT32 host probe build failed with exit code $LASTEXITCODE" }

$cases = @(
    @{ Name='valid'; Expected=$null },
    @{ Name='bad-bpb'; Expected='UnsupportedSectorSize' },
    @{ Name='broken-chain'; Expected='BrokenClusterChain' },
    @{ Name='outside-file'; Expected='InvalidCluster' },
    @{ Name='loop'; Expected='ClusterChainLoop' }
)
foreach ($case in $cases) {
    $image = Join-Path $fatDir "$($case.Name).raw"
    if ($case.Expected) {
        & $probe $image $case.Expected
    } else {
        & $probe $image
    }
    if ($LASTEXITCODE -ne 0) { throw "Host FAT32 case $($case.Name) failed with exit code $LASTEXITCODE" }
    Write-Host "[PASS] host FAT32 case=$($case.Name)" -ForegroundColor Green
}
Write-Host '[PASS] Shared GPT/FAT32/LFN host matrix complete.' -ForegroundColor Green
