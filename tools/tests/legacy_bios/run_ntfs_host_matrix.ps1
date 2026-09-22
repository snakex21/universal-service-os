$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$fixturePrep = Full 'tools/tests/legacy_bios/prepare_ntfs_fixture.ps1'
$zig = Full 'tools/zig/zig.exe'
$fixtureDir = Full 'zig-out/legacy-bios/ntfs-fixture'
$probe = Full 'zig-out/bin/usos-legacy-ntfs-probe.exe'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixturePrep
if ($LASTEXITCODE -ne 0) { throw "NTFS fixture preparation failed with exit code $LASTEXITCODE" }
& $zig build legacy-ntfs-probe -Doptimize=Debug
if ($LASTEXITCODE -ne 0) { throw "Legacy NTFS host probe build failed with exit code $LASTEXITCODE" }

$cases = @(
    @{ Name='valid-hard'; Expected=$null },
    @{ Name='bad-vbr'; Expected='InvalidBPB' },
    @{ Name='bad-mft-signature'; Expected='InvalidMftSignature' },
    @{ Name='bad-fixup'; Expected='InvalidFixup' },
    @{ Name='run-outside'; Expected='RunlistBounds' },
    @{ Name='run-loop'; Expected='RunlistLoop' }
)
foreach ($case in $cases) {
    $image = Join-Path $fixtureDir "$($case.Name).raw"
    if ($case.Expected) {
        & $probe $image $case.Expected
    } else {
        & $probe $image
    }
    if ($LASTEXITCODE -ne 0) { throw "Host NTFS case $($case.Name) failed with exit code $LASTEXITCODE" }
    Write-Host "[PASS] host NTFS case=$($case.Name)" -ForegroundColor Green
}
Write-Host '[PASS] Shared NTFS host matrix complete: fragmented $MFT + $INDEX_ALLOCATION + negative corruption cases.' -ForegroundColor Green
