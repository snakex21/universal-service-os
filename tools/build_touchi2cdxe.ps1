# Rebuilds the vendored TouchI2cDxe driver from pinned sources, OUTSIDE the
# repository (default %LOCALAPPDATA%\USOS\edk2-build). Not part of build.bat:
# the release only signs the vendored tools\vendor\touchi2cdxe\<version>\
# TouchI2cDxe.efi. Run this to reproduce or refresh that file; it prints the
# SHA-256 and compares it with manifest.json.
#
# Needs: git, python 3, Visual Studio 2022 Build Tools (MSVC x86 + x64).
# Downloads: TouchI2cDxe (GitHub), EDK2 edk2-stable202411 shallow + 3
# submodules (GitHub), NASM 2.16.03 (nasm.us, SHA-256 checked).
param(
    [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'USOS\edk2-build'),
    [string]$Version = 'v1.3.1-usos1',
    [switch]$Vendor
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vendorDir = Join-Path $root "tools\vendor\touchi2cdxe\$Version"
$manifest = Get-Content -LiteralPath (Join-Path $vendorDir 'manifest.json') -Raw | ConvertFrom-Json
if ($WorkDir.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "WorkDir must be outside the repository: $WorkDir" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Invoke-Checked([string]$File, [string[]]$Arguments, [string]$Where = $WorkDir) {
    Push-Location $Where
    try {
        if ($File -eq 'git') { $Arguments = @('-c', 'core.longpaths=true') + $Arguments }
        & $File @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$File $($Arguments -join ' ') failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
}

# 1. Driver sources at the pinned commit, plus the USOS patch.
$src = Join-Path $WorkDir 'TouchI2cDxe'
if (-not (Test-Path $src)) {
    Invoke-Checked git @('init', '-q', $src)
    Invoke-Checked git @('remote', 'add', 'origin', $manifest.upstream.repository) $src
}
Invoke-Checked git @('fetch', '-q', '--depth', '1', 'origin', $manifest.upstream.commit) $src
Invoke-Checked git @('-c', 'core.autocrlf=false', 'checkout', '-q', '-f', '--detach', $manifest.upstream.commit) $src
Invoke-Checked git @('-c', 'core.autocrlf=false', 'reset', '-q', '--hard', $manifest.upstream.commit) $src
foreach ($entry in $manifest.upstream.source_sha256.PSObject.Properties) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $src $entry.Name)).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "Upstream $($entry.Name) SHA-256 $actual, manifest pins $($entry.Value)" }
}
Invoke-Checked git @('apply', '--whitespace=nowarn', (Join-Path $vendorDir 'usos-rc71l.patch')) $src

# 2. EDK2 at the commit upstream CI uses (edk2-stable202411), shallow, with
#    only the submodules this build needs.
$edk2 = Join-Path $WorkDir 'edk2'
if (-not (Test-Path (Join-Path $edk2 'edksetup.bat'))) {
    Invoke-Checked git @('init', '-q', $edk2)
    Invoke-Checked git @('remote', 'add', 'origin', 'https://github.com/tianocore/edk2.git') $edk2
    Invoke-Checked git @('fetch', '-q', '--depth', '1', 'origin', $manifest.edk2.commit) $edk2
    Invoke-Checked git @('checkout', '-q', '--detach', 'FETCH_HEAD') $edk2
}
$head = (& git -C $edk2 rev-parse HEAD).Trim()
if ($head -ne $manifest.edk2.commit) { throw "EDK2 checkout is $head, manifest pins $($manifest.edk2.commit)" }
Invoke-Checked git (@('submodule', 'update', '--init', '--depth', '1') + $manifest.edk2.submodules) $edk2

# 3. NASM (EDK2's BaseLib has .nasm sources).
$nasmZip = Join-Path $WorkDir 'nasm.zip'
if (-not (Test-Path $nasmZip)) { Invoke-WebRequest -UseBasicParsing -Uri $manifest.toolchain.nasm_url -OutFile $nasmZip }
$nasmHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nasmZip).Hash.ToLowerInvariant()
if ($nasmHash -ne $manifest.toolchain.nasm_zip_sha256) { throw "nasm.zip SHA-256 $nasmHash, manifest pins $($manifest.toolchain.nasm_zip_sha256)" }
if (-not (Test-Path (Join-Path $WorkDir 'nasm-2.16.03\nasm.exe'))) { Expand-Archive -LiteralPath $nasmZip -DestinationPath $WorkDir -Force }

# 4. Package: the minimal DSC + the patched sources inside the workspace.
$pkg = Join-Path $edk2 'UsosTouchPkg'
if (Test-Path $pkg) { Remove-Item -LiteralPath $pkg -Recurse -Force }
New-Item -ItemType Directory -Force -Path $pkg | Out-Null
Copy-Item -Recurse -LiteralPath (Join-Path $src 'src') -Destination $pkg
Copy-Item -LiteralPath (Join-Path $vendorDir 'UsosTouchPkg.dsc') -Destination $pkg
$buildOut = Join-Path $edk2 'Build\UsosTouch'
if (Test-Path $buildOut) { Remove-Item -LiteralPath $buildOut -Recurse -Force }

# 5. BaseTools (32-bit host tools, as edksetup expects) and the driver.
$vs = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build'
$common = @"
@echo off
set "PATH=%PATH%;C:\Program Files (x86)\Microsoft Visual Studio\Installer"
set "WORKSPACE=$edk2"
set "PACKAGES_PATH=$edk2"
set "NASM_PREFIX=$WorkDir\nasm-2.16.03\"
set "PYTHON_COMMAND=python"
cd /d "$edk2"
"@
if (-not (Test-Path (Join-Path $edk2 'BaseTools\Bin\Win32\GenFw.exe'))) {
    $script = Join-Path $WorkDir 'build-basetools.cmd'
    [IO.File]::WriteAllText($script, ($common + "`r`ncall `"$vs\vcvars32.bat`" >nul`r`ncd /d `"$edk2`"`r`ncall `"$edk2\edksetup.bat`" Rebuild VS2022`r`n").Replace("`r`n", "`n").Replace("`n", "`r`n"))
    Invoke-Checked cmd.exe @('/c', $script)
}
$script = Join-Path $WorkDir 'build-driver.cmd'
[IO.File]::WriteAllText($script, ($common + "`r`ncall `"$edk2\edksetup.bat`" VS2022`r`ncall build -a X64 -t VS2022 -b RELEASE -p UsosTouchPkg/UsosTouchPkg.dsc -n 1`r`n").Replace("`r`n", "`n").Replace("`n", "`r`n"))
Invoke-Checked cmd.exe @('/c', $script)

$efi = Join-Path $buildOut 'RELEASE_VS2022\X64\TouchI2cDxe.efi'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $efi).Hash.ToLowerInvariant()
Write-Host "[BUILD] $efi"
Write-Host "[BUILD] SHA-256 $hash ($((Get-Item $efi).Length) bytes)"
if ($hash -eq $manifest.files.'TouchI2cDxe.efi') {
    Write-Host '[PASS] Identical to the vendored TouchI2cDxe.efi (reproducible).'
} elseif ($Vendor) {
    Copy-Item -LiteralPath $efi -Destination (Join-Path $vendorDir 'TouchI2cDxe.efi') -Force
    Write-Host '[VENDOR] Copied; update manifest.json and PROVENANCE.md with the new hash.'
} else {
    throw "Rebuilt TouchI2cDxe.efi $hash differs from the vendored $($manifest.files.'TouchI2cDxe.efi') (use -Vendor to replace it)"
}
