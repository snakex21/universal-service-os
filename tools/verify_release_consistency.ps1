param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$usbRoot = Join-Path $ProjectRoot 'zig-out\usb'
$releaseBoot = Join-Path $usbRoot 'EFI\BOOT\BOOTX64.EFI'
$manualBoot = Join-Path $ProjectRoot 'zig-out\manual-usb\EFI\BOOT\BOOTX64.EFI'
$payloadPath = Join-Path $ProjectRoot 'installer\internal\payload\assets\payload.zip'

foreach ($required in @($releaseBoot, $manualBoot, $payloadPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing release consistency input: $required"
    }
}

$releaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseBoot).Hash
$manualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manualBoot).Hash
if ($releaseHash -ne $manualHash) {
    throw "BOOTX64.EFI mismatch: release=$releaseHash manual=$manualHash"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($payloadPath)
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $entries = @{}
    foreach ($entry in $archive.Entries) {
        $entries[$entry.FullName] = $entry
    }

    $requiredPayloadPaths = @(
        'EFI/BOOT/BOOTX64.EFI',
        'UI/index.html',
        'UI/theme.css',
        'UI/Icons/Systems/windows-11.png',
        'Systems/Windows/Windows 11/Unattended/win10-11 best-ustawienia.xml'
    )
    foreach ($requiredPath in $requiredPayloadPaths) {
        if (-not $entries.ContainsKey($requiredPath)) {
            throw "Embedded payload missing required file: $requiredPath"
        }
    }

    $usbFiles = Get-ChildItem -LiteralPath $usbRoot -Recurse -File
    foreach ($source in $usbFiles) {
        $relative = $source.FullName.Substring($usbRoot.Length).TrimStart('\').Replace('\', '/')
        if (-not $entries.ContainsKey($relative)) {
            throw "Embedded payload is stale; missing USB file: $relative"
        }

        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash
        $stream = $entries[$relative].Open()
        try {
            $payloadHashBytes = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
        $payloadHash = ([BitConverter]::ToString($payloadHashBytes)).Replace('-', '')
        if ($sourceHash -ne $payloadHash) {
            throw "Embedded payload differs from USB file: $relative source=$sourceHash payload=$payloadHash"
        }
    }
} finally {
    $sha256.Dispose()
    $archive.Dispose()
}

Write-Host "[PASS] BOOTX64.EFI shared SHA-256=$releaseHash"
Write-Host '[PASS] Embedded payload contains the current USB UI, icons, systems and unattended file.'
