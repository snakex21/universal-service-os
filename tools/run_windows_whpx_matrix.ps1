param(
    [string]$BasePath = 'tools/tests/artifacts/qemu/usos-installer-windows-base.vhd',
    [string]$QemuPath = 'tools/qemu/qemu-system-x86_64.exe',
    [string]$QemuImgPath = 'tools/qemu/qemu-img.exe',
    [int]$TimeoutMinutes = 12,
    [ValidateRange(0,4)]
    [int]$StartIndex = 0
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
    } finally {
        $client.Dispose()
    }
}

$BasePath = Full $BasePath
$QemuPath = Full $QemuPath
$QemuImgPath = Full $QemuImgPath
$firmwareCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVars = Full 'tools/qemu/share/edk2-i386-vars.fd'
$tagSource = Full 'tools/tests/fixtures/installer/winpe-gpt-qemu/USOS_QEMU_TEST.TAG'
$artifactRoot = Full 'tools/tests/artifacts/qemu/whpx-windows-matrix'
$installerDir = Full 'installer'
foreach ($required in @($BasePath,$QemuPath,$QemuImgPath,$firmwareCode,$firmwareVars,$tagSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
$probeExe = Join-Path $artifactRoot 'usos-windows-boot-probe.exe'
Push-Location $installerDir
try {
    & go.exe build -trimpath -o $probeExe ./cmd/usos-windows-boot-probe
    if ($LASTEXITCODE -ne 0) { throw "go build boot probe failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

$baseInfo = (& $QemuImgPath info --output=json $BasePath | Out-String | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($baseInfo.format)) { throw 'qemu-img info failed for Windows base' }

$cases = @(
    [pscustomobject]@{ Name='qemu64'; CPU='qemu64'; Machine='q35'; SeparateAccel=$true },
    [pscustomobject]@{ Name='qemu64-no-xsave'; CPU='qemu64,-xsave'; Machine='q35'; SeparateAccel=$true },
    [pscustomobject]@{ Name='skylake-client-v4'; CPU='Skylake-Client-v4'; Machine='q35'; SeparateAccel=$true },
    [pscustomobject]@{ Name='host'; CPU='host'; Machine='q35'; SeparateAccel=$true },
    [pscustomobject]@{ Name='machine-q35-accel-whpx'; CPU='qemu64,-xsave'; Machine='q35,accel=whpx'; SeparateAccel=$false }
)
$results = @()
$selectedCases = @($cases[$StartIndex..($cases.Count-1)])
foreach ($case in $selectedCases) {
    $caseDir = Join-Path $artifactRoot $case.Name
    $overlay = Join-Path $caseDir 'windows-overlay.qcow2'
    $configVhd = Join-Path $caseDir 'config.vhd'
    $varsCopy = Join-Path $caseDir 'edk2-vars.fd'
    $serial = Join-Path $caseDir 'serial.log'
    $stderr = Join-Path $caseDir 'qemu.stderr.log'
    $stdout = Join-Path $caseDir 'qemu.stdout.log'
    $screenPpm = Join-Path $caseDir 'timeout-screen.ppm'
    $screenPng = [IO.Path]::ChangeExtension($screenPpm, '.png')
    Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path -LiteralPath $caseDir) { Remove-Item -LiteralPath $caseDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
    Copy-Item -LiteralPath $firmwareVars -Destination $varsCopy -Force

    & $QemuImgPath create -f qcow2 -F $baseInfo.format -b $BasePath $overlay | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "create overlay failed for $($case.Name): $LASTEXITCODE" }
    & $QemuImgPath check $overlay | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "check overlay failed for $($case.Name): $LASTEXITCODE" }
    & $QemuImgPath create -f vpc -o subformat=fixed $configVhd 256M | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "create config VHD failed for $($case.Name): $LASTEXITCODE" }
    & fsutil.exe sparse setflag $configVhd 0 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "clear sparse flag failed for $($case.Name): $LASTEXITCODE" }
    $mounted = $false
    try {
        Mount-DiskImage -ImagePath $configVhd -StorageType VHD -NoDriveLetter | Out-Null
        $mounted = $true
        $disk = Get-DiskImage -ImagePath $configVhd | Get-Disk
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR | Out-Null
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        $part | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_CONFIG' -Force -Confirm:$false | Out-Null
        $rootPath = "$($part.DriveLetter):\"
        Copy-Item -LiteralPath $tagSource -Destination (Join-Path $rootPath 'USOS_QEMU_TEST.TAG') -Force
        Copy-Item -LiteralPath $probeExe -Destination (Join-Path $rootPath 'usos-installer-qemu-e2e.exe') -Force
    } finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null }
    }

    $port = Get-FreeTcpPort
    $args = @(
        '-machine',$case.Machine,
        '-cpu',$case.CPU,
        '-m','4096',
        '-smp','4',
        '-nic','none',
        '-display','none',
        '-rtc','base=localtime',
        '-monitor',"tcp:127.0.0.1:$port,server=on,wait=off",
        '-serial',"file:$($serial.Replace('\','/'))",
        '-drive',"if=pflash,format=raw,readonly=on,file=$firmwareCode",
        '-drive',"if=pflash,format=raw,file=$varsCopy",
        '-drive',"if=none,id=os,file=$overlay,format=qcow2,cache=unsafe",
        '-device','ide-hd,bus=ide.0,drive=os,bootindex=1',
        '-device','qemu-xhci,id=xhci',
        '-drive',"if=none,id=usoscfg,file=$configVhd,format=vpc,cache=unsafe",
        '-device','usb-storage,bus=xhci.0,drive=usoscfg,removable=on,serial=USOS-CONFIG'
    )
    if ($case.SeparateAccel) {
        $args = @('-machine',$case.Machine,'-accel','whpx') + $args[2..($args.Count-1)]
    }
    $started = [DateTime]::UtcNow
    Write-Host "[TEST] WHPX $($case.Name) cpu=$($case.CPU) machine=$($case.Machine)"
    $process = Start-Process -FilePath $QemuPath -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -RedirectStandardError $stderr -RedirectStandardOutput $stdout
    $deadline = $started.AddMinutes($TimeoutMinutes)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        $process.Refresh()
    }
    $timedOut = -not $process.HasExited
    if ($timedOut) {
        try {
            Send-Hmp $port "screendump $($screenPpm.Replace('\','/'))"
            Wait-AndConvert-QemuPpmToPng -PpmPath $screenPpm -RemovePpm | Out-Null
        } catch {
            Write-Host "[WARN] screenshot failed for $($case.Name): $($_.Exception.Message)"
        }
        $process.Kill()
    }
    $process.WaitForExit()
    $elapsed = [DateTime]::UtcNow - $started
    $bootPass = $false
    $resultText = ''
    $mounted = $false
    try {
        Mount-DiskImage -ImagePath $configVhd -StorageType VHD -NoDriveLetter | Out-Null
        $mounted = $true
        $disk = Get-DiskImage -ImagePath $configVhd | Get-Disk
        $part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 0 } | Select-Object -First 1
        if (-not $part.AccessPaths -or $part.AccessPaths.Count -eq 0) {
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AssignDriveLetter | Out-Null
            $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
        }
        $access = @($part.AccessPaths | Where-Object { $_ -like '\\?\Volume*' })[0]
        if (-not $access) { $access = "$($part.DriveLetter):\" }
        $resultFile = Join-Path $access 'usos-installer-e2e-result.txt'
        if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
            $resultText = Get-Content -LiteralPath $resultFile -Raw
            $bootPass = $resultText -match 'BOOT_PROBE=PASS'
        }
    } finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $configVhd -StorageType VHD -ErrorAction SilentlyContinue | Out-Null }
    }
    $status = if ($bootPass) { 'PASS' } elseif ($timedOut) { 'TIMEOUT' } else { 'EXIT_NO_PROBE' }
    $results += [pscustomobject]@{
        Case=$case.Name
        CPU=$case.CPU
        Machine=$case.Machine
        Status=$status
        Seconds=[math]::Round($elapsed.TotalSeconds,1)
        ExitCode=$process.ExitCode
        Screenshot=if (Test-Path -LiteralPath $screenPng) { $screenPng } else { '' }
        Stderr=$stderr
    }
    Write-Host "[$status] $($case.Name) seconds=$([math]::Round($elapsed.TotalSeconds,1)) exit=$($process.ExitCode) screenshot=$screenPng"
}
$csv = Join-Path $artifactRoot 'results.csv'
$results | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
$results | Format-Table -AutoSize
Write-Host "RESULTS=$csv"
