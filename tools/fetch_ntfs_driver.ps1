param(
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$Url = 'https://github.com/pbatard/efifs/releases/download/v1.12/ntfs_x64.efi'
$ExpectedSha256 = '59c37d5026ca14553a158939e3f2cf20286b6135a713a62c08b569ac9caedcb7'

$parent = Split-Path -Parent $OutputPath
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

# Pinned local copy first (tools\cache\efifs, restored from the build kit by
# tools\release\use_buildkit.ps1); USOS_OFFLINE=1 forbids the download.
$cached = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\cache\efifs\ntfs_x64.efi'
if (Test-Path -LiteralPath $cached -PathType Leaf) {
    $bytes = [IO.File]::ReadAllBytes($cached)
    Write-Host "[CACHE] $cached"
} elseif ($env:USOS_OFFLINE -eq '1') {
    throw "Offline build: $cached is missing (restore it with tools\release\use_buildkit.ps1)"
} else {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    try {
        $bytes = $client.GetByteArrayAsync($Url).GetAwaiter().GetResult()
    } finally {
        $client.Dispose()
    }
}

$sha = [Security.Cryptography.SHA256]::Create()
try {
    $actual = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
} finally {
    $sha.Dispose()
}

if ($actual -ne $ExpectedSha256) {
    throw "ntfs_x64.efi SHA-256 mismatch: expected $ExpectedSha256, got $actual"
}

[IO.File]::WriteAllBytes($OutputPath, $bytes)
if (-not (Test-Path -LiteralPath $cached -PathType Leaf)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cached) | Out-Null
    [IO.File]::WriteAllBytes($cached, $bytes)
}
Write-Host "[PASS] ntfs_x64.efi $($bytes.Length) bytes SHA256=$actual"
