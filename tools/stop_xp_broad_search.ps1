$items=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -eq 'rg.exe' -and $_.CommandLine -like '*csmwrap src tools*'})
foreach($item in $items){Stop-Process -Id $item.ProcessId -ErrorAction SilentlyContinue}
Write-Output 'Unused broad CSMWrap search stopped'
