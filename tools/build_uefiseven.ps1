# Rebuilds UefiSeven 1.30 from the sources vendored in
# tools\vendor\uefiseven\1.30\src, OUTSIDE the repository (default
# %LOCALAPPDATA%\USOS\edk2-build, the EDK2 workspace that
# tools\build_touchi2cdxe.ps1 prepares). Not part of build.bat: the release
# still ships the pinned upstream binary tools\vendor\uefiseven\1.30\UefiSeven.efi
# (see PROVENANCE.md). This script proves that the vendored sources build
# reproducibly and produces the source-built binary for QEMU trials.
#
# Needs: the EDK2 workspace (edk2-stable202411 + BaseTools + NASM) from
# tools\build_touchi2cdxe.ps1, python 3, Visual Studio 2022 Build Tools.
# Downloads nothing.
param(
    [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'USOS\edk2-build'),
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vendorDir = Join-Path $root 'tools\vendor\uefiseven\1.30'
$manifest = Get-Content -LiteralPath (Join-Path $vendorDir 'manifest.json') -Raw | ConvertFrom-Json
if ($WorkDir.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "WorkDir must be outside the repository: $WorkDir" }

# 1. Vendored sources must be exactly the pinned upstream files.
$src = Join-Path $vendorDir 'src'
foreach ($entry in $manifest.upstream_source.sha256.PSObject.Properties) {
    $file = Join-Path $src $entry.Name
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "Vendored $($entry.Name) SHA-256 $actual, manifest pins $($entry.Value)" }
}
$dsc = Join-Path $vendorDir 'UsosUefiSevenPkg.dsc'
$dscHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dsc).Hash.ToLowerInvariant()
if ($dscHash -ne $manifest.source_build.dsc_sha256) { throw "UsosUefiSevenPkg.dsc SHA-256 $dscHash, manifest pins $($manifest.source_build.dsc_sha256)" }

# 2. The EDK2 workspace of build_touchi2cdxe.ps1, at the pinned commit
#    (read from .git\HEAD: the checkout is detached, no git call needed).
$edk2 = Join-Path $WorkDir 'edk2'
if (-not (Test-Path (Join-Path $edk2 'BaseTools\Bin\Win32\GenFw.exe'))) { throw "No EDK2 workspace with BaseTools at $edk2; run tools\build_touchi2cdxe.ps1 first" }
$head = (Get-Content -LiteralPath (Join-Path $edk2 '.git\HEAD') -Raw).Trim()
if ($head -ne $manifest.source_build.edk2_commit) { throw "EDK2 checkout is $head, manifest pins $($manifest.source_build.edk2_commit)" }
# MdeModulePkg.dec names the brotli include path of a submodule that
# build_touchi2cdxe.ps1 does not check out. At edk2-stable202411 it pins the
# same google/brotli commit (f4153a09f87cbb9c826d8fc12c74642bb2d879ea) as
# BaseTools/Source/C/BrotliCompress/brotli, which is checked out: copy its
# headers (UefiSeven uses none of them; the path only has to exist).
$brotli = Join-Path $edk2 'MdeModulePkg\Library\BrotliCustomDecompressLib\brotli\c\include'
if (-not (Test-Path (Join-Path $brotli 'brotli\decode.h'))) {
    $from = Join-Path $edk2 'BaseTools\Source\C\BrotliCompress\brotli\c\include'
    if (-not (Test-Path (Join-Path $from 'brotli\decode.h'))) { throw "BaseTools brotli submodule missing at $from" }
    & robocopy.exe $from $brotli /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy brotli headers failed ($LASTEXITCODE)" }
}
$nasm = Join-Path $WorkDir 'nasm-2.16.03\'
if (-not (Test-Path (Join-Path $nasm 'nasm.exe'))) { throw "NASM missing at $nasm; run tools\build_touchi2cdxe.ps1 first" }

# 3. Packages outside the EDK2 tree (PACKAGES_PATH), fresh every run.
$pkgs = Join-Path $WorkDir 'uefiseven-pkgs'
if (Test-Path $pkgs) { Remove-Item -LiteralPath $pkgs -Recurse -Force }
New-Item -ItemType Directory -Force -Path $pkgs | Out-Null
# robocopy: Windows PowerShell 5.1 Copy-Item -Recurse fails on nested folders.
foreach ($name in 'UefiSevenPkg', 'IntelFrameworkPkg') {
    & robocopy.exe (Join-Path $src $name) (Join-Path $pkgs $name) /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $name failed ($LASTEXITCODE)" }
}
Copy-Item -LiteralPath $dsc -Destination (Join-Path $pkgs 'UefiSevenPkg')
$buildOut = Join-Path $edk2 'Build\UsosUefiSeven'
if (Test-Path $buildOut) { Remove-Item -LiteralPath $buildOut -Recurse -Force }

$script = Join-Path $WorkDir 'build-uefiseven.cmd'
$cmd = @"
@echo off
set "PATH=%PATH%;C:\Program Files (x86)\Microsoft Visual Studio\Installer"
set "WORKSPACE=$edk2"
set "PACKAGES_PATH=$edk2;$pkgs"
set "NASM_PREFIX=$nasm"
set "PYTHON_COMMAND=python"
cd /d "$edk2"
call "$edk2\edksetup.bat" VS2022
call build -a X64 -t VS2022 -b RELEASE -p UefiSevenPkg/UsosUefiSevenPkg.dsc -n 1
"@
[IO.File]::WriteAllText($script, $cmd.Replace("`r`n", "`n").Replace("`n", "`r`n"))
& cmd.exe /c $script
if ($LASTEXITCODE -ne 0) { throw "EDK2 build failed ($LASTEXITCODE)" }

$efi = Join-Path $buildOut 'RELEASE_VS2022\X64\UefiSeven.efi'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $efi).Hash.ToLowerInvariant()
Write-Host "[BUILD] $efi"
Write-Host "[BUILD] SHA-256 $hash ($((Get-Item $efi).Length) bytes)"
if ($OutFile) { Copy-Item -LiteralPath $efi -Destination $OutFile -Force; Write-Host "[BUILD] copied to $OutFile" }
if ($hash -eq $manifest.source_build.efi_sha256) {
    Write-Host '[PASS] Identical to the recorded source build (reproducible).'
} else {
    throw "Source-built UefiSeven.efi $hash differs from the recorded $($manifest.source_build.efi_sha256)"
}
