<#
.SYNOPSIS
  Test-only: restore the native-path stick VHD from its pristine copy, replace
  ESP files with fresh build outputs, and take a read-only baseline snapshot
  with tools/compare_esp_snapshot.ps1 (-AllowVirtualDisk).
#>
param(
    [string]$Vhd = 'tools\tests\artifacts\windows-native\stick.vhd',
    [string[]]$EspFiles = @('EFI\USOS\windows-native\modern-support.cpio=zig-out\windows-native\modern-support.cpio'),
    [string]$Baseline = 'tools\tests\artifacts\windows-native\baseline'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
Set-Location $root
$Vhd = (Resolve-Path $Vhd).Path
Copy-Item "$Vhd.pristine" $Vhd -Force
Mount-DiskImage -ImagePath $Vhd -NoDriveLetter | Out-Null
try {
    Start-Sleep 2
    $disk = Get-DiskImage -ImagePath $Vhd | Get-Disk
    $esp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
    $volume = ($esp | Get-Volume).Path
    foreach ($pair in $EspFiles) {
        $target, $source = $pair.Split('=', 2)
        [IO.File]::Copy((Join-Path $root $source), $volume + $target, $true)
        Write-Host "[REFRESH] $target <- $source"
    }
    $guid = "$($disk.Guid)"
} finally { Dismount-DiskImage -ImagePath $Vhd | Out-Null }
Mount-DiskImage -ImagePath $Vhd -Access ReadOnly -NoDriveLetter | Out-Null
try {
    Start-Sleep 2
    if (Test-Path $Baseline) { Remove-Item $Baseline -Recurse -Force }
    & .\tools\compare_esp_snapshot.ps1 -SnapshotOnly -AllowVirtualDisk -OutDir $Baseline -DiskGuid $guid | Select-Object -Last 1
} finally { Dismount-DiskImage -ImagePath $Vhd | Out-Null }
Write-Host "[REFRESH] disk $guid ready; baseline $Baseline"
