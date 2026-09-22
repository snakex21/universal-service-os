param(
    [Parameter(Mandatory=$true)][string]$SourceQcow2Path,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\process_argument_line.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$source = [IO.Path]::GetFullPath($SourceQcow2Path)
$artifactRoot = Full 'tools/tests/artifacts/qemu/gpt-no-block-io'
$raw = Join-Path $artifactRoot 'usos-no-block-io.raw'
$patched = Join-Path $artifactRoot 'usos-no-block-io.qcow2'
$esp = Join-Path $artifactRoot 'probe-esp'
$vars = Join-Path $artifactRoot 'edk2-vars.fd'
$serial = Join-Path $artifactRoot 'serial.log'
$qemuErr = Join-Path $artifactRoot 'qemu.stderr.log'
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$firmwareCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVars = Full 'tools/qemu/share/edk2-i386-vars.fd'
$zig = Full 'tools/zig/zig.exe'
$zigCache = Full 'tools/cache/zig'
$patcher = Full 'tools/tests/gpt_patch_no_block_io.py'
$probeEfi = Full 'zig-out/test-assets/gpt-no-block-io-probe-x86_64.efi'
$ntfsDriver = Full 'zig-out/test-assets/ntfs_x64.efi'

$allowedRoot = Full 'tools/tests/artifacts/qemu'
foreach ($path in @($artifactRoot,$raw,$patched,$esp,$vars,$serial,$qemuErr)) {
    if (-not $path.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing test path outside tools/tests/artifacts/qemu: $path"
    }
}
foreach ($required in @($source,$qemu,$qemuImg,$firmwareCode,$firmwareVars,$zig,$patcher)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
if ($source -match '(?i)PhysicalDrive|^\\\\\.\\') { throw 'Refusing physical device as source image.' }
if ($TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 120) { throw 'TimeoutSeconds must be in range 5..120.' }

New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
Get-ChildItem -LiteralPath $artifactRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $esp 'EFI\BOOT'),(Join-Path $esp 'EFI\USOS') | Out-Null

Push-Location $root
try {
    & $zig build --cache-dir $zigCache gpt-no-block-io-probe-app fetch-ntfs-driver -Doptimize=ReleaseFast
    if ($LASTEXITCODE -ne 0) { throw "probe build failed: $LASTEXITCODE" }
} finally { Pop-Location }
foreach ($required in @($probeEfi,$ntfsDriver)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing built probe asset: $required" }
}

Copy-Item -LiteralPath $probeEfi -Destination (Join-Path $esp 'EFI\BOOT\BOOTX64.EFI') -Force
Copy-Item -LiteralPath $ntfsDriver -Destination (Join-Path $esp 'EFI\USOS\ntfs_x64.efi') -Force
Copy-Item -LiteralPath $firmwareVars -Destination $vars -Force

& $qemuImg convert -f qcow2 -O raw -S 4k $source $raw
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert qcow2->raw failed: $LASTEXITCODE" }
& py.exe -3 $patcher $raw
if ($LASTEXITCODE -ne 0) { throw "GPT NO_BLOCK_IO patch failed: $LASTEXITCODE" }
& $qemuImg convert -f raw -O qcow2 -S 4k $raw $patched
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert raw->qcow2 failed: $LASTEXITCODE" }
Remove-Item -LiteralPath $raw -Force
& $qemuImg check $patched
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed after GPT patch: $LASTEXITCODE" }

$espForQemu = $esp.Replace('\\','/').Replace('\','/')
$args = @(
    '-name','USOS-gpt-no-block-io-probe',
    '-machine','q35',
    '-accel','tcg,thread=multi',
    '-cpu','max',
    '-m','768',
    '-smp','2',
    '-nic','none',
    '-display','none',
    '-monitor','none',
    '-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=pflash,format=raw,readonly=on,file=$firmwareCode",
    '-drive',"if=pflash,format=raw,file=$vars",
    '-drive',"if=none,id=probeesp,format=raw,file=fat:rw:$espForQemu",
    '-device','ide-hd,bus=ide.0,drive=probeesp,bootindex=1,serial=USOS-NOBLOCK-PROBE-ESP',
    '-drive',"if=none,id=usostest,file=$patched,format=qcow2,cache=writeback",
    '-device','ide-hd,bus=ide.1,drive=usostest,bootindex=2,serial=USOS-NOBLOCK-TEST',
    '-no-reboot'
)
if (($args -join ' ') -match '(?i)PhysicalDrive') { throw 'Refusing physical disk in QEMU arguments.' }

$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $qemuErr
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$result = ''
while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $process.Refresh()
    if (Test-Path -LiteralPath $serial -PathType Leaf) {
        $text = Get-Content -LiteralPath $serial -Raw -ErrorAction SilentlyContinue
        if ($text -match 'NO-BLOCK-IO VISIBILITY PASS') { $result = 'PASS'; break }
        if ($text -match 'NO-BLOCK-IO VISIBILITY FAIL') { $result = 'FAIL'; break }
    }
}
if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
if (-not (Test-Path -LiteralPath $serial -PathType Leaf)) {
    $stderr = if (Test-Path -LiteralPath $qemuErr) { Get-Content -LiteralPath $qemuErr -Raw } else { '' }
    throw "probe produced no serial log. QEMU stderr: $stderr"
}
$text = Get-Content -LiteralPath $serial -Raw
Write-Host $text
if ($result -eq 'PASS') {
    Write-Host '[PASS] DATA and WORK remain visible as UEFI SimpleFileSystem volumes after NTFS driver binding.' -ForegroundColor Green
    Write-Host "[PASS] patched QEMU image: $patched" -ForegroundColor Green
    exit 0
}
if ($result -eq 'FAIL') {
    throw 'NO_BLOCK_IO_PROTOCOL hides DATA and/or WORK from the UEFI NTFS path. Do not continue to full E2E.'
}
throw "probe timed out without PASS/FAIL after $TimeoutSeconds seconds"
