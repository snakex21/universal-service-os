param(
    [string]$SourceTargetRaw = 'zig-out/legacy-bios/xp-diag-exact120-physical-mbr-base.raw',
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path){ if([IO.Path]::IsPathRooted($Path)){return [IO.Path]::GetFullPath($Path)}; return [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Get-FreeTcpPort { $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()} }
function Send-Hmp([int]$Port,[string]$Command){$c=[Net.Sockets.TcpClient]::new();$c.Connect('127.0.0.1',$Port);try{$s=$c.GetStream();Start-Sleep -Milliseconds 50;$b=[Text.Encoding]::ASCII.GetBytes($Command+"`n");$s.Write($b,0,$b.Length);$s.Flush();Start-Sleep -Milliseconds 100}finally{$c.Dispose()}}
function Read-Vga([string]$Path){$b=[IO.File]::ReadAllBytes($Path);$sb=[Text.StringBuilder]::new();for($r=0;$r-lt25;$r++){for($c=0;$c-lt80;$c++){$i=(($r*80)+$c)*2;$x=$b[$i];if($x-ge32-and$x-le126){[void]$sb.Append([char]$x)}else{[void]$sb.Append(' ')}};[void]$sb.Append("`n")};return $sb.ToString()}
function Capture([int]$Port,[string]$Dir,[string]$Name){$bin=Join-Path $Dir "$Name.bin";Send-Hmp $Port "pmemsave 0xb8000 4000 `"$($bin.Replace('\','/'))`"";$d=[DateTime]::UtcNow.AddSeconds(2);while((-not(Test-Path $bin))-and[DateTime]::UtcNow-lt$d){Start-Sleep -Milliseconds 100};if(-not(Test-Path $bin)){throw "missing VGA dump $Name"};return Read-Vga $bin}

$source=Full $SourceTargetRaw
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "source target missing: $source"}
if((Get-Item -LiteralPath $source).Length-ne120034123776){throw 'gate 2 requires exact 120034123776-byte target'}
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$diagBuilder=Full 'tools/build_xp_boot_diagnostic.ps1'
$diagPatcher=Full 'tools/tests/legacy_bios/prepare_xp_boot_diagnostic_fixture.py'
$eddPatcher=Full 'tools/tests/legacy_bios/install_xp_edd_loader_fixture.py'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $diagBuilder
if($LASTEXITCODE-ne0){throw "diagnostic build failed: $LASTEXITCODE"}

$tag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=Full ("zig-out/legacy-bios/xp-geometry-mismatch-edd-$tag")
New-Item -ItemType Directory -Force -Path $out|Out-Null
$raw=Join-Path $out 'target-instrumented.raw'
& $qemuImg convert -f raw -O raw -S 4k $source $raw
if($LASTEXITCODE-ne0){throw "sparse clone failed: $LASTEXITCODE"}

# First install the proven diagnostic MBR/prelude/runtime with the 240/63 INT13 shim.
& $python $diagPatcher --target-raw $raw --diag-mbr (Full 'zig-out/xp-boot-diagnostic/diag-mbr-440.bin') --diag-prelude (Full 'zig-out/xp-boot-diagnostic/diag-prelude-external-mismatch-lba1-8.bin') --diag-vbr-helper (Full 'zig-out/xp-boot-diagnostic/diag-vbr-helper.bin') --diag-stage2-helper (Full 'zig-out/xp-boot-diagnostic/diag-stage2-helper.bin') --diag-runtime (Full 'zig-out/xp-boot-diagnostic/diag-runtime-512.bin') --nt52-vbr-tail (Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin') --nt52-stage2 (Full 'zig-out/xp-bios/xp-nt52-stage2.bin') --xpsetup-slot 1
if($LASTEXITCODE-ne0){throw "diagnostic fixture patch failed: $LASTEXITCODE"}

# Then replace only VBR/stage2 with the EDD/LBA loader diagnostic variant.
& $python $eddPatcher --target-raw $raw --vbr-code (Full 'zig-out/xp-bios/xp-vbr-code.bin') --stage2 (Full 'zig-out/xp-bios/xp-stage2-diag.bin') --int13-shim (Full 'zig-out/xp-boot-diagnostic/diag-int13-shim-512.bin') --xpsetup-slot 1
if($LASTEXITCODE-ne0){throw "EDD fixture patch failed: $LASTEXITCODE"}

$monitor=Get-FreeTcpPort
$stderr=Join-Path $out 'stderr.log'
$serial=Join-Path $out 'serial.log'
$driveArg="if=ide,index=0,format=raw,file=$($raw.Replace('\','/')),media=disk,snapshot=on"
$args=@('-name','USOS-XP-Geometry-Mismatch-EDD','-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2','-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none','-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial',"file:$($serial.Replace('\','/'))",'-drive',$driveArg)
$p=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$pass=$false
try {
    Start-Sleep -Seconds 3
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $before=$null
    $timerSeenAt=$null
    $i=0
    while([DateTime]::UtcNow-lt$deadline-and-not$p.HasExited){
        try{$s=Capture $monitor $out ("probe-{0:D2}" -f $i)}catch{$i++;continue}
        $i++
        if($s.Contains('CRC RAM=4D42CE43 EXPECT=4D42CE43 SAME=YES') -and $s.Contains('AUTO 5s BIOS TIMER...')){$before=$s;$timerSeenAt=[DateTime]::UtcNow;break}
        Start-Sleep -Milliseconds 150
    }
    if(-not$before){
        $ser=if(Test-Path $serial){Get-Content -Raw $serial}else{''}
        throw "gate 2 did not reach correct RAM CRC. serial=$ser"
    }
    Write-Host '--- GATE 2 VGA ---';Write-Host $before

    $required=@(
        'G Cmax=1022 H=240 S=63',
        'B BPB H=255 S=63',
        'LBA1123648',
        ' EDD=OK',
        ' AH08 C=74 H=75 S=44 IO=OK SAME=YES',
        ' BPB  C=69 H=240 S=44 IO=OK SAME=NO',
        'J DL=80',
        'CRC RAM=4D42CE43 EXPECT=4D42CE43 SAME=YES'
    )
    foreach($needle in $required){if(-not$before.Contains($needle)){throw "gate 2 missing required evidence [$needle]"}}

    $serText=if(Test-Path $serial){Get-Content -Raw $serial}else{''}
    foreach($needle in @('[XP-VBR] START','[XP-VBR] STAGE2 READ PASS','[XP-BOOT] STAGE2','[XP-BOOT] NTLDR FOUND','[XP-BOOT] NTLDR JUMP')){if(-not$serText.Contains($needle)){throw "gate 2 serial missing EDD-loader evidence [$needle]"}}

    # No key event is sent until Windows XP itself becomes visible.
    $firstXp=$null
    $noKeyDeadline=[DateTime]::UtcNow.AddSeconds(35)
    $j=0
    while([DateTime]::UtcNow-lt$noKeyDeadline-and-not$p.HasExited){
        Start-Sleep -Milliseconds 300
        try{$s=Capture $monitor $out ("auto-{0:D2}" -f $j)}catch{$j++;continue}
        $j++
        $lo=$s.ToLowerInvariant()
        if((($lo.Contains('windows xp')-or$lo.Contains('instalator systemu windows')) -and ($lo.Contains('zapraszamy')-or$lo.Contains('welcome')-or$lo.Contains('f8')-or$lo.Contains('licen')-or$lo.Contains('partycj')-or$lo.Contains('unpartitioned')-or$lo.Contains('nie podziel')))){$firstXp=$s;break}
    }
    if(-not$firstXp){throw 'gate 2 correct CRC did not continue into Windows XP Setup'}
    $elapsed=([DateTime]::UtcNow-$timerSeenAt).TotalSeconds
    if($elapsed-lt4.0){throw ("gate 2 XP appeared too early for BIOS timer: {0:N2}s" -f $elapsed)}

    $setup=$null
    $lo=$firstXp.ToLowerInvariant()
    if(($lo.Contains('partycj')-or$lo.Contains('unpartitioned')-or$lo.Contains('nie podziel'))-and$lo.Contains('enter')){$setup=$firstXp}
    elseif(($lo.Contains('zapraszamy')-or$lo.Contains('welcome'))-and$lo.Contains('windows xp')-and$lo.Contains('enter')){Send-Hmp $monitor 'sendkey ret'}
    elseif(($lo.Contains('f8')-or$lo.Contains('f 8'))-and($lo.Contains('licen')-or$lo.Contains('umow'))){Send-Hmp $monitor 'sendkey f8'}

    $d2=[DateTime]::UtcNow.AddSeconds(45)
    $k=0
    while(-not$setup-and[DateTime]::UtcNow-lt$d2-and-not$p.HasExited){
        Start-Sleep -Milliseconds 700
        try{$s=Capture $monitor $out ("setup-{0:D2}" -f $k)}catch{$k++;continue}
        $k++
        $lo=$s.ToLowerInvariant()
        if(($lo.Contains('partycj')-or$lo.Contains('unpartitioned')-or$lo.Contains('nie podziel'))-and$lo.Contains('enter')){$setup=$s;break}
        if(($lo.Contains('zapraszamy')-or$lo.Contains('welcome'))-and$lo.Contains('windows xp')-and$lo.Contains('enter')){Send-Hmp $monitor 'sendkey ret';continue}
        if(($lo.Contains('f8')-or$lo.Contains('f 8'))-and($lo.Contains('licen')-or$lo.Contains('umow'))){Send-Hmp $monitor 'sendkey f8';continue}
    }
    if(-not$setup){throw 'gate 2 did not reach XP Text Mode partition screen'}
    Write-Host '--- GATE 2 POST-JUMP VGA ---';Write-Host $setup

    $passFile=Join-Path $out 'gate2.pass'
    Set-Content -LiteralPath $passFile -Encoding ASCII -Value @(
        'gate=2',
        'loader=USOS-EDD-LBA',
        'bios_geometry=1023/240/63',
        'bpb_geometry=255/63',
        'chs_bpb_same=NO',
        'crc_ram=4D42CE43',
        'crc_expect=4D42CE43',
        'crc_same=YES',
        'no_key_until_windows_xp=yes',
        'xp_textmode=yes'
    )
    Write-Host '[PASS] GATE 2: same 240/255 mismatch fixture, EDD/LBA loader loads exact NTLDR and reaches XP Text Mode.' -ForegroundColor Green
    Write-Host "PASS_FILE=$passFile"
    $pass=$true
} finally {
    if(-not$p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;$p.WaitForExit(3000)|Out-Null}
}
if(-not$pass){exit 1}
