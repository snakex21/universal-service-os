<#
.SYNOPSIS
Prepares an offline USOS build from an extracted build kit.

.DESCRIPTION
  powershell -ExecutionPolicy Bypass -File tools\release\use_buildkit.ps1 -Kit <kit folder> [-DryRun]

build.bat calls this automatically when USOS_BUILDKIT is set. It:
  1. checks every kit file against MANIFEST.json (SHA-256 and size);
  2. restores inputs/<repo path> into the repository (tools\cache\alpine,
     tools\cache\efifs, git-ignored vendor archives, Windows 7 MSUs, the frozen
     Vista payload); an existing file must already match, it is never
     overwritten;
  3. unpacks Zig into tools\zig when tools\zig\zig.exe is missing (an existing
     one must match the official 0.16.0 zig.exe), Go, 7-Zip and Pillow into
     tools\cache\buildkit;
  4. writes build\generated\buildkit-env.cmd: PATH with the kit's Go first,
     GOTOOLCHAIN=local, GOPROXY=file:// on the kit's module cache,
     GOSUMDB=off (go.sum is still checked), USOS_7Z, PYTHONPATH and
     USOS_OFFLINE=1 (downloaders fail instead of fetching).
-DryRun only resolves and reports every input; it writes nothing.
#>
param(
    [Parameter(Mandatory = $true)][string]$Kit,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Kit = [IO.Path]::GetFullPath($Kit)
$manifestPath = Join-Path $Kit 'MANIFEST.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No MANIFEST.json in $Kit (point USOS_BUILDKIT at the extracted USOS-<version>-buildkit folder)" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$repoVersion = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
if ($manifest.usos_version -ne $repoVersion) { Write-Warning "Build kit is for USOS $($manifest.usos_version), the repository is $repoVersion" }

function Hash([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
$tag = if ($DryRun) { '[DRY-RUN]' } else { '[BUILDKIT]' }

# 1. Kit integrity
$byPath = @{}
foreach ($f in $manifest.files) {
    $path = Join-Path $Kit ($f.path -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Build kit file missing: $($f.path)" }
    if ((Get-Item -LiteralPath $path).Length -ne $f.size -or (Hash $path) -ne $f.sha256) { throw "Build kit file damaged: $($f.path)" }
    $byPath[$f.path] = $path
}
Write-Output "$tag kit verified: $($manifest.files.Count) files (USOS $($manifest.usos_version), build $($manifest.usos_build))"

# 2. Inputs into the repository
$restored = 0; $present = 0
foreach ($f in $manifest.files | Where-Object { $_.path -like 'inputs/*' }) {
    $rel = $f.path.Substring(7)
    $target = Join-Path $root ($rel -replace '/', '\')
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        if ((Hash $target) -ne $f.sha256) { throw "Repository file differs from the build kit (not overwritten): $rel" }
        $present++
        continue
    }
    $restored++
    if ($DryRun) { Write-Output "$tag would restore $rel"; continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $byPath[$f.path] -Destination $target
}
Write-Output "$tag inputs: $present already in place, $restored $(if ($DryRun) { 'to restore' } else { 'restored' })"

# 3. Toolchains
$tools = Join-Path $root 'tools\cache\buildkit'
function Unzip([string]$Zip, [string]$Destination, [string]$StripPrefix) {
    $temp = "$Destination.partial"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $temp)
    $inner = if ($StripPrefix) { Join-Path $temp $StripPrefix } else { $temp }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    Move-Item -LiteralPath $inner -Destination $Destination
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
$zigZip = ($manifest.files | Where-Object { $_.path -like 'toolchains/zig-*.zip' }).path
$goZip = ($manifest.files | Where-Object { $_.path -like 'toolchains/go*.zip' }).path
$wheel = ($manifest.files | Where-Object { $_.path -like 'python/*.whl' }).path
$zigExe = Join-Path $root 'tools\zig\zig.exe'
$zigPrefix = [IO.Path]::GetFileNameWithoutExtension($zigZip)
$archive = [IO.Compression.ZipFile]::OpenRead($byPath[$zigZip])
try {
    $entry = $archive.GetEntry("$zigPrefix/zig.exe")
    $sha = [Security.Cryptography.SHA256]::Create(); $stream = $entry.Open()
    try { $officialZig = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
} finally { $archive.Dispose() }
if (Test-Path -LiteralPath $zigExe) {
    if ((Hash $zigExe) -ne $officialZig) { throw "tools\zig\zig.exe is not the kit's official Zig ($zigPrefix)" }
    Write-Output "$tag Zig: tools\zig matches $zigPrefix"
} elseif ($DryRun) {
    Write-Output "$tag would unpack $zigPrefix into tools\zig"
} else {
    Unzip $byPath[$zigZip] (Join-Path $root 'tools\zig') $zigPrefix
    Write-Output "$tag Zig: unpacked $zigPrefix into tools\zig"
}
$goRoot = Join-Path $tools 'go'
$sevenDir = Join-Path $tools '7zip'
$site = Join-Path $tools 'python-site'
if ($DryRun) {
    Write-Output "$tag would unpack $goZip, 7-Zip and $wheel into tools\cache\buildkit"
} else {
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    $goMarker = Join-Path $goRoot 'USOS-BUILDKIT'
    if (-not (Test-Path -LiteralPath $goMarker) -or (Get-Content -LiteralPath $goMarker) -ne $goZip) {
        Unzip $byPath[$goZip] $goRoot 'go'
        Set-Content -LiteralPath $goMarker -Value $goZip -Encoding ascii
    }
    New-Item -ItemType Directory -Force -Path $sevenDir | Out-Null
    foreach ($f in $manifest.files | Where-Object { $_.path -like 'toolchains/7zip/*' }) {
        Copy-Item -LiteralPath $byPath[$f.path] -Destination (Join-Path $sevenDir ([IO.Path]::GetFileName($f.path))) -Force
    }
    $siteMarker = Join-Path $site 'USOS-BUILDKIT'
    if (-not (Test-Path -LiteralPath $siteMarker) -or (Get-Content -LiteralPath $siteMarker) -ne $wheel) {
        if (Test-Path -LiteralPath $site) { Remove-Item -LiteralPath $site -Recurse -Force }
        [IO.Compression.ZipFile]::ExtractToDirectory($byPath[$wheel], $site)
        Set-Content -LiteralPath $siteMarker -Value $wheel -Encoding ascii
    }
}

# Python: the kit's Pillow wheel is built for CPython 3.13 x64.
$python = & python.exe -c "import sys,struct;print('%d.%d %d' % (sys.version_info[0], sys.version_info[1], struct.calcsize('P')*8))" 2>$null
if ($python -ne '3.13 64') { Write-Warning "python.exe is '$python'; the build kit expects CPython 3.13 x64 (Pillow wheel)" } else { Write-Output "$tag Python 3.13 x64 found" }

# 4. Environment for build.bat
$goProxy = 'file:///' + ((Join-Path $Kit 'go-mod\cache\download') -replace '\\', '/')
$envLines = @(
    '@echo off',
    'rem Generated by tools\release\use_buildkit.ps1: offline build from the USOS build kit.',
    ('set "PATH={0};%PATH%"' -f (Join-Path $goRoot 'bin')),
    ('set "GOROOT={0}"' -f $goRoot),
    'set "GOTOOLCHAIN=local"',
    ('set "GOPROXY={0}"' -f $goProxy),
    'set "GOSUMDB=off"',
    'set "GOFLAGS=-mod=readonly"',
    ('set "USOS_7Z={0}"' -f (Join-Path $sevenDir '7z.exe')),
    ('set "PYTHONPATH={0};%PYTHONPATH%"' -f $site),
    'set "USOS_OFFLINE=1"'
)
$envPath = Join-Path $root 'build\generated\buildkit-env.cmd'
if ($DryRun) {
    Write-Output "$tag would write build\generated\buildkit-env.cmd:"
    $envLines | Select-Object -Skip 2 | ForEach-Object { Write-Output "    $_" }
    Write-Output "$tag PASS: every build input resolves from the kit"
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $envPath) | Out-Null
    [IO.File]::WriteAllText($envPath, ($envLines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
    Write-Output "$tag PASS: offline environment in build\generated\buildkit-env.cmd"
}
