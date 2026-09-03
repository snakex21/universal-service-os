param(
    [switch]$DeleteBase
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = [IO.Path]::GetFullPath((Join-Path $root 'tools/tests/artifacts/qemu'))

$targets = @(
    (Join-Path $testRoot 'usos-manual-run.qcow2'),
    (Join-Path $testRoot 'usos-manual-windows.qcow2'),
    (Join-Path $testRoot 'usos-manual-run')
)
if ($DeleteBase) {
    $targets += (Join-Path $testRoot 'usos-e2e-base.qcow2')
}

$active = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and ($_.CommandLine.Contains('usos-manual-run.qcow2') -or $_.CommandLine.Contains('usos-manual-windows.qcow2'))
})
if ($active.Count -gt 0) {
    throw "Close the USOS QEMU window before reset. Active PID=$($active[0].ProcessId)"
}

foreach ($target in $targets) {
    $full = [IO.Path]::GetFullPath($target)
    if (-not $full.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete path outside tools/tests/artifacts/qemu: $full"
    }
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
        Write-Host "[RESET] Removed $full"
    }
}

Write-Host ''
Write-Host '[PASS] Wirtualna instalacja i stan USOS zostaly wyczyszczone.' -ForegroundColor Green
if ($DeleteBase) {
    Write-Host 'Przy kolejnym TEST-USOS.cmd baza zostanie zbudowana od nowa.'
} else {
    Write-Host 'Baza z ISO zostala zachowana, wiec kolejny test wystartuje szybciej.'
}
