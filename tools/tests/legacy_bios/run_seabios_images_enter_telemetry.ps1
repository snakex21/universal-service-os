param([int]$TimeoutSeconds = 30)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Get-FreeTcpPort { $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $l.Start(); try { ([Net.IPEndPoint]$l.LocalEndpoint).Port } finally { $l.Stop() } }
function Read-SharedText([string]$Path) { if(-not(Test-Path -LiteralPath $Path)){return ''}; $s=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite); try {$r=[IO.StreamReader]::new($s); try{$r.ReadToEnd()}finally{$r.Dispose()}}finally{$s.Dispose()} }
function Wait-Text([string]$Path,[string]$Needle,[Diagnostics.Process]$Process,[int]$Seconds) { $d=[DateTime]::UtcNow.AddSeconds($Seconds); while([DateTime]::UtcNow -lt $d -and -not $Process.HasExited){$t=Read-SharedText $Path;if($t.Contains($Needle)){return $true};Start-Sleep -Milliseconds 100;$Process.Refresh()};return $false }
function Send-Hmp([int]$Port,[string]$Command) { $c=[Net.Sockets.TcpClient]::new();$c.Connect('127.0.0.1',$Port);try{$s=$c.GetStream();$w=[IO.StreamWriter]::new($s);$w.AutoFlush=$true;$w.WriteLine($Command);Start-Sleep -Milliseconds 250}finally{$c.Dispose()} }

$prepare=Full 'tools/tests/legacy_bios/prepare_ntfs_catalog_boot_fixture.ps1'
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$out=Full 'zig-out/legacy-bios/ntfs-catalog-boot'
$image=Join-Path $out 'ntfs-catalog.qcow2'
$serial=Join-Path $out 'images-enter.serial.log'
$stderr=Join-Path $out 'images-enter.stderr.log'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $prepare
if($LASTEXITCODE -ne 0){throw "fixture failed: $LASTEXITCODE"}
Remove-Item -LiteralPath $serial,$stderr -Force -ErrorAction SilentlyContinue
$monitor=Get-FreeTcpPort
$args=@('-name','USOS-Legacy-Images-Enter','-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','128M','-smp','1','-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','cirrus','-nic','none','-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial',"file:$($serial.Replace('\','/'))",'-drive',"if=ide,format=qcow2,file=$($image.Replace('\','/'))",'-no-reboot')
$p=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
try {
  if(-not(Wait-Text $serial 'CATEGORIES' $p $TimeoutSeconds)){throw "no categories`n$(Read-SharedText $serial)"}
  Send-Hmp $monitor 'sendkey ret'
  if(-not(Wait-Text $serial 'CATEGORY: Windows' $p $TimeoutSeconds)){throw "no Windows menu`n$(Read-SharedText $serial)"}
  Send-Hmp $monitor 'sendkey ret'
  if(-not(Wait-Text $serial 'IMAGES: Windows 11' $p $TimeoutSeconds)){throw "no images screen`n$(Read-SharedText $serial)"}
  Send-Hmp $monitor 'sendkey ret'
  Start-Sleep -Milliseconds 250
  Send-Hmp $monitor 'sendkey d'
  if(-not(Wait-Text $serial 'USOS LEGACY BIOS DIAGNOSTICS' $p $TimeoutSeconds)){throw "no diagnostics`n$(Read-SharedText $serial)"}
  Start-Sleep -Milliseconds 250
  $text=Read-SharedText $serial
  if($text -notmatch 'LAST ENTER: screen=IMAGES index=0 count=[0-9]+ event=ENTER'){throw "missing Enter-on-IMAGES telemetry`n$text"}
  Write-Host '[PASS] Enter on IMAGES reaches Legacy input handling and survives D as LAST ENTER.' -ForegroundColor Green
} finally { if(-not $p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue} }
