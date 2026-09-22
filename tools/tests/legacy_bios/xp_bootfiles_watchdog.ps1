param(
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][int]$OwnerPid,
    [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
    [Parameter(Mandatory=$true)][string]$DoneFile
)

$ErrorActionPreference='SilentlyContinue'
$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

function Stop-TokenProcesses {
    $owned=@(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($Token)
    })
    foreach($proc in $owned | Sort-Object ProcessId -Descending){
        & taskkill.exe /PID $proc.ProcessId /T /F 2>$null | Out-Null
    }
}

while([DateTime]::UtcNow -lt $deadline){
    if(Test-Path -LiteralPath $DoneFile -PathType Leaf){ exit 0 }
    if(-not (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)){
        Stop-TokenProcesses
        exit 2
    }
    Start-Sleep -Milliseconds 500
}

if(-not (Test-Path -LiteralPath $DoneFile -PathType Leaf)){
    Stop-TokenProcesses
    exit 3
}
exit 0
