function Resolve-QemuHarnessFfmpeg {
    $candidate = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($null -eq $candidate) { $candidate = Get-Command ffmpeg -ErrorAction SilentlyContinue }
    if ($null -eq $candidate) { throw 'ffmpeg is required for QEMU screenshot conversion but was not found in PATH' }
    return $candidate.Source
}

function Convert-QemuPpmToPng {
    param(
        [Parameter(Mandatory=$true)][string]$PpmPath,
        [switch]$RemovePpm
    )

    $ppm = [IO.Path]::GetFullPath($PpmPath)
    if (-not (Test-Path -LiteralPath $ppm -PathType Leaf)) {
        throw "QEMU screenshot was not created: $ppm"
    }
    $png = [IO.Path]::ChangeExtension($ppm, '.png')
    $ffmpeg = Resolve-QemuHarnessFfmpeg
    if (-not (Get-Command ConvertTo-NativeArgumentLine -ErrorAction SilentlyContinue)) {
        throw 'ConvertTo-NativeArgumentLine is required before loading qemu_harness.ps1'
    }
    $ffmpegErr = $png + '.ffmpeg.stderr.log'
    Remove-Item -LiteralPath $ffmpegErr -Force -ErrorAction SilentlyContinue
    $args = @('-y','-i',$ppm,$png)
    $process = Start-Process -FilePath $ffmpeg -ArgumentList (ConvertTo-NativeArgumentLine -Arguments $args) -PassThru -Wait -WindowStyle Hidden -RedirectStandardError $ffmpegErr
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $png -PathType Leaf) -or (Get-Item -LiteralPath $png).Length -le 0) {
        $detail = if (Test-Path -LiteralPath $ffmpegErr -PathType Leaf) { (Get-Content -LiteralPath $ffmpegErr -Tail 20) -join ' ' } else { '' }
        throw "ffmpeg failed to convert QEMU screenshot to PNG: $ppm exit=$($process.ExitCode) $detail"
    }
    Remove-Item -LiteralPath $ffmpegErr -Force -ErrorAction SilentlyContinue
    if ($RemovePpm) { Remove-Item -LiteralPath $ppm -Force }
    return $png
}

function Wait-AndConvert-QemuPpmToPng {
    param(
        [Parameter(Mandatory=$true)][string]$PpmPath,
        [int]$TimeoutMilliseconds = 3000,
        [switch]$RemovePpm
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while (-not (Test-Path -LiteralPath $PpmPath -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for QEMU screenshot: $PpmPath" }
        Start-Sleep -Milliseconds 25
    }
    return Convert-QemuPpmToPng -PpmPath $PpmPath -RemovePpm:$RemovePpm
}
