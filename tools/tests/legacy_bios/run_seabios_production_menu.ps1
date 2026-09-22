param(
    [int]$WindowsTimeoutSeconds = 2400,
    [int]$SeaBiosTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$ovmfCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$ovmfVarsSource = Full 'tools/qemu/share/edk2-i386-vars.fd'
$seabios = Full 'tools/qemu/share/bios-256k.bin'
$windowsBase = Full 'tools/tests/artifacts/qemu/usos-installer-windows-base.vhd'
$productionBase = Full 'tools/tests/artifacts/qemu/usos-backend-e2e-base.qcow2'
$tagSource = Full 'tools/tests/fixtures/installer/winpe-gpt-qemu/USOS_QEMU_TEST.TAG'
$artifactDir = Full 'tools/tests/artifacts/qemu/legacy-production-menu'
$windowsOverlay = Join-Path $artifactDir 'windows-overlay.qcow2'
$targetOverlay = Join-Path $artifactDir 'usos-production-menu.qcow2'
$configVhd = Join-Path $artifactDir 'config.vhd'
$configMount = Join-Path $artifactDir '.mount-config'
$varsPath = Join-Path $artifactDir 'edk2-vars.fd'
$windowsErr = Join-Path $artifactDir 'windows.stderr.log'
$windowsSerial = Join-Path $artifactDir 'windows.serial.log'
$seaSerial = Join-Path $artifactDir 'seabios.serial.log'
$seaErr = Join-Path $artifactDir 'seabios.stderr.log'
$resultName = 'usos-installer-e2e-result.txt'
$installer = Full 'installer/USOS Installer.exe'
$updateExe = Join-Path $artifactDir 'usos-installer-qemu-e2e.exe'

foreach ($required in @($qemu,$qemuImg,$ovmfCode,$ovmfVarsSource,$seabios,$windowsBase,$productionBase,$tagSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$active = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($artifactDir)
})
if ($active.Count -gt 0) { throw "Production-menu QEMU already running: PID=$($active[0].ProcessId)" }

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Send-Hmp([int]$Port, [string]$Command) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $writer = [IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine($Command)
        Start-Sleep -Milliseconds 250
    } finally {
        $client.Dispose()
    }
}

function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Count-TextOccurrence([string]$Text, [string]$Needle) {
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Needle)) { return 0 }
    return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
}

function Wait-SerialOccurrence([string]$Path, [string]$Needle, [int]$Minimum, [Diagnostics.Process]$Process, [int]$TimeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and -not $Process.HasExited) {
        if ((Count-TextOccurrence (Read-SharedText $Path) $Needle) -ge $Minimum) { return $true }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
    }
    return $false
}

function Read-ConfigResult([string]$ImagePath) {
    $mounted = $false
    try {
        Dismount-DiskImage -ImagePath $ImagePath -StorageType VHD -ErrorAction SilentlyContinue | Out-Null
        Mount-DiskImage -ImagePath $ImagePath -StorageType VHD -Access ReadOnly -NoDriveLetter | Out-Null
        $mounted = $true
        Start-Sleep -Milliseconds 300
        $disk = Get-DiskImage -ImagePath $ImagePath | Get-Disk
        foreach ($partition in @(Get-Partition -DiskNumber $disk.Number)) {
            $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
            if ($null -eq $volume -or [string]::IsNullOrWhiteSpace($volume.Path)) { continue }
            $resultPath = Join-Path $volume.Path $resultName
            if (Test-Path -LiteralPath $resultPath -PathType Leaf) { return Get-Content -LiteralPath $resultPath -Raw }
        }
        return $null
    } finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $ImagePath -StorageType VHD -ErrorAction SilentlyContinue | Out-Null }
    }
}

# Build the exact Legacy payload that the production installer will embed.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/build_legacy_bios.ps1')
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS build failed: $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/generate_legacy_boot_payload.ps1')
if ($LASTEXITCODE -ne 0) { throw "Legacy payload generation failed: $LASTEXITCODE" }

Push-Location (Full 'installer')
try {
    & go.exe build -trimpath -ldflags '-H=windowsgui' -o $installer ./cmd/usos-installer
    if ($LASTEXITCODE -ne 0) { throw "build USOS Installer.exe failed: $LASTEXITCODE" }
    # The existing Windows-base bootstrap invokes this fixed filename and CLI.
    # Build the local-update E2E command under that filename; no Windows base mutation is needed.
    & go.exe build -trimpath -o $updateExe ./cmd/usos-localupdate-qemu-e2e
    if ($LASTEXITCODE -ne 0) { throw "build usos-localupdate-qemu-e2e failed: $LASTEXITCODE" }
} finally { Pop-Location }

# Fresh overlays: neither the verified Windows base nor the production USOS base is modified.
Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null
Remove-Item -LiteralPath $windowsOverlay,$targetOverlay,$configVhd,$varsPath,$windowsErr,$windowsSerial,$seaSerial,$seaErr -Force -ErrorAction SilentlyContinue
& $qemuImg create -f qcow2 -F vpc -b $windowsBase $windowsOverlay | Out-Null
if ($LASTEXITCODE -ne 0) { throw "create Windows overlay failed: $LASTEXITCODE" }
& $qemuImg create -f qcow2 -F qcow2 -b $productionBase $targetOverlay | Out-Null
if ($LASTEXITCODE -ne 0) { throw "create production USOS overlay failed: $LASTEXITCODE" }
Copy-Item -LiteralPath $ovmfVarsSource -Destination $varsPath -Force

# Config VHD consumed by the immutable bootstrap already present in the Windows base.
& $qemuImg create -f vpc -o subformat=fixed $configVhd 256M | Out-Null
if ($LASTEXITCODE -ne 0) { throw "create config VHD failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $configVhd 0 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "clear config VHD sparse flag failed: $LASTEXITCODE" }
$mountedConfig = $false
Remove-Item -LiteralPath $configMount -Recurse -Force -ErrorAction SilentlyContinue
try {
    Mount-DiskImage -ImagePath $configVhd -StorageType VHD -NoDriveLetter | Out-Null
    $mountedConfig = $true
    $configDisk = Get-DiskImage -ImagePath $configVhd | Get-Disk
    Initialize-Disk -Number $configDisk.Number -PartitionStyle MBR | Out-Null
    $part = New-Partition -DiskNumber $configDisk.Number -UseMaximumSize
    $part | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_CONFIG' -Force -Confirm:$false | Out-Null
    New-Item -ItemType Directory -Force -Path $configMount | Out-Null
    $part | Add-PartitionAccessPath -AccessPath $configMount | Out-Null
    Copy-Item -LiteralPath $tagSource -Destination (Join-Path $configMount 'USOS_QEMU_TEST.TAG') -Force
    Copy-Item -LiteralPath $installer -Destination (Join-Path $configMount 'USOS Installer.exe') -Force
    Copy-Item -LiteralPath $updateExe -Destination (Join-Path $configMount 'usos-installer-qemu-e2e.exe') -Force
    $part | Remove-PartitionAccessPath -AccessPath $configMount -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $configMount -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    if ($mountedConfig) { Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item -LiteralPath $configMount -Recurse -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

# Hard preflight: the config disk must survive a complete dismount/remount before QEMU sees it.
$raw = [IO.File]::Open($configVhd,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
try {
    $mbr = New-Object byte[] 512
    [void]$raw.Read($mbr,0,512)
    if ($mbr[510] -ne 0x55 -or $mbr[511] -ne 0xAA) { throw 'config VHD MBR signature missing before QEMU' }
} finally { $raw.Dispose() }
$preflightMounted = $false
try {
    Mount-DiskImage -ImagePath $configVhd -StorageType VHD -Access ReadOnly -NoDriveLetter | Out-Null
    $preflightMounted = $true
    Start-Sleep -Milliseconds 300
    $preflightDisk = Get-DiskImage -ImagePath $configVhd | Get-Disk
    $preflightVolume = $null
    foreach ($partition in @(Get-Partition -DiskNumber $preflightDisk.Number)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -ne $volume -and $volume.FileSystemLabel -eq 'USOS_CONFIG') { $preflightVolume = $volume; break }
    }
    if ($null -eq $preflightVolume -or [string]::IsNullOrWhiteSpace($preflightVolume.Path)) { throw 'config VHD preflight cannot find USOS_CONFIG' }
    foreach ($name in @('USOS_QEMU_TEST.TAG','USOS Installer.exe','usos-installer-qemu-e2e.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $preflightVolume.Path $name) -PathType Leaf)) { throw "config VHD preflight missing $name" }
    }
    Write-Host '[PASS] config VHD survives dismount/remount with tag and both executables'
} finally {
    if ($preflightMounted) { Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null }
}

$windowsMonitor = Get-FreeTcpPort
$windowsArgs = @(
    '-machine','q35', '-accel','tcg,thread=multi', '-cpu','max', '-m','4096', '-smp','4',
    '-nic','none', '-display','none', '-rtc','base=localtime',
    '-monitor',"tcp:127.0.0.1:$windowsMonitor,server=on,wait=off",
    '-serial',"file:$($windowsSerial.Replace('\','/'))",
    '-drive',"if=pflash,format=raw,readonly=on,file=$ovmfCode",
    '-drive',"if=pflash,format=raw,file=$varsPath",
    '-drive',"if=none,id=os,file=$windowsOverlay,format=qcow2,cache=unsafe",
    '-device','ide-hd,bus=ide.0,drive=os,bootindex=1',
    '-device','qemu-xhci,id=xhci',
    '-drive',"if=none,id=usostarget,file=$targetOverlay,format=qcow2,cache=writeback",
    '-device','usb-storage,bus=xhci.0,drive=usostarget,removable=on,serial=USOS-GPT-TEST',
    '-drive',"if=none,id=usoscfg,file=$configVhd,format=vpc,cache=writeback",
    '-device','usb-storage,bus=xhci.0,drive=usoscfg,removable=on,serial=USOS-CONFIG'
)
Write-Host '[INFO] Running production localupdate.Engine inside full Windows QEMU...'
$windowsProcess = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $windowsArgs) -PassThru -RedirectStandardError $windowsErr
$deadline = [DateTime]::UtcNow.AddSeconds($WindowsTimeoutSeconds)
$artifactFull = [IO.Path]::GetFullPath($artifactDir)
while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 2
    $activeWindowsQemu = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.Contains($artifactFull)
    })
    if ($activeWindowsQemu.Count -eq 0) {
        Start-Sleep -Seconds 2
        $activeWindowsQemu = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains($artifactFull)
        })
        if ($activeWindowsQemu.Count -eq 0) { break }
    }
}
$activeWindowsQemu = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($artifactFull)
})
if ($activeWindowsQemu.Count -gt 0) {
    foreach ($proc in $activeWindowsQemu) { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
    throw "Windows local-update QEMU timed out after $WindowsTimeoutSeconds seconds"
}
Start-Sleep -Seconds 1
$result = Read-ConfigResult $configVhd
if ([string]::IsNullOrWhiteSpace($result)) { throw "Windows local-update QEMU produced no result file. stderr=$windowsErr" }
Write-Host $result
if ($result -notmatch 'RESULT=PASS') { throw 'Production localupdate.Engine inside Windows QEMU reported FAIL' }
& $qemuImg check $targetOverlay | Out-Null
if ($LASTEXITCODE -ne 0) { throw "updated production target failed qemu-img check: $LASTEXITCODE" }
Write-Host '[PASS] production layout updated through normal removable-device localupdate.Engine'

# Boot the exact updated production overlay under SeaBIOS with Cirrus VGA. Cirrus exposes VBE but no 32-bit LFB,
# so this deliberately exercises the production VESA-2 -> VGA text fallback and the direct PM32 8042 menu path.
$seaMonitor = Get-FreeTcpPort
$seaArgs = @(
    '-name','USOS-Legacy-Production-Menu', '-machine','pc', '-accel','tcg,thread=multi', '-cpu','max',
    '-m','128M', '-smp','1', '-bios',$seabios, '-boot','order=c,strict=on', '-display','none', '-vga','cirrus', '-nic','none',
    '-monitor',"tcp:127.0.0.1:$seaMonitor,server=on,wait=off",
    '-serial',"file:$($seaSerial.Replace('\','/'))",
    '-drive',"if=ide,format=qcow2,file=$targetOverlay", '-no-reboot'
)
$seaProcess = Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $seaArgs) -PassThru -RedirectStandardError $seaErr
try {
    if (-not (Wait-SerialOccurrence $seaSerial 'CATEGORIES' 1 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS did not reach category menu.`n$(Read-SharedText $seaSerial)"
    }
    $beforeDiagnostics = Read-SharedText $seaSerial
    if ($beforeDiagnostics.Contains('ROOT DIRECTORY:') -or $beforeDiagnostics.Contains('EFI DIRECTORY:')) {
        throw 'diagnostic directory listing leaked into normal startup'
    }
    foreach ($marker in @('KBD LIVE POLL CALLS:', 'SCANCODES READ:', 'RAW TAIL:', 'MENU EVENTS:', 'INT13 READS:')) {
        if ($beforeDiagnostics.Contains($marker)) {
            throw "keyboard/service diagnostics leaked into normal category screen: $marker"
        }
    }

    # D from the first screen is deliberately before discovery. This must be 0/0,
    # and ESC must return through the same direct 8042 path instead of trapping the user.
    Send-Hmp $seaMonitor 'sendkey d'
    if (-not (Wait-SerialOccurrence $seaSerial 'USOS LEGACY BIOS DIAGNOSTICS' 1 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS D diagnostics did not open from categories.`n$(Read-SharedText $seaSerial)"
    }
    $categoryDiagnostics = Read-SharedText $seaSerial
    if (-not $categoryDiagnostics.Contains('DISCOVERY CACHE HITS/MISSES: 0/0')) {
        throw "SeaBIOS category diagnostics did not capture pre-discovery cache 0/0.`n$categoryDiagnostics"
    }
    if (-not $categoryDiagnostics.Contains('A20 POLICY: FAST 0x92 ONLY; INT15/8042 A20 DISABLED')) {
        throw "SeaBIOS diagnostics did not expose the Fast A20-only policy.`n$categoryDiagnostics"
    }
    if (-not $categoryDiagnostics.Contains('8042: keyboard polling; AUX mouse enable/defaults/streaming only')) {
        throw "SeaBIOS diagnostics did not report the keyboard/mouse controller policy.`n$categoryDiagnostics"
    }
    if ($categoryDiagnostics -notmatch 'KBD LIVE POLL CALLS: [1-9][0-9]*   LAST STATUS: 0x[0-9A-F]{2}') {
        throw "SeaBIOS category diagnostics did not expose live 8042 poll telemetry.`n$categoryDiagnostics"
    }
    if ($categoryDiagnostics -notmatch 'SCANCODES READ: [1-9][0-9]*') {
        throw "SeaBIOS category diagnostics did not expose raw 8042 scancode telemetry.`n$categoryDiagnostics"
    }
    Send-Hmp $seaMonitor 'sendkey esc'
    if (-not (Wait-SerialOccurrence $seaSerial 'CATEGORIES' 2 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS ESC did not return from diagnostics to categories.`n$(Read-SharedText $seaSerial)"
    }

    # Enter the Windows submenu. The real hardware regression happened after these
    # FAT32/INT13 reads, so immediately exercise D -> ESC and submenu -> ESC here.
    Send-Hmp $seaMonitor 'sendkey ret'
    if (-not (Wait-SerialOccurrence $seaSerial 'FIRMWARE: BIOS   CATEGORY: Windows' 1 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS did not render real Windows systems.`n$(Read-SharedText $seaSerial)"
    }
    $systemsAll = Read-SharedText $seaSerial
    $systemsMarker = 'FIRMWARE: BIOS   CATEGORY: Windows'
    $systemsStart = $systemsAll.LastIndexOf($systemsMarker)
    if ($systemsStart -lt 0) { throw "SeaBIOS Windows submenu marker disappeared.`n$systemsAll" }
    $systemsText = $systemsAll.Substring($systemsStart)
    if (-not $systemsText.Contains('Windows 11 [images=')) {
        throw "SeaBIOS Windows submenu did not contain Windows 11 media status.`n$systemsText"
    }
    foreach ($marker in @('KBD LIVE POLL CALLS:', 'SCANCODES READ:', 'RAW TAIL:', 'MENU EVENTS:', 'INT13 READS:')) {
        if ($systemsText.Contains($marker)) {
            throw "keyboard/service diagnostics leaked into normal Windows submenu: $marker`n$systemsText"
        }
    }

    Send-Hmp $seaMonitor 'sendkey d'
    if (-not (Wait-SerialOccurrence $seaSerial 'USOS LEGACY BIOS DIAGNOSTICS' 2 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS D diagnostics did not open from Windows submenu.`n$(Read-SharedText $seaSerial)"
    }
    $postDiscoveryDiagnostics = Read-SharedText $seaSerial
    if (-not $postDiscoveryDiagnostics.Contains('DISCOVERY CACHE HITS/MISSES: 14/14')) {
        throw "SeaBIOS post-discovery diagnostics did not contain expected first-pass cache 14/14.`n$postDiscoveryDiagnostics"
    }
    if ($postDiscoveryDiagnostics -notmatch 'INT13 READS: [1-9][0-9]*   8042 BEFORE/AFTER: 0x[0-9A-F]{2}/0x[0-9A-F]{2}') {
        throw "SeaBIOS D diagnostics did not expose INT13/8042 transition telemetry.`n$postDiscoveryDiagnostics"
    }
    if ($postDiscoveryDiagnostics -notmatch 'MENU EVENTS: [1-9][0-9]*   LAST MENU EVENT: DIAGNOSTICS') {
        throw "SeaBIOS D diagnostics did not expose menu-event telemetry.`n$postDiscoveryDiagnostics"
    }
    Send-Hmp $seaMonitor 'sendkey esc'
    if (-not (Wait-SerialOccurrence $seaSerial 'FIRMWARE: BIOS   CATEGORY: Windows' 2 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS ESC did not return from diagnostics to Windows submenu.`n$(Read-SharedText $seaSerial)"
    }

    # Missing media is navigable, not skipped. Windows 10 has no image in this
    # fixture, so Down must visibly select it and Enter must explain where to copy one.
    Send-Hmp $seaMonitor 'sendkey down'
    if (-not (Wait-SerialOccurrence $seaSerial '> Windows 10 [no image]' 1 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS skipped the navigable Windows 10 [no image] row.`n$(Read-SharedText $seaSerial)"
    }
    Send-Hmp $seaMonitor 'sendkey ret'
    if (-not (Wait-SerialOccurrence $seaSerial 'NO IMAGES: Windows 10' 1 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS Enter on [no image] did not show the missing-image notice.`n$(Read-SharedText $seaSerial)"
    }
    $missingImageText = Read-SharedText $seaSerial
    if (-not $missingImageText.Contains('Systems\Windows\Windows 10\Images')) {
        throw "SeaBIOS missing-image notice did not show the exact target path.`n$missingImageText"
    }
    Send-Hmp $seaMonitor 'sendkey esc'
    if (-not (Wait-SerialOccurrence $seaSerial 'FIRMWARE: BIOS   CATEGORY: Windows' 3 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS ESC did not return from missing-image notice to Windows submenu.`n$(Read-SharedText $seaSerial)"
    }

    Send-Hmp $seaMonitor 'sendkey esc'
    if (-not (Wait-SerialOccurrence $seaSerial 'CATEGORIES' 3 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS ESC did not return from Windows submenu to categories.`n$(Read-SharedText $seaSerial)"
    }

    # Re-enter and verify the image screen, then verify ESC from that nested screen.
    Send-Hmp $seaMonitor 'sendkey ret'
    if (-not (Wait-SerialOccurrence $seaSerial 'FIRMWARE: BIOS   CATEGORY: Windows' 3 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS did not re-enter Windows submenu.`n$(Read-SharedText $seaSerial)"
    }
    Send-Hmp $seaMonitor 'sendkey ret'
    if (-not (Wait-SerialOccurrence $seaSerial 'IMAGES: Windows 11' 1 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS did not render production Windows 11 image metadata.`n$(Read-SharedText $seaSerial)"
    }
    $imagesText = Read-SharedText $seaSerial
    if (-not $imagesText.Contains('Win11_25H2_Polish_x64_v2.iso')) {
        throw "SeaBIOS image screen did not contain Win11_25H2_Polish_x64_v2.iso.`n$imagesText"
    }
    Send-Hmp $seaMonitor 'sendkey esc'
    if (-not (Wait-SerialOccurrence $seaSerial 'FIRMWARE: BIOS   CATEGORY: Windows' 4 $seaProcess $SeaBiosTimeoutSeconds)) {
        throw "SeaBIOS ESC did not return from image screen to Windows submenu.`n$(Read-SharedText $seaSerial)"
    }

    $serialText = Read-SharedText $seaSerial
    Write-Host $serialText
    Write-Host '[PASS] SeaBIOS production menu keyboard regression: categories <-> diagnostics, Windows submenu <-> diagnostics, submenu -> categories, images -> submenu.'
} finally {
    if (-not $seaProcess.HasExited) {
        Stop-Process -Id $seaProcess.Id -Force -ErrorAction SilentlyContinue
        $seaProcess.WaitForExit()
    }
}

Write-Host "[PASS] production menu target overlay: $targetOverlay"
