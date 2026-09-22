param(
    [ValidateSet('tcg','whpx','auto')]
    [string]$Accel = 'tcg',
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

if ($TimeoutMinutes -lt 1) { throw 'TimeoutMinutes must be at least 1.' }

$configDir = Full 'tools/tests/artifacts/qemu/usos-installer-full-config'
$configVhd = Full 'tools/tests/artifacts/qemu/usos-installer-full-config.vhd'
$startScript = Full 'tools/start_installer_full_qemu.ps1'
$screenshotPpm = Join-Path $configDir 'timeout-screen.ppm'
$screenshotPng = Join-Path $configDir 'timeout-screen.png'
$resultName = 'usos-installer-e2e-result.txt'
$bootstrapFailure = 'C:\USOS_TEST\bootstrap-failed.txt'

function Send-Hmp([int]$Port, [string]$Command) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $writer = [IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine($Command)
        Start-Sleep -Milliseconds 500
    } finally {
        $client.Dispose()
    }
}

function Read-ConfigResult([string]$ImagePath) {
    $mounted = $null
    try {
        Dismount-DiskImage -ImagePath $ImagePath -StorageType VHD -ErrorAction SilentlyContinue | Out-Null
        $mounted = Mount-DiskImage -ImagePath $ImagePath -StorageType VHD -Access ReadOnly -NoDriveLetter -PassThru
        Start-Sleep -Milliseconds 300
        $disk = $mounted | Get-Disk
        if ($null -eq $disk) { throw 'config VHD did not expose a disk after QEMU exit' }
        foreach ($part in @(Get-Partition -DiskNumber $disk.Number)) {
            $volume = $part | Get-Volume -ErrorAction SilentlyContinue
            if ($null -eq $volume -or [string]::IsNullOrWhiteSpace($volume.Path)) { continue }
            $resultPath = Join-Path $volume.Path $resultName
            if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                return Get-Content -LiteralPath $resultPath -Raw
            }
        }
        return $null
    } finally {
        if ($null -ne $mounted) {
            Dismount-DiskImage -InputObject $mounted -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

Write-Host "[INFO] Full installer E2E timeout: $TimeoutMinutes minutes"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript -Accel $Accel
if ($LASTEXITCODE -ne 0) { throw "start_installer_full_qemu.ps1 failed: $LASTEXITCODE" }

$pidPath = Join-Path $configDir 'qemu.pid'
$monitorPath = Join-Path $configDir 'monitor.port'
if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { throw "QEMU PID file missing: $pidPath" }
if (-not (Test-Path -LiteralPath $monitorPath -PathType Leaf)) { throw "QEMU monitor port file missing: $monitorPath" }

$qemuPid = [int](Get-Content -LiteralPath $pidPath -Raw)
$monitorPort = [int](Get-Content -LiteralPath $monitorPath -Raw)
$started = [DateTime]::UtcNow
$deadline = $started.AddMinutes($TimeoutMinutes)
Write-Host "[INFO] Waiting for QEMU PID=$qemuPid until $($deadline.ToString('o'))"

$timedOut = $false
while ($true) {
    $process = Get-Process -Id $qemuPid -ErrorAction SilentlyContinue
    if ($null -eq $process) { break }
    if ([DateTime]::UtcNow -ge $deadline) {
        $timedOut = $true
        break
    }
    Start-Sleep -Seconds 2
}

if ($timedOut) {
    Write-Host "[FAIL] Full installer E2E timed out after $TimeoutMinutes minutes. Capturing QEMU screen."
    Remove-Item -LiteralPath $screenshotPpm,$screenshotPng -Force -ErrorAction SilentlyContinue
    try {
        Send-Hmp -Port $monitorPort -Command ("screendump " + $screenshotPpm.Replace('\\','/'))
        $png = Wait-AndConvert-QemuPpmToPng -PpmPath $screenshotPpm -RemovePpm
        Write-Host "TIMEOUT_SCREEN=$png"
    } catch {
        Write-Host "[WARN] Screenshot capture failed: $($_.Exception.Message)"
    }
    $process = Get-Process -Id $qemuPid -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        Stop-Process -Id $qemuPid -Force
        $process.WaitForExit()
    }
    throw "Full installer E2E timed out after $TimeoutMinutes minutes"
}

$result = Read-ConfigResult -ImagePath $configVhd
if ([string]::IsNullOrWhiteSpace($result)) {
    throw 'QEMU exited without usos-installer-e2e-result.txt on config VHD'
}

Write-Host $result
if ($result -notmatch 'RESULT=PASS') {
    throw 'Full installer E2E reported FAIL'
}
Write-Host '[PASS] Full installer E2E RESULT=PASS'
