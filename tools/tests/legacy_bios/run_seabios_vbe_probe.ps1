param(
    [ValidateSet('std', 'cirrus', 'vmware')]
    [string]$Vga = 'std',
    [int]$VgaMemoryMb = 0
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
function Get-PpmRegionUniqueColors([string]$Path, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $head = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(128, $bytes.Length))
    $match = [regex]::Match($head, '^P6\s+([0-9]+)\s+([0-9]+)\s+255\s')
    if (-not $match.Success) { throw "Unsupported PPM header: $Path" }
    $imageWidth = [int]$match.Groups[1].Value
    $imageHeight = [int]$match.Groups[2].Value
    $pixelOffset = $match.Length
    $colors = [Collections.Generic.HashSet[int]]::new()
    $right = [Math]::Min($imageWidth, $X + $Width)
    $bottom = [Math]::Min($imageHeight, $Y + $Height)
    for ($py = [Math]::Max(0, $Y); $py -lt $bottom; $py++) {
        for ($px = [Math]::Max(0, $X); $px -lt $right; $px++) {
            $offset = $pixelOffset + (($py * $imageWidth + $px) * 3)
            if ($offset + 2 -ge $bytes.Length) { continue }
            $color = ([int]$bytes[$offset] -shl 16) -bor ([int]$bytes[$offset + 1] -shl 8) -bor [int]$bytes[$offset + 2]
            [void]$colors.Add($color)
        }
    }
    return [pscustomobject]@{ Count = $colors.Count; Width = $imageWidth; Height = $imageHeight }
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

$builder = Full 'tools/build_legacy_bios.ps1'
$fixturePrep = Full 'tools/tests/legacy_bios/prepare_fat32_fixture.ps1'
$fixtureBuilder = Full 'tools/tests/legacy_bios/create_fat32_boot_fixture.py'
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$out = Full 'zig-out/legacy-bios'
$fatDir = Join-Path $out 'fat32-fixture'
$image = Join-Path $out 'usos-legacy-vbe.qcow2'
$serial = Join-Path $out "seabios-vbe-$Vga.serial.log"
$stderr = Join-Path $out "seabios-vbe-$Vga.stderr.log"
$variant = if ($VgaMemoryMb -gt 0) { "$Vga-$($VgaMemoryMb)mb" } else { $Vga }
$screenshot = Join-Path $out "seabios-vbe-$variant.ppm"
$windowsScreenshot = Join-Path $out "seabios-vbe-$variant-windows.ppm"
$expectFallback = $Vga -eq 'cirrus'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixturePrep
if ($LASTEXITCODE -ne 0) { throw "FAT32 fixture preparation failed: $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if ($LASTEXITCODE -ne 0) { throw "Legacy build failed: $LASTEXITCODE" }

$stage1 = Join-Path $out 'stage1.bin'
$core = Join-Path $out 'core-slot.bin'
$raw = Join-Path $fatDir 'valid.raw'
& $python $fixtureBuilder --qemu-img $qemuImg --source-raw $raw --stage1 $stage1 --core-slot $core --output $image
if ($LASTEXITCODE -ne 0) { throw "VBE fixture creation failed: $LASTEXITCODE" }

Remove-Item -LiteralPath $serial, $stderr, $screenshot, $windowsScreenshot -Force -ErrorAction SilentlyContinue
$monitor = Get-FreeTcpPort
$videoArgs = if ($VgaMemoryMb -gt 0 -and $Vga -eq 'std') { @('-device', "VGA,vgamem_mb=$VgaMemoryMb") } else { @('-vga', $Vga) }
$args = @(
    '-name','USOS-Legacy-VBE2', '-machine','pc', '-accel','tcg,thread=multi', '-cpu','max',
    '-m','64M', '-smp','1', '-bios',$seabios, '-boot','order=c,strict=on', '-display','none'
) + $videoArgs + @(
    '-nic','none', '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off", '-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=ide,format=qcow2,file=$($image.Replace('\','/'))", '-no-reboot'
)
$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $text = ''
    $targetMarker = if ($expectFallback) { 'VESA-2 TEXT FALLBACK ACTIVE' } else { 'VESA-2 MENU ACTIVE' }
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $text = Read-SharedText $serial
        if ($text.Contains($targetMarker)) { break }
    }

    $summary = [regex]::Match($text, 'VBE CONTROLLER version=([^ ]+) mode_ids=([0-9]+) lfb32=([0-9]+)')
    if (-not $summary.Success) { throw "VBE summary missing.`n$text" }
    $reported = [int]$summary.Groups[3].Value
    $modeLines = [regex]::Matches($text, '(?m)^VBE MODE 0x').Count
    if ($reported -ne $modeLines) { throw "VBE mode list incomplete: summary=$reported lines=$modeLines" }

    if ($expectFallback) {
        if ($reported -ne 0 -or -not $text.Contains('VESA-2 TEXT FALLBACK ACTIVE') -or -not $text.Contains('CATEGORIES')) {
            throw "Expected VESA-2 text fallback did not activate correctly.`n$text"
        }
        Send-Hmp $monitor 'sendkey esc'
        $powerDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([DateTime]::UtcNow -lt $powerDeadline) {
            Start-Sleep -Milliseconds 100
            $text = Read-SharedText $serial
            if ($text.Contains('> POWER')) { break }
        }
        if (-not $text.Contains('> POWER')) { throw "Text fallback keyboard flow did not reach POWER.`n$text" }
        Write-Host "[PASS] VESA-2 SeaBIOS text fallback: vga=$Vga mode_ids=$($summary.Groups[2].Value) lfb32=0"
        return
    }

    if (-not ($text.Contains('VBE MODE 0x') -and $text.Contains('SELECTED:') -and $text.Contains('FRAMEBUFFER:') -and $text.Contains('VESA-2 MENU ACTIVE'))) {
        throw "VESA-2 did not reach the graphical menu.`n$text`n$(Read-SharedText $stderr)"
    }

    $hmpPath = $screenshot.Replace('\','/')
    Send-Hmp $monitor "screendump `"$hmpPath`""
    $shotDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $screenshot -PathType Leaf) -and [DateTime]::UtcNow -lt $shotDeadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $screenshot -PathType Leaf)) { throw 'QEMU VBE screendump missing' }
    if ((Get-Item -LiteralPath $screenshot).Length -lt 100000) { throw 'QEMU VBE screendump is unexpectedly small' }

    $shot = [IO.File]::ReadAllBytes($screenshot)
    $sampleCount = [Math]::Min($shot.Length, 1048576)
    $unique = [Collections.Generic.HashSet[byte]]::new()
    for ($i = 0; $i -lt $sampleCount; $i += 97) { [void]$unique.Add($shot[$i]) }
    if ($unique.Count -lt 6) { throw "QEMU VBE screendump looks uniform: unique sampled byte values=$($unique.Count)" }

    # Open Windows and verify that the first system row contains a real RGBA icon,
    # not only the uniform selected-row background.
    Send-Hmp $monitor 'sendkey ret'
    Start-Sleep -Seconds 2
    $windowsHmpPath = $windowsScreenshot.Replace('\','/')
    Send-Hmp $monitor "screendump `"$windowsHmpPath`""
    $windowsDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $windowsScreenshot -PathType Leaf) -and [DateTime]::UtcNow -lt $windowsDeadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $windowsScreenshot -PathType Leaf)) { throw 'QEMU VBE Windows-list screendump missing' }

    $probe = Get-PpmRegionUniqueColors $windowsScreenshot 0 0 1 1
    $w = $probe.Width
    $h = $probe.Height
    $marginX = [Math]::Min(40, [Math]::Max(20, [int]($w / 32)))
    $marginY = [Math]::Min(32, [Math]::Max(16, [int]($h / 32)))
    $headerSubtitleY = $marginY + [Math]::Min(44, [Math]::Max(28, [int]($h / 22)))
    $headerRuleY = $headerSubtitleY + [Math]::Min(28, [Math]::Max(18, [int]($h / 36)))
    $listTop = $headerRuleY + [Math]::Min(22, [Math]::Max(12, [int]($h / 48)))
    $rowHeight = [Math]::Min(48, [Math]::Max(40, [int]($h / 18)))
    $rowGap = [Math]::Min(7, [Math]::Max(4, [int]($rowHeight / 7)))
    $rowInset = [Math]::Min(20, [Math]::Max(12, [int]($w / 64)))
    $rowBoxHeight = $rowHeight - $rowGap
    $iconX = $marginX + $rowInset + 12
    $iconY = $listTop + $rowInset + [int](($rowBoxHeight - 32) / 2)
    $iconColors = Get-PpmRegionUniqueColors $windowsScreenshot $iconX $iconY 32 32
    if ($iconColors.Count -lt 8) { throw "Legacy Windows system icon looks missing/uniform: colors=$($iconColors.Count) screenshot=$windowsScreenshot" }

    Send-Hmp $monitor 'sendkey d'
    $diagDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $diagDeadline) {
        Start-Sleep -Milliseconds 100
        $text = Read-SharedText $serial
        if ($text.Contains('USOS LEGACY BIOS DIAGNOSTICS')) { break }
    }
    if (-not $text.Contains('USOS LEGACY BIOS DIAGNOSTICS')) { throw "D did not switch VESA-2 to text diagnostics.`n$text" }
    Send-Hmp $monitor 'sendkey esc'
    $restoreDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $restoreDeadline) {
        Start-Sleep -Milliseconds 100
        $text = Read-SharedText $serial
        if ($text.Contains('VESA-2 GRAPHICS RESTORED')) { break }
    }
    if (-not $text.Contains('VESA-2 GRAPHICS RESTORED')) { throw "VESA-2 did not restore graphics after diagnostics.`n$text" }

    Write-Host "[PASS] VESA-2 SeaBIOS graphics menu + D/text/4F02 restore: vga=$Vga lfb32=$reported screenshot=$screenshot"
    $text -split "`r?`n" | Where-Object { $_ -match '^(VBE CONTROLLER|VBE MODE|SELECTED:|FRAMEBUFFER:)' } | ForEach-Object { Write-Host $_ }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
