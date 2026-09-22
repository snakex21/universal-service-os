param(
    [string]$SourceTargetRaw = 'zig-out/legacy-bios/xp-diag-exact120-physical-mbr-base.raw',
    [int]$TimeoutSeconds = 30
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
if((Get-Item -LiteralPath $source).Length-ne120034123776){throw 'mismatch fixture requires exact 120034123776-byte target'}
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$builder=Full 'tools/build_xp_boot_diagnostic.ps1'
$patcher=Full 'tools/tests/legacy_bios/prepare_xp_boot_diagnostic_fixture.py'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if($LASTEXITCODE-ne0){throw "diagnostic build failed: $LASTEXITCODE"}

$tag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=Full ("zig-out/legacy-bios/xp-geometry-mismatch-nt52-$tag")
New-Item -ItemType Directory -Force -Path $out|Out-Null
$raw=Join-Path $out 'target-instrumented.raw'
& $qemuImg convert -f raw -O raw -S 4k $source $raw
if($LASTEXITCODE-ne0){throw "sparse clone failed: $LASTEXITCODE"}
& $python $patcher --target-raw $raw --diag-mbr (Full 'zig-out/xp-boot-diagnostic/diag-mbr-440.bin') --diag-prelude (Full 'zig-out/xp-boot-diagnostic/diag-prelude-mismatch-lba1-8.bin') --diag-vbr-helper (Full 'zig-out/xp-boot-diagnostic/diag-vbr-helper.bin') --diag-stage2-helper (Full 'zig-out/xp-boot-diagnostic/diag-stage2-helper.bin') --diag-runtime (Full 'zig-out/xp-boot-diagnostic/diag-runtime-512.bin') --nt52-vbr-tail (Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin') --nt52-stage2 (Full 'zig-out/xp-bios/xp-nt52-stage2.bin') --xpsetup-slot 1
if($LASTEXITCODE-ne0){throw "diagnostic fixture patch failed: $LASTEXITCODE"}

$monitor=Get-FreeTcpPort
$stderr=Join-Path $out 'stderr.log'
$driveArg="if=ide,index=0,format=raw,file=$($raw.Replace('\','/')),media=disk,snapshot=on"
$args=@('-name','USOS-XP-Geometry-Mismatch-NT52','-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2','-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none','-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none','-drive',$driveArg)
$p=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$pass=$false
try {
    Start-Sleep -Seconds 3
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $text=$null
    $i=0
    while([DateTime]::UtcNow-lt$deadline-and-not$p.HasExited){
        try{$s=Capture $monitor $out ("probe-{0:D2}" -f $i)}catch{$i++;continue}
        $i++
        if($s.Contains('CRC RAM=')){$text=$s;break}
        Start-Sleep -Milliseconds 150
    }
    if(-not$text){
        $err=if(Test-Path $stderr){Get-Content -Raw $stderr}else{''}
        throw "mismatch fixture did not reach CRC evidence. stderr=$err"
    }
    Write-Host '--- GEOMETRY MISMATCH VGA ---'
    Write-Host $text

    $required=@(
        'G Cmax=1022 H=240 S=63',
        'B BPB H=255 S=63',
        'LBA1123648',
        ' EDD=OK',
        ' AH08 C=74 H=75 S=44 IO=OK SAME=YES',
        ' BPB  C=69 H=240 S=44 IO=OK SAME=NO',
        'CRC RAM=C8D2C92B EXPECT=4D42CE43 SAME=NO'
    )
    foreach($needle in $required){if(-not$text.Contains($needle)){throw "gate 1 mismatch fixture FAILED to reproduce MS-7100 evidence: missing [$needle]"}}

    $passFile=Join-Path $out 'gate1.pass'
    Set-Content -LiteralPath $passFile -Encoding ASCII -Value @(
        'gate=1',
        'loader=Microsoft-NT52',
        'bios_geometry=1023/240/63',
        'bpb_geometry=255/63',
        'lba1123648_edd=OK',
        'lba1123648_chs_ah08_same=YES',
        'lba1123648_chs_bpb_same=NO',
        'crc_ram=C8D2C92B',
        'crc_expect=4D42CE43',
        'crc_same=NO',
        'physical_failure_reproduced=yes'
    )
    Write-Host '[PASS] GATE 1: forced 240/63 BIOS with BPB 255/63 reproduces the physical MS-7100 NT52 corruption exactly.' -ForegroundColor Green
    Write-Host "PASS_FILE=$passFile"
    $pass=$true
} finally {
    if(-not$p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;$p.WaitForExit(3000)|Out-Null}
}
if(-not$pass){exit 1}
