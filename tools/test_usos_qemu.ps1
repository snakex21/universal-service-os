param(
    [switch]$ForceRebuild
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$zig = Full 'tools/zig/zig.exe'
$zigCache = Full 'tools/cache/zig'
$base = Full 'tools/tests/artifacts/qemu/usos-e2e-base.qcow2'
$launcher = Full 'tools/start_manual_full_flow_qemu.ps1'

foreach ($required in @($zig, $launcher)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing required file: $required"
    }
}

function Get-NewestInputTime {
    $paths = @(
        (Full 'build.zig'),
        (Full 'src'),
        (Full 'media'),
        (Full 'tools/micro_linux.lock.json'),
        (Full 'tools/build_micro_linux.py'),
        (Full 'tools/micro_linux_init.sh'),
        (Full 'tools/micro_linux_ui.sh'),
        (Full 'tools/device_guard.sh'),
        (Full 'tools/extract.sh'),
        (Full 'tools/prepare_work.sh'),
        (Full 'tools/prepare_wimboot.sh'),
        (Full 'tools/prepare_vhdboot.sh'),
        (Full 'tools/prepare_e2e_base.ps1')
    )

    $newest = [DateTime]::MinValue
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction Stop | ForEach-Object {
                if ($_.LastWriteTimeUtc -gt $newest) { $newest = $_.LastWriteTimeUtc }
            }
        } elseif ($item.LastWriteTimeUtc -gt $newest) {
            $newest = $item.LastWriteTimeUtc
        }
    }
    return $newest
}

$needsBuild = $ForceRebuild -or -not (Test-Path -LiteralPath $base -PathType Leaf)
if (-not $needsBuild) {
    $baseTime = (Get-Item -LiteralPath $base).LastWriteTimeUtc
    $needsBuild = (Get-NewestInputTime) -gt $baseTime
}

if ($needsBuild) {
    Write-Host '[USOS] Buduje swieza baze QEMU z aktualnego kodu i media...' -ForegroundColor Cyan
    Push-Location $root
    try {
        & $zig build --cache-dir $zigCache prepare-e2e-base -Doptimize=ReleaseFast
        if ($LASTEXITCODE -ne 0) { throw "prepare-e2e-base failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
} else {
    Write-Host '[USOS] Baza QEMU jest aktualna - pomijam ponowne kopiowanie ISO.' -ForegroundColor DarkGray
}

Write-Host '[USOS] Tworze czysty stan testu i uruchamiam QEMU...' -ForegroundColor Cyan
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcher -Fresh
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
