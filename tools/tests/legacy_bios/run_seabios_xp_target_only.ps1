param(
    [Parameter(Mandatory=$true)][string]$SourceTargetRaw,
    [int]$XpSetupSlot = 2
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Get-FreeTcpPort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}
function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try { $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$true,4096,$true); try { return $reader.ReadToEnd() } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}
function Send-Hmp([int]$Port,[string]$Command) {
    $client=[Net.Sockets.TcpClient]::new(); $client.Connect('127.0.0.1',$Port)
    try { $stream=$client.GetStream(); Start-Sleep -Milliseconds 50; $bytes=[Text.Encoding]::ASCII.GetBytes($Command+"`n"); $stream.Write($bytes,0,$bytes.Length); $stream.Flush(); Start-Sleep -Milliseconds 80 } finally { $client.Dispose() }
}
function Read-VgaText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $bytes=[IO.File]::ReadAllBytes($Path); $sb=[Text.StringBuilder]::new()
    for ($row=0; $row -lt 25; $row++) {
        for ($col=0; $col -lt 80; $col++) {
            $i=(($row*80)+$col)*2; if ($i -ge $bytes.Length) { break }
            $c=$bytes[$i]; if ($c -lt 32 -or $c -gt 126) { [void]$sb.Append(' ') } else { [void]$sb.Append([char]$c) }
        }
        [void]$sb.Append("`n")
    }
    return $sb.ToString()
}

$source=[IO.Path]::GetFullPath($SourceTargetRaw)
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "prepared XP target missing: $source" }
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$helper=Full 'tools/tests/legacy_bios/prepare_xp_target_only_fixture.py'
$xpBuilder=Full 'tools/build_xp_bootstrap.ps1'
$bootsect="$env:SystemRoot\System32\bootsect.exe"
if (-not (Test-Path -LiteralPath $bootsect -PathType Leaf)) { throw "Microsoft bootsect.exe missing: $bootsect" }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $xpBuilder
if ($LASTEXITCODE -ne 0) { throw "XP bootstrap build failed: $LASTEXITCODE" }

$tag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=Full ("zig-out/legacy-bios/xp-target-only-$tag")
New-Item -ItemType Directory -Force -Path $out | Out-Null
$target=Join-Path $out 'target-only.raw'
$serial=Join-Path $out 'serial.log'
$stderr=Join-Path $out 'stderr.log'

& $qemuImg convert -f raw -O raw -S 4k $source $target
if ($LASTEXITCODE -ne 0) { throw "sparse target-only clone failed: $LASTEXITCODE" }
& $python $helper --target-raw $target --bootsect-exe $bootsect --vbr-code (Full 'zig-out/xp-bios/xp-vbr-code.bin') --stage2 (Full 'zig-out/xp-bios/xp-stage2.bin') --xpsetup-slot $XpSetupSlot
if ($LASTEXITCODE -ne 0) { throw "target-only fixture preparation failed: $LASTEXITCODE" }

$monitor=Get-FreeTcpPort
$args=@(
    '-name','USOS-XP-TargetOnly', '-machine','pc', '-accel','tcg,thread=multi', '-cpu','max',
    '-m','512M', '-smp','2', '-bios',$seabios, '-boot','order=c,strict=on', '-display','none', '-vga','std', '-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off", '-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=ide,index=0,format=raw,file=$($target.Replace('\','/')),media=disk"
)
$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$green=$false
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(25); $text=''
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $text=Read-SharedText $serial
        if ($text.Contains('[XP-BOOT] NTLDR JUMP')) { break }
    }
    $text=Read-SharedText $serial
    foreach ($marker in @('[XP-VBR] START','[XP-VBR] STAGE2 READ PASS','[XP-BOOT] STAGE2','[XP-BOOT] NTLDR FOUND','[XP-BOOT] NTLDR JUMP')) {
        if (-not $text.Contains($marker)) { throw "target-only stopped before $marker`n--- serial ---`n$text`n--- stderr ---`n$(Read-SharedText $stderr)" }
    }

    $screenEvidence=''; $screenPath=''; $ntdetectFailed=$false; $setupAdvanced=$false
    for ($i=0; $i -lt 48 -and -not $process.HasExited; $i++) {
        Start-Sleep -Milliseconds 250
        $dump=Join-Path $out ("vga-{0:D2}.bin" -f $i)
        $shot=Join-Path $out ("screen-{0:D2}.ppm" -f $i)
        try {
            Send-Hmp $monitor "pmemsave 0xb8000 4000 `"$($dump.Replace('\','/'))`""
            Send-Hmp $monitor "screendump `"$($shot.Replace('\','/'))`""
        } catch { break }
        $vga=Read-VgaText $dump
        $lower=$vga.ToLowerInvariant()
        if ($lower.Contains('ntdetect')) {
            $ntdetectFailed=$true; $screenEvidence=$vga; $screenPath=$shot; break
        }
        if ($lower.Contains('windows xp') -or $lower.Contains('instalator systemu windows') -or $lower.Contains('partycj') -or $lower.Contains('i386')) {
            $setupAdvanced=$true; $screenEvidence=$vga; $screenPath=$shot; break
        }
        $current=Read-SharedText $serial
        if (($current.Split('[XP-VBR] START').Count - 1) -ge 2) { break }
    }

    $finalSerial=Read-SharedText $serial
    Write-Host '--- TARGET-ONLY SERIAL ---'
    Write-Host $finalSerial
    if ($screenEvidence) { Write-Host '--- VGA EVIDENCE ---'; Write-Host $screenEvidence }

    if ($ntdetectFailed) { throw "target-only BIOS 0x80 still reports NTDETECT failure; screenshot=$screenPath" }
    if (-not $setupAdvanced) {
        throw "target-only BIOS 0x80 did not produce Setup evidence before reboot/timeout; inspect $out"
    }

    $green=$true
    Set-Content -LiteralPath (Join-Path $out 'target-only.pass') -Value "BIOS_0x80_NTDETECT_PASS`nscreenshot=$screenPath" -Encoding ASCII
    Write-Host "[PASS] target-only BIOS drive 0x80 advanced past NTDETECT: $screenPath" -ForegroundColor Green
}
finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; $process.WaitForExit(3000) | Out-Null }
    if ($green -and (Test-Path -LiteralPath $target)) { Remove-Item -LiteralPath $target -Force; Write-Host '[CLEAN] target-only.raw' }
}
