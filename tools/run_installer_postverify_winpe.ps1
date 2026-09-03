param(
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$qemu = Full 'tools/qemu/qemu-system-x86_64.exe'
$iso = Full 'media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso'
$target = Full 'tools/tests/artifacts/qemu/usos-installer-full-target.qcow2'
$config = Full 'tools/tests/artifacts/qemu/usos-postverify-winpe-config'
$firmwareCode = Full 'tools/qemu/share/edk2-x86_64-code.fd'
$firmwareVarsSource = Full 'tools/qemu/share/edk2-i386-vars.fd'
$varsCopy = Join-Path $config 'edk2-vars.fd'
$result = Join-Path $config 'usos-postverify-result.txt'
$qemuErr = Join-Path $config 'qemu.stderr.log'
$screen = Join-Path $config 'timeout.ppm'

foreach ($required in @($qemu,$iso,$target,$firmwareCode,$firmwareVarsSource,(Join-Path $config 'Autounattend.xml'),(Join-Path $config 'run-usos-gpt-test.cmd'),(Join-Path $config 'USOS_QEMU_TEST.TAG'),(Join-Path $config 'usos-gpt-qemu-test.exe'),(Join-Path $config 'USOS Installer.exe'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}

$active = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($config) })
if ($active.Count -gt 0) { throw "Post-verify WinPE QEMU already running: PID=$($active[0].ProcessId)" }

Copy-Item -LiteralPath $firmwareVarsSource -Destination $varsCopy -Force
Remove-Item -LiteralPath $result,$qemuErr,$screen -Force -ErrorAction SilentlyContinue

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}
function Send-Hmp([int]$Port,[string]$Command) {
    $client = [Net.Sockets.TcpClient]::new('127.0.0.1',$Port)
    try {
        $stream = $client.GetStream()
        $writer = [IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine($Command)
        Start-Sleep -Milliseconds 50
    } finally { $client.Dispose() }
}

$monitorPort = Get-FreeTcpPort
$configForQemu = $config.Replace('\','/')
$args = @(
    '-machine','q35',
    '-accel','tcg',
    '-cpu','max',
    '-m','4096',
    '-smp','4',
    '-nic','none',
    '-display','none',
    '-no-reboot',
    '-boot','order=d,menu=off',
    '-monitor',"tcp:127.0.0.1:$monitorPort,server=on,wait=off",
    '-drive',"if=pflash,format=raw,readonly=on,file=$firmwareCode",
    '-drive',"if=pflash,format=raw,file=$varsCopy",
    '-drive',"file=$iso,media=cdrom,readonly=on",
    '-drive',"if=none,id=target,file=$target,format=qcow2,readonly=on",
    '-device','qemu-xhci,id=xhci',
    '-device','usb-storage,bus=xhci.0,drive=target,removable=on,serial=USOS-GPT-TEST',
    '-drive',"if=none,id=cfg,file=fat:rw:$configForQemu,format=raw",
    '-device','usb-storage,bus=xhci.0,drive=cfg,removable=on,serial=USOS-CONFIG'
)

$process = Start-Process -FilePath $qemu -ArgumentList $args -PassThru -RedirectStandardError $qemuErr
$startedAt = [DateTime]::UtcNow
$deadline = $startedAt.AddSeconds($TimeoutSeconds)
$nextBootKeyAt = $startedAt.AddSeconds(1)
while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    $now = [DateTime]::UtcNow
    if ($now -ge $nextBootKeyAt -and ($now-$startedAt).TotalSeconds -le 35) {
        try { Send-Hmp $monitorPort 'sendkey ret' } catch {}
        $nextBootKeyAt = $now.AddSeconds(2)
    }
    if (Test-Path -LiteralPath $result) {
        $text = Get-Content -LiteralPath $result -Raw -ErrorAction SilentlyContinue
        if ($text -match 'RESULT=(PASS|FAIL)') { break }
    }
}
if (-not (Test-Path -LiteralPath $result -PathType Leaf) -and -not $process.HasExited) {
    try { Send-Hmp $monitorPort "screendump $($screen.Replace('\','/'))" } catch {}
}
if (-not $process.HasExited) { $process.Kill() }
$process.WaitForExit()

if (-not (Test-Path -LiteralPath $result -PathType Leaf)) {
    throw "QEMU/WinPE produced no result file. See $qemuErr and $screen"
}
Get-Content -LiteralPath $result -Raw
