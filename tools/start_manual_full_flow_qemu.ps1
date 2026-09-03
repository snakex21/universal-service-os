param(
    [switch]$Fresh,
    [int]$MemoryMiB = 4096,
    [int]$CpuCount = 4,
    [int]$WindowsDiskGiB = 64
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = [IO.Path]::GetFullPath((Join-Path $root 'tools/tests/artifacts/qemu'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$firmwareCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVarsSource = Full 'tools/qemu/share/edk2-i386-vars.fd'
$base = Full 'tools/tests/artifacts/qemu/usos-e2e-base.qcow2'
$overlay = Full 'tools/tests/artifacts/qemu/usos-manual-run.qcow2'
$windowsDisk = Full 'tools/tests/artifacts/qemu/usos-manual-windows.qcow2'
$runDir = Full 'tools/tests/artifacts/qemu/usos-manual-run'
$firmwareVars = Join-Path $runDir 'edk2-vars.fd'
$serialLog = Join-Path $runDir 'serial.log'
$qemuLog = Join-Path $runDir 'qemu.stderr.log'
$pidFile = Join-Path $runDir 'qemu.pid'
$monitorFile = Join-Path $runDir 'monitor.port'
$unattend = Full 'media/Systems/Windows/Windows 11/Unattended/win10-11 best-ustawienia.xml'

foreach ($path in @($overlay, $windowsDisk, $runDir)) {
    if (-not $path.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing manual-test path outside tools/tests/artifacts/qemu: $path"
    }
}
foreach ($required in @($qemu, $qemuImg, $firmwareCode, $firmwareVarsSource, $base, $unattend)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing required file: $required"
    }
}
if ($MemoryMiB -lt 2048 -or $MemoryMiB -gt 32768) { throw 'MemoryMiB must be in range 2048..32768' }
if ($CpuCount -lt 1 -or $CpuCount -gt 16) { throw 'CpuCount must be in range 1..16' }
if ($WindowsDiskGiB -lt 40 -or $WindowsDiskGiB -gt 512) { throw 'WindowsDiskGiB must be in range 40..512' }

$unattendText = Get-Content -LiteralPath $unattend -Raw
try { $null = [xml]$unattendText } catch { throw "Invalid unattended XML: $($_.Exception.Message)" }
if ($unattendText -match '<\s*(DiskConfiguration|InstallTo)\b') {
    throw 'Refusing unattended XML that contains automatic disk selection or partitioning'
}
foreach ($bypass in @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck', 'BypassStorageCheck')) {
    if ($unattendText -notmatch [regex]::Escape($bypass)) { throw "Unattended XML is missing $bypass" }
}

$active = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and ($_.CommandLine.Contains($overlay) -or $_.CommandLine.Contains($windowsDisk))
})
if ($active.Count -gt 0) { throw "Manual USOS QEMU is already running: PID=$($active[0].ProcessId)" }

& $qemuImg check $base
if ($LASTEXITCODE -ne 0) { throw "Base qcow2 check failed: $LASTEXITCODE" }

New-Item -ItemType Directory -Force -Path $runDir | Out-Null
if ($Fresh) {
    foreach ($path in @($overlay, $windowsDisk, $firmwareVars, $serialLog, $qemuLog, $pidFile, $monitorFile)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
}

$overlayExists = Test-Path -LiteralPath $overlay -PathType Leaf
$windowsDiskExists = Test-Path -LiteralPath $windowsDisk -PathType Leaf
if ($overlayExists -xor $windowsDiskExists) {
    throw 'Incomplete manual-test state. Run RESET-USOS-TEST.cmd, then TEST-USOS.cmd.'
}
if (-not $overlayExists) {
    & (Full 'tools/create_qcow2_overlay.ps1') -QemuImgPath $qemuImg -BasePath $base -OverlayPath $overlay
    if ($LASTEXITCODE -ne 0) { throw "USOS overlay creation failed: $LASTEXITCODE" }
    & $qemuImg create -f qcow2 $windowsDisk "${WindowsDiskGiB}G"
    if ($LASTEXITCODE -ne 0) { throw "Windows target creation failed: $LASTEXITCODE" }
}
foreach ($image in @($overlay, $windowsDisk)) {
    & $qemuImg check $image
    if ($LASTEXITCODE -ne 0) { throw "qcow2 check failed for $image with exit code $LASTEXITCODE" }
}
if (-not (Test-Path -LiteralPath $firmwareVars -PathType Leaf)) {
    Copy-Item -LiteralPath $firmwareVarsSource -Destination $firmwareVars
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}
function Resolve-QemuAccelerator {
    $probeLog = Join-Path $runDir 'whpx-probe.err'
    Remove-Item -LiteralPath $probeLog -Force -ErrorAction SilentlyContinue
    $probeArgs = @(
        '-machine', 'q35',
        '-accel', 'whpx',
        '-cpu', 'max',
        '-m', '64M',
        '-nodefaults',
        '-display', 'none',
        '-monitor', 'none',
        '-serial', 'none',
        '-S'
    )
    try {
        $probe = Start-Process -FilePath $qemu -ArgumentList $probeArgs -PassThru -RedirectStandardError $probeLog
        if ($probe.WaitForExit(1200)) {
            return 'tcg,thread=multi'
        }
        Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue
        $probe.WaitForExit()
        return 'whpx'
    } catch {
        return 'tcg,thread=multi'
    }
}

$monitorPort = Get-FreeTcpPort
$accelerator = Resolve-QemuAccelerator
Remove-Item -LiteralPath $qemuLog -Force -ErrorAction SilentlyContinue

$args = @(
    '-name', 'USOS-manual-full-flow-test',
    '-machine', 'q35',
    '-accel', $accelerator,
    '-cpu', 'max',
    '-m', [string]$MemoryMiB,
    '-smp', [string]$CpuCount,
    '-nic', 'none',
    '-rtc', 'base=localtime',
    '-display', 'gtk',
    '-vga', 'std',
    '-boot', 'menu=on,strict=on',
    '-monitor', "tcp:127.0.0.1:$monitorPort,server=on,wait=off",
    '-serial', "file:$($serialLog.Replace('\','/'))",
    '-drive', "if=pflash,format=raw,readonly=on,file=$firmwareCode",
    '-drive', "if=pflash,format=raw,file=$firmwareVars",
    '-drive', "if=none,id=usos,file=$overlay,format=qcow2,cache=writeback",
    '-device', 'ide-hd,bus=ide.0,drive=usos,bootindex=1,serial=USOS-MANUAL',
    '-drive', "if=none,id=windows,file=$windowsDisk,format=qcow2,cache=writeback",
    '-device', 'ide-hd,bus=ide.1,drive=windows,bootindex=2,serial=WINDOWS-TARGET',
    '-device', 'qemu-xhci,id=input-xhci',
    '-device', 'usb-kbd,bus=input-xhci.0'
)
if (($args -join ' ') -match '(?i)PhysicalDrive') { throw 'Refusing physical disk in manual QEMU arguments' }

$process = Start-Process -FilePath $qemu -ArgumentList $args -PassThru -RedirectStandardError $qemuLog
[IO.File]::WriteAllText($pidFile, [string]$process.Id)
[IO.File]::WriteAllText($monitorFile, [string]$monitorPort)

Write-Host ''
Write-Host '[PASS] Visible QEMU window started.' -ForegroundColor Green
Write-Host "Accelerator: $accelerator"
Write-Host "PID: $($process.Id)"
Write-Host 'USOS disk: 24 GiB overlay (do not install Windows here)'
Write-Host "Windows target: $WindowsDiskGiB GiB empty qcow2 (select this disk in Windows Setup)"
Write-Host 'Unattended profile already stored on DATA: win10-11 best-ustawienia.xml'
Write-Host "Serial log: $serialLog"
Write-Host ''
Write-Host 'Choose in USOS: Windows -> Windows 11 -> ISO -> setup method -> unattended.xml.' -ForegroundColor Cyan
Write-Host "In Windows Setup choose only the empty $WindowsDiskGiB GiB disk." -ForegroundColor Yellow
Write-Host 'Closing the QEMU window affects only qcow2 files in tools/tests/artifacts/qemu.'
