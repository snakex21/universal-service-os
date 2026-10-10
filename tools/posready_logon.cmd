@echo off
rem USOS: Windows Embedded POSReady 2009, first logon in the install VM
rem (RunOnce from LOGON.REG, docs/posready-2009-2026-10-10.md). The First
rem Boot Agent is done: checks that the community acpi.sys survived FBA's
rem PnP (the XP Tablet lesson), writes DONE.TXT and shuts the VM down.
set S=%~dp0
echo USOS POSReady first logon >> "%S%FIRST.LOG"
fc /b "%S%DRV\acpi.sys" %SystemRoot%\system32\drivers\acpi.sys > nul
if errorlevel 1 echo ACPI RESTORED: stock acpi.sys after FBA, community copied again >> "%S%FIRST.LOG"
if errorlevel 1 copy /y "%S%DRV\acpi.sys" %SystemRoot%\system32\drivers\acpi.sys >> "%S%FIRST.LOG"
fc /b "%S%DRV\acpi.sys" %SystemRoot%\system32\drivers\acpi.sys > nul
if not errorlevel 1 echo done> "%S%DONE.TXT"
shutdown -s -f -t 0
