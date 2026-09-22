param(
    [Parameter(Mandatory=$true)][string]$SourceTargetRaw,
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path){ if([IO.Path]::IsPathRooted($Path)){return [IO.Path]::GetFullPath($Path)}; return [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Get-FreeTcpPort { $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()} }
function Send-Hmp([int]$Port,[string]$Command){$c=[Net.Sockets.TcpClient]::new();$c.Connect('127.0.0.1',$Port);try{$s=$c.GetStream();Start-Sleep -Milliseconds 50;$b=[Text.Encoding]::ASCII.GetBytes($Command+"`n");$s.Write($b,0,$b.Length);$s.Flush();Start-Sleep -Milliseconds 100}finally{$c.Dispose()}}
function Read-Vga([string]$Path){$b=[IO.File]::ReadAllBytes($Path);$sb=[Text.StringBuilder]::new();for($r=0;$r-lt25;$r++){for($c=0;$c-lt80;$c++){$i=(($r*80)+$c)*2;$x=$b[$i];if($x-ge32-and$x-le126){[void]$sb.Append([char]$x)}else{[void]$sb.Append(' ')}};[void]$sb.Append("`n")};return $sb.ToString()}
function Capture([int]$Port,[string]$Dir,[string]$Name){$bin=Join-Path $Dir "$Name.bin";$ppm=Join-Path $Dir "$Name.ppm";Send-Hmp $Port "pmemsave 0xb8000 4000 `"$($bin.Replace('\','/'))`"";Send-Hmp $Port "screendump `"$($ppm.Replace('\','/'))`"";$d=[DateTime]::UtcNow.AddSeconds(3);while(((-not(Test-Path $bin))-or(-not(Test-Path $ppm)))-and[DateTime]::UtcNow-lt$d){Start-Sleep -Milliseconds 100};if(-not(Test-Path $bin)){throw "missing VGA dump $Name"};return [pscustomobject]@{Text=(Read-Vga $bin);Bin=$bin;Ppm=$ppm}}

$source=Full $SourceTargetRaw
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "source target missing: $source"}
$sourceInfo=Get-Item -LiteralPath $source
if($sourceInfo.Length-ne120034123776){throw "diagnostic exact-target gate requires 120034123776 bytes, got $($sourceInfo.Length)"}
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$builder=Full 'tools/build_xp_boot_diagnostic.ps1'
$patcher=Full 'tools/tests/legacy_bios/prepare_xp_boot_diagnostic_fixture.py'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if($LASTEXITCODE-ne0){throw "diagnostic build failed: $LASTEXITCODE"}

$tag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=Full ("zig-out/legacy-bios/xp-boot-diagnostic-$tag")
New-Item -ItemType Directory -Force -Path $out|Out-Null
$raw=Join-Path $out 'target-instrumented.raw'
& $qemuImg convert -f raw -O raw -S 4k $source $raw
if($LASTEXITCODE-ne0){throw "sparse clone failed: $LASTEXITCODE"}
& $python $patcher --target-raw $raw --diag-mbr (Full 'zig-out/xp-boot-diagnostic/diag-mbr-440.bin') --diag-prelude (Full 'zig-out/xp-boot-diagnostic/diag-prelude-lba1-8.bin') --diag-vbr-helper (Full 'zig-out/xp-boot-diagnostic/diag-vbr-helper.bin') --diag-stage2-helper (Full 'zig-out/xp-boot-diagnostic/diag-stage2-helper.bin') --diag-runtime (Full 'zig-out/xp-boot-diagnostic/diag-runtime-512.bin') --nt52-vbr-tail (Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin') --nt52-stage2 (Full 'zig-out/xp-bios/xp-nt52-stage2.bin') --xpsetup-slot 1
if($LASTEXITCODE-ne0){throw "diagnostic fixture patch failed: $LASTEXITCODE"}

$monitor=Get-FreeTcpPort
$stderr=Join-Path $out 'stderr.log'
$args=@('-name','USOS-XP-Boot-Diagnostic','-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2','-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none','-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none','-drive',"if=ide,index=0,format=raw,file=$($raw.Replace('\','/')),media=disk,snapshot=on")
$p=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$pass=$false
try{
    Start-Sleep -Seconds 3
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $before=$null
    $timerSeenAt=$null
    while([DateTime]::UtcNow-lt$deadline-and-not$p.HasExited){
        $s=Capture $monitor $out 'breadcrumbs-current'
        if($s.Text.Contains('J DL=80') -and $s.Text.Contains('CRC RAM=') -and $s.Text.Contains('SAME=YES') -and $s.Text.Contains('AUTO 5s BIOS TIMER...')){
            $before=$s
            $timerSeenAt=[DateTime]::UtcNow
            break
        }
        Start-Sleep -Milliseconds 150
    }
    if(-not$before){throw 'J/CRC/timer diagnostic evidence not reached'}
    Write-Host '--- BREADCRUMB VGA ---';Write-Host $before.Text
    $need=@('M DL=80','G Cmax=','B BPB H=','LBA2048',' EDD=OK',' AH08 C=',' BPB  C=','LBA2060','LBA1123648','V DL=80','2 DL=80','F DL=80','N DL=80','J DL=80','CRC RAM=',' EXPECT=',' SAME=YES','AUTO 5s BIOS TIMER...')
    $last=-1
    foreach($m in $need){$at=$before.Text.IndexOf($m,$last+1,[StringComparison]::Ordinal);if($at-lt0){throw "missing ordered diagnostic evidence: $m"};$last=$at}

    # Deliberately send NO keyboard event from J until Windows XP itself is
    # visible. This proves the transition does not depend on INT 16h/USB input.
    $firstXp=$null
    $continueMarkerSeen=$false
    $noKeyDeadline=[DateTime]::UtcNow.AddSeconds(25)
    $autoIndex=0
    while([DateTime]::UtcNow-lt$noKeyDeadline-and-not$p.HasExited){
        Start-Sleep -Milliseconds 250
        try { $auto=Capture $monitor $out ("auto-{0:D2}"-f$autoIndex) } catch { $autoIndex++; continue }
        $autoIndex++
        if($auto.Text.Contains('AUTO CONTINUE -> NTLDR')){$continueMarkerSeen=$true}
        $alo=$auto.Text.ToLowerInvariant()
        if((($alo.Contains('windows xp')-or$alo.Contains('instalator systemu windows')) -and ($alo.Contains('zapraszamy')-or$alo.Contains('welcome')-or$alo.Contains('f8')-or$alo.Contains('licen')-or$alo.Contains('partycj')-or$alo.Contains('unpartitioned')-or$alo.Contains('nie podziel')))){$firstXp=$auto;break}
    }
    if(-not$firstXp){throw 'no-key BIOS-timer auto-continue did not reach any Windows XP Setup screen'}
    $noKeyElapsed=([DateTime]::UtcNow-$timerSeenAt).TotalSeconds
    if($noKeyElapsed-lt4.0){throw ("Windows XP appeared too early for a 5 s BIOS timer: {0:N2}s" -f $noKeyElapsed)}
    Write-Host ("[PASS] J -> Windows XP required no key event; first XP screen after {0:N2}s; AUTO marker captured={1}" -f $noKeyElapsed,$continueMarkerSeen) -ForegroundColor Green

    $setup=$null
    $firstLower=$firstXp.Text.ToLowerInvariant()
    if(($firstLower.Contains('partycj')-or$firstLower.Contains('unpartitioned')-or$firstLower.Contains('nie podziel'))-and$firstLower.Contains('enter')){$setup=$firstXp}
    elseif(($firstLower.Contains('zapraszamy')-or$firstLower.Contains('welcome'))-and$firstLower.Contains('windows xp')-and$firstLower.Contains('enter')){Send-Hmp $monitor 'sendkey ret'}
    elseif(($firstLower.Contains('f8')-or$firstLower.Contains('f 8'))-and($firstLower.Contains('licen')-or$firstLower.Contains('umow'))){Send-Hmp $monitor 'sendkey f8'}

    $d2=[DateTime]::UtcNow.AddSeconds(45)
    $i=0
    while(-not$setup-and[DateTime]::UtcNow-lt$d2-and-not$p.HasExited){
        Start-Sleep -Milliseconds 750
        try { $s=Capture $monitor $out ("after-jump-{0:D2}"-f$i) } catch { $i++; Start-Sleep -Milliseconds 250; continue }
        $i++
        $lo=$s.Text.ToLowerInvariant()
        if(($lo.Contains('partycj')-or$lo.Contains('unpartitioned')-or$lo.Contains('nie podziel'))-and$lo.Contains('enter')){$setup=$s;break}
        if(($lo.Contains('zapraszamy')-or$lo.Contains('welcome'))-and$lo.Contains('windows xp')-and$lo.Contains('enter')){Send-Hmp $monitor 'sendkey ret';continue}
        if(($lo.Contains('f8')-or$lo.Contains('f 8'))-and($lo.Contains('licen')-or$lo.Contains('umow'))){Send-Hmp $monitor 'sendkey f8';continue}
    }
    if(-not$setup){throw 'breadcrumbs/CRC passed, but BIOS-timer auto-continue did not reach XP Setup'}
    Write-Host '--- POST-JUMP VGA ---';Write-Host $setup.Text
    Set-Content -LiteralPath (Join-Path $out 'diagnostic.pass') -Encoding ASCII -Value ("exact_target_bytes=120034123776`nbreadcrumbs=M,V,2,F,N,J`ndl=80`ntriple_reads=EDD,CHS-AH08,CHS-BPB`ncrc_ram_match=yes`nauto_continue_bios_timer=yes`nno_key_until_windows_xp=yes`nno_key_elapsed_seconds={0:N2}`nauto_continue_marker_seen={1}`npost_j_setup=yes" -f $noKeyElapsed,$continueMarkerSeen)
    Write-Host ("[PASS] XP boot diagnostic: triple EDD/AH08/BPB reads visible, RAM NTLDR CRC matches, BIOS-timer auto-continue reaches Windows XP with no key event ({0:N2}s to first XP screen), then Text Mode partition screen passes." -f $noKeyElapsed) -ForegroundColor Green
    Write-Host "OUTPUT=$out"
    $pass=$true
} finally {
    if(-not$p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;$p.WaitForExit(3000)|Out-Null}
}
if(-not$pass){exit 1}
