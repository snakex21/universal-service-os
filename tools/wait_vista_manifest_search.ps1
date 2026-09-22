$items=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'rg.exe' -and $_.CommandLine -like '*SkipMachineOOBE*'})
foreach($item in $items){Wait-Process -Id $item.ProcessId -ErrorAction SilentlyContinue}
Write-Output 'MANIFEST_SEARCH_FINISHED'
