param(
    [Parameter(Mandatory=$true)][string]$Path
)

$ErrorActionPreference = 'Stop'
$fullPath = [IO.Path]::GetFullPath($Path)
$stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if ($stream.Length -lt 512) { throw 'file is too small to contain a fixed VHD footer' }
    $stream.Position = $stream.Length - 512
    $footer = New-Object byte[] 512
    if ($stream.Read($footer, 0, 512) -ne 512) { throw 'failed to read fixed VHD footer' }
    $signature = [Text.Encoding]::ASCII.GetString($footer, 0, 8)
    if ($signature -ne 'conectix') { throw "missing fixed VHD footer signature: $signature" }

    $currentSizeBytes = $footer[48..55]
    [Array]::Reverse($currentSizeBytes)
    $currentSize = [BitConverter]::ToUInt64($currentSizeBytes, 0)
    if ($stream.Length - 512 -ne $currentSize) {
        throw "fixed VHD footer size mismatch: file payload=$($stream.Length - 512) footer current_size=$currentSize"
    }

    $stream.SetLength([int64]$currentSize)
    $stream.Flush($true)
    Write-Host "[PASS] stripped fixed VHD footer: $fullPath size=$currentSize"
} finally {
    $stream.Dispose()
}
