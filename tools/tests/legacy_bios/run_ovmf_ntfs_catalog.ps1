param(
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try { $reader=[IO.StreamReader]::new($stream); try { return $reader.ReadToEnd() } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}

$prepare = Full 'tools/tests/legacy_bios/prepare_ntfs_catalog_boot_fixture.ps1'
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$ovmfCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$ovmfVarsSource = Full 'tools/qemu/share/edk2-i386-vars.fd'
$out = Full 'zig-out/legacy-bios/ntfs-catalog-boot'
$image = Join-Path $out 'ntfs-catalog.qcow2'
$vars = Join-Path $out 'ovmf-vars.fd'
$serial = Join-Path $out 'ovmf.serial.log'
$stderr = Join-Path $out 'ovmf.stderr.log'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $prepare
if($LASTEXITCODE -ne 0){ throw "NTFS catalog fixture preparation failed: $LASTEXITCODE" }
Copy-Item -LiteralPath $ovmfVarsSource -Destination $vars -Force
Remove-Item -LiteralPath $serial,$stderr -Force -ErrorAction SilentlyContinue

$args=@(
    '-name','USOS-UEFI-NTFS-Catalog','-machine','q35','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-display','none','-vga','std','-nic','none','-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=pflash,format=raw,readonly=on,file=$ovmfCode",
    '-drive',"if=pflash,format=raw,file=$vars",
    '-drive',"if=none,id=usos,format=qcow2,file=$($image.Replace('\','/'))",
    '-device','qemu-xhci,id=xhci',
    '-device','usb-storage,bus=xhci.0,drive=usos,removable=on,serial=USOS-NTFS-CATALOG,bootindex=1'
)
$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
try {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $pass=$false
    while([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited){
        Start-Sleep -Milliseconds 100
        $text=Read-SharedText $serial
        if($text.Contains('UEFI NTFS CATALOG PASS')){$pass=$true;break}
        if($text.Contains('FAIL')){break}
        $process.Refresh()
    }
    $text=Read-SharedText $serial
    if(-not $pass){ throw "UEFI direct NTFS catalog probe failed.`n$text`n$(Read-SharedText $stderr)" }
    foreach($marker in @('DATA BLOCKIO NTFS PASS','XP IMAGES=1','WIN11 IMAGES=1','UEFI NTFS CATALOG PASS')){
        if(-not $text.Contains($marker)){ throw "UEFI NTFS probe missing marker $marker`n$text" }
    }
    Write-Host '[PASS] UEFI reads USOS_DATA directly through BlockIo + the shared read-only NTFS parser; ntfs_x64.efi is not used for discovery.' -ForegroundColor Green
    Write-Host '[PASS] UEFI discovers XP and Windows 11 images with ESP image markers empty.' -ForegroundColor Green
} finally {
    if(-not $process.HasExited){ Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
