param(
    [string]$WindowsBase = 'tools/tests/artifacts/qemu/usos-installer-windows-base.vhd',
    [string]$InstalledTargetBase = 'tools/tests/artifacts/qemu/usos-installer-full-target.qcow2',
    [ValidateSet('tcg','whpx')]
    [string]$Accel = 'tcg',
    [string]$WhpxCPU = 'qemu64,-xsave',
    [int]$TimeoutMinutes = 90
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'process_argument_line.ps1')
. (Join-Path $PSScriptRoot 'qemu_harness.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}
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
        $writer = [IO.StreamWriter]::new($client.GetStream())
        $writer.AutoFlush = $true
        $writer.WriteLine($Command)
        Start-Sleep -Milliseconds 500
    } finally { $client.Dispose() }
}
function Read-ConfigResult([string]$ImagePath) {
    $mounted = $null
    try {
        Dismount-DiskImage -ImagePath $ImagePath -StorageType VHD -ErrorAction SilentlyContinue | Out-Null
        $mounted = Mount-DiskImage -ImagePath $ImagePath -StorageType VHD -Access ReadOnly -NoDriveLetter -PassThru
        Start-Sleep -Milliseconds 300
        $disk = $mounted | Get-Disk
        foreach ($part in @(Get-Partition -DiskNumber $disk.Number)) {
            $vol = $part | Get-Volume -ErrorAction SilentlyContinue
            if ($null -eq $vol -or [string]::IsNullOrWhiteSpace($vol.Path)) { continue }
            $candidate = Join-Path $vol.Path 'usos-installer-e2e-result.txt'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return Get-Content -LiteralPath $candidate -Raw }
        }
        return $null
    } finally {
        if ($null -ne $mounted) { Dismount-DiskImage -InputObject $mounted -ErrorAction SilentlyContinue | Out-Null }
    }
}

$WindowsBase = Full $WindowsBase
$InstalledTargetBase = Full $InstalledTargetBase
$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$firmwareCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVars = Full 'tools/qemu/share/edk2-i386-vars.fd'
$tagSource = Full 'tools/tests/fixtures/installer/winpe-gpt-qemu/USOS_QEMU_TEST.TAG'
$artifactDir = Full 'tools/tests/artifacts/qemu/legacy-update-cycle'
$windowsOverlay = Join-Path $artifactDir 'windows-overlay.qcow2'
$targetOverlay = Join-Path $artifactDir 'target-overlay.qcow2'
$configVhd = Join-Path $artifactDir 'config.vhd'
$varsCopy = Join-Path $artifactDir 'edk2-vars.fd'
$serial = Join-Path $artifactDir 'serial.log'
$stderr = Join-Path $artifactDir 'qemu.stderr.log'
$stdout = Join-Path $artifactDir 'qemu.stdout.log'
$screenPpm = Join-Path $artifactDir 'timeout-screen.ppm'
$installerDir = Full 'installer'
foreach ($required in @($WindowsBase,$InstalledTargetBase,$qemu,$qemuImg,$firmwareCode,$firmwareVars,$tagSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
& $qemuImg check $InstalledTargetBase | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Installed target base qemu-img check failed: $LASTEXITCODE" }

$active = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($artifactDir) })
if ($active.Count -gt 0) { throw "Legacy update cycle QEMU already running: PID=$($active[0].ProcessId)" }
Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null
if (Test-Path -LiteralPath $artifactDir) { Remove-Item -LiteralPath $artifactDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Copy-Item -LiteralPath $firmwareVars -Destination $varsCopy -Force

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/build_legacy_bios.ps1')
if ($LASTEXITCODE -ne 0) { throw "Legacy BIOS build failed: $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/generate_legacy_boot_payload.ps1')
if ($LASTEXITCODE -ne 0) { throw "Legacy payload generation failed: $LASTEXITCODE" }

$installerExe = Join-Path $artifactDir 'USOS Installer.exe'
$cycleExe = Join-Path $artifactDir 'usos-installer-qemu-e2e.exe'
Push-Location $installerDir
try {
    & go.exe build -trimpath -ldflags '-H=windowsgui' -o $installerExe ./cmd/usos-installer
    if ($LASTEXITCODE -ne 0) { throw "build installer failed: $LASTEXITCODE" }
    & go.exe build -trimpath -o $cycleExe ./cmd/usos-legacy-update-cycle-qemu-e2e
    if ($LASTEXITCODE -ne 0) { throw "build update-cycle E2E failed: $LASTEXITCODE" }
} finally { Pop-Location }

& $qemuImg create -f vpc -o subformat=fixed $configVhd 512M | Out-Null
if ($LASTEXITCODE -ne 0) { throw "create config VHD failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $configVhd 0 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "clear config sparse flag failed: $LASTEXITCODE" }
$mounted = $false
try {
    Mount-DiskImage -ImagePath $configVhd -StorageType VHD -NoDriveLetter | Out-Null
    $mounted = $true
    $disk = Get-DiskImage -ImagePath $configVhd | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR | Out-Null
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    $part | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_CONFIG' -Force -Confirm:$false | Out-Null
    $cfgRoot = "$($part.DriveLetter):\"
    Copy-Item -LiteralPath $tagSource -Destination (Join-Path $cfgRoot 'USOS_QEMU_TEST.TAG') -Force
    Copy-Item -LiteralPath $installerExe -Destination (Join-Path $cfgRoot 'USOS Installer.exe') -Force
    Copy-Item -LiteralPath $cycleExe -Destination (Join-Path $cfgRoot 'usos-installer-qemu-e2e.exe') -Force
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null }
}

$winInfo = (& $qemuImg info --output=json $WindowsBase | Out-String | ConvertFrom-Json)
& $qemuImg create -f qcow2 -F $winInfo.format -b $WindowsBase $windowsOverlay | Out-Null
if ($LASTEXITCODE -ne 0) { throw "create Windows overlay failed: $LASTEXITCODE" }
& $qemuImg check $windowsOverlay | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Windows overlay check failed: $LASTEXITCODE" }
& $qemuImg create -f qcow2 -F qcow2 -b $InstalledTargetBase $targetOverlay | Out-Null
if ($LASTEXITCODE -ne 0) { throw "create target overlay failed: $LASTEXITCODE" }
& $qemuImg check $targetOverlay | Out-Host
if ($LASTEXITCODE -ne 0) { throw "target overlay check failed: $LASTEXITCODE" }

$port = Get-FreeTcpPort
$cpu = if ($Accel -eq 'whpx') { $WhpxCPU } else { 'max' }
$accelArg = if ($Accel -eq 'whpx') { 'whpx' } else { 'tcg,thread=multi' }
$args = @(
    '-machine','q35','-accel',$accelArg,'-cpu',$cpu,
    '-m','4096','-smp','4','-nic','none','-display','none','-rtc','base=localtime',
    '-monitor',"tcp:127.0.0.1:$port,server=on,wait=off",
    '-serial',"file:$($serial.Replace('\','/'))",
    '-drive',"if=pflash,format=raw,readonly=on,file=$firmwareCode",
    '-drive',"if=pflash,format=raw,file=$varsCopy",
    '-drive',"if=none,id=os,file=$windowsOverlay,format=qcow2,cache=unsafe",
    '-device','ide-hd,bus=ide.0,drive=os,bootindex=1',
    '-device','qemu-xhci,id=xhci',
    '-drive',"if=none,id=usostarget,file=$targetOverlay,format=qcow2,cache=unsafe",
    '-device','usb-storage,bus=xhci.0,drive=usostarget,removable=on,serial=USOS-GPT-TEST',
    '-drive',"if=none,id=usoscfg,file=$configVhd,format=vpc,cache=unsafe",
    '-device','usb-storage,bus=xhci.0,drive=usoscfg,removable=on,serial=USOS-CONFIG'
)
Write-Host "[INFO] Legacy update cycle accel=$accelArg cpu=$cpu timeout=${TimeoutMinutes}m"
$started=[DateTime]::UtcNow
$process=Start-Process -FilePath $qemu -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr -RedirectStandardOutput $stdout
$deadline=$started.AddMinutes($TimeoutMinutes)
while(-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline){ Start-Sleep -Seconds 2; $process.Refresh() }
if(-not $process.HasExited){
    try {
        Send-Hmp $port ("screendump " + $screenPpm.Replace('\','/'))
        $png=Wait-AndConvert-QemuPpmToPng -PpmPath $screenPpm -RemovePpm
        Write-Host "TIMEOUT_SCREEN=$png"
    } catch { Write-Host "[WARN] screenshot failed: $($_.Exception.Message)" }
    $process.Kill(); $process.WaitForExit()
    throw "Legacy update cycle timed out after $TimeoutMinutes minutes"
}
$result=Read-ConfigResult $configVhd
if([string]::IsNullOrWhiteSpace($result)){ throw 'QEMU exited without update-cycle result file' }
Write-Host $result
if($result -notmatch 'RESULT=PASS'){ throw 'Legacy update cycle reported FAIL' }
& $qemuImg check $targetOverlay | Out-Host
if($LASTEXITCODE -ne 0){ throw "target overlay qemu-img check failed after cycle: $LASTEXITCODE" }
Write-Host "[PASS] Legacy update -> clear -> update cycle PASS in $([math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,1)) seconds"
