# Replaces the ESP content of the Linux ISO test disk with -EspSource (default
# zig-out/usb; after `usos-efisign release` that is the shim chain, else the
# unsigned USOS as EFI\BOOT\BOOTX64.EFI). DATA and its ISOs stay. Also puts
# the Legacy BIOS pieces in place like the installer does: bios-ui.bin on the
# ESP, Stage 1 in the MBR code area and the Core slot at LBA 64. Elevated.
param(
    [string]$Vhd = "",
    [string]$EspSource = ""
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if (-not $Vhd) { $Vhd = Join-Path $root 'tools\tests\artifacts\linux-iso\usos-linux-test.vhd' }
if (-not $EspSource) { $EspSource = Join-Path $root 'zig-out\usb' }
$legacy = Join-Path $root 'zig-out\legacy-bios'
Mount-DiskImage -ImagePath $Vhd -StorageType VHD -NoDriveLetter | Out-Null
Start-Sleep -Milliseconds 500
$disk = Get-DiskImage -ImagePath $Vhd | Get-Disk
if ($null -eq $disk -or $disk.BusType -ne 'File Backed Virtual') { throw 'Test VHD did not expose a file-backed disk' }
$esp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
$path = "$Vhd.esp"
try {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -AccessPath $path
    & robocopy.exe $EspSource $path /E /XD "System Volume Information" (Join-Path $EspSource "Systems") /R:0 /W:0 /COPY:D /DCOPY:D /NP /NDL /NJH /LOG:"$Vhd.esp.log" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy ESP failed: $LASTEXITCODE" }
    $ui = Join-Path $legacy 'bios-ui.bin'
    if (Test-Path -LiteralPath $ui) { Copy-Item -LiteralPath $ui -Destination (Join-Path $path 'EFI\USOS\bios-ui.bin') -Force }
} finally {
    Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -AccessPath $path -Confirm:$false -ErrorAction SilentlyContinue
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}
$stage1Path = Join-Path $legacy 'stage1.bin'
$corePath = Join-Path $legacy 'core-slot.bin'
if ((Test-Path -LiteralPath $stage1Path) -and (Test-Path -LiteralPath $corePath)) {
    $stage1 = [IO.File]::ReadAllBytes($stage1Path)
    $core = [IO.File]::ReadAllBytes($corePath)
    $stream = [IO.File]::Open($Vhd, 'Open', 'ReadWrite')
    try {
        $stream.Position = 0
        $stream.Write($stage1, 0, 440)
        $stream.Position = 64 * 512
        $stream.Write($core, 0, $core.Length)
    } finally {
        $stream.Dispose()
    }
    Write-Host "[PASS] Legacy Stage 1 + Core slot written"
}
Write-Host "[PASS] ESP of $Vhd <- $EspSource"
exit 0
