$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $true, 4096, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

$builder = Full 'tools/build_legacy_bios.ps1'
$fixturePrep = Full 'tools/tests/legacy_bios/prepare_fat32_fixture.ps1'
$fixtureBuilder = Full 'tools/tests/legacy_bios/create_fat32_boot_fixture.py'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$artifactDir = Full 'zig-out/legacy-bios'
$fatDir = Join-Path $artifactDir 'fat32-fixture'
$image = Join-Path $artifactDir 'usos-legacy-fat32.qcow2'
$serial = Join-Path $artifactDir 'seabios-fat32.serial.log'
$debug = Join-Path $artifactDir 'seabios-fat32.debug.log'
$qemuErr = Join-Path $artifactDir 'seabios-fat32.stderr.log'

foreach ($required in @($builder, $fixturePrep, $fixtureBuilder, $qemu, $qemuImg, $seabios)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixturePrep
if ($LASTEXITCODE -ne 0) { throw "FAT32 fixture preparation failed with exit code $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS build failed with exit code $LASTEXITCODE" }

$stage1 = Join-Path $artifactDir 'stage1.bin'
$core = Join-Path $artifactDir 'core-slot.bin'
$validRaw = Join-Path $fatDir 'valid.raw'
& $python $fixtureBuilder --qemu-img $qemuImg --source-raw $validRaw --stage1 $stage1 --core-slot $core --output $image
if ($LASTEXITCODE -ne 0) { throw "Legacy FAT32 boot fixture creation failed with exit code $LASTEXITCODE" }

Remove-Item -LiteralPath $serial, $debug, $qemuErr -Force -ErrorAction SilentlyContinue
$qemuArgs = @(
    '-name', 'USOS-Legacy-SeaBIOS-FAT32-Test',
    '-machine', 'pc',
    '-accel', 'tcg,thread=multi',
    '-cpu', 'max',
    '-m', '64M',
    '-smp', '1',
    '-bios', $seabios,
    '-boot', 'order=c,strict=on',
    '-display', 'none',
    '-vga', 'cirrus',
    '-monitor', 'none',
    '-nic', 'none',
    '-serial', "file:$($serial.Replace('\','/'))",
    '-debugcon', "file:$($debug.Replace('\','/'))",
    '-drive', "if=ide,format=qcow2,file=$($image.Replace('\','/'))",
    '-no-reboot'
)
$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $qemuArgs) -PassThru -RedirectStandardError $qemuErr
$deadline = [DateTime]::UtcNow.AddSeconds(15)
$finalMarker = 'CATEGORIES'
while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
    if (Test-Path -LiteralPath $serial) {
        $text = Read-SharedText $serial
        if ($text.Contains($finalMarker)) { break }
    }
}
if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit()
}

$serialText = Read-SharedText $serial
$debugText = Read-SharedText $debug
$requiredMarkers = @(
    'USOS LEGACY BOOTSTRAP',
    'CORE HEADER OK',
    'CORE LOAD OK',
    'CORE CRC OK',
    'A20 OK',
    'ENTERING PROTECTED MODE',
    'USOS LEGACY CORE PM32',
    'BOOT CONTEXT OK drive=0x80',
    'GPT OK',
    'GPT NAME: USOS_ESP',
    'FAT32 OK',
    'FAT32 BPB LABEL: NO NAME',
    'UNIVERSAL SERVICE OS',
    'FIRMWARE: BIOS',
    $finalMarker
)
foreach ($marker in $requiredMarkers) {
    if (-not $serialText.Contains($marker)) {
        $err = Read-SharedText $qemuErr
        throw "Missing SeaBIOS FAT32 marker: $marker`nSerial:`n$serialText`nDebugCon:`n$debugText`nQEMU stderr:`n$err"
    }
}

Write-Host '[PASS] SeaBIOS Stage1 -> versioned bootstrap -> PM32 Core.' -ForegroundColor Green
Write-Host '[PASS] PM32 Core read GPT only from BIOS boot drive DL and found GPT name USOS_ESP.' -ForegroundColor Green
Write-Host '[PASS] Shared read-only FAT32/LFN parser mounted the Windows-formatted ESP.' -ForegroundColor Green
Write-Host '[PASS] Production Legacy menu rendered from the real FAT32 fixture.' -ForegroundColor Green
Write-Host $serialText
Write-Host "[PASS] qcow2 only: $image"
Write-Host "[PASS] serial log: $serial"
