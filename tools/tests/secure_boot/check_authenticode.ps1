# Cross-checks the Go Authenticode signer against Windows (WinVerifyTrust via
# Get-AuthenticodeSignature). The USOS certificate is self-signed and not in
# any Windows store, so the expected status is UnknownError ("root not
# trusted"); a wrong PE hash or a malformed PKCS#7 shows up as HashMismatch
# or NotSigned. Also checks that a one-byte change is detected.
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
)
$ErrorActionPreference = 'Stop'
$cert = Join-Path $ProjectRoot 'zig-out\usb\EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer'
if (-not (Test-Path -LiteralPath $cert)) { throw "No USOS certificate on the release layout (unsigned build): $cert" }
$thumbprint = (New-Object Security.Cryptography.X509Certificates.X509Certificate2($cert)).Thumbprint
$files = @(
    'zig-out\usb\EFI\BOOT\grubx64.efi',
    'zig-out\micro-linux\vmlinuz-virt',
    'zig-out\micro-linux\systemd-bootx64.efi',
    'zig-out\test-assets\ntfs_x64.efi',
    'zig-out\usb\EFI\USOS\touchi2c_x64.efi'
)
$failures = 0
foreach ($relative in $files) {
    $path = Join-Path $ProjectRoot $relative
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    $ok = ($signature.Status -eq 'Valid' -or $signature.Status -eq 'UnknownError') -and $signature.SignerCertificate -and $signature.SignerCertificate.Thumbprint -eq $thumbprint
    Write-Host ("[{0}] {1} status={2} signer={3}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $relative, $signature.Status, $signature.SignerCertificate.Subject)
    if (-not $ok) { $failures++ }
}
$tampered = Join-Path $env:TEMP 'usos-authenticode-tamper.efi'
$bytes = [IO.File]::ReadAllBytes((Join-Path $ProjectRoot 'zig-out\usb\EFI\BOOT\grubx64.efi'))
$bytes[0x2000] = $bytes[0x2000] -bxor 0xff
[IO.File]::WriteAllBytes($tampered, $bytes)
try {
    $status = (Get-AuthenticodeSignature -LiteralPath $tampered).Status
    $ok = $status -eq 'HashMismatch'
    Write-Host ("[{0}] tampered grubx64.efi status={1}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $status)
    if (-not $ok) { $failures++ }
} finally {
    Remove-Item -LiteralPath $tampered -ErrorAction SilentlyContinue
}
if ($failures) { throw "$failures Authenticode check(s) failed" }
Write-Host '[PASS] Windows accepts the USOS Authenticode signatures (hash and PKCS#7 valid; root intentionally untrusted)'
