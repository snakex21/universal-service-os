param(
    [string]$IsoPath = 'windows_xp_professional_service_pack_2_x86_pl.iso',
    [string]$CaseName = 'sp2-clean',
    [switch]$BlankTarget,
    [UInt64]$TargetBytes = 0,
    [switch]$KeepArtifacts,
    [switch]$ContinueThroughCopy,
    [switch]$FastBootFilesFixture,
    [switch]$ForceMbrChsRead,
    [switch]$SkipMicroLinuxBuild,
    [switch]$ContinueThroughReboot
)

$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try { $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$true,4096,$true); try { return $reader.ReadToEnd() } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}
function Get-FreeTcpPort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}
function Send-Hmp([int]$Port,[string]$Command) {
    $client=[Net.Sockets.TcpClient]::new(); $client.Connect('127.0.0.1',$Port)
    try { $stream=$client.GetStream(); Start-Sleep -Milliseconds 100; $bytes=[Text.Encoding]::ASCII.GetBytes($Command+"`n"); $stream.Write($bytes,0,$bytes.Length); $stream.Flush(); Start-Sleep -Milliseconds 250 } finally { $client.Dispose() }
}
function Remove-HeavyXpArtifacts([string]$RunDirectory) {
    foreach ($candidate in @(
        (Join-Path $RunDirectory 'xp-target.raw'),
        (Join-Path $RunDirectory 'xp-target-boot-test.raw'),
        (Join-Path $RunDirectory 'usos-xp-boot.qcow2'),
        (Join-Path $RunDirectory 'fixture')
    )) {
        if (Test-Path -LiteralPath $candidate) {
            Remove-Item -LiteralPath $candidate -Recurse -Force
            Write-Host "[CLEAN] $candidate"
        }
    }
}
function Remove-HeavyXpArtifactsFromSuccessfulRuns([string]$ParentDirectory) {
    Get-ChildItem -LiteralPath $ParentDirectory -Directory -Filter 'xp-textmode-*' -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Path -LiteralPath (Join-Path $_.FullName 'milestone.pass') -PathType Leaf) {
            Remove-HeavyXpArtifacts $_.FullName
        }
    }
}
function Read-VgaText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $bytes=[IO.File]::ReadAllBytes($Path)
    $sb=[Text.StringBuilder]::new()
    for ($row=0; $row -lt 25; $row++) {
        for ($col=0; $col -lt 80; $col++) {
            $i=(($row*80)+$col)*2
            if ($i -ge $bytes.Length) { break }
            $c=$bytes[$i]
            if ($c -lt 32 -or $c -gt 126) { [void]$sb.Append(' ') } else { [void]$sb.Append([char]$c) }
        }
        [void]$sb.Append("`n")
    }
    return $sb.ToString()
}
function Capture-VgaState([int]$Monitor,[string]$Directory,[string]$Name) {
    $shot=Join-Path $Directory "$Name.ppm"
    $dump=Join-Path $Directory "$Name.bin"
    Remove-Item -LiteralPath $shot,$dump -Force -ErrorAction SilentlyContinue
    Send-Hmp $Monitor "screendump `"$($shot.Replace('\','/'))`""
    Send-Hmp $Monitor "pmemsave 0xb8000 4000 `"$($dump.Replace('\','/'))`""
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while ((-not (Test-Path -LiteralPath $shot -PathType Leaf) -or -not (Test-Path -LiteralPath $dump -PathType Leaf)) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $shot -PathType Leaf)) { throw "VGA screendump missing: $Name" }
    if (-not (Test-Path -LiteralPath $dump -PathType Leaf)) { throw "VGA text dump missing: $Name" }
    [pscustomobject]@{ Shot=$shot; Dump=$dump; Text=(Read-VgaText $dump) }
}
function Test-PartitionScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('unpartitioned') -or $lower.Contains('nieprzydziel') -or $lower.Contains('nie przydziel') -or $lower.Contains('partycj')) -and ($lower.Contains('enter') -or $lower.Contains('dysk:') -or $lower.Contains('disk')))
}
function Test-CreateSizeScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('rozmiar') -or $lower.Contains('size')) -and ($lower.Contains('partycj') -or $lower.Contains('partition')) -and $lower.Contains('enter'))
}
function Test-BootFilesSpaceError([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('1024') -and ($lower.Contains('miejsca') -or $lower.Contains('space'))) -or
            ($lower.Contains('plik') -and $lower.Contains('startow') -and $lower.Contains('miejsca')) -or
            ($lower.Contains('boot') -and $lower.Contains('files') -and $lower.Contains('space')))
}
function Test-FormatScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('format') -and ($lower.Contains('ntfs') -or $lower.Contains('fat'))) -and ($lower.Contains('enter') -or $lower.Contains('szybk') -or $lower.Contains('quick')))
}
function Test-CopyingScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('instalator kopiuje pliki') -and $lower.Contains('%')) -or
            ($lower.Contains('setup is copying files') -and $lower.Contains('%')))
}
function Test-SourceAccessError([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('dysku cd') -and $lower.Contains('plik') -and ($lower.Contains('nie mo') -or $lower.Contains('dost'))) -or
            ($lower.Contains('cannot access') -and $lower.Contains('cd') -and $lower.Contains('file')))
}
function Test-FormatFailure([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('nie mo') -and $lower.Contains('sformatowa')) -or
            ($lower.Contains('cannot format') -and $lower.Contains('partition')))
}
function Show-VgaState($State) {
    Write-Host "----- $([IO.Path]::GetFileNameWithoutExtension($State.Dump)) VGA TEXT -----"
    Write-Host $State.Text
    Write-Host '----- END VGA TEXT -----'
}
function Test-RowSelected([string]$DumpPath,[string]$Needle) {
    $bytes=[IO.File]::ReadAllBytes($DumpPath)
    for($row=0;$row -lt 25;$row++) {
        $sb=[Text.StringBuilder]::new()
        $selected=0
        for($col=0;$col -lt 80;$col++) {
            $i=(($row*80)+$col)*2
            $c=$bytes[$i]
            if($c -lt 32 -or $c -gt 126){ [void]$sb.Append(' ') } else { [void]$sb.Append([char]$c) }
            if($bytes[$i+1] -eq 0x71){ $selected++ }
        }
        if($sb.ToString().ToLowerInvariant().Contains($Needle.ToLowerInvariant())){ return ($selected -ge 20) }
    }
    return $false
}

$iso = Full $IsoPath
if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) { throw "XP ISO missing: $iso" }
if(($ContinueThroughCopy -or $ContinueThroughReboot) -and -not $BlankTarget){ throw '-ContinueThroughCopy/-ContinueThroughReboot currently requires -BlankTarget so partition 2 is created in unallocated space' }
if($ContinueThroughReboot){ $ContinueThroughCopy=$true }
$caseSlug=($CaseName -replace '[^A-Za-z0-9._-]','-').Trim('-')
if (-not $caseSlug) { $caseSlug='xp' }
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg=Full 'tools/qemu/qemu-img.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$fixturePrep=Full 'tools/tests/legacy_bios/prepare_fat32_fixture.ps1'
$fixtureBuilder=Full 'tools/tests/legacy_bios/create_fat32_boot_fixture.py'
$targetCreator=Full 'tools/tests/legacy_bios/create_xp_existing_target.ps1'
$legacyBuilder=Full 'tools/build_legacy_bios.ps1'
$xpBuilder=Full 'tools/build_xp_bootstrap.ps1'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$runTag=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$out=Full ("zig-out/legacy-bios/xp-textmode-$caseSlug-$runTag")
$fixtureDir=Join-Path $out 'fixture'
$bootImage=Join-Path $out 'usos-xp-boot.qcow2'
$targetRaw=Join-Path $out 'xp-target.raw'
$bootTargetRaw=Join-Path $out 'xp-target-boot-test.raw'
$targetMeta=Join-Path $out 'xp-target.ini'
$prepareSerial=Join-Path $out 'serial-prepare.log'
$prepareStderr=Join-Path $out 'stderr-prepare.log'
$serial=Join-Path $out 'serial-boot.log'
$stderr=Join-Path $out 'stderr-boot.log'
$screenshot=Join-Path $out 'xp-textmode.ppm'
$vgaDump=Join-Path $out 'vga-text.bin'
$targetSerial='XP-TARGET-A'
$green=$false
New-Item -ItemType Directory -Force -Path $out | Out-Null

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $xpBuilder
if ($LASTEXITCODE -ne 0) { throw "XP bootstrap build failed: $LASTEXITCODE" }
if(-not $SkipMicroLinuxBuild){
    & $root\tools\zig\zig.exe build --cache-dir "$root\tools\cache\zig" micro-linux -Doptimize=ReleaseFast
    if ($LASTEXITCODE -ne 0) { throw "micro-Linux build failed: $LASTEXITCODE" }
} else {
    Write-Host '[TEST] Reusing prebuilt micro-Linux initramfs; caller is responsible for its fixture contents.'
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $targetCreator -OutputRaw $targetRaw -MetadataPath $targetMeta
if ($LASTEXITCODE -ne 0) { throw "existing-data XP target creation failed: $LASTEXITCODE" }
if($TargetBytes -gt 0){
    & $qemuImg resize -f raw $targetRaw $TargetBytes
    if($LASTEXITCODE -ne 0){ throw "XP target resize failed: $LASTEXITCODE" }
    if([UInt64](Get-Item -LiteralPath $targetRaw).Length -ne $TargetBytes){ throw 'XP target resize readback mismatch' }
    Write-Host "[PASS] XP target physical-size fixture bytes=$TargetBytes"
}
if ($BlankTarget) {
    $stream=[IO.FileStream]::new($targetRaw,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $mbr=New-Object byte[] 512
        if($stream.Read($mbr,0,512) -ne 512){ throw 'Short target MBR read while preparing blank text-mode fixture' }
        $diskId=[BitConverter]::ToUInt32($mbr,440)
        if($diskId -eq 0 -or $mbr[510] -ne 0x55 -or $mbr[511] -ne 0xAA){ throw 'Blank text-mode fixture requires nonzero disk ID and 55AA' }
        [Array]::Clear($mbr,446,64)
        $stream.Position=0; $stream.Write($mbr,0,512); $stream.Flush($true)
        Write-Host ("[PASS] Text-mode blank target disk_id=0x{0:X8} entries=all-zero" -f $diskId)
    } finally { $stream.Dispose() }
}
$targetValues=@{}
Get-Content -LiteralPath $targetMeta | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { $targetValues[$matches[1]]=$matches[2] }
}
$sentinelSha=$targetValues['sentinel_sha256']
$sentinelPath=$targetValues['sentinel_path']
$sentinelPartition=[int]$targetValues['sentinel_partition']
if (-not $sentinelSha -or -not $sentinelPath -or $sentinelPartition -lt 1) { throw 'XP target metadata is incomplete' }
$fixtureArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixturePrep,'-OutputDirectory',$fixtureDir,'-BootMicroLinux','-XpTargetTest','-XpTargetSerial',$targetSerial,'-XpSentinelSha256',$sentinelSha,'-XpSentinelPath',$sentinelPath,'-XpSentinelPartition',$sentinelPartition,'-OnlyValid')
if($BlankTarget){ $fixtureArgs += '-XpBlankTarget' }
if($FastBootFilesFixture){ $fixtureArgs += '-XpBootFilesFast' }
& powershell.exe @fixtureArgs
if ($LASTEXITCODE -ne 0) { throw "XP boot fixture preparation failed: $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $legacyBuilder
if ($LASTEXITCODE -ne 0) { throw "Legacy build failed: $LASTEXITCODE" }
$raw=Join-Path $fixtureDir 'valid.raw'
& $python $fixtureBuilder --qemu-img $qemuImg --source-raw $raw --stage1 (Full 'zig-out/legacy-bios/stage1.bin') --core-slot (Full 'zig-out/legacy-bios/core-slot.bin') --output $bootImage
if ($LASTEXITCODE -ne 0) { throw "XP boot fixture creation failed: $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $targetRaw -PathType Leaf)) { throw 'existing-data XP target raw disappeared before QEMU start' }

Remove-Item -LiteralPath $prepareSerial,$prepareStderr,$serial,$stderr,$screenshot,$vgaDump -Force -ErrorAction SilentlyContinue
$prepareProcess=$null
$process=$null
try {
    # Phase A: run the production micro-Linux preparation path. Keep the XP
    # target and the read-only ISO source on legacy IDE/PIIX. The Alpine LTS
    # closure explicitly validates ata_piix; the old test-only virtio-blk source
    # is not part of the production XP path. Phase B still boots only the cloned
    # target, with neither the USOS disk nor the ISO attached.
    $prepareMonitor=Get-FreeTcpPort
    $prepareArgs=@(
        '-name','USOS-XP-Prepare', '-machine','pc', '-accel','tcg,thread=multi', '-cpu','max',
        '-m','512M', '-smp','2', '-bios',$seabios, '-boot','order=c,strict=on', '-display','none', '-vga','std', '-nic','none',
        '-monitor',"tcp:127.0.0.1:$prepareMonitor,server=on,wait=off", '-serial',"file:$($prepareSerial.Replace('\','/'))",
        '-drive',"if=ide,index=0,format=qcow2,file=$($bootImage.Replace('\','/'))",
        '-drive',"if=none,id=xpiso,format=raw,snapshot=on,file=$($iso.Replace('\','/'))",
        '-device','ide-hd,bus=ide.1,unit=0,drive=xpiso,serial=XP-ISO-SOURCE',
        '-drive',"if=none,id=xptargetprep,format=raw,file=$($targetRaw.Replace('\','/'))",
        '-device',"ide-hd,bus=ide.0,unit=1,drive=xptargetprep,serial=$targetSerial"
    )
    $prepareProcess=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $prepareArgs) -PassThru -RedirectStandardError $prepareStderr
    $prepareDeadline=[DateTime]::UtcNow.AddMinutes(8)
    $prepareText=''
    while (-not $prepareProcess.HasExited -and [DateTime]::UtcNow -lt $prepareDeadline) {
        Start-Sleep -Milliseconds 200
        $prepareText=Read-SharedText $prepareSerial
        if ($prepareText.Contains('[XP_TARGET_TEST] PREPARED SYNC PASS') -or $prepareText.Contains('[XP_TARGET] STOP:') -or $prepareText.Contains('[XP_LOCAL_SOURCE] STOP:')) { break }
    }
    $prepareText=Read-SharedText $prepareSerial
    $localSourceMarker=if($FastBootFilesFixture){ '[XP_LOCAL_SOURCE] bootfiles ~LS copy PASS' } else { '[XP_LOCAL_SOURCE] complete I386 copy PASS' }
    $prepareMarkers=@(
        '[TARGET_DISK_GUARD] PRE-WRITE PASS',
        '[XP_TARGET] I386 SOURCE PASS',
        '[XP_TARGET] ACTIVE FLAG SWITCH PASS',
        '[XP_TARGET] MBR READBACK PASS',
        '[XP_TARGET] FAT32 GEOMETRY PASS bps=512 spc=8 cluster_bytes=4096',
        '[XP_TARGET] FAT32 NT52 VBR/STAGE2 PASS',
        $localSourceMarker,
        '[XP_LOCAL_SOURCE] PASS',
        '[XP_TARGET] LOCAL SOURCE READBACK PASS',
        '[XP_TARGET] FREE SPACE PASS',
        '[XP_TARGET_TEST] PREPARED SYNC PASS'
    )
    if($BlankTarget){
        $prepareMarkers=@('[XP_TARGET_TEST] BLANK TARGET BEFORE PASS serial=XP-TARGET-A')+$prepareMarkers+@('[XP_TARGET_TEST] BLANK TARGET AFTER PASS xpsetup-created=yes')
    } else {
        $prepareMarkers=@("[XP_TARGET_TEST] EXISTING DATA BEFORE PASS sha256=$sentinelSha")+$prepareMarkers+@("[XP_TARGET_TEST] EXISTING DATA AFTER PASS sha256=$sentinelSha unchanged=yes")
    }
    foreach ($marker in $prepareMarkers) {
        if (-not $prepareText.Contains($marker)) {
            throw "XP preparation stopped before marker: $marker`n--- prepare serial ---`n$prepareText`n--- prepare stderr ---`n$(Read-SharedText $prepareStderr)"
        }
    }
    if (-not $prepareProcess.HasExited) {
        try { Send-Hmp $prepareMonitor 'quit' } catch {}
        if (-not $prepareProcess.WaitForExit(5000)) { Stop-Process -Id $prepareProcess.Id -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "[PASS] XP local source prepared and synced: case=$CaseName"

    # Phase B proves the production remove-USOS handoff directly: boot the
    # prepared target as the sole BIOS HDD (0x80), with NO ISO and NO USOS disk.
    # The historical partition-screen-only regression keeps a clone so its
    # prepared source remains immutable. The focused copy-start regression must
    # continue in one session and intentionally lets XP modify the test target,
    # so boot it in-place and avoid scanning/copying a 120 GB sparse RAW.
    if($ContinueThroughCopy -or $ForceMbrChsRead){
        $bootDiskRaw=$targetRaw
        if($ContinueThroughCopy){
            Write-Host '[PASS] Focused copy-start regression boots prepared target in-place; 120 GB clone scan skipped.'
        } else {
            Write-Host '[PASS] CHS boot regression boots prepared target in-place; 120 GB clone scan skipped.'
        }
    } else {
        & $qemuImg convert -f raw -O raw -S 4k $targetRaw $bootTargetRaw
        if ($LASTEXITCODE -ne 0) { throw "XP production handoff clone failed: $LASTEXITCODE" }
        $bootDiskRaw=$bootTargetRaw
    }

    if($ForceMbrChsRead){
        # Test-only: current Windows/DiskPart MBR uses EDD AH=42 when available,
        # which hid invalid CHS bytes from the regression. NOP the single
        # `inc byte ptr [bp+0x10]` instruction that records EDD support, forcing
        # its existing CHS AH=02 branch without replacing the MBR implementation.
        $chsStream=[IO.FileStream]::new($bootDiskRaw,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            $chsStream.Position=0x56
            $probe=New-Object byte[] 3
            if($chsStream.Read($probe,0,3) -ne 3){ throw 'Short MBR read while enabling CHS-only regression' }
            if($probe[0] -ne 0xFE -or $probe[1] -ne 0x46 -or $probe[2] -ne 0x10){
                throw ("Unexpected DiskPart MBR EDD marker at 0x56: {0}" -f ([BitConverter]::ToString($probe)))
            }
            $chsStream.Position=0x56
            $nops=[byte[]](0x90,0x90,0x90)
            $chsStream.Write($nops,0,3)
            $chsStream.Flush($true)
        } finally { $chsStream.Dispose() }
        Write-Host '[PASS] Test-only MBR patch forces INT13 CHS read path; production MBR policy unchanged.'
    }

    $mbrStream=[IO.FileStream]::new($bootDiskRaw,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $mbrBytes=New-Object byte[] 512
        if($mbrStream.Read($mbrBytes,0,512) -ne 512){ throw 'Short production target MBR read before Phase B' }
    } finally { $mbrStream.Dispose() }
    $activeOffset=if($BlankTarget){446}else{462}
    if($mbrBytes[$activeOffset] -ne 0x80){ throw ("Production XPSETUP is not active before remove-USOS boot at MBR offset {0}: 0x{1:X2}" -f $activeOffset,$mbrBytes[$activeOffset]) }
    foreach($offset in 446,462,478,494){ if($offset -ne $activeOffset -and $mbrBytes[$offset] -ne 0x00){ throw 'Production target has another active MBR partition besides XPSETUP' } }
    Write-Host ("[PASS] Production target readback: XPSETUP slot {0} is the sole active MBR partition before remove-USOS boot." -f $(if($BlankTarget){1}else{2}))

    $monitor=Get-FreeTcpPort
    $bootArgs=@(
        '-name','USOS-XP-Staging-Milestone', '-machine','pc', '-accel','tcg,thread=multi', '-cpu','max',
        '-m','512M', '-smp','2', '-bios',$seabios, '-boot','order=c,strict=on', '-display','none', '-vga','std', '-nic','none',
        '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off", '-serial','none',
        '-drive',"if=ide,index=0,format=raw,file=$($bootDiskRaw.Replace('\','/')),media=disk"
    )
    $process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $bootArgs) -PassThru -RedirectStandardError $stderr

    # SETUPLDR no longer writes serial. Observe its VGA text first; only send
    # the documented Enter/F8 keys when the corresponding Setup screen is
    # actually visible. Any source error is therefore captured verbatim rather
    # than hidden by blind key injection.
    Start-Sleep -Seconds 8
    $partitionState=$null
    $lastState=$null
    for ($step=0; $step -lt 16 -and -not $partitionState; $step++) {
        $state=Capture-VgaState $monitor $out ("setup-stage-{0:D2}" -f $step)
        $lastState=$state
        $lower=$state.Text.ToLowerInvariant()
        if (Test-PartitionScreen $state.Text) {
            $partitionState=$state
            break
        }
        if ($lower.Contains('i386') -and ($lower.Contains('cannot') -or $lower.Contains('not found') -or $lower.Contains('brak') -or $lower.Contains('nie mo'))) {
            throw "SETUPLDR reported an I386/source error:`n$($state.Text)"
        }
        if (($lower.Contains('f8') -or $lower.Contains('f 8')) -and ($lower.Contains('licen') -or $lower.Contains('umow'))) {
            Send-Hmp $monitor 'sendkey f8'
            Start-Sleep -Seconds 3
            continue
        }
        if (($lower.Contains('welcome') -or $lower.Contains('witamy') -or $lower.Contains('instalator') -or $lower.Contains('windows xp')) -and $lower.Contains('enter')) {
            Send-Hmp $monitor 'sendkey ret'
            Start-Sleep -Seconds 3
            continue
        }
        Start-Sleep -Seconds 3
    }
    if (-not $partitionState) {
        $lastText=if ($lastState) { $lastState.Text } else { '<no VGA state captured>' }
        throw "SETUPLDR did not reach the partition-selection screen.`nLast VGA text:`n$lastText"
    }

    Copy-Item -LiteralPath $partitionState.Shot -Destination $screenshot -Force
    Copy-Item -LiteralPath $partitionState.Dump -Destination $vgaDump -Force
    $vga=$partitionState.Text
    Write-Host '----- XP PARTITION SCREEN VGA TEXT -----'
    Write-Host $vga
    Write-Host '----- END XP PARTITION SCREEN VGA TEXT -----'
    if(-not $BlankTarget){ Write-Host "[PASS] existing NTFS sentinel unchanged SHA256=$sentinelSha" }
    Write-Host "[PASS] Production XPSETUP booted as sole BIOS 0x80 disk with no USOS media and no source ISO attached: case=$CaseName iso=$iso blank_target=$BlankTarget"
    Write-Host "[PASS] Windows XP Text Mode Setup reached partition selection. screenshot=$screenshot"
    if($ContinueThroughCopy){
        $copyDeadline=[DateTime]::UtcNow.AddMinutes(6)

        # Continue in THIS SAME SETUPLDR/QEMU session. XPSETUP is selected on
        # entry; move to the unallocated extent, create partition 2 at maximum
        # size, then prove partition 2 is highlighted before selecting it.
        Send-Hmp $monitor 'sendkey down'
        Start-Sleep -Milliseconds 600
        Send-Hmp $monitor 'sendkey c'
        Start-Sleep -Seconds 1
        $createState=Capture-VgaState $monitor $out 'create-partition-size'
        Show-VgaState $createState
        if(-not (Test-CreateSizeScreen $createState.Text)){ throw 'Create-partition size screen not reached after C' }
        Send-Hmp $monitor 'sendkey ret'
        Start-Sleep -Seconds 2

        $createdState=Capture-VgaState $monitor $out 'partition-created'
        Show-VgaState $createdState
        if(-not (Test-PartitionScreen $createdState.Text)){ throw 'Partition screen did not return after creating partition 2' }
        $createdLower=$createdState.Text.ToLowerInvariant()
        if(-not ($createdLower.Contains('partycja2') -or $createdLower.Contains('partition2') -or $createdLower.Contains('partycja 2') -or $createdLower.Contains('partition 2'))){ throw 'Created partition 2 is not visible' }

        Send-Hmp $monitor 'sendkey down'
        Start-Sleep -Milliseconds 600
        $targetState=Capture-VgaState $monitor $out 'partition2-selected'
        Show-VgaState $targetState
        if(-not (Test-RowSelected $targetState.Dump 'partycja2') -and -not (Test-RowSelected $targetState.Dump 'partition2')){ throw 'Partition 2 is not highlighted before installation-target Enter' }
        Send-Hmp $monitor 'sendkey ret'
        Start-Sleep -Seconds 2

        $formatState=$null
        for($i=0;$i -lt 8 -and [DateTime]::UtcNow -lt $copyDeadline -and -not $process.HasExited;$i++) {
            $state=Capture-VgaState $monitor $out ("post-select-{0:D2}" -f $i)
            if(Test-BootFilesSpaceError $state.Text){ Show-VgaState $state; throw 'BOOT-FILES FREE-SPACE FAIL reproduced after selecting partition 2' }
            if(Test-FormatScreen $state.Text){ $formatState=$state; break }
            Start-Sleep -Seconds 1
        }
        if(-not $formatState){ throw 'Neither boot-files error nor format screen appeared after selecting partition 2' }
        Show-VgaState $formatState
        Write-Host '[PASS] XP boot-files free-space check on C: passed; format screen reached.' -ForegroundColor Green

        # XP SP2 puts NTFS Quick at the top for a newly-created partition.
        for($i=0;$i -lt 8;$i++){ Send-Hmp $monitor 'sendkey up' }
        Send-Hmp $monitor 'sendkey ret'

        $copyState=$null
        for($i=0;$i -lt 120 -and [DateTime]::UtcNow -lt $copyDeadline -and -not $process.HasExited;$i++) {
            Start-Sleep -Seconds 1
            if(($i % 3) -ne 0){ continue }
            $state=Capture-VgaState $monitor $out ("format-copy-{0:D3}" -f $i)
            if(Test-BootFilesSpaceError $state.Text){ Show-VgaState $state; throw 'Boot-files free-space error appeared after format selection' }
            if(Test-FormatFailure $state.Text){ Show-VgaState $state; throw 'XP reported a partition-format failure' }
            if(Test-SourceAccessError $state.Text){ Show-VgaState $state; throw 'XP reported local-source/CD access failure after formatting' }
            if(Test-CopyingScreen $state.Text){ $copyState=$state; break }
        }
        if(-not $copyState){ throw 'XP did not reach file-copying screen after format selection' }
        Show-VgaState $copyState
        Write-Host '[PASS] XP Text Mode single-session: partition 2 created -> selected -> boot-files C: check passed -> format completed -> file copying started.' -ForegroundColor Green

        if($ContinueThroughReboot){
            $rebootDeadline=[DateTime]::UtcNow.AddMinutes(12)
            $rebootNoticeSeen=$false
            $secondBios=$null
            for($i=0;$i -lt 240 -and [DateTime]::UtcNow -lt $rebootDeadline -and -not $process.HasExited;$i++){
                Start-Sleep -Seconds 2
                try { $state=Capture-VgaState $monitor $out ("copy-complete-{0:D3}" -f $i) } catch { continue }
                $lower=$state.Text.ToLowerInvariant()
                if(Test-SourceAccessError $state.Text){ Show-VgaState $state; throw 'XP reported local-source/CD access failure while completing Text Mode copy' }
                if($lower.Contains('uruchom') -and $lower.Contains('ponownie')){ $rebootNoticeSeen=$true }
                if($lower.Contains('reboot') -or $lower.Contains('restart')){ $rebootNoticeSeen=$true }
                if($lower.Contains('seabios') -or $lower.Contains('booting from hard disk')){
                    if($rebootNoticeSeen -or $i -gt 5){ $secondBios=$state; break }
                }
            }
            if(-not $secondBios){ throw 'XP Text Mode did not complete copying and reach the first reboot/second BIOS within the gate deadline' }
            Show-VgaState $secondBios
            Write-Host ("[PASS] XP Text Mode copy completed and first reboot reached; reboot_notice_seen={0}" -f $rebootNoticeSeen) -ForegroundColor Green

            try { Send-Hmp $monitor 'stop' } catch {}
            Start-Sleep -Milliseconds 250
            try { Send-Hmp $monitor 'quit' } catch {}
            if(-not $process.WaitForExit(5000)){ throw 'QEMU did not exit cleanly after first-reboot capture' }
            $process=$null

            $mbrStream=[IO.FileStream]::new($bootDiskRaw,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                $postMbr=New-Object byte[] 512
                if($mbrStream.Read($postMbr,0,512) -ne 512){ throw 'Short MBR read after Text Mode reboot' }
                $mbrStream.Position=2048L*512
                $postVbr=New-Object byte[] 512
                if($mbrStream.Read($postVbr,0,512) -ne 512){ throw 'Short XPSETUP VBR read after Text Mode reboot' }
            } finally { $mbrStream.Dispose() }
            $p1Status=$postMbr[446]
            $p1Type=$postMbr[450]
            $p1Start=[BitConverter]::ToUInt32($postMbr,454)
            $p1Sectors=[BitConverter]::ToUInt32($postMbr,458)
            $p1StartChs=('{0:X2}{1:X2}{2:X2}' -f $postMbr[447],$postMbr[448],$postMbr[449])
            $p1EndChs=('{0:X2}{1:X2}{2:X2}' -f $postMbr[451],$postMbr[452],$postMbr[453])
            $bpbTotal=[BitConverter]::ToUInt32($postVbr,32)
            $bpbSpc=$postVbr[13]
            Write-Host ("[POST-TEXTMODE] P1 status=0x{0:X2} type=0x{1:X2} start={2} sectors={3} start_chs={4} end_chs={5}" -f $p1Status,$p1Type,$p1Start,$p1Sectors,$p1StartChs,$p1EndChs)
            Write-Host ("[POST-TEXTMODE] XPSETUP FAT32 bpb_total_sectors={0} spc={1}" -f $bpbTotal,$bpbSpc)
            if($p1Status -ne 0x80){ throw ("2 GiB XPSETUP lost active flag after Text Mode: 0x{0:X2}" -f $p1Status) }
            if($p1Type -ne 0x0C -or $p1Start -ne 2048 -or $p1Sectors -ne 4194304){ throw '2 GiB XPSETUP MBR identity changed unexpectedly after Text Mode' }
            if($bpbTotal -lt 4194000 -or $bpbTotal -gt 4194304){ throw "2 GiB FAT32 BPB total sectors outside expected extent after Text Mode: $bpbTotal" }
            [IO.File]::WriteAllText((Join-Path $out 'milestone.pass'),"XP 2GiB layout Text Mode first-reboot PASS active=yes sectors=$p1Sectors bpb_total=$bpbTotal start_chs=$p1StartChs end_chs=$p1EndChs`r`n",[Text.UTF8Encoding]::new($false))
            Write-Host ("[PASS] 2 GiB XPSETUP survived Text Mode rewrite as active P1; start_chs={0} end_chs={1}." -f $p1StartChs,$p1EndChs) -ForegroundColor Green
        } else {
            [IO.File]::WriteAllText((Join-Path $out 'milestone.pass'),"XP text-mode single-session copy-start PASS case=$CaseName iso=$iso target_bytes=$TargetBytes`r`n",[Text.UTF8Encoding]::new($false))
        }
    } else {
        [IO.File]::WriteAllText((Join-Path $out 'milestone.pass'),"XP text-mode partition selection PASS case=$CaseName iso=$iso`r`n",[Text.UTF8Encoding]::new($false))
    }
    $green=$true
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        [void]$process.WaitForExit(5000)
    }
    if ($prepareProcess -and -not $prepareProcess.HasExited) {
        Stop-Process -Id $prepareProcess.Id -Force -ErrorAction SilentlyContinue
        [void]$prepareProcess.WaitForExit(5000)
    }
    if ($green -and -not $KeepArtifacts) {
        Remove-HeavyXpArtifacts $out
        Remove-HeavyXpArtifactsFromSuccessfulRuns (Split-Path -Parent $out)
        Write-Host '[PASS] Successful XP E2E heavy disk images cleaned automatically; logs/screendumps kept.'
    } elseif($green) {
        Write-Host '[PASS] Successful XP E2E heavy disk images retained by -KeepArtifacts.'
    }
}
