$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'process_argument_line.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$isoPath = Full 'media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso'
$qemuPath = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImgPath = Full 'tools/qemu/qemu-img.exe'
$firmwareCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVars = Full 'tools/qemu/share/edk2-i386-vars.fd'
$templateDir = Full 'tools/tests/fixtures/installer/winpe-gpt-qemu'
$runtimeDir = Full 'tools/tests/artifacts/qemu/usos-backend-installer-config'
$targetImage = Full 'tools/tests/artifacts/qemu/usos-installer-full-target.qcow2'
$installerDir = Full 'installer'
$finalInstaller = Join-Path $installerDir 'USOS Installer.exe'
$testExe = Join-Path $runtimeDir 'usos-gpt-qemu-test.exe'
$resultPath = Join-Path $runtimeDir 'usos-gpt-result.txt'
$varsCopy = Join-Path $runtimeDir 'edk2-vars.fd'
$qemuErr = Join-Path $runtimeDir 'qemu.stderr.log'
$serialLog = Join-Path $runtimeDir 'serial.log'

$testRoot = Full 'tools/tests/artifacts/qemu'
foreach ($path in @($runtimeDir,$targetImage,$testExe,$resultPath,$varsCopy,$qemuErr,$serialLog)) {
    if (-not $path.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing backend installer path outside test artifacts: $path"
    }
}
foreach ($required in @($isoPath,$qemuPath,$qemuImgPath,$firmwareCode,$firmwareVars,$finalInstaller)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}

$active = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($targetImage)
})
if ($active.Count -gt 0) { throw "Backend installer QEMU already running: PID=$($active[0].ProcessId)" }

New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
Get-ChildItem -LiteralPath $runtimeDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Copy-Item -LiteralPath (Join-Path $templateDir 'Autounattend.xml') -Destination $runtimeDir -Force
Copy-Item -LiteralPath (Join-Path $templateDir 'run-usos-gpt-test.cmd') -Destination $runtimeDir -Force
Copy-Item -LiteralPath (Join-Path $templateDir 'USOS_QEMU_TEST.TAG') -Destination $runtimeDir -Force
Copy-Item -LiteralPath $firmwareVars -Destination $varsCopy -Force
Copy-Item -LiteralPath $finalInstaller -Destination (Join-Path $runtimeDir 'USOS Installer.exe') -Force

Push-Location $installerDir
try {
    & go.exe build -trimpath -o $testExe ./cmd/usos-gpt-qemu-test
    if ($LASTEXITCODE -ne 0) { throw "Go build failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

Remove-Item -LiteralPath $targetImage -Force -ErrorAction SilentlyContinue
& $qemuImgPath create -f qcow2 $targetImage 40G | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed: $LASTEXITCODE" }
& $qemuImgPath check $targetImage | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed before test: $LASTEXITCODE" }

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Send-Hmp([int]$Port, [string]$Command) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $writer = [IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine($Command)
        Start-Sleep -Milliseconds 250
    } finally {
        $client.Dispose()
    }
}

$configForQemu = $runtimeDir.Replace('\\','/').Replace('\','/')
$monitorPort = Get-FreeTcpPort
$qemuArgs = @(
    '-machine','q35',
    '-accel','tcg,thread=multi',
    '-cpu','max',
    '-m','4096',
    '-smp','4',
    '-nic','none',
    '-display','none',
    '-no-reboot',
    '-boot','order=d,menu=off',
    '-monitor',"tcp:127.0.0.1:$monitorPort,server=on,wait=off",
    '-serial',"file:$($serialLog.Replace('\','/'))",
    '-drive',"if=pflash,format=raw,readonly=on,file=$firmwareCode",
    '-drive',"if=pflash,format=raw,file=$varsCopy",
    '-drive',"file=$isoPath,media=cdrom,readonly=on",
    '-drive',"if=none,id=usostarget,file=$targetImage,format=qcow2,cache=unsafe",
    '-device','qemu-xhci,id=xhci',
    '-device','usb-storage,bus=xhci.0,drive=usostarget,removable=on,serial=USOS-GPT-TEST',
    '-drive',"if=none,id=usoscfg,file=fat:rw:$configForQemu,format=raw",
    '-device','usb-storage,bus=xhci.0,drive=usoscfg,removable=on,serial=USOS-CONFIG'
)

$process = Start-Process -FilePath $qemuPath -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $qemuArgs) -PassThru -RedirectStandardError $qemuErr
$startedAt = [DateTime]::UtcNow
$deadline = $startedAt.AddMinutes(5)
$nextBootKeyAt = $startedAt.AddSeconds(1)
while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    $now = [DateTime]::UtcNow
    if ($now -ge $nextBootKeyAt -and ($now - $startedAt).TotalSeconds -le 35) {
        try { Send-Hmp -Port $monitorPort -Command 'sendkey ret' } catch {}
        $nextBootKeyAt = $now.AddSeconds(2)
    }
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $text = Get-Content -LiteralPath $resultPath -Raw -ErrorAction SilentlyContinue
        if ($text -match 'RESULT=(PASS|FAIL)') {
            Start-Sleep -Seconds 1
            $process.Refresh()
            if (-not $process.HasExited) { $process.Kill() }
            break
        }
    }
}
if (-not $process.HasExited) { $process.Kill() }
$process.WaitForExit()
if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    throw "Backend installer QEMU produced no result file. See $qemuErr and $serialLog"
}
$result = Get-Content -LiteralPath $resultPath -Raw
Write-Host $result
if ($result -notmatch 'RESULT=PASS') { throw 'Production install.Engine failed inside WinPE/QEMU' }

& $qemuImgPath check $targetImage
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed after test: $LASTEXITCODE" }
Write-Host "[PASS] production install.Engine created file-backed USOS target: $targetImage"
