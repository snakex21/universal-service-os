param(
    [int]$TimeoutSeconds = 30
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
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try { $reader=[IO.StreamReader]::new($stream); try { return $reader.ReadToEnd() } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}
function Send-Hmp([int]$Port,[string]$Command) {
    $client=[Net.Sockets.TcpClient]::new(); $client.Connect('127.0.0.1',$Port)
    try { $stream=$client.GetStream(); $writer=[IO.StreamWriter]::new($stream); $writer.AutoFlush=$true; $writer.WriteLine($Command); Start-Sleep -Milliseconds 250 } finally { $client.Dispose() }
}
function Wait-Text([string]$Path,[string]$Needle,[Diagnostics.Process]$Process,[int]$Seconds) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    while([DateTime]::UtcNow -lt $deadline -and -not $Process.HasExited) {
        $text=Read-SharedText $Path
        if($text.Contains($Needle)){ return $true }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
    }
    return $false
}

$prepare = Full 'tools/tests/legacy_bios/prepare_ntfs_catalog_boot_fixture.ps1'
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$out = Full 'zig-out/legacy-bios/ntfs-catalog-boot'
$image = Join-Path $out 'ntfs-catalog.qcow2'
$serial = Join-Path $out 'seabios.serial.log'
$stderr = Join-Path $out 'seabios.stderr.log'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $prepare
if($LASTEXITCODE -ne 0){ throw "NTFS catalog fixture preparation failed: $LASTEXITCODE" }
Remove-Item -LiteralPath $serial,$stderr -Force -ErrorAction SilentlyContinue

$monitor=Get-FreeTcpPort
$args=@(
    '-name','USOS-Legacy-NTFS-Catalog','-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','128M','-smp','1',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','cirrus','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=ide,format=qcow2,file=$($image.Replace('\','/'))",'-no-reboot'
)
$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
try {
    if(-not (Wait-Text $serial 'CATEGORIES' $process $TimeoutSeconds)){
        throw "SeaBIOS did not reach CATEGORIES.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)"
    }
    $startup=Read-SharedText $serial
    if(-not $startup.Contains('NTFS DATA OK MFT_RUNS=')){ throw "Legacy Core did not mount NTFS DATA.`n$startup" }
    if($startup.Contains('USING ESP CATALOG FALLBACK')){ throw "Legacy Core unexpectedly used ESP catalog fallback.`n$startup" }

    $categoriesPos=$startup.IndexOf('CATEGORIES')
    if($categoriesPos -lt 0){ throw "Legacy Core did not log CATEGORIES after NTFS/VBE probes.`n$startup" }
    $beforeCategories=$startup.Substring(0,$categoriesPos)
    $hashLabels=@('INDEX PRE-VBE single','INDEX PRE-VBE bulk','INDEX POST-VBE single','INDEX POST-VBE bulk')
    $hashValues=@{}
    foreach($label in $hashLabels){
        $match=[regex]::Match($beforeCategories,[regex]::Escape($label)+': FNV32=0x([0-9A-Fa-f]{8})')
        if(-not $match.Success){ throw "Missing startup hash '$label' before CATEGORIES.`n$startup" }
        $hashValues[$label]=$match.Groups[1].Value.ToUpperInvariant()
    }
    $uniqueHashes=@($hashValues.Values | Select-Object -Unique)
    if($uniqueHashes.Count -ne 1){
        throw "PRE/POST or single/bulk NTFS index hashes differ in SeaBIOS: $($hashValues | Out-String)`n$startup"
    }
    Write-Host "[PASS] SeaBIOS index cluster hashes PRE/POST + single/bulk are identical FNV32=0x$($uniqueHashes[0])" -ForegroundColor Green

    Send-Hmp $monitor 'sendkey ret'
    if(-not (Wait-Text $serial 'CATEGORY: Windows' $process $TimeoutSeconds)){
        throw "SeaBIOS did not enter Windows menu.`n$(Read-SharedText $serial)"
    }
    Start-Sleep -Milliseconds 500
    $menu=Read-SharedText $serial
    if($menu -notmatch 'Windows XP \[images=1\]'){
        throw "Windows XP did not report images=1 from NTFS DATA.`n$menu"
    }
    if($menu -notmatch 'Windows 11 \[images=1\]'){
        throw "Windows 11 did not report images=1 from NTFS DATA.`n$menu"
    }
    Send-Hmp $monitor 'sendkey d'
    if(-not (Wait-Text $serial 'USOS LEGACY BIOS DIAGNOSTICS' $process $TimeoutSeconds)){
        throw "Legacy diagnostics did not open.`n$(Read-SharedText $serial)"
    }
    Start-Sleep -Milliseconds 300
    $diag=Read-SharedText $serial
    foreach($needle in @('DATA GPT: FOUND','DATA VBR READ: PASS OEM_NTFS=yes SIG_55AA=yes','NTFS BPB: bytes_per_sector=512 sectors_per_cluster=8 MFT_LCN=','NTFS MOUNT: PASS MFT_RUNS=','DATA \Systems: PASS','NTFS LAST ERROR:')){
        if(-not $diag.Contains($needle)){ throw "Legacy diagnostics missing '$needle'.`n$diag" }
    }
    Write-Host '[PASS] Legacy Core mounted USOS_DATA through read-only NTFS.' -ForegroundColor Green
    Write-Host '[PASS] ESP XP Images was empty; Windows XP still reports [images=1] from DATA.' -ForegroundColor Green
    Write-Host '[PASS] Windows 11 also reports [images=1] through the same NTFS discovery path.' -ForegroundColor Green
    Write-Host '[PASS] D diagnostics expose DATA GPT/VBR/BPB/MFT/Systems state and parser error slot.' -ForegroundColor Green
} finally {
    if(-not $process.HasExited){ Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
