param(
    [string]$InstrumentedRaw = 'zig-out/legacy-bios/xp-diag-exact120-instrumented.raw',
    [int]$TimeoutSeconds = 30
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
function Capture([int]$Port, [string]$Dir, [string]$Name) {
    $bin = Join-Path $Dir "$Name.bin"
    Send-Hmp $Port "pmemsave 0xb8000 4000 `"$($bin.Replace('\','/'))`""
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    while ((-not (Test-Path -LiteralPath $bin -PathType Leaf)) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 80
    }
    if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) { throw "VGA dump missing: $Name" }
    return Read-Vga $bin
}
function Extract-Line([string]$Text, [string]$Prefix) {
    foreach ($line in ($Text -split "`n")) {
        $trim = $line.Trim()
        if ($trim.StartsWith($Prefix, [StringComparison]::Ordinal)) { return $trim }
    }
    return $null
}

$raw = Full $InstrumentedRaw
if (-not (Test-Path -LiteralPath $raw -PathType Leaf)) { throw "Instrumented geometry fixture missing: $raw" }
if ((Get-Item -LiteralPath $raw).Length -ne 120034123776) { throw 'Gate 24 geometry fixture must have exact physical target size 120034123776 bytes' }

$fs = [IO.File]::Open($raw, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
try {
    $fs.Position = 2048L * 512
    $vbr = New-Object byte[] 512
    if ($fs.Read($vbr, 0, 512) -ne 512) { throw 'Short XPSETUP VBR read in Gate 24 geometry fixture' }
} finally { $fs.Dispose() }
if ($vbr[510] -ne 0x55 -or $vbr[511] -ne 0xAA) { throw 'XPSETUP VBR signature missing in Gate 24 geometry fixture' }
$bpbSectors = [BitConverter]::ToUInt16($vbr, 24)
$bpbHeads = [BitConverter]::ToUInt16($vbr, 26)
if ($bpbHeads -ne 255 -or $bpbSectors -ne 63) { throw "Fixture BPB is not exact 255/63: heads=$bpbHeads sectors=$bpbSectors" }

$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$tag = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out = Full ("zig-out/legacy-bios/xp-gate24-geometry-$tag")
New-Item -ItemType Directory -Force -Path $out | Out-Null
$monitor = Get-FreeTcpPort
$stderr = Join-Path $out 'stderr.log'
$rawQ = $raw.Replace('\','/')
$args = @(
    '-name','USOS-XP-Gate24-Geometry',
    '-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none',
    '-drive',"if=none,id=target,format=raw,file=$rawQ,snapshot=on",
    '-device','ide-hd,drive=target,bus=ide.0,unit=0,lcyls=1024,lheads=240,lsecs=63,bios-chs-trans=none'
)
$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$pass = $false
try {
    Start-Sleep -Seconds 2
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $screen = $null
    $i = 0
    while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
        try { $candidate = Capture $monitor $out ("geometry-{0:D2}" -f $i) } catch { $i++; continue }
        $i++
        if ($candidate.Contains('G Cmax=')) {
            $screen = $candidate
            break
        }
        Start-Sleep -Milliseconds 150
    }
    if (-not $screen) {
        $err = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw -LiteralPath $stderr } else { '' }
        throw "Gate 24 geometry probe did not reach AH=08 geometry evidence. stderr=$err"
    }

    $geometry = Extract-Line $screen 'G Cmax='
    Write-Host '--- GATE 24 GEOMETRY VGA ---'
    Write-Host $screen
    Write-Host "BPB heads=$bpbHeads sectors=$bpbSectors"
    if ($geometry -notmatch '^G Cmax=1022 H=240 S=63(?: |$)') { throw "SeaBIOS AH=08 is not the required 240/63 geometry: $geometry" }

    Set-Content -LiteralPath (Join-Path $out 'gate24-geometry.pass') -Encoding ASCII -Value @(
        'gate=24-geometry',
        'source=instrumented-file-only',
        'source_physical_disk=no',
        'qemu_lchs=1024/240/63',
        'bios_ah08_cmax=1022',
        'bios_ah08_heads=240',
        'bios_ah08_sectors=63',
        'bpb_heads=255',
        'bpb_sectors=63',
        'source_writes=none',
        'snapshot=on'
    )
    Write-Host '[PASS] Gate 24 geometry: SeaBIOS AH=08 exposes H=240/S=63 while the XP FAT32 BPB remains H=255/S=63.' -ForegroundColor Green
    Write-Host "OUTPUT=$out"
    $pass = $true
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(3000) | Out-Null
    }
}
if (-not $pass) { exit 1 }
