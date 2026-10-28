param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$Tag,
    [Parameter(Mandatory=$true)][string]$Token
)
# Completion-only subscription. Other serial lines are discarded internally.
# FileSystemWatcher uses ReadDirectoryChangesW; there is no progress timer.
$ErrorActionPreference = 'Stop'
if ($Tag -cnotmatch '^[a-z0-9-]+$' -or $Token -cnotmatch '^USOS_NET_DONE_[a-f0-9]{32}$') {
    throw 'Invalid fixed case or completion token'
}
$markerRoot = [IO.Path]::GetFullPath($Root)
$markerWork = Join-Path 'G:\USOS-Kolekcja\_vm' $Tag
$markerMetadata = Get-Content -LiteralPath (Join-Path $markerWork 'fixture.json') -Raw -Encoding utf8 | ConvertFrom-Json
if ($markerMetadata.private_profile -isnot [bool] -or $markerMetadata.private_profile -ne $false -or
    @('Windows NT 3.51','Windows NT 3.51 Server') -cnotcontains $markerMetadata.folder) {
    throw 'Completion listener requires an explicitly keyless NT351 fixture'
}
$markerDirectory = Join-Path $markerRoot "artifacts\coverage\vm\$Tag"
$markerSerial = Join-Path $markerDirectory 'serial.log'
$markerCleanup = Join-Path $markerDirectory 'cleanup.json'
if (-not [IO.Directory]::Exists($markerDirectory)) { throw 'Endpoint output directory is absent' }
$script:markerOffset = [long]0
$script:markerTail = ''
$script:markerMaximum = 8MB

function Read-Completion {
    if (-not [IO.File]::Exists($markerSerial)) { return $false }
    $stream = [IO.File]::Open($markerSerial,[IO.FileMode]::Open,[IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        if ($stream.Length -lt $script:markerOffset -or $stream.Length -gt $script:markerMaximum) {
            throw 'Completion serial length is outside the bound'
        }
        [void]$stream.Seek($script:markerOffset,[IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new(65536)
        while (($count = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $script:markerOffset += $count
            if ($script:markerOffset -gt $script:markerMaximum) { throw 'Completion serial byte cap exceeded' }
            $text = $script:markerTail + [Text.Encoding]::UTF8.GetString($buffer,0,$count)
            $lines = $text.Split("`n")
            for ($index=0; $index -lt $lines.Length-1; $index++) {
                if ($lines[$index].TrimEnd("`r") -ceq $Token) { return $true }
            }
            $script:markerTail = $lines[-1]
            if ($script:markerTail.Length -gt 65536) { throw 'Completion serial line exceeds the bound' }
        }
        return $false
    } finally { $stream.Dispose() }
}

$markerWatcher = [IO.FileSystemWatcher]::new($markerDirectory,'*')
$markerWatcher.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::FileName
$markerEvents = @()
$markerPrefix = 'nt351-done-' + [Guid]::NewGuid().ToString('N')
try {
    foreach ($kind in @('Changed','Created','Renamed','Error')) {
        $markerEvents += Register-ObjectEvent -InputObject $markerWatcher -EventName $kind -SourceIdentifier "$markerPrefix-$kind"
    }
    $markerWatcher.EnableRaisingEvents = $true
    Write-Output 'COMPLETION_LISTENER_ARMED'
    # Subscribe before the initial read, closing the existing-file race.
    $markerFound = Read-Completion
    if (-not $markerFound -and [IO.File]::Exists($markerCleanup)) { throw 'VM cleanup occurred before the guest completion marker' }
    while (-not $markerFound) {
        $event = Wait-Event
        try {
            if ($event.SourceIdentifier -eq "$markerPrefix-Error") { throw 'Completion subscription overflow or error' }
            $changed = $event.SourceEventArgs.FullPath
            if ($changed -ceq $markerSerial -or $changed -ceq $markerCleanup) {
                $markerFound = Read-Completion
                if (-not $markerFound -and $changed -ceq $markerCleanup) { throw 'VM cleanup occurred before the guest completion marker' }
            }
        } finally { Remove-Event -EventIdentifier $event.EventIdentifier }
    }
    Write-Output "SERIAL_COMPLETION $Token"
} finally {
    foreach ($subscription in $markerEvents) { Unregister-Event -SubscriptionId $subscription.SubscriptionId }
    Get-Event | Where-Object SourceIdentifier -Like "$markerPrefix-*" | Remove-Event
    $markerWatcher.Dispose()
}
