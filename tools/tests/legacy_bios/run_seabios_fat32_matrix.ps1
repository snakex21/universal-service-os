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
    } finally { $stream.Dispose() }
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

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixturePrep
if ($LASTEXITCODE -ne 0) { throw "FAT32 fixture preparation failed with exit code $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS build failed with exit code $LASTEXITCODE" }
$stage1 = Join-Path $artifactDir 'stage1.bin'
$core = Join-Path $artifactDir 'core-slot.bin'

$commonMarkers = @(
    'USOS LEGACY BOOTSTRAP',
    'CORE HEADER OK',
    'CORE LOAD OK',
    'CORE CRC OK',
    'A20 OK',
    'ENTERING PROTECTED MODE',
    'USOS LEGACY CORE PM32',
    'BOOT CONTEXT OK drive=0x80',
    'GPT OK',
    'GPT NAME: USOS_ESP'
)
$cases = @(
    @{ Name='valid'; Required=@('FAT32 OK','FAT32 BPB LABEL: NO NAME','ROOT DIRECTORY:','[DIR]  EFI','EFI DIRECTORY:','[DIR]  USOS','USOS-MENU.INI READ OK bytes=75249'); Forbidden=@(' READ FAIL','FAT32 FAIL','[LIST FAIL') },
    @{ Name='bad-bpb'; Required=@('FAT32 FAIL error=UnsupportedSectorSize'); Forbidden=@('USOS-MENU.INI READ OK') },
    @{ Name='broken-chain'; Required=@('FAT32 OK','USOS-MENU.INI READ FAIL error=BrokenClusterChain'); Forbidden=@('USOS-MENU.INI READ OK') },
    @{ Name='outside-file'; Required=@('FAT32 OK','USOS-MENU.INI READ FAIL error=InvalidCluster'); Forbidden=@('USOS-MENU.INI READ OK') },
    @{ Name='loop'; Required=@('FAT32 OK','USOS-MENU.INI READ FAIL error=ClusterChainLoop'); Forbidden=@('USOS-MENU.INI READ OK') }
)

foreach ($case in $cases) {
    $image = Join-Path $artifactDir "usos-legacy-fat32-$($case.Name).qcow2"
    $serial = Join-Path $artifactDir "seabios-fat32-$($case.Name).serial.log"
    $debug = Join-Path $artifactDir "seabios-fat32-$($case.Name).debug.log"
    $qemuErr = Join-Path $artifactDir "seabios-fat32-$($case.Name).stderr.log"
    $sourceRaw = Join-Path $fatDir "$($case.Name).raw"
    & $python $fixtureBuilder --qemu-img $qemuImg --source-raw $sourceRaw --stage1 $stage1 --core-slot $core --output $image
    if ($LASTEXITCODE -ne 0) { throw "Boot fixture $($case.Name) failed with exit code $LASTEXITCODE" }

    Remove-Item -LiteralPath $serial, $debug, $qemuErr -Force -ErrorAction SilentlyContinue
    $qemuArgs = @(
        '-name', "USOS-Legacy-SeaBIOS-FAT32-$($case.Name)",
        '-machine', 'pc', '-accel', 'tcg,thread=multi', '-cpu', 'max', '-m', '64M', '-smp', '1',
        '-bios', $seabios, '-boot', 'order=c,strict=on', '-display', 'none', '-monitor', 'none', '-nic', 'none',
        '-serial', "file:$($serial.Replace('\','/'))", '-debugcon', "file:$($debug.Replace('\','/'))",
        '-drive', "if=ide,format=qcow2,file=$($image.Replace('\','/'))", '-no-reboot'
    )
    $process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $qemuArgs) -PassThru -RedirectStandardError $qemuErr
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    $terminal = $case.Required[-1]
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $text = Read-SharedText $serial
        if ($text.Contains($terminal)) { break }
    }
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }
    $serialText = Read-SharedText $serial
    $debugText = Read-SharedText $debug
    foreach ($marker in @($commonMarkers + $case.Required)) {
        if (-not $serialText.Contains($marker)) {
            throw "Missing marker in case $($case.Name): $marker`nSerial:`n$serialText`nDebugCon:`n$debugText`nQEMU stderr:`n$(Read-SharedText $qemuErr)"
        }
    }
    foreach ($marker in $case.Forbidden) {
        if ($serialText.Contains($marker)) {
            throw "Forbidden marker in case $($case.Name): $marker`nSerial:`n$serialText"
        }
    }
    Write-Host "[PASS] SeaBIOS FAT32 case=$($case.Name)" -ForegroundColor Green
    Write-Host $serialText
}
Write-Host '[PASS] SeaBIOS GPT/FAT32/LFN positive + fail-closed matrix complete.' -ForegroundColor Green
