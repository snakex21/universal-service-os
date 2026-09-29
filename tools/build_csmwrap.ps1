<#
Builds CSMWrap 3.1.2 (unpatched, as a functional check) and 3.1.2-usos3
(the quiet-boot and boot-priority patches in tools/vendor/csmwrap/3.1.2-usos3/patches) from
source, inside a throwaway Alpine virt live VM in QEMU (WHPX, TCG fallback).
This PC has no WSL, Docker or ELF GCC; the VM is the Linux build host.

  powershell -File tools/build_csmwrap.ps1 [-Work zig-out/csmwrap-build/vm] [-Accel whpx|tcg] [-Stage]

Pinned inputs: tools/csmwrap_build/lock.json (Alpine ISO hash, Alpine branch
and exact apk versions, CSMWrap commit and every submodule commit).
Guest script: tools/csmwrap_build/guest_build.sh. Network is needed (apk and
github.com). Output in <Work>/out: the deterministic source archive, both
binaries, the SeaBIOS blobs, build logs, toolchain.txt and SHA256SUMS.

-Stage copies the usos3 binary and the source archive into
tools/vendor/csmwrap/3.1.2-usos3 and 3.1.2-src and checks them against
3.1.2-usos3/manifest.json (a rebuild with the pinned toolchain must give the
same hashes). The release stages 3.1.2-usos3 (docs/research/csmwrap.md
sections 6 and 7, docs/design/bios-via-csmwrap.md). The guest script names
the patched binary csmwrapx64-usos1.efi whatever the version.
No USB stick or physical disk is touched. The binary stays unsigned.
#>
param(
    [string]$Work = 'zig-out/csmwrap-build/vm',
    [ValidateSet('whpx', 'tcg')]
    [string]$Accel = 'whpx',
    [string]$Iso = '',
    [switch]$Stage,
    # Offline build from the build kit: the kit's partial Alpine mirror
    # (csmwrap-vm/apk) and the vendored source archive; no network.
    [string]$OfflineMirror = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$lock = Get-Content -Raw 'tools/csmwrap_build/lock.json' | ConvertFrom-Json
if (-not $Iso) {
    $Iso = Join-Path $root $lock.alpine_iso.file
    if (-not (Test-Path $Iso) -and $OfflineMirror) { throw "Alpine ISO missing: $Iso (use_buildkit.ps1 restores it)" }
    if (-not (Test-Path $Iso)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $Iso) | Out-Null
        Write-Output "Downloading $($lock.alpine_iso.url)"
        Invoke-WebRequest -Uri $lock.alpine_iso.url -OutFile $Iso -UseBasicParsing
    }
}
$vmArgs = @('tools/csmwrap_build/run_build_vm.py', '--work', $Work, '--accel', $Accel, '--iso', $Iso)
if ($OfflineMirror) { $vmArgs += @('--offline', $OfflineMirror) }
& python @vmArgs
if ($LASTEXITCODE -ne 0) { throw "guest build failed ($LASTEXITCODE)" }

$out = Join-Path $Work 'out'
$manifest = Get-Content -Raw 'tools/vendor/csmwrap/3.1.2-usos3/manifest.json' | ConvertFrom-Json
function Sha([string]$path) { (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant() }
$checks = [ordered]@{
    'csmwrapx64-usos1.efi'    = $manifest.files.'csmwrapx64.efi'
    'csmwrapx64-upstream.efi' = $manifest.upstream_rebuild.sha256
    'csmwrap-3.1.2-src.tar.xz' = $manifest.source_archive.sha256
}
$same = $true
foreach ($name in $checks.Keys) {
    $got = Sha (Join-Path $out $name)
    $ok = $got -eq $checks[$name]
    if (-not $ok) { $same = $false }
    Write-Output ("{0,-26} {1} {2}" -f $name, $got, $(if ($ok) { 'matches manifest' } else { 'DIFFERS from manifest' }))
}
if ($Stage) {
    if (-not $same) { throw 'rebuild differs from 3.1.2-usos3/manifest.json; update the manifest deliberately before staging' }
    Copy-Item (Join-Path $out 'csmwrapx64-usos1.efi') 'tools/vendor/csmwrap/3.1.2-usos3/csmwrapx64.efi' -Force
    Copy-Item (Join-Path $out 'csmwrap-3.1.2-src.tar.xz') 'tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz' -Force
    Write-Output 'Staged tools/vendor/csmwrap/3.1.2-usos3/csmwrapx64.efi and 3.1.2-src/csmwrap-3.1.2-src.tar.xz'
}
