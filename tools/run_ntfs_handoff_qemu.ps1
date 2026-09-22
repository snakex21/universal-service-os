param(
    [Parameter(Mandatory=$true)][string]$QemuPath,
    [Parameter(Mandatory=$true)][string]$ImagePath,
    [Parameter(Mandatory=$true)][string]$FirmwareCode,
    [Parameter(Mandatory=$true)][string]$FirmwareVars,
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [string]$CpuModel = 'max',
    [ValidateSet('auto','raw','qcow2')][string]$ImageFormat = 'auto',
    [string]$EnterAtSeconds = '',
    [string]$KeyAtSeconds = '',
    [string]$TextAtSeconds = '',
    [string]$KernelPath = '',
    [string]$InitrdPath = '',
    [string]$KernelAppend = '',
    [int]$CaptureUntilSeconds = 220,
    [int]$FastCaptureUntilSeconds = 12,
    [int]$FastCaptureIntervalMilliseconds = 250,
    [int]$SlowCaptureIntervalMilliseconds = 3000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'process_argument_line.ps1')
. (Join-Path $PSScriptRoot 'qemu_harness.ps1')
foreach ($name in @('QemuPath','ImagePath','FirmwareCode','FirmwareVars','OutputDir')) {
    Set-Variable -Name $name -Value ([IO.Path]::GetFullPath((Get-Variable -Name $name -ValueOnly)))
}
foreach ($name in @('KernelPath','InitrdPath')) {
    $value = Get-Variable -Name $name -ValueOnly
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $value = [IO.Path]::GetFullPath($value)
        if (-not (Test-Path -LiteralPath $value -PathType Leaf)) { throw "Missing boot artifact: $value" }
        Set-Variable -Name $name -Value $value
    }
}
if ([string]::IsNullOrWhiteSpace($KernelPath) -ne [string]::IsNullOrWhiteSpace($InitrdPath)) {
    throw 'KernelPath and InitrdPath must be supplied together'
}
if ($CaptureUntilSeconds -lt 1) { throw 'CaptureUntilSeconds must be positive' }
if ($ImageFormat -eq 'auto') {
    $ImageFormat = if ([IO.Path]::GetExtension($ImagePath).Equals('.qcow2', [StringComparison]::OrdinalIgnoreCase)) { 'qcow2' } else { 'raw' }
}
if ($FastCaptureUntilSeconds -lt 0 -or $FastCaptureUntilSeconds -gt $CaptureUntilSeconds) {
    throw 'FastCaptureUntilSeconds must be between zero and CaptureUntilSeconds'
}
if ($FastCaptureIntervalMilliseconds -lt 50 -or $SlowCaptureIntervalMilliseconds -lt 50) {
    throw 'Capture intervals must be at least 50 ms'
}
$enterSchedule = @()
if (-not [string]::IsNullOrWhiteSpace($EnterAtSeconds)) {
    $enterSchedule = @($EnterAtSeconds.Split(',') | ForEach-Object {
        $value = 0.0
        if (-not [double]::TryParse($_, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or $value -lt 0) {
            throw "Invalid EnterAtSeconds value: $_"
        }
        $value
    } | Sort-Object)
}
$keySchedule = @($enterSchedule | ForEach-Object {
    [PSCustomObject]@{ Seconds = $_; Key = 'ret' }
})
if (-not [string]::IsNullOrWhiteSpace($KeyAtSeconds)) {
    foreach ($entry in $KeyAtSeconds.Split(',')) {
        $parts = $entry.Split(':', 2)
        $seconds = 0.0
        if ($parts.Count -ne 2 -or
            -not [double]::TryParse($parts[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -or
            $seconds -lt 0 -or [string]::IsNullOrWhiteSpace($parts[1])) {
            throw "Invalid KeyAtSeconds entry: $entry"
        }
        $keySchedule += [PSCustomObject]@{ Seconds = $seconds; Key = $parts[1] }
    }
}
$keySchedule = @($keySchedule | Sort-Object Seconds)
$textSchedule = @()
if (-not [string]::IsNullOrWhiteSpace($TextAtSeconds)) {
    foreach ($entry in $TextAtSeconds.Split('|')) {
        $parts = $entry.Split(':', 2)
        $seconds = 0.0
        if ($parts.Count -ne 2 -or
            -not [double]::TryParse($parts[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -or
            $seconds -lt 0 -or [string]::IsNullOrEmpty($parts[1])) {
            throw "Invalid TextAtSeconds entry: $entry"
        }
        $textSchedule += [PSCustomObject]@{ Seconds = $seconds; Text = $parts[1] }
    }
}
$textSchedule = @($textSchedule | Sort-Object Seconds)

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$serialPath = Join-Path $OutputDir 'serial.log'
$qmpPath = Join-Path $OutputDir 'qmp-events.log'
$stderrPath = Join-Path $OutputDir 'qemu.stderr.log'
$debugPath = Join-Path $OutputDir 'qemu-debug.log'
Get-ChildItem -LiteralPath $OutputDir -Filter 'screen-*.ppm' -File -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -LiteralPath $OutputDir -Filter 'screen-*.png' -File -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $serialPath,$qmpPath,$stderrPath,$debugPath -Force -ErrorAction SilentlyContinue

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Read-QmpLine([IO.StreamReader]$Reader, [Net.Sockets.NetworkStream]$Stream, [int]$TimeoutMilliseconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Stream.DataAvailable) {
        if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { throw 'Timed out waiting for QMP response' }
        Start-Sleep -Milliseconds 10
    }
    return $Reader.ReadLine()
}

function Write-QmpRecord([string]$Kind, $Payload, [Diagnostics.Stopwatch]$Clock) {
    $record = [ordered]@{
        elapsed_ms = $Clock.ElapsedMilliseconds
        kind = $Kind
        payload = $Payload
    } | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $qmpPath -Value $record -Encoding utf8
}

function Invoke-Qmp([string]$Command, $Arguments, [IO.StreamWriter]$Writer, [IO.StreamReader]$Reader, [Net.Sockets.NetworkStream]$Stream, [Diagnostics.Stopwatch]$Clock) {
    $request = if ($null -eq $Arguments) {
        @{ execute = $Command }
    } else {
        @{ execute = $Command; arguments = $Arguments }
    }
    $Writer.WriteLine(($request | ConvertTo-Json -Compress -Depth 8))
    while ($true) {
        $line = Read-QmpLine $Reader $Stream 20000
        $message = $line | ConvertFrom-Json
        if ($null -ne $message.event) {
            Write-QmpRecord 'event' $message $Clock
            continue
        }
        Write-QmpRecord 'response' @{ command = $Command; message = $message } $Clock
        if ($null -ne $message.error) { throw "QMP $Command failed: $line" }
        return $message
    }
}

function Send-QmpText([string]$Value, [IO.StreamWriter]$Writer, [IO.StreamReader]$Reader, [Net.Sockets.NetworkStream]$Stream, [Diagnostics.Stopwatch]$Clock) {
    foreach ($character in $Value.ToLowerInvariant().ToCharArray()) {
        $key = if (($character -ge 'a' -and $character -le 'z') -or ($character -ge '0' -and $character -le '9')) {
            [string]$character
        } else {
            switch ($character) {
                ' ' { 'spc' }
                '\' { 'backslash' }
                '/' { 'slash' }
                '_' { 'shift-minus' }
                '-' { 'minus' }
                '.' { 'dot' }
                default { throw "Unsupported TextAtSeconds character: $character" }
            }
        }
        Invoke-Qmp 'human-monitor-command' @{ 'command-line' = "sendkey $key 20" } $Writer $Reader $Stream $Clock | Out-Null
        Start-Sleep -Milliseconds 30
    }
    Write-QmpRecord 'text-input' @{ text = $Value } $Clock
}

$qmpPort = Get-FreeTcpPort
$qmpEndpoint = "tcp:127.0.0.1:$qmpPort,server=on,wait=off"

function Resolve-QemuProcess {
    $matches = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.Contains($ImagePath) -and $_.CommandLine.Contains(":$qmpPort")
    })
    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -ne 1) { throw "Multiple QEMU processes match image/QMP endpoint: $($matches.ProcessId -join ', ')" }
    return Get-Process -Id $matches[0].ProcessId -ErrorAction Stop
}

$stale = Resolve-QemuProcess
if ($null -ne $stale) { throw "QEMU is already running for this image/QMP endpoint: PID=$($stale.Id)" }

$qemuArgs = @(
    '-machine','q35',
    '-cpu',$CpuModel,
    '-m','4096',
    '-smp','4',
    '-drive',"if=pflash,format=raw,readonly=on,file=$FirmwareCode",
    '-drive',"if=pflash,format=raw,file=$FirmwareVars,snapshot=on",
    '-drive',"file=$ImagePath,format=$ImageFormat,if=ide",
    '-boot','order=c',
    '-net','none',
    '-display','none',
    '-serial',"file:$serialPath",
    '-qmp',$qmpEndpoint,
    '-d','cpu_reset,guest_errors',
    '-D',$debugPath,
    '-no-shutdown'
)
if (-not [string]::IsNullOrWhiteSpace($KernelPath)) {
    $qemuArgs += @('-kernel',$KernelPath,'-initrd',$InitrdPath)
    if (-not [string]::IsNullOrWhiteSpace($KernelAppend)) { $qemuArgs += @('-append',('"' + $KernelAppend + '"')) }
}

$proc = Start-Process -FilePath $QemuPath -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $qemuArgs) -PassThru -WindowStyle Hidden -RedirectStandardError $stderrPath
$client = $null
$clock = [Diagnostics.Stopwatch]::StartNew()
$runnerOutcome = 'running'
try {
    $connectTimer = [Diagnostics.Stopwatch]::StartNew()
    while ($null -eq $client) {
        try {
            $candidate = [Net.Sockets.TcpClient]::new()
            $candidate.Connect('127.0.0.1', $qmpPort)
            $client = $candidate
        } catch {
            if ($null -ne $candidate) { $candidate.Dispose() }
            if ($connectTimer.ElapsedMilliseconds -ge 10000) {
                $exitDetail = if ($proc.HasExited) { " original-process-exit=$($proc.ExitCode)" } else { '' }
                throw "Timed out connecting to QMP.$exitDetail"
            }
            Start-Sleep -Milliseconds 50
        }
    }

    $activeProc = Resolve-QemuProcess
    if ($null -ne $activeProc) {
        $proc = $activeProc
    } elseif ($proc.HasExited) {
        throw "QMP connected but no live QEMU process could be resolved for image $ImagePath"
    }

    $stream = $client.GetStream()
    $reader = [IO.StreamReader]::new($stream)
    $writer = [IO.StreamWriter]::new($stream)
    $writer.AutoFlush = $true
    $greeting = (Read-QmpLine $reader $stream 5000) | ConvertFrom-Json
    Write-QmpRecord 'greeting' $greeting $clock
    Invoke-Qmp 'qmp_capabilities' $null $writer $reader $stream $clock | Out-Null

    $nextCaptureMs = 0
    $nextKey = 0
    $nextText = 0
    while (-not $proc.HasExited -and $clock.Elapsed.TotalSeconds -lt $CaptureUntilSeconds) {
        $elapsedMs = $clock.ElapsedMilliseconds
        while ($nextKey -lt $keySchedule.Count -and $clock.Elapsed.TotalSeconds -ge $keySchedule[$nextKey].Seconds) {
            $key = $keySchedule[$nextKey].Key
            Invoke-Qmp 'human-monitor-command' @{ 'command-line' = "sendkey $key" } $writer $reader $stream $clock | Out-Null
            Write-QmpRecord 'input' @{ key = $key; scheduled_seconds = $keySchedule[$nextKey].Seconds } $clock
            $nextKey += 1
        }
        while ($nextText -lt $textSchedule.Count -and $clock.Elapsed.TotalSeconds -ge $textSchedule[$nextText].Seconds) {
            Send-QmpText $textSchedule[$nextText].Text $writer $reader $stream $clock
            $nextText += 1
        }
        if ($elapsedMs -lt $nextCaptureMs) {
            Start-Sleep -Milliseconds ([Math]::Min(25, $nextCaptureMs - $elapsedMs))
            continue
        }

        $screenName = 'screen-{0:D6}ms.ppm' -f $elapsedMs
        $screenLocalPath = Join-Path $OutputDir $screenName
        $screenPath = $screenLocalPath.Replace('\','/')
        Invoke-Qmp 'screendump' @{ filename = $screenPath } $writer $reader $stream $clock | Out-Null
        Wait-AndConvert-QemuPpmToPng -PpmPath $screenLocalPath -RemovePpm | Out-Null
        if ($clock.Elapsed.TotalSeconds -lt $FastCaptureUntilSeconds) {
            $nextCaptureMs += $FastCaptureIntervalMilliseconds
        } else {
            $nextCaptureMs += $SlowCaptureIntervalMilliseconds
        }
    }

    if (-not $proc.HasExited) {
        Invoke-Qmp 'query-status' $null $writer $reader $stream $clock | Out-Null
        Write-QmpRecord 'runner' @{ action = 'quit'; reason = 'capture-complete' } $clock
        $writer.WriteLine((@{ execute = 'quit' } | ConvertTo-Json -Compress))
        $runnerOutcome = 'capture-complete-qmp-quit'
    } else {
        $runnerOutcome = 'qemu-exited-before-capture-complete'
    }
} finally {
    if ($null -ne $client) { $client.Dispose() }
    if (-not $proc.HasExited) {
        if (-not $proc.WaitForExit(5000)) {
            $proc.Kill()
            $proc.WaitForExit()
            $runnerOutcome = 'forced-kill-after-qmp-timeout'
        }
    }
}

$proc.WaitForExit()
$proc.Refresh()
$exitCodeText = if ($null -eq $proc.ExitCode) { 'unavailable' } else { [string]$proc.ExitCode }

Write-Host "[QEMU] outcome=$runnerOutcome exit-code=$exitCodeText elapsed=$([Math]::Round($clock.Elapsed.TotalSeconds, 2))s"
if (Test-Path -LiteralPath $serialPath) {
    Write-Host '--- SERIAL ---'
    Get-Content -LiteralPath $serialPath
}
if (Test-Path -LiteralPath $qmpPath) {
    Write-Host '--- QMP EVENTS ---'
    Get-Content -LiteralPath $qmpPath | Where-Object { $_ -match '"kind":"event"|"kind":"runner"|query-status' }
}
$screens = @(Get-ChildItem -LiteralPath $OutputDir -Filter 'screen-*.png' -File -ErrorAction SilentlyContinue)
Write-Host "[PASS] screenshots=$($screens.Count) format=PNG output=$OutputDir"
