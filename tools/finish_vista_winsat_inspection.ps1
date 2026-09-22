# The required SP2 schema was found; stop the now-unneeded broad search.
$items=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'rg.exe' -and $_.CommandLine -like '*SkipMachineOOBE zig-out/vista/image/Windows/winsxs/Manifests*'})
foreach($item in $items){Stop-Process -Id $item.ProcessId -ErrorAction SilentlyContinue}
Write-Output 'UNNEEDED_SCHEMA_SEARCH_STOPPED'
