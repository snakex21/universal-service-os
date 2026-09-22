param(
    [switch]$Deep
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'artifacts'))
$qemuRoot = Join-Path $artifactRoot 'qemu'

function Remove-SafePath([string]$Path, [string]$AllowedRoot) {
    $full = [IO.Path]::GetFullPath($Path)
    $allowed = [IO.Path]::GetFullPath($AllowedRoot)
    if (-not $full.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing cleanup outside $allowed : $full"
    }
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
        Write-Host "[CLEAN] $full"
    }
}

$active = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($qemuRoot)
})
if ($active.Count -gt 0) {
    throw "Close QEMU before cleanup. Active PID=$($active[0].ProcessId)"
}

$transient = @(
    'post-merge-positive',
    'post-merge-v2',
    'usos-e2e.qcow2',
    'usos-installer-full-config',
    'usos-installer-gpt-config',
    'usos-installer-gpt-target.qcow2',
    'usos-manual-run',
    'usos-manual-run.qcow2',
    'usos-manual-windows.qcow2',
    'usos-postverify-winpe-config',
    'usos-postverify-readonly-result.txt',
    'qemu-ide-probe.err',
    'whpx-probe.err'
)
foreach ($name in $transient) {
    Remove-SafePath (Join-Path $qemuRoot $name) $qemuRoot
}

$installerArtifacts = Join-Path $artifactRoot 'installer'
Remove-SafePath $installerArtifacts $artifactRoot

$manualUsb = Join-Path $root 'zig-out\manual-usb'
foreach ($obsolete in @('Systems', 'Programs', 'Utilities')) {
    $candidate = Join-Path $manualUsb $obsolete
    if (Test-Path -LiteralPath $candidate) {
        $full = [IO.Path]::GetFullPath($candidate)
        $allowed = [IO.Path]::GetFullPath($manualUsb)
        if (-not $full.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing manual-usb cleanup outside $allowed : $full"
        }
        Remove-Item -LiteralPath $full -Recurse -Force
        Write-Host "[CLEAN] $full"
    }
}

if ($Deep) {
    # Deep cleanup means exactly what it says: everything below the dedicated
    # generated-artifact root is reproducible test output. Keep the source
    # runners/fixtures under tools/tests, but remove all old QEMU images,
    # prepared EXEs, screenshots and cached E2E bases that accumulated there.
    if (Test-Path -LiteralPath $artifactRoot) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $artifactRoot -Force)) {
            Remove-SafePath $entry.FullName $artifactRoot
        }
    }
}

Write-Host ''
if ($Deep) {
    Write-Host '[PASS] All generated test artifacts removed; tools/tests source files kept.' -ForegroundColor Green
} else {
    Write-Host '[PASS] Stale test artifacts removed; E2E base kept for fast TEST-USOS.cmd.' -ForegroundColor Green
}
