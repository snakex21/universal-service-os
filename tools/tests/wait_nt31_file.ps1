param([Parameter(Mandatory=$true)][string]$Name,
      [ValidateSet('r24-nt31-intel-fullmac','r24b-nt31-image-entry','r24c-nt31-registermac-order','r24d-nt31-usb-fullmac')][string]$Tag='r24-nt31-intel-fullmac')
$ErrorActionPreference = 'Stop'
if ($Name -cnotmatch '^(endpoint\.png|operator-[0-9]{2}\.png|completed\.json)$') { throw 'Fixed completion filename required' }
$waitRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\artifacts\nt31-fullmac-runtime'))
$waitDirectory = Join-Path (Join-Path $waitRoot 'vm') $Tag
$waitPaths = @((Join-Path $waitDirectory $Name),(Join-Path $waitDirectory 'completed.json'))
$waitWatcher = [IO.FileSystemWatcher]::new($waitRoot,'*')
$waitWatcher.IncludeSubdirectories = $true
$waitWatcher.NotifyFilter = [IO.NotifyFilters]::FileName
$waitPrefix = 'nt31-file-' + [Guid]::NewGuid().ToString('N')
$waitSubscriptions = @()
try {
    foreach ($kind in @('Created','Renamed','Error')) {
        $waitSubscriptions += Register-ObjectEvent -InputObject $waitWatcher -EventName $kind -SourceIdentifier "$waitPrefix-$kind"
    }
    $waitWatcher.EnableRaisingEvents = $true
    Write-Output 'NT31_FILE_LISTENER_ARMED'
    $waitFound = $waitPaths | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
    while (-not $waitFound) {
        $waitEvent = Wait-Event
        try {
            if ($waitEvent.SourceIdentifier -eq "$waitPrefix-Error") { throw 'Completion subscription error' }
            if ($waitPaths -contains $waitEvent.SourceEventArgs.FullPath) { $waitFound = $waitEvent.SourceEventArgs.FullPath }
        } finally { Remove-Event -EventIdentifier $waitEvent.EventIdentifier }
    }
    Write-Output $waitFound
} finally {
    foreach ($waitSubscription in $waitSubscriptions) { Unregister-Event -SubscriptionId $waitSubscription.SubscriptionId }
    Get-Event | Where-Object SourceIdentifier -Like "$waitPrefix-*" | Remove-Event
    $waitWatcher.Dispose()
}
