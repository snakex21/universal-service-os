param(
    [string]$SourceRaw = 'zig-out/legacy-bios/xp-strategy-b-20260909-021942-739/target-strategy-b.raw',
    [ValidateSet(240,255)][int]$Heads = 240
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
function ShaBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') } finally { $sha.Dispose() }
}

$source = Full $SourceRaw
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Gate 24 source missing: $source" }
$sourceInfo = Get-Item -LiteralPath $source
if ($sourceInfo.Length -ne 120034123776) { throw "Unexpected Gate 24 source size: $($sourceInfo.Length)" }

$expectedMbr = [IO.File]::ReadAllBytes((Full 'zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin'))
if ($expectedMbr.Length -ne 440) { throw 'Production XP geometry-fix MBR artifact must be exactly 440 bytes' }
$fs = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $sector = New-Object byte[] 512
    if ($fs.Read($sector, 0, 512) -ne 512) { throw 'Short source MBR read' }
    $vbr = New-Object byte[] 512
    $fs.Position = 2048L * 512L
    if ($fs.Read($vbr, 0, 512) -ne 512) { throw 'Short XPSETUP VBR read' }
} finally { $fs.Dispose() }
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$sector[0..439], [byte[]]$expectedMbr)) {
    throw 'Gate 24 source does not contain the current production geometry-fix MBR'
}
if ([BitConverter]::ToUInt16($vbr, 26) -ne 255 -or [BitConverter]::ToUInt16($vbr, 24) -ne 63) {
    throw 'Gate 24 must start with unchanged on-disk XPSETUP BPB 255/63'
}

$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$tag = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out = Full ("zig-out/legacy-bios/xp-gate24-desktop-h${Heads}-$tag")
New-Item -ItemType Directory -Force -Path $out | Out-Null
$overlay = Join-Path $out 'target-overlay.qcow2'
$stderr = Join-Path $out 'stderr.log'
$stdout = Join-Path $out 'stdout.log'
$stdin = Join-Path $out 'stdin.txt'
[IO.File]::WriteAllText($stdin, '')
$trace = Join-Path $out 'ide-writes.trace'
& $qemuImg create -f qcow2 -F raw -b $source $overlay
if ($LASTEXITCODE -ne 0) { throw "Gate 24 overlay creation failed: $LASTEXITCODE" }

$monitor = Get-FreeTcpPort
$args = @(
    '-name',"USOS-XP-Gate24-Desktop-H$Heads",
    '-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none',
    '-trace',"enable=ide_sector_write,file=$($trace.Replace('\','/'))",
    '-drive',"if=none,id=target,format=qcow2,file=$($overlay.Replace('\','/'))",
    '-device',"ide-hd,drive=target,bus=ide.0,unit=0,lcyls=1024,lheads=$Heads,lsecs=63,bios-chs-trans=none"
)
$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$state = [ordered]@{
    pid = $process.Id
    monitor_port = $monitor
    source = $source
    overlay = $overlay
    output = $out
    trace = $trace
    source_mbr_code_sha256 = ShaBytes $sector[0..439]
    source_mbr_tail_sha256 = ShaBytes $sector[440..511]
    source_xpsetup_bpb_heads = [BitConverter]::ToUInt16($vbr, 26)
    source_xpsetup_bpb_spt = [BitConverter]::ToUInt16($vbr, 24)
    bios_heads = $Heads
    bios_spt = 63
    physical_intel_writes = 'none'
}
$state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'gate-state.json') -Encoding ASCII
Write-Host "PID=$($process.Id)"
Write-Host "MONITOR=$monitor"
Write-Host "OVERLAY=$overlay"
Write-Host "TRACE=$trace"
Write-Host "OUTPUT=$out"
