param(
    [string]$SourceRaw = 'zig-out/legacy-bios/gate24-inspect/intel-posttextmode-gate24-source.raw',
    [int]$TimeoutSeconds = 45,
    [int]$ExpectedXpSetupStartLba = 2048
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')

function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
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
        Start-Sleep -Milliseconds 50
        $bytes = [Text.Encoding]::ASCII.GetBytes($Command + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        Start-Sleep -Milliseconds 100
    } finally { $client.Dispose() }
}
function Read-Vga([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sb = [Text.StringBuilder]::new()
    for ($row = 0; $row -lt 25; $row++) {
        for ($col = 0; $col -lt 80; $col++) {
            $i = (($row * 80) + $col) * 2
            $x = $bytes[$i]
            if ($x -ge 32 -and $x -le 126) { [void]$sb.Append([char]$x) } else { [void]$sb.Append(' ') }
        }
        [void]$sb.Append("`n")
    }
    return $sb.ToString()
}
function Capture([int]$Port, [string]$Directory, [int]$Index) {
    $bin = Join-Path $Directory ("breadcrumb-{0:D2}.bin" -f $Index)
    $ppm = Join-Path $Directory ("breadcrumb-{0:D2}.ppm" -f $Index)
    Send-Hmp $Port "pmemsave 0xb8000 4000 `"$($bin.Replace('\','/'))`""
    Send-Hmp $Port "screendump `"$($ppm.Replace('\','/'))`""
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while ((-not (Test-Path -LiteralPath $bin -PathType Leaf)) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) { throw "Missing VGA breadcrumb dump: $bin" }
    return [pscustomobject]@{ Text=(Read-Vga $bin); Bin=$bin; Ppm=$ppm }
}
function Has([string]$Text, [string]$Marker) { return $Text.Contains($Marker) }

$source = Full $SourceRaw
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Gate 24 source RAW missing: $source" }
$sourceInfo = Get-Item -LiteralPath $source
if ($sourceInfo.Length -ne 120034123776) { throw "Gate 24 source size mismatch: $($sourceInfo.Length)" }
$sourceStamp = $sourceInfo.LastWriteTimeUtc

$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$builder = Full 'tools/build_xp_boot_diagnostic.ps1'
$patcher = Full 'tools/tests/legacy_bios/prepare_xp_boot_diagnostic_fixture.py'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if ($LASTEXITCODE -ne 0) { throw "XP diagnostic build failed: $LASTEXITCODE" }

$tag = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out = Full ("zig-out/legacy-bios/xp-gate24-breadcrumbs-$tag")
New-Item -ItemType Directory -Force -Path $out | Out-Null
$instrumented = Join-Path $out 'target-instrumented.raw'
& $qemuImg convert -f raw -O raw -S 4k $source $instrumented
if ($LASTEXITCODE -ne 0) { throw "Sparse clone for breadcrumbs failed: $LASTEXITCODE" }

& $python $patcher `
    --target-raw $instrumented `
    --diag-mbr (Full 'zig-out/xp-boot-diagnostic/diag-mbr-440.bin') `
    --diag-prelude (Full 'zig-out/xp-boot-diagnostic/diag-prelude-lba1-8.bin') `
    --diag-vbr-helper (Full 'zig-out/xp-boot-diagnostic/diag-vbr-helper.bin') `
    --diag-stage2-helper (Full 'zig-out/xp-boot-diagnostic/diag-stage2-helper.bin') `
    --diag-runtime (Full 'zig-out/xp-boot-diagnostic/diag-runtime-512.bin') `
    --nt52-vbr-tail (Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin') `
    --nt52-stage2 (Full 'zig-out/xp-bios/xp-nt52-stage2.bin') `
    --xpsetup-slot 1 `
    --expected-xpsetup-start-lba $ExpectedXpSetupStartLba
if ($LASTEXITCODE -ne 0) { throw "Gate 24 breadcrumb instrumentation failed: $LASTEXITCODE" }

$afterClone = Get-Item -LiteralPath $source
if ($afterClone.Length -ne $sourceInfo.Length -or $afterClone.LastWriteTimeUtc -ne $sourceStamp) { throw 'Source RAW changed while preparing disposable diagnostic copy' }

$monitor = Get-FreeTcpPort
$stderr = Join-Path $out 'stderr.log'
$args = @(
    '-name','USOS-XP-Gate24-Breadcrumbs-H240',
    '-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none',
    '-drive',"if=none,id=target,format=raw,file=$($instrumented.Replace('\','/')),snapshot=on",
    '-device','ide-hd,drive=target,bus=ide.0,unit=0,lcyls=1024,lheads=240,lsecs=63,bios-chs-trans=none'
)
$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$last = $null
try {
    Start-Sleep -Seconds 2
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $index = 0
    while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
        try { $capture = Capture $monitor $out $index } catch { $index++; Start-Sleep -Milliseconds 100; continue }
        $last = $capture
        $compact = (($capture.Text -split "`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim().Length -gt 0 }) -join ' | '
        Write-Host ("[GATE24-BREADCRUMB] sample={0} {1}" -f $index,$compact)
        $index++
        if (Has $capture.Text 'J DL=80' -or Has $capture.Text 'M PRELUDE ERR=' -or Has $capture.Text 'NTLDR ERR' -or Has $capture.Text 'CRC RAM=') { break }
        Start-Sleep -Milliseconds 200
    }
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(3000) | Out-Null
    }
}
if (-not $last) { throw 'Gate 24 breadcrumb run produced no VGA evidence' }

$text = $last.Text
$markers = [ordered]@{
    M = (Has $text 'M DL=80')
    V = (Has $text 'V DL=80')
    '2' = (Has $text '2 DL=80')
    F = (Has $text 'F DL=80')
    N = (Has $text 'N DL=80')
    J = (Has $text 'J DL=80')
}
foreach ($entry in $markers.GetEnumerator()) { Write-Host ("MARKER {0}={1}" -f $entry.Key,$entry.Value) }

$stop = if (-not $markers.M) { 'before-diagnostic-MBR-entry' }
elseif (-not $markers.V) { 'inside-original-MBR-before-Microsoft-VBR-entry' }
elseif (-not $markers.'2') { 'inside-Microsoft-VBR-before-stage2-entry' }
elseif (-not $markers.F) { 'inside-Microsoft-stage2-before-root-directory-read' }
elseif (-not $markers.N) { 'Microsoft-stage2-root-read-before-NTLDR-found' }
elseif (-not $markers.J) { 'Microsoft-stage2-after-NTLDR-found-before-far-jump' }
else { 'after-Microsoft-stage2-far-jump-to-NTLDR' }

$geometryLine = (($text -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith('G Cmax=') } | Select-Object -First 1)
$crcLine = (($text -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith('CRC RAM=') } | Select-Object -First 1)
$evidence = @(
    'gate=24-breadcrumbs',
    'source=disposable-instrumented-copy-of-gate24-clone',
    'physical_intel_writes=none',
    'source_gate24_raw_modified=no',
    'bios_heads=240',
    'bios_sectors=63',
    "geometry=$geometryLine",
    "marker_M=$($markers.M)",
    "marker_V=$($markers.V)",
    "marker_2=$($markers.'2')",
    "marker_F=$($markers.F)",
    "marker_N=$($markers.N)",
    "marker_J=$($markers.J)",
    "stop=$stop",
    "crc=$crcLine"
)
Set-Content -LiteralPath (Join-Path $out 'gate24-breadcrumbs.txt') -Encoding ASCII -Value $evidence
Write-Host "STOP_POINT=$stop"
if ($crcLine) { Write-Host "CRC_EVIDENCE=$crcLine" }
Write-Host "OUTPUT=$out"
