param(
    [Parameter(Mandatory=$true)][string]$QemuImgPath,
    [Parameter(Mandatory=$true)][string]$BasePath,
    [Parameter(Mandatory=$true)][string]$OverlayPath
)

$ErrorActionPreference = 'Stop'
$QemuImgPath = [IO.Path]::GetFullPath($QemuImgPath)
$BasePath = [IO.Path]::GetFullPath($BasePath)
$OverlayPath = [IO.Path]::GetFullPath($OverlayPath)
$testImagesRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\test-images'))

foreach ($path in @($BasePath, $OverlayPath)) {
    if (-not $path.StartsWith($testImagesRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing qcow2 path outside test-images: $path"
    }
}
if (-not (Test-Path -LiteralPath $QemuImgPath -PathType Leaf)) { throw "Missing qemu-img: $QemuImgPath" }
if (-not (Test-Path -LiteralPath $BasePath -PathType Leaf)) { throw "Missing qcow2 base: $BasePath" }

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OverlayPath) | Out-Null
if (Test-Path -LiteralPath $OverlayPath) { Remove-Item -LiteralPath $OverlayPath -Force }

Push-Location (Split-Path -Parent $OverlayPath)
try {
    $baseLeaf = Split-Path -Leaf $BasePath
    $overlayLeaf = Split-Path -Leaf $OverlayPath
    & $QemuImgPath create -f qcow2 -F qcow2 -b $baseLeaf $overlayLeaf
    if ($LASTEXITCODE -ne 0) { throw "qemu-img overlay create failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

Write-Host "[PASS] qcow2 overlay=$OverlayPath backing=$BasePath"
