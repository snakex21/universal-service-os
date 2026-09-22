param(
    [string]$SourceRaw = 'zig-out/legacy-bios/gate24-inspect/intel-posttextmode-gate24-source.raw',
    [ValidateSet(240,255)][int]$Heads = 255,
    [int]$TimeoutSeconds = 60
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
function Invoke-Hmp([int]$Port, [string]$Command) {
    $client = [Net.Sockets.TcpClient]::new()
    $client.ReceiveTimeout = 2500
    $client.SendTimeout = 2500
    $client.Connect('127.0.0.1', $Port)
    try {
        $stream = $client.GetStream()
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
        try {
            Start-Sleep -Milliseconds 80
            while ($stream.DataAvailable) { [void]$reader.ReadLine() }
            $bytes = [Text.Encoding]::ASCII.GetBytes($Command + "`n")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            Start-Sleep -Milliseconds 120
            $sb = [Text.StringBuilder]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            while ([DateTime]::UtcNow -lt $deadline) {
                while ($stream.DataAvailable) {
                    $buffer = New-Object char[] 4096
                    $count = $reader.Read($buffer, 0, $buffer.Length)
                    if ($count -gt 0) { [void]$sb.Append($buffer, 0, $count) }
                }
                if ($sb.ToString().Contains('(qemu)')) { break }
                Start-Sleep -Milliseconds 40
            }
            return $sb.ToString()
        } finally { $reader.Dispose() }
    } finally { $client.Dispose() }
}
function Capture-Screen([int]$Port, [string]$Directory, [int]$Index) {
    $path = Join-Path $Directory ("screen-{0:D2}.ppm" -f $Index)
    [void](Invoke-Hmp $Port "screendump `"$($path.Replace('\','/'))`"")
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while ((-not (Test-Path -LiteralPath $path -PathType Leaf)) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing screenshot: $path" }
    $item = Get-Item -LiteralPath $path
    return [pscustomobject]@{ Path=$path; Length=$item.Length; Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}
function Read-Cr0([string]$Registers) {
    $match = [regex]::Match($Registers, '(?im)\bCR0=([0-9A-F]+)')
    if (-not $match.Success) { return $null }
    return [Convert]::ToUInt64($match.Groups[1].Value, 16)
}

$source = Full $SourceRaw
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Gate 24 source RAW missing: $source" }
$sourceInfo = Get-Item -LiteralPath $source
if ($sourceInfo.Length -ne 120034123776) { throw "Gate 24 requires exact 120034123776-byte clone, got $($sourceInfo.Length)" }
$sourceStamp = $sourceInfo.LastWriteTimeUtc

$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$tag = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out = Full ("zig-out/legacy-bios/xp-gate24-control-h${Heads}-$tag")
New-Item -ItemType Directory -Force -Path $out | Out-Null
$overlay = Join-Path $out 'target-overlay.qcow2'
& $qemuImg create -f qcow2 -F raw -b $source $overlay
if ($LASTEXITCODE -ne 0) { throw "Gate 24 overlay creation failed: $LASTEXITCODE" }

$monitor = Get-FreeTcpPort
$stderr = Join-Path $out 'stderr.log'
$args = @(
    '-name',"USOS-XP-Gate24-H$Heads",
    '-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none',
    '-drive',"if=none,id=target,format=qcow2,file=$($overlay.Replace('\','/'))",
    '-device',"ide-hd,drive=target,bus=ide.0,unit=0,lcyls=1024,lheads=$Heads,lsecs=63,bios-chs-trans=none"
)
$process = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$protectedModeSeen = $false
$screens = @()
$registerEvidence = @()
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $index = 0
    while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
        Start-Sleep -Seconds 3
        try {
            $registers = Invoke-Hmp $monitor 'info registers'
            $cr0 = Read-Cr0 $registers
            if ($null -ne $cr0) {
                $pe = (($cr0 -band 1) -ne 0)
                if ($pe) { $protectedModeSeen = $true }
                $registerEvidence += "t=$([Math]::Round(($TimeoutSeconds-($deadline-[DateTime]::UtcNow).TotalSeconds),1)) cr0=0x$('{0:X}' -f $cr0) pe=$pe"
            }
            $screen = Capture-Screen $monitor $out $index
            $screens += $screen
            Write-Host ("[GATE24] H={0} sample={1} ppm_bytes={2} sha={3} protected_mode_seen={4}" -f $Heads,$index,$screen.Length,$screen.Sha256,$protectedModeSeen)
            $index++
            if ($protectedModeSeen -and $screens.Count -ge 2) { break }
        } catch {
            Write-Host "[GATE24] sample error: $($_.Exception.Message)"
        }
    }
} finally {
    if ($process -and -not $process.HasExited) {
        try { [void](Invoke-Hmp $monitor 'quit') } catch {}
        if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

$after = Get-Item -LiteralPath $source
if ($after.Length -ne $sourceInfo.Length -or $after.LastWriteTimeUtc -ne $sourceStamp) { throw 'Gate 24 source RAW metadata changed during snapshot test' }
$overlayInfo = (& $qemuImg info --output=json $overlay | ConvertFrom-Json)
$stderrText = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw -LiteralPath $stderr } else { '' }
$distinctHashes = @($screens | Select-Object -ExpandProperty Sha256 -Unique)
$distinctSizes = @($screens | Select-Object -ExpandProperty Length -Unique)
$evidence = @(
    "gate=24-control",
    "heads=$Heads",
    'sectors=63',
    'target_bios_drive=0x80',
    'usos_present=no',
    'source=full-readonly-clone-of-physical-intel',
    'source_raw_modified=no',
    'guest_writes=qcow2-overlay-only',
    "overlay_actual_size=$($overlayInfo.'actual-size')",
    "protected_mode_seen=$protectedModeSeen",
    "screen_samples=$($screens.Count)",
    "distinct_screen_hashes=$($distinctHashes.Count)",
    "distinct_screen_sizes=$($distinctSizes -join ',')"
) + $registerEvidence
Set-Content -LiteralPath (Join-Path $out 'evidence.txt') -Encoding ASCII -Value $evidence

if ($Heads -eq 255) {
    if (-not $protectedModeSeen) {
        throw "GATE 24 CONTROL FAIL: same clone did not reach protected mode under 255/63. OUTPUT=$out STDERR=$stderrText"
    }
    Set-Content -LiteralPath (Join-Path $out 'gate24-control.pass') -Encoding ASCII -Value $evidence
    Write-Host '[PASS] Gate 24 control: the same clone boots beyond BIOS/real-mode boot code under 255/63 and reaches protected mode.' -ForegroundColor Green
} else {
    if ($protectedModeSeen) {
        Write-Host '[INFO] H=240 reached protected mode; inspect breadcrumbs before drawing a CHS conclusion.' -ForegroundColor Yellow
    } else {
        Write-Host '[INFO] H=240 stayed in real mode for the observation window.' -ForegroundColor Yellow
    }
}
Write-Host "OUTPUT=$out"
