param(
    [Parameter(Mandatory=$true)][string]$SourceTargetRaw,
    [int]$XpSetupSlot = 2
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path){[IO.Path]::GetFullPath((Join-Path $root $Path))}
function Get-FreeTcpPort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
    try{return ([Net.IPEndPoint]$listener.LocalEndpoint).Port}finally{$listener.Stop()}
}
function Send-Hmp([int]$Port,[string]$Command){
    $client=[Net.Sockets.TcpClient]::new();$client.Connect('127.0.0.1',$Port)
    try{$stream=$client.GetStream();Start-Sleep -Milliseconds 50;$bytes=[Text.Encoding]::ASCII.GetBytes($Command+"`n");$stream.Write($bytes,0,$bytes.Length);$stream.Flush();Start-Sleep -Milliseconds 80}finally{$client.Dispose()}
}
function Get-BluePixelCount([string]$Ppm){
    $bytes=[IO.File]::ReadAllBytes($Ppm)
    $newlines=0;$start=-1
    for($i=0;$i -lt $bytes.Length;$i++){
        if($bytes[$i] -eq 10){$newlines++;if($newlines -eq 3){$start=$i+1;break}}
    }
    if($start -lt 0){throw "invalid PPM header: $Ppm"}
    $count=0
    for($i=$start;$i+2 -lt $bytes.Length;$i+=3){if($bytes[$i]-eq 0 -and $bytes[$i+1]-eq 0 -and $bytes[$i+2]-eq 168){$count++}}
    return $count
}

$source=[IO.Path]::GetFullPath($SourceTargetRaw)
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "prepared XP target missing: $source"}
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$helper=Full 'tools/tests/legacy_bios/prepare_xp_target_only_fixture.py'
$bootsect="$env:SystemRoot\System32\bootsect.exe"
$python=(Get-Command python.exe -ErrorAction Stop).Source
$tag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=Full ("zig-out/legacy-bios/xp-msnt52-control-$tag")
New-Item -ItemType Directory -Force -Path $out|Out-Null
$target=Join-Path $out 'target.raw'

& $qemuImg convert -f raw -O raw -S 4k $source $target
if($LASTEXITCODE-ne 0){throw "sparse clone failed: $LASTEXITCODE"}
& $python $helper --target-raw $target --bootsect-exe $bootsect --vbr-code (Full 'zig-out/xp-bios/xp-vbr-code.bin') --stage2 (Full 'zig-out/xp-bios/xp-stage2.bin') --xpsetup-slot $XpSetupSlot --microsoft-nt52-loader
if($LASTEXITCODE-ne 0){throw "Microsoft NT52 fixture preparation failed: $LASTEXITCODE"}

$monitor=Get-FreeTcpPort
$args=@(
    '-name','XP-MSNT52-Control','-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none',
    '-drive',"if=ide,index=0,format=raw,file=$($target.Replace('\','/')),media=disk"
)
$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru
$green=$false
try{
    $bestBlue=0;$bestShot=''
    for($i=0;$i-lt 15 -and -not $process.HasExited;$i++){
        Start-Sleep -Seconds 1
        $shot=Join-Path $out ("screen-{0:D2}.ppm" -f $i)
        Send-Hmp $monitor "screendump `"$($shot.Replace('\','/'))`""
        if(Test-Path -LiteralPath $shot){
            $blue=Get-BluePixelCount $shot
            if($blue -gt $bestBlue){$bestBlue=$blue;$bestShot=$shot}
            Write-Host ("[SCREEN {0:D2}] blue_pixels={1}" -f $i,$blue)
            if($blue -gt 200000){$green=$true;break}
        }
    }
    if($green){
        Set-Content -LiteralPath (Join-Path $out 'msnt52.pass') -Value "blue_pixels=$bestBlue`nscreenshot=$bestShot" -Encoding ASCII
        Write-Host "[PASS] Microsoft NT52 loader reached Windows XP blue Setup screen: $bestShot" -ForegroundColor Green
    }else{
        throw "Microsoft NT52 loader did not reach blue Setup; best_blue_pixels=$bestBlue screenshot=$bestShot output=$out"
    }
}finally{
    if(-not $process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;$process.WaitForExit(3000)|Out-Null}
    if($green -and (Test-Path -LiteralPath $target)){Remove-Item -LiteralPath $target -Force;Write-Host '[CLEAN] target.raw'}
}
