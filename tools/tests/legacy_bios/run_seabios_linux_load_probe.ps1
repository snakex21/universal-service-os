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
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$out = Full 'zig-out/legacy-bios'
$fixtureDir = Join-Path $out 'linux-load-fixture'
$image = Join-Path $out 'usos-legacy-linux-load.qcow2'
$serial = Join-Path $out 'seabios-linux-load.serial.log'
$stderr = Join-Path $out 'seabios-linux-load.stderr.log'
$kernelArtifact = Full 'zig-out/micro-linux/vmlinuz-virt'
$initramfsArtifact = Full 'zig-out/micro-linux/initramfs-usos'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixturePrep -OutputDirectory $fixtureDir -IncludeMicroLinuxProbe -OnlyValid
if ($LASTEXITCODE -ne 0) { throw "Linux load fixture preparation failed: $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if ($LASTEXITCODE -ne 0) { throw "Legacy build failed: $LASTEXITCODE" }
$kernelBytes = (Get-Item -LiteralPath $kernelArtifact).Length
$initramfsBytes = (Get-Item -LiteralPath $initramfsArtifact).Length

$stage1 = Join-Path $out 'stage1.bin'
$core = Join-Path $out 'core-slot.bin'
$raw = Join-Path $fixtureDir 'valid.raw'
& $python $fixtureBuilder --qemu-img $qemuImg --source-raw $raw --stage1 $stage1 --core-slot $core --output $image
if ($LASTEXITCODE -ne 0) { throw "Linux load boot fixture creation failed: $LASTEXITCODE" }

Remove-Item -LiteralPath $serial, $stderr -Force -ErrorAction SilentlyContinue
$args = @(
    '-name','USOS-Legacy-Linux-Load-Probe', '-machine','pc', '-accel','tcg,thread=multi', '-cpu','max',
    '-m','128M', '-smp','1', '-bios',$seabios, '-boot','order=c,strict=on', '-display','none', '-vga','cirrus', '-nic','none',
    '-monitor','none', '-serial',"file:$($serial.Replace('\','/'))", '-drive',"if=ide,format=qcow2,file=$($image.Replace('\','/'))", '-no-reboot'
)
$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $text = ''
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $text = Read-SharedText $serial
        if ($text.Contains('LINUX LOAD PROBE PASS - KERNEL NOT STARTED') -or $text.Contains('LINUX LOAD PROBE FAIL')) { break }
    }

    if ($text.Contains('LINUX LOAD PROBE FAIL')) {
        throw "Legacy Linux load probe reported failure.`n$text`n$(Read-SharedText $stderr)"
    }
    foreach ($marker in @(
        'E820 OK entries=',
        'LINUX LOAD PROBE BEGIN',
        "LINUX HEADER protocol=0x0000020F setup=31 kernel_bytes=$kernelBytes protected_offset=0x00004000 initramfs_bytes=$initramfsBytes",
        'LINUX LAYOUT kernel=0x0000000000100000..0x0000000000CFA400 runtime=0x0000000001000000..0x0000000003604000 initrd=0x',
        'LINUX LOAD kernel_first=0xFCFA8DA6 initramfs_first=0x1F8B0800',
        'LINUX LOAD PROBE PASS - KERNEL NOT STARTED'
    )) {
        if (-not $text.Contains($marker)) {
            throw "Missing Legacy Linux load marker: $marker`n$text`n$(Read-SharedText $stderr)"
        }
    }

    $layout = [regex]::Match($text, 'LINUX LAYOUT kernel=0x([0-9A-F]{16})\.\.0x([0-9A-F]{16}) runtime=0x([0-9A-F]{16})\.\.0x([0-9A-F]{16}) initrd=0x([0-9A-F]{16})\.\.0x([0-9A-F]{16})')
    if (-not $layout.Success) { throw "Could not parse Linux memory layout.`n$text" }
    $initrdStart = [Convert]::ToUInt64($layout.Groups[5].Value, 16)
    $initrdEnd = [Convert]::ToUInt64($layout.Groups[6].Value, 16)
    if (($initrdStart -band 0xFFF) -ne 0) { throw "initramfs start is not 4 KiB aligned: 0x$($layout.Groups[5].Value)" }
    if (($initrdEnd - $initrdStart) -ne $initramfsBytes) { throw "initramfs layout size mismatch: $($initrdEnd - $initrdStart), expected $initramfsBytes" }
    if ($initrdStart -lt 0x03604000) { throw "initramfs overlaps kernel runtime window" }
    if ($initrdEnd -gt [UInt64]2147483648) { throw "initramfs exceeds initrd_addr_max" }

    Write-Host '[PASS] SeaBIOS E820 -> allocator -> vmlinuz/initramfs load; kernel intentionally not started.'
    $text -split "`r?`n" | Where-Object { $_ -match '^(E820 OK|E820\[|LINUX HEADER|LINUX LAYOUT|LINUX LOAD )' } | ForEach-Object { Write-Host $_ }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
