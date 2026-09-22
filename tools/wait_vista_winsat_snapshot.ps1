$ErrorActionPreference='Stop'
$processes=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*-File tools\snapshot_vista_winsat.ps1*'})
foreach($item in $processes){Wait-Process -Id $item.ProcessId -ErrorAction SilentlyContinue}
Write-Output 'SNAPSHOT_AND_FILESYSTEM_REPAIR_FINISHED'
