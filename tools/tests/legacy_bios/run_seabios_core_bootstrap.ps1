$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$builder = Full 'tools/build_legacy_bios.ps1'
$fixtureBuilder = Full 'tools/tests/legacy_bios/create_bootstrap_fixture.py'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$artifactDir = Full 'zig-out/legacy-bios'

foreach ($required in @($builder, $fixtureBuilder, $qemu, $qemuImg, $seabios)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS build failed with exit code $LASTEXITCODE" }

$stage1 = Join-Path $artifactDir 'stage1.bin'
$coreSlot = Join-Path $artifactDir 'core-slot.bin'

function Run-SeaBiosCase {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Mutation,
        [Parameter(Mandatory=$true)][string[]]$RequiredMarkers,
        [string[]]$ForbiddenMarkers = @()
    )

    $image = Join-Path $artifactDir "usos-legacy-$Name.qcow2"
    $serial = Join-Path $artifactDir "$Name.serial.log"
    $debug = Join-Path $artifactDir "$Name.debug.log"
    $qemuErr = Join-Path $artifactDir "$Name.stderr.log"

    & $python $fixtureBuilder --qemu-img $qemuImg --stage1 $stage1 --core-slot $coreSlot --output $image --mutate $Mutation
    if ($LASTEXITCODE -ne 0) { throw "fixture creation failed for $Name with exit code $LASTEXITCODE" }

    Remove-Item -LiteralPath $serial, $debug, $qemuErr -Force -ErrorAction SilentlyContinue
    $qemuArgs = @(
        '-name', "USOS-Legacy-$Name",
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
        '-no-reboot'
    )

    $process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $qemuArgs) -PassThru -RedirectStandardError $qemuErr
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    $matched = $false
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($process.HasExited) { break }
            $text = if (Test-Path -LiteralPath $serial) { [string](Get-Content -LiteralPath $serial -Raw -ErrorAction SilentlyContinue) } else { '' }
            if ($null -eq $text) { $text = '' }
            $all = $true
            foreach ($marker in $RequiredMarkers) {
                if (-not $text.Contains($marker)) { $all = $false; break }
            }
            if ($all) { $matched = $true; break }
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
    } finally {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit()
        }
    }

    $serialText = if (Test-Path -LiteralPath $serial) { [string](Get-Content -LiteralPath $serial -Raw) } else { '' }
    $debugText = if (Test-Path -LiteralPath $debug) { [string](Get-Content -LiteralPath $debug -Raw) } else { '' }
    $errText = if (Test-Path -LiteralPath $qemuErr) { [string](Get-Content -LiteralPath $qemuErr -Raw) } else { '' }
    if ($null -eq $serialText) { $serialText = '' }
    if ($null -eq $debugText) { $debugText = '' }
    if ($null -eq $errText) { $errText = '' }
    if (-not $matched) {
        throw "SeaBIOS case $Name did not reach required markers.`nSerial:`n$serialText`nDebugCon:`n$debugText`nQEMU stderr:`n$errText"
    }
    foreach ($marker in $ForbiddenMarkers) {
        if ($serialText.Contains($marker)) {
            throw "SeaBIOS case $Name reached forbidden marker '$marker'.`nSerial:`n$serialText"
        }
    }
    Write-Host "[PASS] SeaBIOS $Name" -ForegroundColor Green
    Write-Host $serialText
}

Run-SeaBiosCase -Name 'core-bootstrap-pass' -Mutation 'none' -RequiredMarkers @(
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
    'FAT32 FAIL error=InvalidBPB'
)

Run-SeaBiosCase -Name 'core-bootstrap-bad-version' -Mutation 'version' -RequiredMarkers @(
    'USOS LEGACY BOOTSTRAP',
    'CORE HEADER FAIL'
) -ForbiddenMarkers @('ENTERING PROTECTED MODE', 'USOS LEGACY CORE PM32')

Run-SeaBiosCase -Name 'core-bootstrap-bad-crc' -Mutation 'content-crc' -RequiredMarkers @(
    'USOS LEGACY BOOTSTRAP',
    'CORE HEADER OK',
    'CORE LOAD OK',
    'CORE CRC FAIL'
) -ForbiddenMarkers @('ENTERING PROTECTED MODE', 'USOS LEGACY CORE PM32')

Write-Host '[PASS] Legacy bootstrap/header/CRC/protected-mode SeaBIOS matrix complete.' -ForegroundColor Green
