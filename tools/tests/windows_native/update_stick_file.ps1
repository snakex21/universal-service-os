# Replace one file on the ESP of a test stick VHD (tools/tests/artifacts only).
#   update_stick_file.ps1 -VhdPath S.vhd -Source local\file -EspPath EFI\USOS\windows-native\vista-support.cpio
# The attached disk is checked by its Location (= the VHD) before anything is
# written; the ESP is reached through a temporary folder access path.
param(
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$EspPath
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$artifacts = [IO.Path]::GetFullPath((Join-Path $root 'tools\tests\artifacts'))
$VhdPath = [IO.Path]::GetFullPath($VhdPath)
if (-not $VhdPath.StartsWith($artifacts, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing image path outside tools/tests/artifacts: $VhdPath" }
$mount = "$VhdPath.esp"
Mount-DiskImage -ImagePath $VhdPath -NoDriveLetter | Out-Null
try {
    $disk = $null
    for ($i = 0; $i -lt 20 -and -not $disk; $i++) { Start-Sleep -Milliseconds 500; $disk = Get-DiskImage -ImagePath $VhdPath | Get-Disk -ErrorAction SilentlyContinue }
    if (-not $disk -or $disk.Location -ne $VhdPath) { throw 'attached disk is not the VHD' }
    $esp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
    if (@($esp).Count -ne 1) { throw 'the stick VHD has no unique ESP' }
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -AccessPath "$mount\"
    try {
        $target = Join-Path $mount $EspPath
        Copy-Item -LiteralPath $Source -Destination $target -Force
        $a = (Get-FileHash -LiteralPath $Source).Hash; $b = (Get-FileHash -LiteralPath $target).Hash
        if ($a -ne $b) { throw "readback mismatch for $EspPath" }
        Write-Host "[PASS] $EspPath = $a"
    } finally { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -AccessPath "$mount\" }
} finally {
    Dismount-DiskImage -ImagePath $VhdPath | Out-Null
    if (Test-Path -LiteralPath $mount) { Remove-Item -LiteralPath $mount -Force }
}
