$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$builder = Full 'tools/build_legacy_bios.ps1'
$fixtureBuilder = Full 'tools/tests/legacy_bios/create_chainload_fixture.py'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$artifactDir = Full 'zig-out/legacy-bios'
$image = Join-Path $artifactDir 'usos-legacy-chainload.qcow2'
$serial = Join-Path $artifactDir 'seabios-chainload.serial.log'
$debug = Join-Path $artifactDir 'seabios-chainload.debug.log'
$qemuErr = Join-Path $artifactDir 'seabios-chainload.stderr.log'

foreach ($required in @($builder, $fixtureBuilder, $qemu, $qemuImg, $seabios)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS build failed with exit code $LASTEXITCODE" }

$stage1 = Join-Path $artifactDir 'stage1.bin'
$core = Join-Path $artifactDir 'core-padded.bin'
$vbr = Join-Path $artifactDir 'test-vbr.bin'
& $python $fixtureBuilder --qemu-img $qemuImg --stage1 $stage1 --core $core --vbr $vbr --output $image
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS qcow2 fixture creation failed with exit code $LASTEXITCODE" }

Remove-Item -LiteralPath $serial, $debug, $qemuErr -Force -ErrorAction SilentlyContinue
$qemuArgs = @(
    '-name', 'USOS-Legacy-SeaBIOS-Chainload-Test',
    '-machine', 'pc',
    '-accel', 'tcg,thread=multi',
    '-cpu', 'max',
    '-m', '64M',
    '-smp', '1',
    '-bios', $seabios,
    '-boot', 'order=c,strict=on',
    '-display', 'none',
    '-monitor', 'none',
    '-nic', 'none',
    '-serial', "file:$($serial.Replace('\','/'))",
    '-debugcon', "file:$($debug.Replace('\','/'))",
    '-drive', "if=ide,format=qcow2,file=$($image.Replace('\','/'))",
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
    '-no-reboot'
)

$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $qemuArgs) -PassThru -RedirectStandardError $qemuErr
$deadline = [DateTime]::UtcNow.AddSeconds(12)
while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
}
if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit()
    $log = if (Test-Path -LiteralPath $serial) { Get-Content -LiteralPath $serial -Raw } else { '' }
    $debugText = if (Test-Path -LiteralPath $debug) { Get-Content -LiteralPath $debug -Raw } else { '' }
    $err = if (Test-Path -LiteralPath $qemuErr) { Get-Content -LiteralPath $qemuErr -Raw } else { '' }
    throw "SeaBIOS chainload test timed out.`nSerial:`n$log`nDebugCon:`n$debugText`nQEMU stderr:`n$err"
}

$serialText = if (Test-Path -LiteralPath $serial) { Get-Content -LiteralPath $serial -Raw } else { '' }
$debugText = if (Test-Path -LiteralPath $debug) { Get-Content -LiteralPath $debug -Raw } else { '' }
$requiredMarkers = @(
    'USOS LEGACY CORE',
    'GPT OK',
    'MENU',
    'GPT partition 2 [legacy bootable]',
    'CHAINLOADING GPT PARTITION 2',
    'CHAINLOAD PASS'
)
foreach ($marker in $requiredMarkers) {
    if (-not $serialText.Contains($marker)) {
        $err = if (Test-Path -LiteralPath $qemuErr) { Get-Content -LiteralPath $qemuErr -Raw } else { '' }
        throw "Missing SeaBIOS marker: $marker`nSerial:`n$serialText`nDebugCon:`n$debugText`nQEMU stderr:`n$err"
    }
}

Write-Host '[PASS] SeaBIOS loaded protective-MBR Stage 1.' -ForegroundColor Green
Write-Host '[PASS] Stage 1 loaded Legacy Core from the pre-ESP reserve.' -ForegroundColor Green
Write-Host '[PASS] Legacy Core validated GPT and selected GPT partition 2.' -ForegroundColor Green
Write-Host '[PASS] Test VBR executed: CHAINLOAD PASS' -ForegroundColor Green
Write-Host "[PASS] debug path: $debugText"
Write-Host "[PASS] qcow2 only: $image"
Write-Host "[PASS] serial log: $serial"
