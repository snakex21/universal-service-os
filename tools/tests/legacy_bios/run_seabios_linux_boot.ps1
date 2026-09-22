param(
    [ValidateRange(64, 4096)]
    [int]$MemoryMb = 128
)

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
function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}
function Send-Hmp([int]$Port, [string]$Command) {
    $client = [Net.Sockets.TcpClient]::new()
    $client.Connect('127.0.0.1', $Port)
    try {
        $stream = $client.GetStream()
        Start-Sleep -Milliseconds 100
        $bytes = [Text.Encoding]::ASCII.GetBytes($Command + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        Start-Sleep -Milliseconds 250
    } finally { $client.Dispose() }
}
function Get-PpmInfo([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $head = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(128, $bytes.Length))
    $match = [regex]::Match($head, '^P6\s+([0-9]+)\s+([0-9]+)\s+255\s')
    if (-not $match.Success) { throw "Unsupported PPM header: $Path" }
    $unique = [Collections.Generic.HashSet[int]]::new()
    $pixelOffset = $match.Length
    for ($i = $pixelOffset; $i + 2 -lt $bytes.Length; $i += 291) {
        $color = ([int]$bytes[$i] -shl 16) -bor ([int]$bytes[$i + 1] -shl 8) -bor [int]$bytes[$i + 2]
        [void]$unique.Add($color)
    }
    return [pscustomobject]@{
        Width = [int]$match.Groups[1].Value
        Height = [int]$match.Groups[2].Value
        Colors = $unique.Count
    }
}

$builder = Full 'tools/build_legacy_bios.ps1'
$fixturePrep = Full 'tools/tests/legacy_bios/prepare_fat32_fixture.ps1'
$fixtureBuilder = Full 'tools/tests/legacy_bios/create_fat32_boot_fixture.py'
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$out = Full 'zig-out/legacy-bios'
$fixtureDir = Join-Path $out 'linux-boot-fixture'
$image = Join-Path $out 'usos-legacy-linux-boot.qcow2'
$serial = Join-Path $out 'seabios-linux-boot.serial.log'
$stderr = Join-Path $out 'seabios-linux-boot.stderr.log'
$screenshot = Join-Path $out 'seabios-linux-boot-preparation.ppm'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixturePrep -OutputDirectory $fixtureDir -BootMicroLinux -OnlyValid
if ($LASTEXITCODE -ne 0) { throw "Linux boot fixture preparation failed: $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if ($LASTEXITCODE -ne 0) { throw "Legacy build failed: $LASTEXITCODE" }

$stage1 = Join-Path $out 'stage1.bin'
$core = Join-Path $out 'core-slot.bin'
$raw = Join-Path $fixtureDir 'valid.raw'
& $python $fixtureBuilder --qemu-img $qemuImg --source-raw $raw --stage1 $stage1 --core-slot $core --output $image
if ($LASTEXITCODE -ne 0) { throw "Linux boot fixture creation failed: $LASTEXITCODE" }

Remove-Item -LiteralPath $serial, $stderr, $screenshot -Force -ErrorAction SilentlyContinue
$monitor = Get-FreeTcpPort
$args = @(
    '-name','USOS-Legacy-Linux-Boot', '-machine','pc', '-accel','tcg,thread=multi', '-cpu','max',
    '-m',"${MemoryMb}M", '-smp','2', '-bios',$seabios, '-boot','order=c,strict=on', '-display','none', '-vga','std', '-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off", '-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=ide,format=qcow2,file=$($image.Replace('\','/'))", '-no-reboot'
)
$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    $text = ''
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $text = Read-SharedText $serial
        if ($text.Contains('[MICRO-LINUX] boot PASS') -or $text.Contains('LINUX LOAD PROBE FAIL') -or $text.Contains('Kernel panic')) { break }
    }

    $text = Read-SharedText $serial
    if ($text.Contains('LINUX LOAD PROBE FAIL')) { throw "Legacy Linux loader reported failure.`n$text`n$(Read-SharedText $stderr)" }
    if ($text.Contains('Kernel panic')) { throw "Legacy Linux kernel panicked before boot PASS.`n$text`n$(Read-SharedText $stderr)" }

    foreach ($marker in @(
        'LINUX BOOT BEGIN',
        'LINUX HEADER protocol=0x0000020F',
        'LINUX LOAD kernel_first=0xFCFA8DA6 initramfs_first=0x1F8B0800',
        'LINUX BOOT_PARAMS addr=0x00060000 cmdline=0x00062000',
        'LINUX HANDOFF VBE 4F03 expected=0x0000017A current=0x0000017A match=yes',
        'LINUX JUMP entry=0x00100000 - NO RETURN',
        '[USOS-FB-UI] RESOURCE start=0x00000000fd000000',
        '[MICRO-LINUX] boot PASS',
        '[USOS-FB-UI] FIRST_FRAME'
    )) {
        if (-not $text.Contains($marker)) {
            throw "Missing Legacy Linux boot marker: $marker`n$text`n$(Read-SharedText $stderr)"
        }
    }

    $hmpPath = $screenshot.Replace('\','/')
    Send-Hmp $monitor "screendump `"$hmpPath`""
    $shotDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $screenshot -PathType Leaf) -and [DateTime]::UtcNow -lt $shotDeadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $screenshot -PathType Leaf)) { throw 'Legacy Linux preparation screendump missing' }
    if ((Get-Item -LiteralPath $screenshot).Length -lt 100000) { throw 'Legacy Linux preparation screendump is unexpectedly small' }
    $ppm = Get-PpmInfo $screenshot
    if ($ppm.Width -lt 800 -or $ppm.Height -lt 600 -or $ppm.Colors -lt 6) {
        throw "Legacy Linux preparation framebuffer looks invalid: $($ppm.Width)x$($ppm.Height) colors=$($ppm.Colors)"
    }

    Write-Host "[PASS] SeaBIOS Legacy Linux boot protocol -> micro-Linux -> preparation framebuffer: RAM=${MemoryMb}MiB $($ppm.Width)x$($ppm.Height) colors=$($ppm.Colors)"
    $text -split "`r?`n" | Where-Object {
        $_ -match '^(LINUX (HEADER|LAYOUT|LOAD |BOOT_PARAMS|CMDLINE|HANDOFF|JUMP)|\[USOS-FB-UI\]|\[MICRO-LINUX\] boot PASS)'
    } | ForEach-Object { Write-Host $_ }
    Write-Host "[PASS] screenshot=$screenshot"
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
