param(
    [string]$BasePath = 'test-images/usos-installer-windows-base.raw',
    [string]$OverlayPath = 'test-images/usos-installer-windows-overlay.qcow2',
    [string]$TargetPath = 'test-images/usos-installer-full-target.qcow2',
    [string]$ConfigDir = 'test-images/usos-installer-full-config',
    [string]$QemuPath = 'tools/qemu/qemu-system-x86_64.exe',
    [string]$QemuImgPath = 'tools/qemu/qemu-img.exe'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
$BasePath = Full $BasePath
$OverlayPath = Full $OverlayPath
$TargetPath = Full $TargetPath
$ConfigDir = Full $ConfigDir
$QemuPath = Full $QemuPath
$QemuImgPath = Full $QemuImgPath
$testImages = Full 'test-images'
$firmwareCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVarsSource = Full 'tools/qemu/share/edk2-i386-vars.fd'
$tagSource = Full 'installer/testdata/winpe-gpt-qemu/USOS_QEMU_TEST.TAG'
$installerDir = Full 'installer'

foreach ($path in @($BasePath,$OverlayPath,$TargetPath,$ConfigDir)) {
    if (-not $path.StartsWith($testImages, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing test path outside test-images: $path"
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

Remove-Item -LiteralPath $OverlayPath,$TargetPath -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $ConfigDir) { Remove-Item -LiteralPath $ConfigDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Copy-Item -LiteralPath $tagSource -Destination (Join-Path $ConfigDir 'USOS_QEMU_TEST.TAG') -Force
$varsPath = Join-Path $ConfigDir 'edk2-vars.fd'
Copy-Item -LiteralPath $firmwareVarsSource -Destination $varsPath -Force
$resultPath = Join-Path $ConfigDir 'usos-installer-e2e-result.txt'
$qemuErr = Join-Path $ConfigDir 'qemu.stderr.log'
$qemuOut = Join-Path $ConfigDir 'qemu.stdout.log'

Push-Location $installerDir
try {
    $finalInstaller = Join-Path $installerDir 'build\USOS Installer.exe'
    & go.exe build -trimpath -ldflags '-H=windowsgui' -o $finalInstaller ./cmd/usos-installer
    if ($LASTEXITCODE -ne 0) { throw "go build final USOS Installer.exe failed: $LASTEXITCODE" }
    Copy-Item -LiteralPath $finalInstaller -Destination (Join-Path $ConfigDir 'USOS Installer.exe') -Force

    & go.exe build -trimpath -o (Join-Path $ConfigDir 'usos-installer-qemu-e2e.exe') ./cmd/usos-installer-qemu-e2e
    if ($LASTEXITCODE -ne 0) { throw "go build E2E executable failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

& $QemuImgPath create -f qcow2 -F raw -b $BasePath $OverlayPath
if ($LASTEXITCODE -ne 0) { throw "qemu-img create Windows overlay failed: $LASTEXITCODE" }
& $QemuImgPath create -f qcow2 $TargetPath 40G
if ($LASTEXITCODE -ne 0) { throw "qemu-img create target failed: $LASTEXITCODE" }

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}
$monitorPort = Get-FreeTcpPort
$configFat = 'fat:rw:' + ($ConfigDir -replace '\\','/')

$args = @(
    '-machine','q35',
    '-accel','tcg,thread=multi',
    '-cpu','max',
    '-m','4096',
    '-smp','4',
    '-nic','none',
    '-display','none',
    '-rtc','base=localtime',
    '-monitor',"tcp:127.0.0.1:$monitorPort,server=on,wait=off",
    '-drive',"if=pflash,format=raw,readonly=on,file=$firmwareCode",
    '-drive',"if=pflash,format=raw,file=$varsPath",
    '-drive',"if=none,id=os,file=$OverlayPath,format=qcow2,cache=unsafe",
    '-device','ide-hd,bus=ide.0,drive=os,bootindex=1',
    '-device','qemu-xhci,id=xhci',
    '-drive',"if=none,id=usostarget,file=$TargetPath,format=qcow2,cache=unsafe",
    '-device','usb-storage,bus=xhci.0,drive=usostarget,removable=on,serial=USOS-GPT-TEST',
    '-drive',"if=none,id=usoscfg,file=$configFat,format=raw",
    '-device','usb-storage,bus=xhci.0,drive=usoscfg,removable=on,serial=USOS-CONFIG'
)

$process = Start-Process -FilePath $QemuPath -ArgumentList $args -PassThru -RedirectStandardError $qemuErr -RedirectStandardOutput $qemuOut
[IO.File]::WriteAllText((Join-Path $ConfigDir 'qemu.pid'), [string]$process.Id)
[IO.File]::WriteAllText((Join-Path $ConfigDir 'monitor.port'), [string]$monitorPort)
Write-Host "[PASS] QEMU full installer E2E started PID=$($process.Id) monitor=$monitorPort"
Write-Host "RESULT=$resultPath"
Write-Host "OVERLAY=$OverlayPath"
Write-Host "TARGET=$TargetPath"
