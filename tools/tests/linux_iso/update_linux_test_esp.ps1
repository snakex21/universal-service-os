# Replaces the ESP content of the Linux ISO test disk with -EspSource (default
# zig-out/manual-usb: unsigned USOS as EFI\BOOT\BOOTX64.EFI, for Secure Boot
# off; use zig-out/usb for the shim chain). DATA and its ISOs stay. Elevated.
param(
    [string]$Vhd = "",
    [string]$EspSource = ""
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if (-not $Vhd) { $Vhd = Join-Path $root 'tools\tests\artifacts\linux-iso\usos-linux-test.vhd' }
if (-not $EspSource) { $EspSource = Join-Path $root 'zig-out\manual-usb' }
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
} finally {
    Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -AccessPath $path -Confirm:$false -ErrorAction SilentlyContinue
    Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}
Write-Host "[PASS] ESP of $Vhd <- $EspSource"
exit 0
