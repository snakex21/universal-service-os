param(
    [Parameter(Mandatory=$true)][string]$RawPath,
    [string]$OutputDirectory = '',
    [int]$TimeoutMinutes = 12,
    [switch]$Snapshot,
    [switch]$StopAtPartition,
    [switch]$ContinueThroughReboot
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')

function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}
function Get-FreeTcpPort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}
function Send-Hmp([int]$Port,[string]$Command) {
    $client=[Net.Sockets.TcpClient]::new()
    $client.Connect('127.0.0.1',$Port)
    try {
        $stream=$client.GetStream()
        Start-Sleep -Milliseconds 100
        $bytes=[Text.Encoding]::ASCII.GetBytes($Command+"`n")
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush()
        Start-Sleep -Milliseconds 250
    } finally { $client.Dispose() }
}
function Read-VgaText([string]$Path) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    $sb=[Text.StringBuilder]::new()
    for($row=0;$row -lt 25;$row++) {
        for($col=0;$col -lt 80;$col++) {
            $i=(($row*80)+$col)*2
            if($i -ge $bytes.Length){ break }
            $c=$bytes[$i]
            if($c -lt 32 -or $c -gt 126){ [void]$sb.Append(' ') } else { [void]$sb.Append([char]$c) }
        }
        [void]$sb.Append("`n")
    }
    return $sb.ToString()
}
function Capture-Vga([int]$Port,[string]$Directory,[string]$Name) {
    $dump=Join-Path $Directory "$Name.bin"
    $shot=Join-Path $Directory "$Name.ppm"
    Remove-Item -LiteralPath $dump,$shot -Force -ErrorAction SilentlyContinue
    Send-Hmp $Port "pmemsave 0xb8000 4000 `"$($dump.Replace('\','/'))`""
    Send-Hmp $Port "screendump `"$($shot.Replace('\','/'))`""
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while(((-not (Test-Path -LiteralPath $dump -PathType Leaf)) -or (-not (Test-Path -LiteralPath $shot -PathType Leaf))) -and [DateTime]::UtcNow -lt $deadline){ Start-Sleep -Milliseconds 100 }
    if(-not (Test-Path -LiteralPath $dump -PathType Leaf)){ throw "VGA dump missing: $Name" }
    [pscustomobject]@{ Name=$Name; Text=(Read-VgaText $dump); Dump=$dump; Shot=$shot }
}
function Is-PartitionScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('partycj') -or $lower.Contains('unpartitioned') -or $lower.Contains('nie przydziel')) -and $lower.Contains('enter') -and ($lower.Contains('dysk:') -or $lower.Contains('disk')))
}
function Is-LicenseScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('f8') -or $lower.Contains('f 8')) -and ($lower.Contains('licen') -or $lower.Contains('umow')))
}
function Is-WelcomeScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('windows xp') -or $lower.Contains('instalator') -or $lower.Contains('welcome') -or $lower.Contains('witamy')) -and $lower.Contains('enter'))
}
function Is-CreateSizeScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('rozmiar') -or $lower.Contains('size')) -and ($lower.Contains('partycj') -or $lower.Contains('partition')) -and $lower.Contains('enter'))
}
function Is-BootFilesSpaceError([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('1024') -and ($lower.Contains('miejsca') -or $lower.Contains('space'))) -or
            ($lower.Contains('plik') -and $lower.Contains('startow') -and $lower.Contains('miejsca')) -or
            ($lower.Contains('boot') -and $lower.Contains('files') -and $lower.Contains('space')))
}
function Is-FormatScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('format') -and ($lower.Contains('ntfs') -or $lower.Contains('fat'))) -and ($lower.Contains('enter') -or $lower.Contains('szybk') -or $lower.Contains('quick')))
}
function Is-CopyingScreen([string]$Text) {
    $lower=$Text.ToLowerInvariant()
    return (($lower.Contains('kopi') -and $lower.Contains('plik')) -or ($lower.Contains('copy') -and $lower.Contains('file')))
}
function Show-State($State) {
    Write-Host "----- $($State.Name) VGA TEXT -----"
    Write-Host $State.Text
    Write-Host "----- END $($State.Name) -----"
}
function Is-RowSelected([string]$DumpPath,[string]$Needle) {
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

$raw=Full $RawPath
if(-not (Test-Path -LiteralPath $raw -PathType Leaf)){ throw "Raw target missing: $raw" }
if(-not $OutputDirectory){ $OutputDirectory=Join-Path (Split-Path -Parent $raw) 'continued-textmode' }
$out=Full $OutputDirectory
New-Item -ItemType Directory -Force -Path $out | Out-Null
$qemu=Full 'tools/qemu/qemu-system-x86_64.exe'
$seabios=Full 'tools/qemu/share/bios-256k.bin'
$stderr=Join-Path $out 'stderr.log'
Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue

$monitor=Get-FreeTcpPort
$args=@(
    '-name','USOS-XP-Continue-TextMode','-machine','pc','-accel','tcg,thread=multi','-cpu','max',
    '-m','512M','-smp','2','-bios',$seabios,'-boot','order=c,strict=on','-display','none','-vga','std','-nic','none',
    '-monitor',"tcp:127.0.0.1:$monitor,server=on,wait=off",'-serial','none',
    '-drive',("if=ide,index=0,format=raw,file=$($raw.Replace('\','/')),media=disk" + $(if($Snapshot){',snapshot=on'}else{''}))
)
$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr
$deadline=[DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$step=0
try {
    Start-Sleep -Seconds 8
    $partition=$null
    while([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited -and -not $partition) {
        $state=Capture-Vga $monitor $out ("nav-{0:D2}" -f $step); $step++
        $lower=$state.Text.ToLowerInvariant()
        if(Is-PartitionScreen $state.Text){ $partition=$state; break }
        if(Is-LicenseScreen $state.Text){ Send-Hmp $monitor 'sendkey f8'; Start-Sleep -Seconds 2; continue }
        if(Is-WelcomeScreen $state.Text){ Send-Hmp $monitor 'sendkey ret'; Start-Sleep -Seconds 2; continue }
        if($lower.Contains('i386') -and ($lower.Contains('brak') -or $lower.Contains('cannot') -or $lower.Contains('not found'))){ Show-State $state; throw 'XP source error before partition screen' }
        Start-Sleep -Seconds 2
    }
    if(-not $partition){ throw 'Partition-selection screen not reached' }
    Show-State $partition
    $pLower=$partition.Text.ToLowerInvariant()
    if(-not $pLower.Contains('xpsetup')){ throw 'XPSETUP is not visible on partition screen' }
    if(-not ($pLower.Contains('nie podziel') -or $pLower.Contains('nie przydziel') -or $pLower.Contains('unpartitioned'))){ throw 'No unallocated region visible after XPSETUP' }
    if($StopAtPartition){
        Write-Host '[PASS] XP physical-byte clone booted through MBR/VBR/SETUPLDR to the Text Mode partition-selection screen.' -ForegroundColor Green
        Write-Host "RAW=$raw"
        Write-Host "OUTPUT=$out"
        return
    }

    $partition2AlreadyExists=($pLower.Contains('partycja2') -or $pLower.Contains('partition2') -or $pLower.Contains('partycja 2') -or $pLower.Contains('partition 2'))
    if(-not $partition2AlreadyExists){
        # XPSETUP is the first row and initially selected. Move to the unallocated row, create partition 2, accept maximum size.
        Send-Hmp $monitor 'sendkey down'
        Start-Sleep -Milliseconds 600
        Send-Hmp $monitor 'sendkey c'
        Start-Sleep -Seconds 1
        $create=Capture-Vga $monitor $out 'create-partition-size'
        Show-State $create
        if(-not (Is-CreateSizeScreen $create.Text)){ throw 'Create-partition size screen not reached after C' }
        Send-Hmp $monitor 'sendkey ret'
        Start-Sleep -Seconds 2

        $afterCreate=Capture-Vga $monitor $out 'partition-created'
        Show-State $afterCreate
        if(-not (Is-PartitionScreen $afterCreate.Text)){ throw 'Partition screen did not return after creating partition 2' }
        $afterLower=$afterCreate.Text.ToLowerInvariant()
        if(-not ($afterLower.Contains('partycja2') -or $afterLower.Contains('partition2') -or $afterLower.Contains('partycja 2') -or $afterLower.Contains('partition 2'))){ throw 'Created partition 2 is not visible' }
    } else {
        Write-Host '[INFO] Partition 2 already exists on this continuation RAW; skipping the create-partition keystrokes.'
    }

    # XP Setup returns selection to C: XPSETUP after creating the new partition,
    # and also starts there on a continuation RAW with an existing partition 2.
    # Move exactly one row to partition 2 and prove the VGA highlight before Enter.
    Send-Hmp $monitor 'sendkey down'
    Start-Sleep -Milliseconds 600
    $targetSelected=Capture-Vga $monitor $out 'partition2-selected'
    Show-State $targetSelected
    if(-not (Is-RowSelected $targetSelected.Dump 'partycja2')){ throw 'Partition 2 is not highlighted before installation-target Enter' }
    Send-Hmp $monitor 'sendkey ret'
    Start-Sleep -Seconds 2
    $postSelect=$null
    # Large physical-size fixtures and custom XP media can spend well over a
    # minute on "Setup is examining your disks" after target selection. This
    # is forward progress, not a format-screen failure. Keep the wait bounded
    # by the overall test deadline, but do not impose the old ~8-second gate.
    for($i=0;$i -lt 60 -and [DateTime]::UtcNow -lt $deadline;$i++) {
        $state=Capture-Vga $monitor $out ("post-select-{0:D2}" -f $i)
        if(($i % 5) -eq 0){ Show-State $state }
        if(Is-BootFilesSpaceError $state.Text){ throw "BOOT-FILES FREE-SPACE FAIL reproduced in QEMU: $($state.Dump)" }
        if(Is-FormatScreen $state.Text){ $postSelect=$state; break }
        Start-Sleep -Seconds 2
    }
    if(-not $postSelect){ throw 'Neither boot-files error nor format screen appeared after selecting partition 2 within the bounded disk-scan wait' }
    Write-Host '[PASS] XP boot-files free-space check on C: passed; format screen reached.' -ForegroundColor Green

    # Force the first formatting option. XP SP2 places NTFS quick at the top when a new partition is selected.
    for($i=0;$i -lt 8;$i++){ Send-Hmp $monitor 'sendkey up' }
    Send-Hmp $monitor 'sendkey ret'

    $copying=$null
    for($i=0;$i -lt 120 -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited;$i++) {
        Start-Sleep -Seconds 1
        if(($i % 3) -ne 0){ continue }
        $state=Capture-Vga $monitor $out ("format-copy-{0:D3}" -f $i)
        if(Is-BootFilesSpaceError $state.Text){ Show-State $state; throw 'Boot-files free-space error appeared after format selection' }
        if(Is-CopyingScreen $state.Text){ $copying=$state; break }
    }
    if(-not $copying){ throw 'XP did not reach file-copying screen after format selection' }
    Show-State $copying
    Write-Host '[PASS] XP Text Mode: partition 2 created -> selected -> boot-files C: check passed -> format started/completed -> file copying started.' -ForegroundColor Green

    if($ContinueThroughReboot){
        $rebootDeadline=[DateTime]::UtcNow.AddMinutes(12)
        $rebootNoticeSeen=$false
        $secondBios=$null
        for($i=0;$i -lt 240 -and [DateTime]::UtcNow -lt $rebootDeadline -and -not $process.HasExited;$i++){
            Start-Sleep -Seconds 2
            try { $state=Capture-Vga $monitor $out ("copy-complete-{0:D3}" -f $i) } catch { continue }
            $lower=$state.Text.ToLowerInvariant()
            if($lower.Contains('uruchom') -and $lower.Contains('ponownie')){ $rebootNoticeSeen=$true }
            if($lower.Contains('reboot') -or $lower.Contains('restart')){ $rebootNoticeSeen=$true }
            if($lower.Contains('seabios') -or $lower.Contains('booting from hard disk')){
                if($rebootNoticeSeen -or $i -gt 5){ $secondBios=$state; break }
            }
        }
        if(-not $secondBios){ throw 'XP Text Mode did not complete copying and reach first reboot/second BIOS' }
        Show-State $secondBios
        Write-Host ("[PASS] XP Text Mode copy completed and first reboot reached; reboot_notice_seen={0}" -f $rebootNoticeSeen) -ForegroundColor Green

        try { Send-Hmp $monitor 'stop' } catch {}
        Start-Sleep -Milliseconds 250
        try { Send-Hmp $monitor 'quit' } catch {}
        if(-not $process.WaitForExit(5000)){ throw 'QEMU did not exit cleanly after first-reboot capture' }
        $process=$null

        $fs=[IO.FileStream]::new($raw,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $mbr=New-Object byte[] 512
            if($fs.Read($mbr,0,512) -ne 512){ throw 'Short MBR read after Text Mode reboot' }
            $fs.Position=2048L*512
            $vbr=New-Object byte[] 512
            if($fs.Read($vbr,0,512) -ne 512){ throw 'Short XPSETUP VBR read after Text Mode reboot' }
        } finally { $fs.Dispose() }
        $status=$mbr[446]
        $type=$mbr[450]
        $start=[BitConverter]::ToUInt32($mbr,454)
        $sectors=[BitConverter]::ToUInt32($mbr,458)
        $startChs=('{0:X2}{1:X2}{2:X2}' -f $mbr[447],$mbr[448],$mbr[449])
        $endChs=('{0:X2}{1:X2}{2:X2}' -f $mbr[451],$mbr[452],$mbr[453])
        $bpbTotal=[BitConverter]::ToUInt32($vbr,32)
        $bpbSpc=$vbr[13]
        Write-Host ("[POST-TEXTMODE] P1 status=0x{0:X2} type=0x{1:X2} start={2} sectors={3} start_chs={4} end_chs={5}" -f $status,$type,$start,$sectors,$startChs,$endChs)
        Write-Host ("[POST-TEXTMODE] XPSETUP FAT32 bpb_total_sectors={0} spc={1}" -f $bpbTotal,$bpbSpc)
        if($status -ne 0x80){ throw ("XPSETUP lost active flag after Text Mode: 0x{0:X2}" -f $status) }
        if($type -ne 0x0C -or $start -ne 2048 -or $sectors -ne 4194304){ throw '2 GiB XPSETUP MBR identity changed unexpectedly after Text Mode' }
        if($bpbTotal -lt 4194000 -or $bpbTotal -gt 4194304){ throw "2 GiB FAT32 BPB total sectors outside expected extent after Text Mode: $bpbTotal" }
        [IO.File]::WriteAllText((Join-Path $out 'textmode-reboot.pass'),"active=yes`r`nsectors=$sectors`r`nbpb_total=$bpbTotal`r`nstart_chs=$startChs`r`nend_chs=$endChs`r`n",[Text.UTF8Encoding]::new($false))
        Write-Host ("[PASS] 2 GiB XPSETUP survived XP Text Mode rewrite as active P1; start_chs={0} end_chs={1}." -f $startChs,$endChs) -ForegroundColor Green
    }

    Write-Host "RAW=$raw"
    Write-Host "OUTPUT=$out"
} finally {
    if($process -and -not $process.HasExited){
        try { Send-Hmp $monitor 'quit' } catch {}
        if(-not $process.WaitForExit(5000)){ Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}
