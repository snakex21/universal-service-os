param(
    [string]$BasePath = 'tools/tests/artifacts/qemu/usos-installer-windows-base.vhd',
    [string]$OverlayPath = 'tools/tests/artifacts/qemu/usos-installer-windows-overlay.qcow2',
    [string]$TargetPath = 'tools/tests/artifacts/qemu/usos-installer-full-target.qcow2',
    [string]$ConfigDir = 'tools/tests/artifacts/qemu/usos-installer-full-config',
    [string]$QemuPath = 'tools/qemu/qemu-system-x86_64.exe',
    [string]$QemuImgPath = 'tools/qemu/qemu-img.exe',
    [ValidateSet('auto','whpx','tcg')]
    [string]$Accel = 'tcg'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'process_argument_line.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}
$BasePath = Full $BasePath
$OverlayPath = Full $OverlayPath
$TargetPath = Full $TargetPath
$ConfigDir = Full $ConfigDir
$QemuPath = Full $QemuPath
$QemuImgPath = Full $QemuImgPath
$testImages = Full 'tools/tests/artifacts/qemu'
$firmwareCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVarsSource = Full 'tools/qemu/share/edk2-i386-vars.fd'
$tagSource = Full 'tools/tests/fixtures/installer/winpe-gpt-qemu/USOS_QEMU_TEST.TAG'
$installerDir = Full 'installer'
$configVhd = Full 'tools/tests/artifacts/qemu/usos-installer-full-config.vhd'

foreach ($path in @($BasePath,$OverlayPath,$TargetPath,$ConfigDir,$configVhd)) {
    if (-not $path.StartsWith($testImages, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing test path outside tools/tests/artifacts/qemu: $path"
    }
}
foreach ($required in @($BasePath,$QemuPath,$QemuImgPath,$firmwareCode,$firmwareVarsSource,$tagSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}

$active = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and ($_.CommandLine.Contains($OverlayPath) -or $_.CommandLine.Contains($TargetPath))
})
if ($active.Count -gt 0) {
    throw "Installer full QEMU test is already running: PID=$($active[0].ProcessId)"
}

Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null
Remove-Item -LiteralPath $OverlayPath,$TargetPath,$configVhd -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $ConfigDir) { Remove-Item -LiteralPath $ConfigDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$varsPath = Join-Path $ConfigDir 'edk2-vars.fd'
Copy-Item -LiteralPath $firmwareVarsSource -Destination $varsPath -Force
$qemuErr = Join-Path $ConfigDir 'qemu.stderr.log'
$qemuOut = Join-Path $ConfigDir 'qemu.stdout.log'
$serialLog = Join-Path $ConfigDir 'serial.log'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/build_legacy_bios.ps1')
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS build failed: $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/generate_legacy_boot_payload.ps1')
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS payload generation failed: $LASTEXITCODE" }

Push-Location $installerDir
try {
    $finalInstaller = Join-Path $installerDir 'USOS Installer.exe'
    & go.exe build -trimpath -ldflags '-H=windowsgui' -o $finalInstaller ./cmd/usos-installer
    if ($LASTEXITCODE -ne 0) { throw "go build final USOS Installer.exe failed: $LASTEXITCODE" }
    Copy-Item -LiteralPath $finalInstaller -Destination (Join-Path $ConfigDir 'USOS Installer.exe') -Force

    & go.exe build -trimpath -o (Join-Path $ConfigDir 'usos-installer-qemu-e2e.exe') ./cmd/usos-installer-qemu-e2e
    if ($LASTEXITCODE -ne 0) { throw "go build E2E executable failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

& $QemuImgPath create -f vpc -o subformat=fixed $configVhd 512M | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img create config VHD failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $configVhd 0 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "failed to clear sparse flag on config VHD: $LASTEXITCODE" }
$configMounted = $false
try {
    Mount-DiskImage -ImagePath $configVhd -StorageType VHD -NoDriveLetter | Out-Null
    $configMounted = $true
    $configDisk = Get-DiskImage -ImagePath $configVhd | Get-Disk
    if ($null -eq $configDisk) { throw 'config VHD did not expose a disk' }
    Initialize-Disk -Number $configDisk.Number -PartitionStyle MBR | Out-Null
    $configPart = New-Partition -DiskNumber $configDisk.Number -UseMaximumSize -AssignDriveLetter
    $configPart | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_CONFIG' -Force -Confirm:$false | Out-Null
    $configRoot = "$($configPart.DriveLetter):\"
    Copy-Item -LiteralPath $tagSource -Destination (Join-Path $configRoot 'USOS_QEMU_TEST.TAG') -Force
    Copy-Item -LiteralPath (Join-Path $ConfigDir 'USOS Installer.exe') -Destination (Join-Path $configRoot 'USOS Installer.exe') -Force
    Copy-Item -LiteralPath (Join-Path $ConfigDir 'usos-installer-qemu-e2e.exe') -Destination (Join-Path $configRoot 'usos-installer-qemu-e2e.exe') -Force
} finally {
    if ($configMounted) { Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null }
}

$baseInfo = (& $QemuImgPath info --output=json $BasePath | Out-String | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($baseInfo.format)) { throw 'qemu-img info failed for Windows base' }
& $QemuImgPath create -f qcow2 -F $baseInfo.format -b $BasePath $OverlayPath
if ($LASTEXITCODE -ne 0) { throw "qemu-img create Windows overlay failed: $LASTEXITCODE" }
& $QemuImgPath check $OverlayPath
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed for fresh Windows overlay: $LASTEXITCODE" }
& $QemuImgPath create -f qcow2 $TargetPath 40G
if ($LASTEXITCODE -ne 0) { throw "qemu-img create target failed: $LASTEXITCODE" }
& $QemuImgPath check $TargetPath
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed for fresh target image: $LASTEXITCODE" }

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}
$monitorPort = Get-FreeTcpPort
$accelArg = 'tcg,thread=multi'
if ($Accel -eq 'whpx') {
    $accelArg = 'whpx'
} elseif ($Accel -eq 'auto') {
    $accelHelp = (& $QemuPath -accel help 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $accelHelp -match '(?m)^whpx\s*$') { $accelArg = 'whpx' }
}
Write-Host "[INFO] QEMU accelerator: $accelArg"

$qemuArgs = @(
    '-machine','q35',
    '-accel',$accelArg,
    '-cpu','max',
    '-m','4096',
    '-smp','4',
    '-nic','none',
    '-display','none',
    '-rtc','base=localtime',
    '-monitor',"tcp:127.0.0.1:$monitorPort,server=on,wait=off",
    '-serial',"file:$($serialLog.Replace('\','/'))",
    '-drive',"if=pflash,format=raw,readonly=on,file=$firmwareCode",
    '-drive',"if=pflash,format=raw,file=$varsPath",
    '-drive',"if=none,id=os,file=$OverlayPath,format=qcow2,cache=unsafe",
    '-device','ide-hd,bus=ide.0,drive=os,bootindex=1',
    '-device','qemu-xhci,id=xhci',
    '-drive',"if=none,id=usostarget,file=$TargetPath,format=qcow2,cache=unsafe",
    '-device','usb-storage,bus=xhci.0,drive=usostarget,removable=on,serial=USOS-GPT-TEST',
    '-drive',"if=none,id=usoscfg,file=$configVhd,format=vpc,cache=unsafe",
    '-device','usb-storage,bus=xhci.0,drive=usoscfg,removable=on,serial=USOS-CONFIG'
)

$process = Start-Process -FilePath $QemuPath -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $qemuArgs) -PassThru -RedirectStandardError $qemuErr -RedirectStandardOutput $qemuOut
[IO.File]::WriteAllText((Join-Path $ConfigDir 'qemu.pid'), [string]$process.Id)
[IO.File]::WriteAllText((Join-Path $ConfigDir 'monitor.port'), [string]$monitorPort)
Write-Host "[PASS] QEMU full installer E2E started PID=$($process.Id) monitor=$monitorPort"
Write-Host "SERIAL_LOG=$serialLog"
Write-Host "CONFIG_VHD=$configVhd"
Write-Host "OVERLAY=$OverlayPath"
Write-Host "TARGET=$TargetPath"
