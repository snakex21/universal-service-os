# Refetches the vendored EDK2 UEFI Shell (tools/vendor/uefi-shell/<version>)
# from the official TianoCore release asset and checks every hash pinned in
# its manifest.json. Without -Write it only verifies (the vendored files must
# equal the upstream bytes); with -Write it (re)creates Shell.efi and
# License.txt from upstream.
#
#   powershell -File tools/fetch_uefi_shell.ps1          verify
#   powershell -File tools/fetch_uefi_shell.ps1 -Write   refetch
param(
    [string]$Version = 'edk2-stable202002',
    [switch]$Write
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vendor = Join-Path $root "tools\vendor\uefi-shell\$Version"
$manifest = Get-Content -LiteralPath (Join-Path $vendor 'manifest.json') -Raw | ConvertFrom-Json

function Get-Bytes([string]$Url) {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    try { return $client.GetByteArrayAsync($Url).GetAwaiter().GetResult() } finally { $client.Dispose() }
}

function Get-Sha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function Assert-Hash([string]$Name, [byte[]]$Bytes, [string]$Expected) {
    $actual = Get-Sha256 $Bytes
    if ($actual -ne $Expected.ToLowerInvariant()) { throw "$Name SHA-256 mismatch: expected $Expected, got $actual" }
    Write-Host "[PASS] $Name $($Bytes.Length) bytes SHA256=$actual"
}

$zipBytes = Get-Bytes $manifest.upstream.asset_url
Assert-Hash 'ShellBinPkg.zip' $zipBytes $manifest.upstream.asset_sha256

Add-Type -AssemblyName System.IO.Compression
$stream = New-Object IO.MemoryStream(, $zipBytes)
$archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
try {
    $entry = $archive.GetEntry($manifest.upstream.asset_member)
    if ($null -eq $entry) { throw "ShellBinPkg.zip has no $($manifest.upstream.asset_member)" }
    $memory = New-Object IO.MemoryStream
    $entryStream = $entry.Open()
    try { $entryStream.CopyTo($memory) } finally { $entryStream.Dispose() }
    $shell = $memory.ToArray()
} finally {
    $archive.Dispose()
}
Assert-Hash 'Shell.efi (upstream)' $shell $manifest.files.'Shell.efi'
$license = Get-Bytes $manifest.upstream.license_url
Assert-Hash 'License.txt (upstream)' $license $manifest.files.'License.txt'

foreach ($item in @(@{ Name = 'Shell.efi'; Bytes = $shell }, @{ Name = 'License.txt'; Bytes = $license })) {
    $path = Join-Path $vendor $item.Name
    if ($Write) {
        [IO.File]::WriteAllBytes($path, $item.Bytes)
        Write-Host "[WROTE] $path"
    } else {
        Assert-Hash "vendored $($item.Name)" ([IO.File]::ReadAllBytes($path)) $manifest.files.($item.Name)
    }
}
Write-Host "[PASS] UEFI Shell $Version matches the official TianoCore release."
