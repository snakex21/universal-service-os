param(
    [string]$IsoPath = 'test-images/xp-enum-dummy.iso',
    [ValidateSet('ide','ahci','none')][string]$TargetMode = 'ide',
    [switch]$AutoStorageProbe,
    [UInt64]$TargetBytes = 0,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}
function Get-FreeTcpPort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}
function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try { $reader=[IO.StreamReader]::new($stream); try { return $reader.ReadToEnd() } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}
function Wait-Any([string]$Path,[string[]]$Needles,[Diagnostics.Process]$Process,[DateTime]$Deadline) {
    while([DateTime]::UtcNow -lt $Deadline -and -not $Process.HasExited) {
        $text=Read-SharedText $Path
        foreach($needle in $Needles){ if($text.Contains($needle)){ return $needle } }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
    }
    return $null
}

$iso=Full $IsoPath
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$fixturePrep=Full 'tools/tests/legacy_bios/prepare_legacy_xp_menu_fixture.ps1'
$targetCreator=Full 'tools/tests/legacy_bios/create_xp_existing_target.ps1'
$runTag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=Full "zig-out/legacy-bios/xp-disk-enum-$TargetMode-$runTag"
$fixtureDir=Join-Path $out 'fixture'
$bootImage=Join-Path $fixtureDir 'xp-menu-usos.qcow2'
$targetRaw=Join-Path $out 'xp-target.raw'
$targetMeta=Join-Path $out 'xp-target.ini'
$serial=Join-Path $out 'serial.log'
$stderr=Join-Path $out 'stderr.log'
$targetSerial='XP-TARGET-A'
New-Item -ItemType Directory -Force -Path $out,$fixtureDir | Out-Null

if($TargetMode -ne 'none'){
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $targetCreator -OutputRaw $targetRaw -MetadataPath $targetMeta -ExistingActive
    if($LASTEXITCODE -ne 0){ throw "XP target fixture failed: $LASTEXITCODE" }
    if($TargetBytes -gt 0){
        & $qemuImg resize -f raw $targetRaw $TargetBytes
        if($LASTEXITCODE -ne 0){ throw "XP target resize failed: $LASTEXITCODE" }
        if((Get-Item -LiteralPath $targetRaw).Length -ne $TargetBytes){ throw "XP target resize readback mismatch" }
        Write-Host "[PASS] XP enumeration target bytes=$TargetBytes" -ForegroundColor Green
    }
}
$fixtureArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixturePrep,'-IsoPath',$iso,'-OutputDirectory',$fixtureDir,'-TargetSerial',$targetSerial,'-StopAfterPrepare','yes','-CatalogMode','esp-fallback')
if($AutoStorageProbe){
    if($TargetMode -eq 'ide'){
        $fixtureArgs += @('-StorageProbeVendor','0x8086','-StorageProbeDevice','0x7010','-StorageProbeDriver','ata_piix','-StorageProbeCandidates','1')
    } elseif($TargetMode -eq 'ahci') {
        $fixtureArgs += @('-StorageProbeVendor','0x8086','-StorageProbeDevice','0x2922','-StorageProbeDriver','ahci','-StorageProbeCandidates','1')
    } else {
        throw '-AutoStorageProbe requires ide or ahci target mode'
    }
}
& powershell.exe @fixtureArgs
if($LASTEXITCODE -ne 0){ throw "XP menu fixture failed: $LASTEXITCODE" }
if(-not (Test-Path -LiteralPath $bootImage -PathType Leaf)){ throw "Missing boot fixture: $bootImage" }

$monitor=Get-FreeTcpPort
$args=@(
    '-name',"USOS-XP-Disk-Enum-$TargetMode",'-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','cirrus','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=ide,index=0,format=qcow2,file=$($bootImage.Replace('\','/'))"
)
if($TargetMode -eq 'ide'){
    $args += @('-drive',"if=none,id=xptarget,format=raw,file=$($targetRaw.Replace('\','/'))",'-device',"ide-hd,bus=ide.0,unit=1,drive=xptarget,serial=$targetSerial")
} elseif($TargetMode -eq 'ahci') {
    $args += @('-drive',"if=none,id=xptarget,format=raw,file=$($targetRaw.Replace('\','/'))",'-device','ich9-ahci,id=ahci','-device',"ide-hd,bus=ahci.0,drive=xptarget,serial=$targetSerial")
}
$args += '-no-reboot'

$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
try {
    $waitMarkers=@('[LEGACY_XP] DIAGNOSTIC PERSIST path=EFI/USOS/legacy-xp-disk-enumeration.txt','[LEGACY_XP] DISK ENUMERATION DIAGNOSTIC FROZEN')
    if($AutoStorageProbe){ $waitMarkers=@('[LTS_PROBE] RESULT=PASS','[LTS_PROBE] RESULT=FAIL') }
    $marker=Wait-Any $serial $waitMarkers $process $deadline
    if(-not $marker){ throw "Disk enumeration did not complete before timeout.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)" }
    $text=Read-SharedText $serial
    foreach($needle in @('[LEGACY_MENU_TEST] BOOT METHOD BYPASS PASS enabled=1 backend=xp-staging','[LEGACY_MENU_TEST] UNATTENDED SCREEN PASS extension=.sif selected=safe.sif','[LEGACY_XP] BIOS DISK INVENTORY END','[LEGACY_XP] LINUX BLOCK INVENTORY END')){
        if(-not $text.Contains($needle)){ throw "Missing '$needle'.`n$text" }
    }

    if($AutoStorageProbe){
        foreach($needle in @('[LTS_PROBE] CHECK1 modalias=1','[LTS_PROBE] CHECK2 driver=1','[LTS_PROBE] CHECK3 candidate=1','[LTS_PROBE] RESULT=PASS')){
            if(-not $text.Contains($needle)){ throw "Automatic LTS storage probe missing '$needle'.`n$text" }
        }
        Write-Host "[PASS] Automatic LTS storage probe stops before target selection/staging. mode=$TargetMode" -ForegroundColor Green
    }

    $biosLines = @($text -split "`r?`n" | Where-Object { $_ -match '^\[LEGACY_XP\] BIOS (DISK|INVENTORY)' })
    $linuxLines = @($text -split "`r?`n" | Where-Object { $_ -match '^\[LEGACY_XP\] (LINUX DISK|LINUX BLOCK INVENTORY|ENUMERATION RESULT)' })
    Write-Host "[PASS] XP single-method bypass + UNATTENDED flow reached storage enumeration. mode=$TargetMode" -ForegroundColor Green
    $biosLines | ForEach-Object { Write-Host $_ }
    $linuxLines | ForEach-Object { Write-Host $_ }

    if($TargetMode -eq 'ide'){
        foreach($needle in @('drive=0x80','drive=0x81','decision=REJECT reason=USOS-boot-drive','decision=ACCEPT reason=non-USOS-BIOS-drive','candidates=1','driver=ata_piix')){
            if(-not $text.Contains($needle)){ throw "IDE inventory expectation missing '$needle'.`n$text" }
        }
        Write-Host '[PASS] IDE control: BIOS and micro-Linux expose the target; PCI modalias bound ata_piix.' -ForegroundColor Green
    } elseif($TargetMode -eq 'none') {
        if(-not $text.Contains('candidates=0')){ throw "No-target case unexpectedly produced a Linux target.`n$text" }
        if(-not $text.Contains('BIOS reports only the USOS boot disk')){ throw "No-target diagnostic did not explain the rejection.`n$text" }
        Write-Host '[PASS] No-target control: diagnostic freezes at stage 1 and explains that BIOS reports only USOS.' -ForegroundColor Green
    } else {
        foreach($needle in @('BIOS DISK drive=0x81','candidates=1','driver=ahci')){
            if(-not $text.Contains($needle)){ throw "AHCI LTS regression expectation missing '$needle'.`n$text" }
        }
        Write-Host '[PASS] AHCI control: target is visible to BIOS/Linux and PCI modalias bound ahci.' -ForegroundColor Green
    }
    Write-Host "SERIAL=$serial"
} finally {
    if(-not $process.HasExited){ Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
