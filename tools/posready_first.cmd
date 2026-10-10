@echo off
rem USOS: Windows Embedded POSReady 2009, RunOnce of the answer file. POSReady
rem runs it inside the First Boot Agent (docs/posready-2009-2026-10-10.md),
rem from \USOS\POSR on the FAT16 Setup partition: installs the XP x86 X470
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
regedit /s "%S%LOGON.REG"
echo regedit LOGON %ERRORLEVEL% >> "%S%FIRST.LOG"
