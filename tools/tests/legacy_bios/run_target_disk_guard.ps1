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

$fixturePrep = Full 'tools/tests/legacy_bios/prepare_fat32_fixture.ps1'
$fixtureBuilder = Full 'tools/tests/legacy_bios/create_fat32_boot_fixture.py'
$targetBuilder = Full 'tools/tests/legacy_bios/create_target_guard_disk.py'
$legacyBuilder = Full 'tools/build_legacy_bios.ps1'
$microBuilder = Full 'build.bat'
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$out = Full 'zig-out/legacy-bios'
$serialValue = 'XP-TARGET-A'

# Build once so the test uses the same initramfs payload that ships in release.
& cmd.exe /c $microBuilder
if ($LASTEXITCODE -ne 0) { throw "build.bat failed: $LASTEXITCODE" }

foreach ($case in @(
    @{ Mode = 'mbr-changed'; DiskMode = 'existing-mbr'; Expected = '[TARGET_GUARD_TEST] mbr-changed PASS: guard stopped changed MBR before XPSETUP write' },
    @{ Mode = 'serial-mismatch'; DiskMode = 'existing-mbr'; Expected = '[TARGET_GUARD_TEST] serial-mismatch PASS: guard stopped changed serial before write' }
)) {
    $caseDir = Join-Path $out "target-guard-$($case.Mode)"
    $bootImage = Join-Path $caseDir 'boot.qcow2'
    $targetRaw = Join-Path $caseDir 'target.raw'
    $serialLog = Join-Path $caseDir 'serial.log'
    $stderrLog = Join-Path $caseDir 'stderr.log'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixturePrep -OutputDirectory (Join-Path $caseDir 'fixture') -BootMicroLinux -TargetGuardTestMode $case.Mode -TargetGuardTargetSerial $serialValue -OnlyValid
    if ($LASTEXITCODE -ne 0) { throw "fixture preparation failed for $($case.Mode): $LASTEXITCODE" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $legacyBuilder
    if ($LASTEXITCODE -ne 0) { throw "Legacy build failed: $LASTEXITCODE" }

    $raw = Join-Path $caseDir 'fixture\valid.raw'
    & $python $fixtureBuilder --qemu-img $qemuImg --source-raw $raw --stage1 (Join-Path $out 'stage1.bin') --core-slot (Join-Path $out 'core-slot.bin') --output $bootImage
    if ($LASTEXITCODE -ne 0) { throw "boot fixture creation failed for $($case.Mode): $LASTEXITCODE" }
    & $python $targetBuilder --output $targetRaw --mode $case.DiskMode
    if ($LASTEXITCODE -ne 0) { throw "target fixture creation failed for $($case.Mode): $LASTEXITCODE" }

    Remove-Item -LiteralPath $serialLog, $stderrLog -Force -ErrorAction SilentlyContinue
    $args = @(
        '-name',"USOS-Target-Guard-$($case.Mode)", '-machine','pc', '-accel','tcg,thread=multi', '-cpu','max',
        '-m','256M', '-smp','1', '-bios',$seabios, '-boot','order=c,strict=on', '-display','none', '-vga','cirrus', '-nic','none',
        '-monitor','none', '-serial',"file:$($serialLog.Replace('\','/'))",
        '-drive',"if=ide,format=qcow2,file=$($bootImage.Replace('\','/'))",
        '-drive',"if=none,id=xptarget,format=raw,file=$($targetRaw.Replace('\','/'))",
        '-device','virtio-scsi-pci,id=scsi0',
        '-device',"scsi-hd,bus=scsi0.0,drive=xptarget,serial=$serialValue",
        '-no-reboot'
    )
    $process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderrLog
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        $text = ''
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $text = Read-SharedText $serialLog
            if ($text.Contains('[TARGET_GUARD_TEST] DONE') -or $text.Contains('TARGET GUARD NEGATIVE TEST FAIL')) { break }
        }
        if (-not $text.Contains($case.Expected)) {
            throw "Target guard negative test failed: $($case.Mode)`n$text`n$(Read-SharedText $stderrLog)"
        }
        if (-not $text.Contains('[TARGET_GUARD_TEST] DONE')) {
            throw "Target guard test did not reach DONE: $($case.Mode)`n$text"
        }
        Write-Host "[PASS] target_disk_guard negative test: $($case.Mode)"
        $text -split "`r?`n" | Where-Object { $_ -match '^\[(TARGET_GUARD_TEST|TARGET_DISK_GUARD)\]' } | ForEach-Object { Write-Host $_ }
    } finally {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host '[PASS] target_disk_guard negative matrix complete; guard never executed the reserved XPSETUP write.'
