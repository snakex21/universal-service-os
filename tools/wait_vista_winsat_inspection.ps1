$ErrorActionPreference='Stop'
$jobs=@(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'"|Where-Object {$_.CommandLine -like '*tools\inspect_vista_winsat_code.py*'})
foreach($job in $jobs){Wait-Process -Id $job.ProcessId -ErrorAction SilentlyContinue}
Write-Output 'Static inspection completed.'
