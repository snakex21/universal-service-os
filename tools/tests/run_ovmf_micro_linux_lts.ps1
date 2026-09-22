param(
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try { $reader=[IO.StreamReader]::new($stream); try { return $reader.ReadToEnd() } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}

$prepare = Full 'tools/tests/legacy_bios/prepare_fat32_fixture.ps1'
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$ovmfCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$ovmfVarsSource = Full 'tools/qemu/share/edk2-i386-vars.fd'
$loader = Full 'zig-out/micro-linux/systemd-bootx64.efi'
$out = Full 'zig-out/uefi-lts-smoke'
$fixtureDir = Join-Path $out 'fixture'
$vhd = Join-Path $fixtureDir 'formatted-fat32.vhd'
$image = Join-Path $out 'uefi-lts.qcow2'
$vars = Join-Path $out 'ovmf-vars.fd'
$serial = Join-Path $out 'serial.log'
$stderr = Join-Path $out 'stderr.log'

foreach($required in @($prepare,$qemu,$qemuImg,$ovmfCode,$ovmfVarsSource,$loader)){
    if(-not (Test-Path -LiteralPath $required -PathType Leaf)){ throw "Missing required UEFI LTS smoke input: $required" }
}
New-Item -ItemType Directory -Force -Path $out | Out-Null

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $prepare -OutputDirectory $fixtureDir -BootMicroLinux -OnlyValid
if($LASTEXITCODE -ne 0){ throw "FAT32 micro-Linux fixture preparation failed: $LASTEXITCODE" }

$mounted=$false
$mountRoot=Join-Path $out '.mount-esp'
Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
try {
    Mount-DiskImage -ImagePath $vhd -StorageType VHD -NoDriveLetter | Out-Null
    $mounted=$true
    Start-Sleep -Milliseconds 300
    $disk=Get-DiskImage -ImagePath $vhd | Get-Disk
    if($null -eq $disk){ throw 'Cannot resolve UEFI LTS fixture disk' }
    $esp=Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
    if(@($esp).Count -ne 1){ throw "Expected one ESP in UEFI LTS fixture, got $(@($esp).Count)" }
    New-Item -ItemType Directory -Force -Path $mountRoot | Out-Null
    $esp | Add-PartitionAccessPath -AccessPath $mountRoot | Out-Null
    $espGuid="$($esp.Guid)".Trim('{}')

    New-Item -ItemType Directory -Force -Path (Join-Path $mountRoot 'EFI\BOOT'),(Join-Path $mountRoot 'loader\entries') | Out-Null
    Copy-Item -LiteralPath $loader -Destination (Join-Path $mountRoot 'EFI\BOOT\BOOTX64.EFI') -Force
    [IO.File]::WriteAllText((Join-Path $mountRoot 'loader\loader.conf'), "default usos-lts.conf`r`ntimeout 0`r`neditor no`r`n", [Text.UTF8Encoding]::new($false))
    $entry=@(
        'title USOS Alpine LTS smoke',
        'linux /EFI/USOS/micro-linux/vmlinuz-virt',
        'initrd /EFI/USOS/micro-linux/initramfs-usos',
        "options console=tty0 console=ttyS0,115200 quiet loglevel=3 vt.global_cursor_default=0 rdinit=/usos-init usos.esp_partuuid=$espGuid"
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $mountRoot 'loader\entries\usos-lts.conf'), $entry + "`r`n", [Text.UTF8Encoding]::new($false))
    $esp | Remove-PartitionAccessPath -AccessPath $mountRoot -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    if($mounted){
        try {
            $disk=Get-DiskImage -ImagePath $vhd | Get-Disk
            Get-Partition -DiskNumber $disk.Number | ForEach-Object { $_ | Remove-PartitionAccessPath -AccessPath $mountRoot -ErrorAction SilentlyContinue | Out-Null }
        } catch {}
        Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $image,$serial,$stderr -Force -ErrorAction SilentlyContinue
& $qemuImg convert -f vpc -O qcow2 $vhd $image
if($LASTEXITCODE -ne 0){ throw "qemu-img VHD->qcow2 failed: $LASTEXITCODE" }
Copy-Item -LiteralPath $ovmfVarsSource -Destination $vars -Force

$args=@(
    '-name','USOS-UEFI-LTS-Smoke','-machine','q35','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-display','none','-vga','std','-nic','none','-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=pflash,format=raw,readonly=on,file=$ovmfCode",
    '-drive',"if=pflash,format=raw,file=$vars",
    '-drive',"if=none,id=usos,format=qcow2,file=$($image.Replace('\','/'))",
    '-device','qemu-xhci,id=xhci',
    '-device','usb-storage,bus=xhci.0,drive=usos,removable=on,serial=USOS-LTS-SMOKE,bootindex=1',
    '-no-reboot'
)
$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
try {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $pass=$false
    while([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited){
        Start-Sleep -Milliseconds 100
        $text=Read-SharedText $serial
        if($text.Contains('[MICRO-LINUX] boot PASS kernel=6.18.35-0-lts')){$pass=$true;break}
        $process.Refresh()
    }
    $text=Read-SharedText $serial
    if(-not $pass){ throw "OVMF did not boot the Alpine LTS micro-Linux.`n$text`n$(Read-SharedText $stderr)" }
    if(-not $text.Contains('[USOS-FB-UI] FIRST_FRAME')){ throw "OVMF LTS boot reached userspace but framebuffer first frame is missing.`n$text" }
    Write-Host '[PASS] OVMF -> systemd-boot -> Alpine LTS micro-Linux userspace.' -ForegroundColor Green
    Write-Host '[PASS] UEFI LTS framebuffer produced FIRST_FRAME.' -ForegroundColor Green
    Write-Host "SERIAL=$serial"
} finally {
    if(-not $process.HasExited){ Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
