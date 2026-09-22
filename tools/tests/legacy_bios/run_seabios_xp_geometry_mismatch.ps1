param(
    [Parameter(Mandatory=$true)][string]$SourceTargetRaw,
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path){ if([IO.Path]::IsPathRooted($Path)){return [IO.Path]::GetFullPath($Path)}; return [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Get-FreeTcpPort { $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()} }
function Send-Hmp([int]$Port,[string]$Command){$c=[Net.Sockets.TcpClient]::new();$c.Connect('127.0.0.1',$Port);try{$s=$c.GetStream();Start-Sleep -Milliseconds 40;$b=[Text.Encoding]::ASCII.GetBytes($Command+"`n");$s.Write($b,0,$b.Length);$s.Flush();Start-Sleep -Milliseconds 80}finally{$c.Dispose()}}
function Read-Vga([string]$Path){$b=[IO.File]::ReadAllBytes($Path);$sb=[Text.StringBuilder]::new();for($r=0;$r-lt25;$r++){for($c=0;$c-lt80;$c++){$i=(($r*80)+$c)*2;$x=$b[$i];if($x-ge32-and$x-le126){[void]$sb.Append([char]$x)}else{[void]$sb.Append(' ')}};[void]$sb.Append("`n")};return $sb.ToString()}
function Capture([int]$Port,[string]$Dir,[string]$Name){$bin=Join-Path $Dir "$Name.bin";Send-Hmp $Port "pmemsave 0xb8000 4000 `"$($bin.Replace('\','/'))`"";$d=[DateTime]::UtcNow.AddSeconds(2);while((-not(Test-Path $bin))-and[DateTime]::UtcNow-lt$d){Start-Sleep -Milliseconds 80};if(-not(Test-Path $bin)){throw "missing VGA dump $Name"};return (Read-Vga $bin)}
function Extract-Line([string]$Text,[string]$Prefix){foreach($line in ($Text -split "`n")){if($line.TrimStart().StartsWith($Prefix,[StringComparison]::Ordinal)){return $line.Trim()}};return $null}

$source=Full $SourceTargetRaw
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "source target missing: $source"}
if((Get-Item -LiteralPath $source).Length-ne120034123776){throw 'mismatch fixture requires exact physical target size 120034123776'}
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$builder=Full 'tools/build_xp_boot_diagnostic.ps1'
$patcher=Full 'tools/tests/legacy_bios/prepare_xp_boot_diagnostic_fixture.py'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if($LASTEXITCODE-ne0){throw "diagnostic build failed: $LASTEXITCODE"}

$tag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=Full ("zig-out/legacy-bios/xp-geometry-mismatch-$tag")
New-Item -ItemType Directory -Force -Path $out|Out-Null
$raw=Join-Path $out 'target-instrumented.raw'
& $qemuImg convert -f raw -O raw -S 4k $source $raw
if($LASTEXITCODE-ne0){throw "sparse clone failed: $LASTEXITCODE"}
& $python $patcher --target-raw $raw --diag-mbr (Full 'zig-out/xp-boot-diagnostic/diag-mbr-440.bin') --diag-prelude (Full 'zig-out/xp-boot-diagnostic/diag-prelude-mismatch-lba1-8.bin') --diag-vbr-helper (Full 'zig-out/xp-boot-diagnostic/diag-vbr-helper.bin') --diag-stage2-helper (Full 'zig-out/xp-boot-diagnostic/diag-stage2-helper.bin') --diag-runtime (Full 'zig-out/xp-boot-diagnostic/diag-runtime-512.bin') --nt52-vbr-tail (Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin') --nt52-stage2 (Full 'zig-out/xp-bios/xp-nt52-stage2.bin') --xpsetup-slot 1
if($LASTEXITCODE-ne0){throw "diagnostic fixture patch failed: $LASTEXITCODE"}

$monitor=Get-FreeTcpPort
$stderr=Join-Path $out 'stderr.log'
$rawQ=$raw.Replace('\','/')
$args=@(
    '-name','USOS-XP-Geometry-Mismatch',
    '-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none',
    '-drive',"if=ide,index=0,format=raw,file=$rawQ,media=disk,snapshot=on"
)
$p=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$pass=$false
try{
    Start-Sleep -Seconds 3
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $screen=$null
    $i=0
    while([DateTime]::UtcNow-lt$deadline-and-not$p.HasExited){
        try{$t=Capture $monitor $out ("mismatch-{0:D2}"-f$i)}catch{$i++;Start-Sleep -Milliseconds 200;continue}
        $i++
        if($t.Contains('J DL=80') -and $t.Contains('CRC RAM=')){$screen=$t;break}
        Start-Sleep -Milliseconds 250
    }
    if(-not$screen){
        $err=if(Test-Path $stderr){Get-Content -Raw $stderr}else{''}
        throw "mismatch diagnostic did not reach J/CRC. QEMU stderr: $err"
    }
    Write-Host '--- GEOMETRY MISMATCH VGA ---';Write-Host $screen

    $g=Extract-Line $screen 'G Cmax='
    $b=Extract-Line $screen 'B BPB H='
    $crc=Extract-Line $screen 'CRC RAM='
    if(-not$g-or-not$b-or-not$crc){throw 'missing G/B/CRC evidence'}
    if($g-notmatch 'H=240\s+S=63'){throw "fixture did not expose AH=08 H=240/S=63: $g"}
    if($b-notmatch 'H=255\s+S=63'){throw "fixture did not preserve BPB H=255/S=63: $b"}

    $lines=$screen -split "`n"
    $idx=-1
    for($n=0;$n-lt$lines.Length;$n++){if($lines[$n].Trim()-eq'LBA1123648'){$idx=$n;break}}
    if($idx-lt0-or$idx+3-ge$lines.Length){throw 'missing LBA1123648 triple-read block'}
    $edd=$lines[$idx+1].Trim();$ah08=$lines[$idx+2].Trim();$bpb=$lines[$idx+3].Trim()
    if($edd-ne'EDD=OK'){throw "expected EDD=OK, got: $edd"}
    if($ah08-notmatch '^AH08 C=74 H=75 S=44 IO=OK SAME=YES$'){throw "AH08 path did not reproduce MS-7100 mapping: $ah08"}
    if($bpb-notmatch '^BPB\s+C=69 H=240 S=44 IO=OK SAME=NO$'){throw "BPB CHS path did not reproduce MS-7100 mismatch: $bpb"}
    if($crc-notmatch '^CRC RAM=([0-9A-F]{8}) EXPECT=4D42CE43 SAME=NO$'){throw "expected bad NTLDR CRC, got: $crc"}
    $actualCrc=$Matches[1]

    $passText=@(
        'gate=1',
        'old_loader=Microsoft-NT52',
        'bios_ah08_heads=240',
        'bpb_heads=255',
        'lba1123648_edd=OK',
        'lba1123648_ah08=74/75/44 SAME=YES',
        'lba1123648_bpb=69/240/44 SAME=NO',
        "crc_ram=$actualCrc",
        'crc_expect=4D42CE43',
        'crc_same=NO',
        'fixture_reproduces_physical_failure=yes'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $out 'gate1.pass') -Encoding ASCII -Value $passText
    Write-Host "[PASS] GATE 1: old Microsoft NT52 reproduces MS-7100 geometry mismatch and corrupt NTLDR load. CRC_RAM=$actualCrc EXPECT=4D42CE43." -ForegroundColor Green
    Write-Host "OUTPUT=$out"
    $pass=$true
} finally {
    if(-not$p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;$p.WaitForExit(3000)|Out-Null}
}
if(-not$pass){exit 1}
