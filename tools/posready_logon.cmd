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
rem The automatic logon of LOGON.REG is for this first logon only.
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f > nul
echo autologon off %ERRORLEVEL% >> "%S%FIRST.LOG"
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f > nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /f > nul 2>&1
fc /b "%S%DRV\acpi.sys" %SystemRoot%\system32\drivers\acpi.sys > nul
if not errorlevel 1 echo done> "%S%DONE.TXT"
rem USOSRES (docs/display-policy.md): the automatic display resolution for this
rem NT 5.1 core, the same contract and Run value as XP / Server 2003: native
rem EDID mode, else the highest, only modes from the driver's list, full
rem screen. posready_csmwrap_target.sh staged it in \USOS\POSR; the helper
rem waits for a real driver and logs C:\USOS\POSR\USOSRES.LOG.
if exist "%S%USOSRES.EXE" reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v USOSDisplay /t REG_SZ /d "%SystemDrive%\USOS\POSR\USOSRES.EXE" /f >> "%S%FIRST.LOG" 2>&1
echo display registered %ERRORLEVEL% >> "%S%FIRST.LOG"
shutdown -s -f -t 0
