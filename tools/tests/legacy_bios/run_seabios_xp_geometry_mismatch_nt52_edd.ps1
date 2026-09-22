param(
    [string]$SourceTargetRaw = 'zig-out/legacy-bios/xp-diag-exact120-physical-mbr-base.raw',
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
function Send-Hmp([int]$Port, [string]$Command) {
    $client = [Net.Sockets.TcpClient]::new()
    $client.Connect('127.0.0.1', $Port)
    try {
        $stream = $client.GetStream()
        Start-Sleep -Milliseconds 40
        $bytes = [Text.Encoding]::ASCII.GetBytes($Command + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        Start-Sleep -Milliseconds 80
    } finally { $client.Dispose() }
}
function Read-Vga([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sb = [Text.StringBuilder]::new()
    for ($r = 0; $r -lt 25; $r++) {
        for ($c = 0; $c -lt 80; $c++) {
            $i = (($r * 80) + $c) * 2
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
    while ((-not (Test-Path $bin)) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 80 }
    if (-not (Test-Path $bin)) { throw "missing VGA dump $Name" }
    return Read-Vga $bin
}

$source = Full $SourceTargetRaw
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "source target missing: $source" }
if ((Get-Item -LiteralPath $source).Length -ne 120034123776) { throw 'gate 2/3 requires exact 120034123776-byte target' }

$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$python = (Get-Command python.exe -ErrorAction Stop).Source

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/build_xp_boot_diagnostic.ps1')
if ($LASTEXITCODE -ne 0) { throw 'diagnostic build failed' }

$tag = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out = Full ("zig-out/legacy-bios/xp-geometry-mismatch-nt52-edd-$tag")
New-Item -ItemType Directory -Force -Path $out | Out-Null
$raw = Join-Path $out 'target-instrumented.raw'
& $qemuImg convert -f raw -O raw -S 4k $source $raw
if ($LASTEXITCODE -ne 0) { throw 'sparse clone failed' }

& $python (Full 'tools/tests/legacy_bios/prepare_xp_boot_diagnostic_fixture.py') `
    --target-raw $raw `
    --diag-mbr (Full 'zig-out/xp-boot-diagnostic/diag-mbr-440.bin') `
    --diag-prelude (Full 'zig-out/xp-boot-diagnostic/diag-prelude-mismatch-lba1-8.bin') `
    --diag-vbr-helper (Full 'zig-out/xp-boot-diagnostic/diag-vbr-helper.bin') `
    --diag-stage2-helper (Full 'zig-out/xp-boot-diagnostic/diag-stage2-helper.bin') `
    --diag-runtime (Full 'zig-out/xp-boot-diagnostic/diag-runtime-512.bin') `
    --nt52-vbr-tail (Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin') `
    --nt52-stage2 (Full 'zig-out/xp-bios/xp-nt52-stage2.bin') `
    --xpsetup-slot 1
if ($LASTEXITCODE -ne 0) { throw 'diagnostic fixture failed' }

& $python (Full 'tools/tests/legacy_bios/install_xp_nt52_edd_patch_fixture.py') --target-raw $raw --xpsetup-slot 1
if ($LASTEXITCODE -ne 0) { throw 'NT52 EDD-only fixture patch failed' }

$monitor = Get-FreeTcpPort
$stderr = Join-Path $out 'stderr.log'
$args = @(
    '-name','USOS-XP-NT52-EDD-Mismatch',
    '-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none',
    '-drive',"if=ide,index=0,format=raw,file=$($raw.Replace('\','/')),media=disk,snapshot=on"
)
$p = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$pass = $false
try {
    Start-Sleep -Seconds 3
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $before = $null
    $timerAt = $null
    $i = 0
    while ([DateTime]::UtcNow -lt $deadline -and -not $p.HasExited) {
        try { $screen = Capture $monitor $out ("probe-{0:D2}" -f $i) } catch { $i++; continue }
        $i++
        if ($screen.Contains('CRC RAM=4D42CE43 EXPECT=4D42CE43 SAME=YES') -and $screen.Contains('AUTO 5s BIOS TIMER...')) {
            $before = $screen
            $timerAt = [DateTime]::UtcNow
            break
        }
        Start-Sleep -Milliseconds 150
    }
    if (-not $before) { throw 'GATE 2 FAIL: patched NT52 did not reach exact RAM CRC' }

    Write-Host '--- GATE 2 VGA ---'
    Write-Host $before
    $required = @(
        'G Cmax=1022 H=240 S=63',
        'B BPB H=255 S=63',
        'LBA1123648',
        ' AH08 C=74 H=75 S=44 IO=OK SAME=YES',
        ' BPB  C=69 H=240 S=44 IO=OK SAME=NO',
        'V DL=80','2 DL=80','F DL=80','N DL=80','J DL=80',
        'CRC RAM=4D42CE43 EXPECT=4D42CE43 SAME=YES'
    )
    foreach ($needle in $required) {
        if (-not $before.Contains($needle)) { throw "GATE 2 missing evidence [$needle]" }
    }
    Set-Content -LiteralPath (Join-Path $out 'gate2.pass') -Encoding ASCII -Value @(
        'gate=2',
        'loader=Microsoft-NT52-EDD-only',
        'patch=VBR-tail+0x8C 0F824A00->90909090',
        'bios_geometry=1023/240/63',
        'bpb_geometry=255/63',
        'chs_bpb_same=NO',
        'crc_ram=4D42CE43',
        'crc_same=YES'
    )
    Write-Host '[PASS] GATE 2: Microsoft NT52 with only the 4-byte EDD-only patch loads exact NTLDR under 240/255 mismatch.' -ForegroundColor Green

    # Gate 3: no keyboard event from J until Windows XP itself is visible.
    $firstXp = $null
    $noKeyDeadline = [DateTime]::UtcNow.AddSeconds(35)
    $j = 0
    while ([DateTime]::UtcNow -lt $noKeyDeadline -and -not $p.HasExited) {
        Start-Sleep -Milliseconds 300
        try { $screen = Capture $monitor $out ("auto-{0:D2}" -f $j) } catch { $j++; continue }
        $j++
        $lower = $screen.ToLowerInvariant()
        if (($lower.Contains('windows xp') -or $lower.Contains('instalator systemu windows')) -and
            ($lower.Contains('zapraszamy') -or $lower.Contains('welcome') -or $lower.Contains('f8') -or $lower.Contains('licen') -or $lower.Contains('partycj') -or $lower.Contains('unpartitioned') -or $lower.Contains('nie podziel'))) {
            $firstXp = $screen
            break
        }
    }
    if (-not $firstXp) {
        $counterFile = Join-Path $out 'post-j-int13-counters.bin'
        try {
            Send-Hmp $monitor "pmemsave 0x0f00 6 `"$($counterFile.Replace('\','/'))`""
            $counterDeadline = [DateTime]::UtcNow.AddSeconds(2)
            while ((-not (Test-Path $counterFile)) -and [DateTime]::UtcNow -lt $counterDeadline) { Start-Sleep -Milliseconds 80 }
            if (Test-Path $counterFile) {
                $cb = [IO.File]::ReadAllBytes($counterFile)
                if ($cb.Length -ge 6) {
                    $c02 = [BitConverter]::ToUInt16($cb, 0)
                    $c42 = [BitConverter]::ToUInt16($cb, 2)
                    $c08 = [BitConverter]::ToUInt16($cb, 4)
                    Write-Host "POST_J_INT13 AH02=$c02 AH42=$c42 AH08=$c08"
                }
            }
        } catch { Write-Host "POST_J_INT13 counter read failed: $($_.Exception.Message)" }
        throw 'GATE 3 FAIL: exact NTLDR did not auto-continue into Windows XP Setup'
    }
    $elapsed = ([DateTime]::UtcNow - $timerAt).TotalSeconds
    if ($elapsed -lt 4.0) { throw ("GATE 3 timer too short: {0:N2}s" -f $elapsed) }

    $setup = $null
    $lower = $firstXp.ToLowerInvariant()
    if (($lower.Contains('partycj') -or $lower.Contains('unpartitioned') -or $lower.Contains('nie podziel')) -and $lower.Contains('enter')) {
        $setup = $firstXp
    } elseif (($lower.Contains('zapraszamy') -or $lower.Contains('welcome')) -and $lower.Contains('enter')) {
        Send-Hmp $monitor 'sendkey ret'
    } elseif (($lower.Contains('f8') -or $lower.Contains('f 8')) -and ($lower.Contains('licen') -or $lower.Contains('umow'))) {
        Send-Hmp $monitor 'sendkey f8'
    }

    $setupDeadline = [DateTime]::UtcNow.AddSeconds(45)
    $k = 0
    while (-not $setup -and [DateTime]::UtcNow -lt $setupDeadline -and -not $p.HasExited) {
        Start-Sleep -Milliseconds 650
        try { $screen = Capture $monitor $out ("setup-{0:D2}" -f $k) } catch { $k++; continue }
        $k++
        $lower = $screen.ToLowerInvariant()
        if (($lower.Contains('partycj') -or $lower.Contains('unpartitioned') -or $lower.Contains('nie podziel')) -and $lower.Contains('enter')) {
            $setup = $screen
            break
        }
        if (($lower.Contains('zapraszamy') -or $lower.Contains('welcome')) -and $lower.Contains('enter')) { Send-Hmp $monitor 'sendkey ret'; continue }
        if (($lower.Contains('f8') -or $lower.Contains('f 8')) -and ($lower.Contains('licen') -or $lower.Contains('umow'))) { Send-Hmp $monitor 'sendkey f8'; continue }
    }
    if (-not $setup) { throw 'GATE 3 FAIL: Windows XP did not reach Text Mode partition screen' }

    Write-Host '--- GATE 3 POST-JUMP VGA ---'
    Write-Host $setup
    Set-Content -LiteralPath (Join-Path $out 'gate3.pass') -Encoding ASCII -Value @(
        'gate=3',
        'no_key_until_windows_xp=yes',
        ("first_xp_after_seconds={0:N2}" -f $elapsed),
        'xp_textmode_partition_screen=yes'
    )
    Write-Host ("[PASS] GATE 3: patched Microsoft NT52 auto-continues into XP Text Mode ({0:N2}s to first XP screen)." -f $elapsed) -ForegroundColor Green
    Write-Host "OUTPUT=$out"
    $pass = $true
} finally {
    if (-not $p.HasExited) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $p.WaitForExit(3000) | Out-Null
    }
}
if (-not $pass) { exit 1 }
