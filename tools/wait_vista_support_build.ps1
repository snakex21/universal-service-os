# One blocking wait for the known compiler driver; no progress polling.
$ErrorActionPreference='Stop'
$builders=@(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" | Where-Object {$_.CommandLine -like '*tools\build_windows_native_support.py*'})
foreach($builder in $builders){Wait-Process -Id $builder.ProcessId -ErrorAction SilentlyContinue}
Write-Output 'Native-support builder has completed.'
