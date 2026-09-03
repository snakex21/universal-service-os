$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$zigOut = [IO.Path]::GetFullPath((Join-Path $root 'zig-out'))

foreach ($name in @('usb', 'manual-usb', 'qemu-usb', 'qemu-arm64-usb')) {
    $path = [IO.Path]::GetFullPath((Join-Path $zigOut $name))
    if (-not $path.StartsWith($zigOut + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing generated-output cleanup outside zig-out: $path"
    }
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
        Write-Host "[CLEAN] $path"
    }
}
