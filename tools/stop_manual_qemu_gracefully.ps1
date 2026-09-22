param(
    [int]$TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runDir = [IO.Path]::GetFullPath((Join-Path $root 'tools/tests/artifacts/qemu/usos-manual-run'))
$pidFile = Join-Path $runDir 'qemu.pid'
$qmpFile = Join-Path $runDir 'qmp.port'
$invalidMarker = Join-Path $runDir 'phase-b-invalid.txt'

if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 60) { throw 'TimeoutSeconds must be in range 1..60' }
foreach ($required in @($pidFile, $qmpFile)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing QEMU control file: $required" }
}

$pidValue = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
$qmpPort = [int](Get-Content -LiteralPath $qmpFile -Raw).Trim()
$process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
if ($null -eq $process) { throw "QEMU process is not running: PID=$pidValue" }

function Read-QmpLine([IO.StreamReader]$Reader, [Net.Sockets.NetworkStream]$Stream, [int]$TimeoutMilliseconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Stream.DataAvailable) {
        if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { throw 'Timed out waiting for QMP response' }
        Start-Sleep -Milliseconds 10
    }
    $Reader.ReadLine()
}

function Invoke-Qmp([string]$Command, [IO.StreamWriter]$Writer, [IO.StreamReader]$Reader, [Net.Sockets.NetworkStream]$Stream) {
    $Writer.WriteLine((@{ execute = $Command } | ConvertTo-Json -Compress))
    while ($true) {
        $line = Read-QmpLine $Reader $Stream 5000
        $message = $line | ConvertFrom-Json
        if ($null -ne $message.event) { continue }
        if ($null -ne $message.error) { throw "QMP $Command failed: $line" }
        return
    }
}

$client = [Net.Sockets.TcpClient]::new()
try {
    $client.Connect('127.0.0.1', $qmpPort)
    $stream = $client.GetStream()
    $reader = [IO.StreamReader]::new($stream)
    $writer = [IO.StreamWriter]::new($stream)
    $writer.AutoFlush = $true
    $null = (Read-QmpLine $reader $stream 5000) | ConvertFrom-Json
    Invoke-Qmp 'qmp_capabilities' $writer $reader $stream
    Write-Host "[QMP] quit PID=$pidValue port=$qmpPort"
    $writer.WriteLine((@{ execute = 'quit' } | ConvertTo-Json -Compress))
} finally {
    $client.Dispose()
}

try {
    Wait-Process -Id $pidValue -Timeout $TimeoutSeconds -ErrorAction Stop
    Remove-Item -LiteralPath $invalidMarker -Force -ErrorAction SilentlyContinue
    Write-Host "[PASS] QEMU exited cleanly after QMP quit PID=$pidValue"
    exit 0
} catch {
    if ($null -eq (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $invalidMarker -Force -ErrorAction SilentlyContinue
        Write-Host "[PASS] QEMU exited cleanly after QMP quit PID=$pidValue"
        exit 0
    }
}

Write-Warning "QEMU did not exit within ${TimeoutSeconds}s after QMP quit; forcing termination. Phase B image is invalid."
[IO.File]::WriteAllText($invalidMarker, "forced termination after QMP quit timeout; PID=$pidValue`r`n")
Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
try { Wait-Process -Id $pidValue -Timeout 5 -ErrorAction Stop } catch {}
throw 'QEMU required forced termination; do not use this image for Phase B'
