param(
    [string]$IsoPath = 'media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso',
    [string]$QemuPath = 'tools/qemu/qemu-system-x86_64.exe',
    [string]$QemuImgPath = 'tools/qemu/qemu-img.exe',
    [string]$FirmwareCode = 'tools/qemu/share/edk2-x86_64-code.fd',
    [string]$FirmwareVars = 'tools/qemu/share/edk2-i386-vars.fd',
    [string]$TargetImage = 'tools/tests/artifacts/qemu/usos-installer-gpt-target.qcow2',
    [string]$RuntimeConfigDir = 'tools/tests/artifacts/qemu/usos-installer-gpt-config',
    [int]$TimeoutSeconds = 260
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$path) { [IO.Path]::GetFullPath((Join-Path $root $path)) }

$IsoPath = Full $IsoPath
$QemuPath = Full $QemuPath
$QemuImgPath = Full $QemuImgPath
$FirmwareCode = Full $FirmwareCode
$FirmwareVars = Full $FirmwareVars
$TargetImage = Full $TargetImage
$RuntimeConfigDir = Full $RuntimeConfigDir
$testImagesRoot = Full 'tools/tests/artifacts/qemu'
$templateDir = Full 'tools/tests/fixtures/installer/winpe-gpt-qemu'
$installerDir = Full 'installer'
$testExe = Join-Path $RuntimeConfigDir 'usos-gpt-qemu-test.exe'
$resultPath = Join-Path $RuntimeConfigDir 'usos-gpt-result.txt'
$varsCopy = Join-Path $RuntimeConfigDir 'edk2-vars.fd'
$qemuErr = Join-Path $RuntimeConfigDir 'qemu.stderr.log'
$screenPath = Join-Path $RuntimeConfigDir 'timeout-screen.ppm'

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Send-Hmp([int]$port, [string]$command) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', $port)
        $stream = $client.GetStream()
        $writer = [IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine($command)
        Start-Sleep -Milliseconds 500
    } finally {
        $client.Dispose()
    }
}

foreach ($required in @($IsoPath, $QemuPath, $QemuImgPath, $FirmwareCode, $FirmwareVars)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
if (-not $TargetImage.StartsWith($testImagesRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing target image outside tools/tests/artifacts/qemu: $TargetImage"
}
if (-not $RuntimeConfigDir.StartsWith($testImagesRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing runtime config outside tools/tests/artifacts/qemu: $RuntimeConfigDir"
}
if ($TargetImage -match 'PhysicalDrive|\\\\\.\\') {
    throw "Refusing physical device target: $TargetImage"
}

New-Item -ItemType Directory -Force -Path $RuntimeConfigDir | Out-Null
Get-ChildItem -LiteralPath $RuntimeConfigDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Copy-Item -LiteralPath (Join-Path $templateDir 'Autounattend.xml') -Destination $RuntimeConfigDir
Copy-Item -LiteralPath (Join-Path $templateDir 'run-usos-gpt-test.cmd') -Destination $RuntimeConfigDir
Copy-Item -LiteralPath (Join-Path $templateDir 'USOS_QEMU_TEST.TAG') -Destination $RuntimeConfigDir
Copy-Item -LiteralPath $FirmwareVars -Destination $varsCopy

Push-Location $installerDir
try {
    & go.exe build -trimpath -o $testExe ./cmd/usos-gpt-qemu-test
    if ($LASTEXITCODE -ne 0) { throw "Go build failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

if (Test-Path -LiteralPath $TargetImage) { Remove-Item -LiteralPath $TargetImage -Force }
& $QemuImgPath create -f qcow2 $TargetImage 40G | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed: $LASTEXITCODE" }
& $QemuImgPath check $TargetImage | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed before test: $LASTEXITCODE" }

$configForQemu = $RuntimeConfigDir.Replace('\\','/').Replace('\','/')
$monitorPort = Get-FreeTcpPort
$arguments = @(
    '-machine','q35',
    '-accel','tcg',
    '-cpu','max',
    '-m','4096',
    '-smp','4',
    '-nic','none',
    '-display','none',
    '-no-reboot',
    '-boot','order=d,menu=off',
    '-monitor',"tcp:127.0.0.1:$monitorPort,server=on,wait=off",
    '-drive',"if=pflash,format=raw,readonly=on,file=$FirmwareCode",
    '-drive',"if=pflash,format=raw,file=$varsCopy",
    '-drive',"file=$IsoPath,media=cdrom,readonly=on",
    '-drive',"if=none,id=usostarget,file=$TargetImage,format=qcow2,cache=unsafe",
    '-device','qemu-xhci,id=xhci',
    '-device','usb-storage,bus=xhci.0,drive=usostarget,removable=on,serial=USOS-GPT-TEST',
    '-drive',"if=none,id=usoscfg,file=fat:rw:$configForQemu,format=raw",
    '-device','usb-storage,bus=xhci.0,drive=usoscfg,removable=on,serial=USOS-CONFIG'
)

$process = Start-Process -FilePath $QemuPath -ArgumentList $arguments -PassThru -RedirectStandardError $qemuErr
$startedAt = [DateTime]::UtcNow
$deadline = $startedAt.AddSeconds($TimeoutSeconds)
$nextBootKeyAt = $startedAt.AddSeconds(1)
while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    $now = [DateTime]::UtcNow
    if ($now -ge $nextBootKeyAt -and ($now - $startedAt).TotalSeconds -le 35) {
        try { Send-Hmp $monitorPort 'sendkey ret' } catch {}
        $nextBootKeyAt = $now.AddSeconds(2)
    }
    if (Test-Path -LiteralPath $resultPath) {
        $text = Get-Content -LiteralPath $resultPath -Raw -ErrorAction SilentlyContinue
        if ($text -match 'RESULT=(PASS|FAIL)') {
            Start-Sleep -Seconds 2
            $process.Refresh()
            if (-not $process.HasExited) { $process.Kill() }
            break
        }
    }
}
if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and -not $process.HasExited) {
    try { Send-Hmp $monitorPort "screendump $($screenPath.Replace('\\','/'))" } catch {}
}
if (-not $process.HasExited) { $process.Kill() }
$process.WaitForExit()

if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    throw "QEMU/WinPE produced no result file. See $qemuErr and $screenPath"
}
$result = Get-Content -LiteralPath $resultPath -Raw
Write-Host $result
if ($result -notmatch 'RESULT=PASS') {
    throw 'GPT destructive integration test failed inside QEMU/WinPE'
}

& $QemuImgPath check $TargetImage
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed after test: $LASTEXITCODE" }
Write-Host "[PASS] destructive GPT test used only QEMU USB Mass Storage image: $TargetImage"
