# Replaces the ESP content of the Linux ISO test disk with -EspSource (default
# zig-out/usb; after `usos-efisign release` that is the shim chain, else the
# unsigned USOS as EFI\BOOT\BOOTX64.EFI). DATA and its ISOs stay. Also puts
# the Legacy BIOS pieces in place like the installer does: bios-ui.bin on the
# ESP, Stage 1 in the MBR code area and the Core slot at LBA 64. Elevated.
param(
    [string]$Vhd = "",
    [string]$EspSource = "",
    # Also put this answer profile into EFI\USOS\profiles (test runs only).
    [string]$Profile = "",
    # Extra ISOs for DATA: "<manifest.json name>=<Systems\Linux folder>".
    [string[]]$AddIso = @()
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
    if ($Profile) {
        New-Item -ItemType Directory -Force -Path (Join-Path $path 'EFI\USOS\profiles') | Out-Null
        Copy-Item -LiteralPath $Profile -Destination (Join-Path $path 'EFI\USOS\profiles') -Force
    }
    if ($AddIso.Count -gt 0) {
        $assets = Join-Path $env:LOCALAPPDATA 'USOS\test-assets\linux'
        $manifest = Get-Content (Join-Path $assets 'manifest.json') -Raw | ConvertFrom-Json
        $data = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' } | Select-Object -First 1
        $dataPath = "$Vhd.data"
        New-Item -ItemType Directory -Force -Path $dataPath | Out-Null
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $data.PartitionNumber -AccessPath $dataPath
        try {
            foreach ($item in $AddIso) {
                $name, $folder = $item.Split('=', 2)
                $file = $manifest.$name.file
                $dir = Join-Path $dataPath "Systems\Linux\$folder\Images"
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                & robocopy.exe $assets $dir $file /J /R:2 /W:2 /NP /NFL /NDL /NJH /NJS | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "robocopy $file failed: $LASTEXITCODE" }
                Write-Host "[PASS] DATA += $folder\$file"
            }
        } finally {
            Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $data.PartitionNumber -AccessPath $dataPath -Confirm:$false -ErrorAction SilentlyContinue
            [IO.Directory]::Delete($dataPath)
        }
    }
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
