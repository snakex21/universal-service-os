$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'process_argument_line.ps1')

function Expect([string]$Name, [string]$Actual, [string]$Expected) {
    if ($Actual -ne $Expected) {
        throw "$Name failed: actual=[$Actual] expected=[$Expected]"
    }
    Write-Host "[PASS] $Name"
}

Expect 'simple arguments' (ConvertTo-NativeArgumentLine -Arguments @('-m','4096')) '-m 4096'
Expect 'path with spaces' (ConvertTo-NativeArgumentLine -Arguments @('-drive','file=C:\Media\Windows 11\install.iso,media=cdrom')) '-drive "file=C:\Media\Windows 11\install.iso,media=cdrom"'
Expect 'empty argument' (ConvertTo-NativeArgumentLine -Arguments @('')) '""'
Expect 'embedded quote' (ConvertTo-NativeArgumentLine -Arguments @('a"b')) '"a\"b"'
Expect 'trailing slash in quoted argument' (ConvertTo-NativeArgumentLine -Arguments @('C:\Folder With Space\')) '"C:\Folder With Space\\"'
