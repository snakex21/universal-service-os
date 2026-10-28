@echo off
rem USOS: Windows Embedded POSReady 2009, RunOnce of the answer file. POSReady
rem runs it inside the First Boot Agent (docs/posready-2009-2026-10-10.md),
rem from C:\USOS\POSR (posready_after_setup copied it onto the Windows
rem partition; the FAT16 Setup partition has no letter inside FBA): installs the XP x86 X470
rem driver set (community ACPI, GenAHCI + StorPort, KMDF 1.11 + USB3 xHCI)
rem and LOGON.REG, whose RunOnce starts LOGON.CMD at the first logon (the
rem ACPI check after FBA's PnP, DONE.TXT, shutdown). The community acpi.sys
rem also goes into dllcache first, so Windows File Protection cannot put the
rem stock one back.
set S=%~dp0
echo USOS POSReady FBA RunOnce > "%S%FIRST.LOG"
if exist %SystemRoot%\system32\dllcache\acpi.sys copy /y "%S%DRV\acpi.sys" %SystemRoot%\system32\dllcache\acpi.sys >> "%S%FIRST.LOG"
copy /y "%S%DRV\*.sys" %SystemRoot%\system32\drivers\ >> "%S%FIRST.LOG"
copy /y "%S%DRV\*.inf" %SystemRoot%\inf\ >> "%S%FIRST.LOG"
regedit /s "%S%X470.REG"
echo regedit X470 %ERRORLEVEL% >> "%S%FIRST.LOG"
rem Every partition of a USB stick gets a letter: usosmpart.sys (own GPL disk
rem class lower filter, tools/nt/usosmpart; copied with DRV\*.sys above) as a
rem boot-start service, appended to the disk class LowerFilters.
if not exist %SystemRoot%\system32\drivers\usosmpart.sys goto mpart_done
set "USOS_SVC=HKLM\SYSTEM\CurrentControlSet\Services\usosmpart"
set "USOS_CLS=HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E967-E325-11CE-BFC1-08002BE10318}"
reg add "%USOS_SVC%" /v Type /t REG_DWORD /d 1 /f >> "%S%FIRST.LOG"
reg add "%USOS_SVC%" /v Start /t REG_DWORD /d 0 /f >> "%S%FIRST.LOG"
reg add "%USOS_SVC%" /v ErrorControl /t REG_DWORD /d 1 /f >> "%S%FIRST.LOG"
reg add "%USOS_SVC%" /v Group /t REG_SZ /d "Filter" /f >> "%S%FIRST.LOG"
reg add "%USOS_SVC%" /v ImagePath /t REG_EXPAND_SZ /d "system32\drivers\usosmpart.sys" /f >> "%S%FIRST.LOG"
set "USOS_LF="
for /f "tokens=2,*" %%A in ('reg query "%USOS_CLS%" /v LowerFilters 2^>nul ^| find /i "LowerFilters"') do set "USOS_LF=%%B"
echo "\0%USOS_LF%\0" | find /i "\0usosmpart\0" >nul
if not errorlevel 1 goto mpart_listed
if defined USOS_LF (reg add "%USOS_CLS%" /v LowerFilters /t REG_MULTI_SZ /d "%USOS_LF%\0usosmpart" /f >> "%S%FIRST.LOG") else (reg add "%USOS_CLS%" /v LowerFilters /t REG_MULTI_SZ /d "usosmpart" /f >> "%S%FIRST.LOG")
:mpart_listed
echo usosmpart registered %ERRORLEVEL% >> "%S%FIRST.LOG"
:mpart_done
regedit /s "%S%LOGON.REG"
rem Use the real AdminPassword from the existing Setup answer. Disable the
rem blank-password fallback first; LOGON.EXE enables it only after success.
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f >nul
"%S%LOGON.EXE"
if errorlevel 1 echo autologon preparation failed - credentials were not logged >> "%S%FIRST.LOG"
echo regedit LOGON %ERRORLEVEL% >> "%S%FIRST.LOG"
