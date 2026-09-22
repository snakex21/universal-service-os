param(
    [string]$SourceTargetRaw = 'zig-out/legacy-bios/xp-diag-exact120-physical-mbr-base.raw'
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path){if([IO.Path]::IsPathRooted($Path)){return [IO.Path]::GetFullPath($Path)};return [IO.Path]::GetFullPath((Join-Path $root $Path))}
function Get-FreeTcpPort{$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()}}
function Send-Hmp([int]$Port,[string]$Command){$c=[Net.Sockets.TcpClient]::new();$c.Connect('127.0.0.1',$Port);try{$s=$c.GetStream();Start-Sleep -Milliseconds 50;$b=[Text.Encoding]::ASCII.GetBytes($Command+"`n");$s.Write($b,0,$b.Length);$s.Flush();Start-Sleep -Milliseconds 100}finally{$c.Dispose()}}
function Read-U32([byte[]]$b,[int]$o){[BitConverter]::ToUInt32($b,$o)}
function Read-U16([byte[]]$b,[int]$o){[BitConverter]::ToUInt16($b,$o)}
function Format-Regs([byte[]]$b){
    if((Read-U32 $b 0)-ne0x53474552){throw 'register capture magic missing'}
    return [ordered]@{
        EAX=('{0:X8}'-f(Read-U32 $b 4)); EBX=('{0:X8}'-f(Read-U32 $b 8)); ECX=('{0:X8}'-f(Read-U32 $b 12)); EDX=('{0:X8}'-f(Read-U32 $b 16));
        ESI=('{0:X8}'-f(Read-U32 $b 20)); EDI=('{0:X8}'-f(Read-U32 $b 24)); EBP=('{0:X8}'-f(Read-U32 $b 28)); SP=('{0:X4}'-f(Read-U16 $b 32));
        DS=('{0:X4}'-f(Read-U16 $b 34)); ES=('{0:X4}'-f(Read-U16 $b 36)); FS=('{0:X4}'-f(Read-U16 $b 38)); GS=('{0:X4}'-f(Read-U16 $b 40)); SS=('{0:X4}'-f(Read-U16 $b 42)); FLAGS=('{0:X4}'-f(Read-U16 $b 44))
    }
}
function Boot-Capture([string]$Raw,[string]$Name,[string]$Out){
    $qemu=Full 'tools/qemu/qemu-system-x86_64.exe';$seabios=Full 'tools/qemu/share/bios-256k.bin';$port=Get-FreeTcpPort
    $stderr=Join-Path $Out "$Name-stderr.log";$serial=Join-Path $Out "$Name-serial.log"
    $args=@('-name',$Name,'-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2','-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none','-monitor',"tcp:127.0.0.1:$port,server=on,wait=off",'-serial',"file:$($serial.Replace('\','/'))",'-drive',"if=ide,index=0,format=raw,file=$($Raw.Replace('\','/')),media=disk,snapshot=on")
    $p=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
    try{
        Start-Sleep -Seconds 3;$deadline=[DateTime]::UtcNow.AddSeconds(30);$n=0
        while([DateTime]::UtcNow-lt$deadline-and-not$p.HasExited){
            $cap=Join-Path $Out ("$Name-regs-{0:D2}.bin"-f$n);$n++
            try{Send-Hmp $port "pmemsave 0x1000 46 `"$($cap.Replace('\','/'))`""}catch{Start-Sleep -Milliseconds 100;continue}
            if(Test-Path $cap){$b=[IO.File]::ReadAllBytes($cap);if($b.Length-ge46-and(Read-U32 $b 0)-eq0x53474552){$serialText='';if(Test-Path $serial){$serialText=Get-Content -Raw $serial};return [pscustomobject]@{Regs=(Format-Regs $b);Serial=$serialText}}}
            Start-Sleep -Milliseconds 150
        }
        throw "$Name did not reach register-capture halt"
    }finally{if(-not$p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;$p.WaitForExit(3000)|Out-Null}}
}

$source=Full $SourceTargetRaw;if((Get-Item $source).Length-ne120034123776){throw 'exact target size required'}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/build_xp_boot_diagnostic.ps1');if($LASTEXITCODE-ne0){throw 'diagnostic build failed'}
$qemuImg=Full 'tools/qemu/qemu-img.exe';$python=(Get-Command python.exe -ErrorAction Stop).Source
$tag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff');$out=Full("zig-out/legacy-bios/xp-handoff-regs-$tag");New-Item -ItemType Directory -Force -Path $out|Out-Null

$ms=Join-Path $out 'microsoft.raw';& $qemuImg convert -f raw -O raw -S 4k $source $ms;if($LASTEXITCODE-ne0){throw 'ms clone failed'}
& $python (Full 'tools/tests/legacy_bios/prepare_xp_boot_diagnostic_fixture.py') --target-raw $ms --diag-mbr (Full 'zig-out/xp-boot-diagnostic/diag-mbr-440.bin') --diag-prelude (Full 'zig-out/xp-boot-diagnostic/diag-prelude-lba1-8.bin') --diag-vbr-helper (Full 'zig-out/xp-boot-diagnostic/diag-vbr-helper.bin') --diag-stage2-helper (Full 'zig-out/xp-boot-diagnostic/diag-stage2-regs-helper.bin') --diag-runtime (Full 'zig-out/xp-boot-diagnostic/diag-runtime-512.bin') --nt52-vbr-tail (Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin') --nt52-stage2 (Full 'zig-out/xp-bios/xp-nt52-stage2.bin') --xpsetup-slot 1;if($LASTEXITCODE-ne0){throw 'ms fixture failed'}
$msCap=Boot-Capture $ms 'Microsoft-NT52' $out

$edd=Join-Path $out 'edd.raw';& $qemuImg convert -f raw -O raw -S 4k $source $edd;if($LASTEXITCODE-ne0){throw 'edd clone failed'}
& $python (Full 'tools/tests/legacy_bios/prepare_xp_boot_diagnostic_fixture.py') --target-raw $edd --diag-mbr (Full 'zig-out/xp-boot-diagnostic/diag-mbr-440.bin') --diag-prelude (Full 'zig-out/xp-boot-diagnostic/diag-prelude-lba1-8.bin') --diag-vbr-helper (Full 'zig-out/xp-boot-diagnostic/diag-vbr-helper.bin') --diag-stage2-helper (Full 'zig-out/xp-boot-diagnostic/diag-stage2-helper.bin') --diag-runtime (Full 'zig-out/xp-boot-diagnostic/diag-runtime-512.bin') --nt52-vbr-tail (Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin') --nt52-stage2 (Full 'zig-out/xp-bios/xp-nt52-stage2.bin') --xpsetup-slot 1;if($LASTEXITCODE-ne0){throw 'edd diagnostic base failed'}
& $python (Full 'tools/tests/legacy_bios/install_xp_edd_loader_fixture.py') --target-raw $edd --vbr-code (Full 'zig-out/xp-bios/xp-vbr-code.bin') --stage2 (Full 'zig-out/xp-bios/xp-stage2-regs.bin') --xpsetup-slot 1;if($LASTEXITCODE-ne0){throw 'edd fixture failed'}
$eddCap=Boot-Capture $edd 'USOS-EDD' $out

Write-Host '--- MICROSOFT NT52 PRE-JUMP ---';$msCap.Regs.GetEnumerator()|ForEach-Object{Write-Host ("{0}={1}"-f$_.Key,$_.Value)}
Write-Host '--- USOS EDD PRE-HANDOFF ---';$eddCap.Regs.GetEnumerator()|ForEach-Object{Write-Host ("{0}={1}"-f$_.Key,$_.Value)}
Write-Host '--- USOS EDD SERIAL ---';Write-Host $eddCap.Serial
Write-Host "OUTPUT=$out"
