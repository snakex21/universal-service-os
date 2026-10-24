param(
    # Toolchain checkout (tools/qemu, tools/cache/efifs); defaults to this checkout.
    [string]$ToolsRoot = '',
    [int]$TimeoutSeconds = 40
)

# QEMU/OVMF check of the USOS partition handles for GPT bit 1
# (EFI_PART_ATTR_NO_BLOCK_IO_PROTOCOL) on DATA/WORK. A small Windows-made
# fixture (ESP FAT32 + DATA NTFS + WORK NTFS with .usos-work and an
# EFI/USOS-WORK boot file) is booted twice with the real efifs ntfs_x64.efi:
#   baseline  GPT names USOS_*, attributes 0  -> firmware handles, PASS
#   hidden    same plus bit 1 on DATA/WORK    -> OVMF makes no handles; USOS
#             installs its own; DATA/WORK SimpleFS, WORK discovery and
#             LoadImage from WORK must PASS
# Only disposable files under tools/tests/artifacts/qemu are touched.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\process_argument_line.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $ToolsRoot) { $ToolsRoot = $root }
$ToolsRoot = [IO.Path]::GetFullPath($ToolsRoot)
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Tool([string]$Path) { [IO.Path]::GetFullPath((Join-Path $ToolsRoot $Path)) }

$artifactRoot = Full 'tools/tests/artifacts/qemu/gpt-partition-handles'
$vhd = Join-Path $artifactRoot 'fixture.vhd'
$baseRaw = Join-Path $artifactRoot 'baseline.raw'
$hiddenRaw = Join-Path $artifactRoot 'hidden.raw'
$esp = Join-Path $artifactRoot 'probe-esp'
$qemu = Tool 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Tool 'tools/qemu/qemu-img.exe'
$firmwareCode = Tool 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVars = Tool 'tools/qemu/share/edk2-i386-vars.fd'
$ntfsDriver = Tool 'tools/cache/efifs/ntfs_x64.efi'
$patcher = Full 'tools/tests/gpt_patch_no_block_io.py'
$probeEfi = Full 'zig-out/test-assets/gpt-no-block-io-probe-x86_64.efi'

$allowedRoot = Full 'tools/tests/artifacts/qemu'
foreach ($path in @($artifactRoot,$vhd,$baseRaw,$hiddenRaw,$esp)) {
    if (-not $path.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing test path outside tools/tests/artifacts/qemu: $path" }
}
foreach ($required in @($qemu,$qemuImg,$firmwareCode,$firmwareVars,$ntfsDriver,$patcher,$probeEfi)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required (build: zig build gpt-no-block-io-probe-app)" }
}

New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
Get-ChildItem -LiteralPath $artifactRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $esp 'EFI\BOOT'),(Join-Path $esp 'EFI\USOS') | Out-Null
Copy-Item -LiteralPath $probeEfi -Destination (Join-Path $esp 'EFI\BOOT\BOOTX64.EFI') -Force
Copy-Item -LiteralPath $ntfsDriver -Destination (Join-Path $esp 'EFI\USOS\ntfs_x64.efi') -Force

& $qemuImg create -f vpc -o subformat=fixed $vhd 640M | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $vhd 0 | Out-Null
$mounted = $false
try {
    Mount-DiskImage -ImagePath $vhd -StorageType VHD -NoDriveLetter | Out-Null
    $mounted = $true
    Start-Sleep -Milliseconds 500
    $disk = Get-DiskImage -ImagePath $vhd | Get-Disk
    if ($null -eq $disk -or $disk.PartitionStyle -ne 'RAW' -or $disk.Size -gt 1GB) { throw 'fixture VHD did not attach as a new small RAW disk' }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $p1 = New-Partition -DiskNumber $disk.Number -Size 100MB -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
    $p2 = New-Partition -DiskNumber $disk.Number -Size 200MB -GptType '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
    $p3 = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
    $p1 | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    $p2 | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
    $p3 | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_WORK' -Confirm:$false -Force | Out-Null
    # Letters only after formatting (no Windows "format this disk" prompt).
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $p2.PartitionNumber -AssignDriveLetter | Out-Null
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $p3.PartitionNumber -AssignDriveLetter | Out-Null
    $data = Get-Partition -DiskNumber $disk.Number -PartitionNumber $p2.PartitionNumber
    $work = Get-Partition -DiskNumber $disk.Number -PartitionNumber $p3.PartitionNumber
    $workRoot = "$($work.DriveLetter):\"
    $dataRoot = "$($data.DriveLetter):\"
    [IO.File]::WriteAllText((Join-Path $workRoot '.usos-work'), "nonce=partition-handles`r`n")
    New-Item -ItemType Directory -Force -Path (Join-Path $workRoot 'EFI\USOS-WORK') | Out-Null
    Copy-Item -LiteralPath $probeEfi -Destination (Join-Path $workRoot 'EFI\USOS-WORK\BOOTX64.EFI') -Force
    [IO.File]::WriteAllText((Join-Path $dataRoot 'usos-data-marker.txt'), "DATA`r`n")
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null }
}

& $qemuImg convert -f vpc -O raw $vhd $baseRaw
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert failed: $LASTEXITCODE" }
Remove-Item -LiteralPath $vhd -Force
& py.exe -3 -I $patcher $baseRaw --usos-names --names-only
if ($LASTEXITCODE -ne 0) { throw "GPT name patch failed: $LASTEXITCODE" }
Copy-Item -LiteralPath $baseRaw -Destination $hiddenRaw -Force
& py.exe -3 -I $patcher $hiddenRaw --usos-names
if ($LASTEXITCODE -ne 0) { throw "GPT bit 1 patch failed: $LASTEXITCODE" }

function Run-Probe([string]$name, [string]$image) {
    $serial = Join-Path $artifactRoot "$name-serial.log"
    $vars = Join-Path $artifactRoot "$name-vars.fd"
    $qemuErr = Join-Path $artifactRoot "$name-qemu.stderr.log"
    Copy-Item -LiteralPath $firmwareVars -Destination $vars -Force
    $espForQemu = $esp.Replace('\','/')
    $qargs = @(
        '-name',"USOS-partition-handles-$name", '-machine','q35', '-accel','tcg,thread=multi', '-cpu','max', '-m','512', '-smp','2',
        '-nic','none', '-display','none', '-monitor','none', '-serial',"file:$($serial.Replace('\','/'))",
        '-drive',"if=pflash,format=raw,readonly=on,file=$firmwareCode", '-drive',"if=pflash,format=raw,file=$vars",
        '-drive',"if=none,id=probeesp,format=raw,file=fat:rw:$espForQemu",
        '-device','ide-hd,bus=ide.0,drive=probeesp,bootindex=1',
        '-drive',"if=none,id=usostest,file=$($image.Replace('\','/')),format=raw,cache=writeback",
        '-device','ide-hd,bus=ide.1,drive=usostest,bootindex=2', '-no-reboot'
    )
    if (($qargs -join ' ') -match '(?i)PhysicalDrive') { throw 'Refusing physical disk in QEMU arguments.' }
    $process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $qargs) -PassThru -RedirectStandardError $qemuErr
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $result = 'TIMEOUT'
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if (Test-Path -LiteralPath $serial -PathType Leaf) {
            $text = Get-Content -LiteralPath $serial -Raw -ErrorAction SilentlyContinue
            if ($text -match 'NO-BLOCK-IO VISIBILITY PASS') { $result = 'PASS'; break }
            if ($text -match 'NO-BLOCK-IO VISIBILITY FAIL') { $result = 'FAIL'; break }
        }
    }
    Start-Sleep -Milliseconds 300
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $text = if (Test-Path -LiteralPath $serial) { Get-Content -LiteralPath $serial -Raw } else { '' }
    Write-Host "----- $name -----"
    Write-Host $text
    return [pscustomobject]@{ Name = $name; Result = $result; Text = $text }
}

$baseline = Run-Probe 'baseline' $baseRaw
$hidden = Run-Probe 'hidden' $hiddenRaw
$ok = $true
if ($baseline.Result -ne 'PASS') { Write-Host '[FAIL] baseline (attributes 0) probe' -ForegroundColor Red; $ok = $false }
if ($baseline.Text -match 'USOS PARTITION HANDLES INSTALLED') { Write-Host '[FAIL] baseline installed USOS handles although the firmware made them' -ForegroundColor Red; $ok = $false }
if ($hidden.Result -ne 'PASS') { Write-Host '[FAIL] hidden (bit 1) probe' -ForegroundColor Red; $ok = $false }
if ($hidden.Text -notmatch 'USOS PARTITION HANDLES INSTALLED') { Write-Host '[FAIL] hidden probe did not use USOS partition handles' -ForegroundColor Red; $ok = $false }
if ($hidden.Text -match 'FIRMWARE IGNORED GPT BIT 1') { Write-Host '[FAIL] OVMF ignored bit 1; the hidden case was not exercised' -ForegroundColor Red; $ok = $false }
if ($hidden.Text -notmatch 'WORK LOADIMAGE PASS') { Write-Host '[FAIL] hidden probe: no LoadImage from WORK' -ForegroundColor Red; $ok = $false }
if (-not $ok) { exit 1 }
Remove-Item -LiteralPath $baseRaw,$hiddenRaw -Force
Write-Host '[PASS] GPT bit 1: firmware handles absent, USOS partition handles give DATA/WORK SimpleFS, WORK discovery and LoadImage' -ForegroundColor Green
exit 0
