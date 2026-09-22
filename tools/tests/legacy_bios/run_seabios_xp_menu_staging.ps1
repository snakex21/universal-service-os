param(
    [string]$IsoPath = 'windows_xp_professional_service_pack_2_x86_pl.iso',
    [int]$TimeoutMinutes = 10,
    [ValidateSet('direct-ntfs','esp-fallback')][string]$CatalogMode = 'direct-ntfs',
    [switch]$BlankTarget,
    [UInt64]$TargetBytes = 0,
    [string]$OutputDirectory = '',
    [switch]$SelectNoUnattended,
    [string]$UnattendedSourcePath = '',
    [string]$ExistingTargetRaw = '',
    [switch]$ExpectReuse,
    [switch]$SkipMicroLinuxBuild
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
function Send-Hmp([int]$Port,[string]$Command) {
    $client=[Net.Sockets.TcpClient]::new(); $client.Connect('127.0.0.1',$Port)
    try { $stream=$client.GetStream(); $writer=[IO.StreamWriter]::new($stream); $writer.AutoFlush=$true; $writer.WriteLine($Command); Start-Sleep -Milliseconds 350 } finally { $client.Dispose() }
}
function Wait-Text([string]$Path,[string]$Needle,[Diagnostics.Process]$Process,[DateTime]$Deadline) {
    while([DateTime]::UtcNow -lt $Deadline -and -not $Process.HasExited) {
        $text=Read-SharedText $Path
        if($text.Contains($Needle)){ return $true }
        if($text.Contains('[MICRO-LINUX] STOP:') -or $text.Contains('[XP_TARGET] STOP:') -or $text.Contains('[XP_LOCAL_SOURCE] STOP:')) { return $false }
        Start-Sleep -Milliseconds 150
        $Process.Refresh()
    }
    return $false
}

$iso=Full $IsoPath
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$fixturePrep=Full 'tools/tests/legacy_bios/prepare_legacy_xp_menu_fixture.ps1'
$targetCreator=Full 'tools/tests/legacy_bios/create_xp_existing_target.ps1'
$runTag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=if($OutputDirectory){ Full $OutputDirectory } else { Full "zig-out/legacy-bios/xp-menu-flow-$runTag" }
$fixtureDir=Join-Path $out 'fixture'
$bootImage=Join-Path $fixtureDir 'xp-menu-usos.qcow2'
$targetRaw=if($ExistingTargetRaw){ Full $ExistingTargetRaw } else { Join-Path $out 'xp-target.raw' }
$targetMeta=Join-Path $out 'xp-target.ini'
$serial=Join-Path $out 'serial.log'
$stderr=Join-Path $out 'stderr.log'
$targetSerial='XP-TARGET-A'
New-Item -ItemType Directory -Force -Path $out,$fixtureDir | Out-Null

if($ExistingTargetRaw){
    if(-not (Test-Path -LiteralPath $targetRaw -PathType Leaf)){ throw "Existing target raw missing: $targetRaw" }
    Write-Host "[PASS] Reusing existing prepared target raw=$targetRaw" -ForegroundColor Green
} else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $targetCreator -OutputRaw $targetRaw -MetadataPath $targetMeta -ExistingActive
    if($LASTEXITCODE -ne 0){ throw "XP target fixture failed: $LASTEXITCODE" }
    if($TargetBytes -gt 0){
        & $qemuImg resize -f raw $targetRaw $TargetBytes
        if($LASTEXITCODE -ne 0){ throw "XP target resize failed: $LASTEXITCODE" }
        if([UInt64](Get-Item -LiteralPath $targetRaw).Length -ne $TargetBytes){ throw 'XP target resize readback mismatch' }
        Write-Host "[PASS] XP production-topology target bytes=$TargetBytes" -ForegroundColor Green
    }
}
if($TargetBytes -gt 0 -and $ExistingTargetRaw){ throw '-TargetBytes cannot be combined with -ExistingTargetRaw' }
if($BlankTarget -and -not $ExistingTargetRaw){
    $stream=[IO.FileStream]::new($targetRaw,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $mbr=New-Object byte[] 512
        if($stream.Read($mbr,0,512) -ne 512){ throw 'Short target MBR read while preparing blank-MBR fixture' }
        $diskIdBefore=[BitConverter]::ToUInt32($mbr,440)
        if($diskIdBefore -eq 0){ throw 'Blank-MBR fixture requires a nonzero disk signature' }
        if($mbr[510] -ne 0x55 -or $mbr[511] -ne 0xAA){ throw 'Blank-MBR fixture lost 55AA before partition-table clear' }
        [Array]::Clear($mbr,446,64)
        $stream.Position=0
        $stream.Write($mbr,0,512)
        $stream.Flush($true)
        $stream.Position=0
        $readback=New-Object byte[] 512
        if($stream.Read($readback,0,512) -ne 512){ throw 'Short blank-MBR readback' }
        if([BitConverter]::ToUInt32($readback,440) -ne $diskIdBefore){ throw 'Blank-MBR fixture changed disk signature' }
        for($i=446;$i -lt 510;$i++){ if($readback[$i] -ne 0){ throw "Blank-MBR fixture partition table not empty at byte $i" } }
        if($readback[510] -ne 0x55 -or $readback[511] -ne 0xAA){ throw 'Blank-MBR fixture changed 55AA' }
        Write-Host ("[PASS] Blank-MBR target fixture disk_id=0x{0:X8} entries=all-zero signature=55AA" -f $diskIdBefore) -ForegroundColor Green
    } finally { $stream.Dispose() }
}
$fixtureArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixturePrep,'-IsoPath',$iso,'-OutputDirectory',$fixtureDir,'-TargetSerial',$targetSerial,'-StopAfterPrepare','no','-CatalogMode',$CatalogMode)
if($SkipMicroLinuxBuild){ $fixtureArgs += '-SkipMicroLinuxBuild' }
if($SelectNoUnattended){ $fixtureArgs += '-SelectNoUnattended' }
if($UnattendedSourcePath){ $fixtureArgs += @('-UnattendedSourcePath',(Full $UnattendedSourcePath)) }
& powershell.exe @fixtureArgs
if($LASTEXITCODE -ne 0){ throw "XP menu fixture failed: $LASTEXITCODE" }
$unattendedScreenMarker=if($SelectNoUnattended){ '[LEGACY_MENU_TEST] UNATTENDED SCREEN PASS extension=.sif discovered=safe.sif selected=None' } else { '[LEGACY_MENU_TEST] UNATTENDED SCREEN PASS extension=.sif selected=safe.sif' }
if(-not (Test-Path -LiteralPath $bootImage -PathType Leaf)){ throw "Missing boot fixture: $bootImage" }

$monitor=Get-FreeTcpPort
$args=@(
    '-name','USOS-Legacy-XP-Menu-Staging','-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512M','-smp','2',
    '-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=ide,index=0,format=qcow2,file=$($bootImage.Replace('\','/'))",
    '-drive',"if=none,id=xptarget,format=raw,file=$($targetRaw.Replace('\','/'))",
    '-device',"ide-hd,bus=ide.0,unit=1,drive=xptarget,serial=$targetSerial",
    '-no-reboot'
)
$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$deadline=[DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
try {
    if(-not (Wait-Text $serial '[LEGACY_MENU_TEST] BOOT METHOD BYPASS PASS enabled=1 backend=xp-staging' $process $deadline)){
        throw "SeaBIOS did not bypass the redundant XP BOOT METHOD screen.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)"
    }
    if(-not (Wait-Text $serial $unattendedScreenMarker $process $deadline)){
        throw "SeaBIOS did not complete the XP UNATTENDED selection after method bypass.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)"
    }
    $methods=Read-SharedText $serial
    foreach($needle in @(
        '[LEGACY_MENU_TEST] BOOT METHOD BYPASS PASS enabled=1 backend=xp-staging',
        '[LEGACY_MENU_TEST] XP AUTOMATIC backend=xp-staging status=TESTED_IN_VM PASS',
        '[LEGACY_MENU_TEST] CHAINLOAD DISABLED reason=[requires UEFI; running BIOS]',
        $unattendedScreenMarker
    )){
        if(-not $methods.Contains($needle)){ throw "XP method-bypass integration output missing '$needle'.`n$methods" }
    }
    Write-Host '[PASS] XP has exactly one enabled BIOS method and skips the redundant BOOT METHOD screen.' -ForegroundColor Green
    Write-Host '[PASS] XP Automatic resolves to dedicated xp-staging with shared [TESTED IN VM] status.' -ForegroundColor Green
    Write-Host '[PASS] UEFI-only Chainload remains disabled with the shared firmware reason.' -ForegroundColor Green

    if(-not (Wait-Text $serial '[LEGACY_XP] BIOS DISK INVENTORY END' $process $deadline)){
        throw "XP staging did not emit BIOS disk inventory.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)"
    }
    $inventory=Read-SharedText $serial
    foreach($needle in @(
        '[LEGACY_XP] BIOS DISK drive=0x80',
        'decision=REJECT reason=USOS-boot-drive',
        '[LEGACY_XP] BIOS DISK drive=0x81',
        'decision=ACCEPT reason=non-USOS-BIOS-drive',
        '[LEGACY_XP] BIOS DISK INVENTORY END detected=2 edd_sized=2 boot=0x80'
    )){
        if(-not $inventory.Contains($needle)){ throw "BIOS inventory missing '$needle'.`n$inventory" }
    }
    Write-Host '[PASS] SeaBIOS inventory sees BIOS drives 0x80/0x81 and classifies only 0x80 as the USOS boot drive.' -ForegroundColor Green

    if(-not (Wait-Text $serial '[LEGACY_XP] PREPARE_XP_TARGET BEGIN' $process $deadline)){
        throw "XP Automatic did not enter prepare_xp_target.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)"
    }
    if(-not (Wait-Text $serial '[LEGACY_XP] WAITING FOR USER: remove USOS USB, then press ENTER to power off; target will boot XPSETUP as BIOS 0x80 on next power-on' $process $deadline)){
        throw "XP staging did not reach the remove-USOS ready screen.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)"
    }
    $final=Read-SharedText $serial
    $expectedTargetMarkers = if($ExpectReuse){ @(
        '[TARGET_DISK_GUARD] XPSETUP REUSE slot=1 start=2048 sectors=4194304 label=XPSETUP fat32=validated',
        '[LEGACY_XP] REUSE existing XPSETUP approved by strict guard; no second MBR slot will be created',
        '[TARGET_DISK_GUARD] PRE-WRITE PASS',
        '[XP_TARGET] REUSE EXISTING XPSETUP slot=1 start=2048 sectors=4194304; contents will be reformatted in place',
        '[XP_TARGET] ACTIVE FLAG SWITCH PASS previous=1 now=1(XPSETUP) other_entry_bytes=unchanged',
        '[XP_TARGET] MBR READBACK PASS xpsetup_entry=1 active=0x80 previous_active_flags_cleared=none other_entries=bitwise-unchanged'
    ) } elseif($BlankTarget){ @(
        '[TARGET_DISK_GUARD] ACTIVE PARTITION: none; XPSETUP will become the active boot partition',
        '[TARGET_DISK_GUARD] PRE-WRITE PASS',
        '[XP_TARGET] ACTIVE FLAG SWITCH PASS previous=none now=1(XPSETUP) other_entry_bytes=unchanged',
        '[XP_TARGET] MBR READBACK PASS xpsetup_entry=1 active=0x80 previous_active_flags_cleared=none other_entries=bitwise-unchanged'
    ) } else { @(
        '[LEGACY_XP] WARNING: Partycja 1 jest obecnie aktywna. Po przygotowaniu XPSETUP komputer bedzie startowal z instalatora XP.',
        '[TARGET_DISK_GUARD] PRE-WRITE PASS',
        '[XP_TARGET] ACTIVE FLAG SWITCH PASS previous=1 now=2(XPSETUP) other_entry_bytes=unchanged',
        '[XP_TARGET] MBR READBACK PASS xpsetup_entry=2 active=0x80 previous_active_flags_cleared=1 other_entries=bitwise-unchanged'
    ) }
    $unattendedStagingMarkers=if($SelectNoUnattended){ @(
        '[LEGACY_XP] UNATTENDED none; minimal WINNT.SIF will be generated without ProductKey',
        '[XP_LOCAL_SOURCE] WINNT.SIF source=minimal product_key=omitted'
    ) } else { @(
        '[LEGACY_XP] UNATTENDED PASS selected=safe.sif partition_selection=manual product_key=user-controlled',
        '[XP_LOCAL_SOURCE] WINNT.SIF source=user',
        '[LEGACY_XP] UNATTENDED READBACK PASS selected=safe.sif'
    ) }
    foreach($needle in @(
        '[LEGACY_XP] REQUEST backend=xp-staging',
        '[LEGACY_XP] BACKEND prepare_xp_target.sh',
        '[LEGACY_XP] PREPARE_XP_TARGET BEGIN'
    ) + $unattendedStagingMarkers + $expectedTargetMarkers + @(
        '[XP_TARGET] MBR CHS PASS',
        '[XP_TARGET] LOCAL SOURCE READBACK PASS',
        '[LEGACY_XP] PREPARE_XP_TARGET PASS',
        '[LEGACY_XP] PREPARED PASS backend=xp-staging',
        '[LEGACY_XP] REMOVE-USOS HANDOFF PASS auto_chainload_marker=cleared target_boot=BIOS-0x80',
        '[USOS-FB-UI] STAGE current=1/5 title=Preparation environment started',
        '[USOS-FB-UI] STAGE current=2/5 title=Verifying target device',
        '[USOS-FB-UI] STAGE current=3/5 title=Preparing workspace',
        '[USOS-FB-UI] STAGE current=4/5 title=Copying files',
        '[USOS-FB-UI] STAGE current=5/5 title=Verification and finalization',
        '[LEGACY_XP] PREPARED SYNC PASS; USOS media may now be removed safely',
        'XPSETUP GOTOWE.',
        'Wyjmij pendrive USOS, a nastepnie nacisnij ENTER, aby wylaczyc komputer.',
        '[USOS-FB-UI] DONE title=XPSETUP GOTOWE detail=REMOVE USOS USB, THEN PRESS ENTER TO POWER OFF.',
        '[USOS-FB-UI] DONE RENDER PASS backend=',
        'action=[ENTER]-POWER-OFF',
        '[LEGACY_XP] WAITING FOR USER: remove USOS USB, then press ENTER to power off; target will boot XPSETUP as BIOS 0x80 on next power-on'
    )){
        if(-not $final.Contains($needle)){ throw "Missing XP staging marker '$needle'.`n$final" }
    }
    Write-Host '[PASS] XP Automatic entered prepare_xp_target through the dedicated xp-staging backend.' -ForegroundColor Green
    if($SelectNoUnattended){
        Write-Host '[PASS] XP UNATTENDED screen selected None; staging generated the production minimal local-source WINNT.SIF.' -ForegroundColor Green
    } else {
        Write-Host '[PASS] XP unattended screen selected safe.sif and staging read it back byte-identically.' -ForegroundColor Green
    }
    Write-Host '[PASS] Staging reached the remove-USOS/reboot ready screen; no automatic 0x81 chainload was attempted.' -ForegroundColor Green

    Send-Hmp $monitor 'sendkey ret'
    $poweroffDeadline=[DateTime]::UtcNow.AddSeconds(20)
    $poweroffMarker=$false
    while([DateTime]::UtcNow -lt $poweroffDeadline){
        $powerText=Read-SharedText $serial
        if($powerText.Contains('[LEGACY_XP] POWER OFF REQUESTED')){ $poweroffMarker=$true }
        $process.Refresh()
        if($process.HasExited){ break }
        Start-Sleep -Milliseconds 150
    }
    if(-not $poweroffMarker){ throw "ENTER on DONE did not reach the power-off handler.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)" }
    if(-not $process.HasExited){ throw "ENTER reached the power-off handler, but QEMU did not power off within 20 seconds.`n$(Read-SharedText $serial)`n$(Read-SharedText $stderr)" }
    Write-Host '[PASS] DONE framebuffer rendered the ENTER action; Enter reached POWER OFF REQUESTED and QEMU powered off.' -ForegroundColor Green
    Write-Host "SERIAL=$serial"
} finally {
    if(-not $process.HasExited){
        try { Send-Hmp $monitor 'quit' } catch {}
        if(-not $process.WaitForExit(5000)){ Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

$stream=[IO.FileStream]::new($targetRaw,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $mbr=New-Object byte[] 512
    if($stream.Read($mbr,0,512) -ne 512){ throw 'Short target MBR read after XP staging' }
} finally { $stream.Dispose() }
if($BlankTarget -or $ExpectReuse){
    if($mbr[446] -ne 0x80){ throw ("XPSETUP partition 1 is not active on blank/reuse target: 0x{0:X2}" -f $mbr[446]) }
    if($mbr[450] -ne 0x0C){ throw ("XPSETUP partition 1 type is not FAT32 LBA: 0x{0:X2}" -f $mbr[450]) }
    foreach($offset in 462,478,494){ if($mbr[$offset] -ne 0x00){ throw ("Unexpected active flag on blank-target MBR at offset {0}: 0x{1:X2}" -f $offset,$mbr[$offset]) } }
    if($ExpectReuse){
        Write-Host '[PASS] External MBR readback: existing XPSETUP partition 1 was reused; no second partition was created.' -ForegroundColor Green
    } else {
        Write-Host '[PASS] External MBR readback: blank target gained only active XPSETUP partition 1.' -ForegroundColor Green
    }
} else {
    if($mbr[446] -ne 0x00){ throw ("Existing partition 1 active flag was not cleared: 0x{0:X2}" -f $mbr[446]) }
    if($mbr[462] -ne 0x80){ throw ("XPSETUP partition 2 is not active: 0x{0:X2}" -f $mbr[462]) }
    if($mbr[450] -ne 0x07 -or $mbr[466] -ne 0x0C){ throw 'Partition types changed during active-flag switch' }
    Write-Host '[PASS] External MBR readback: existing partition 1 inactive; XPSETUP partition 2 is the sole active partition.' -ForegroundColor Green
}
$strategyMbr=[IO.File]::ReadAllBytes((Join-Path $root 'zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin'))
if($strategyMbr.Length -ne 440){ throw 'Strategy B MBR artifact is not exactly 440 bytes' }
if(-not [Linq.Enumerable]::SequenceEqual([byte[]]$mbr[0..439],[byte[]]$strategyMbr)){
    throw 'Production XP staging did not install the exact Strategy B MBR into bytes 0..439'
}
Write-Host ("[PASS] Production Strategy B MBR readback: bytes 0..439 exact SHA256={0}; tail 440..511 preserved by prepare_xp_target." -f (Get-FileHash -LiteralPath (Join-Path $root 'zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin') -Algorithm SHA256).Hash) -ForegroundColor Green
Write-Host "TARGET_RAW=$targetRaw"
Write-Host "OUTPUT=$out"
