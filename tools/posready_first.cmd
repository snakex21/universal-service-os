@echo off
rem USOS: Windows Embedded POSReady 2009, first logon in the install VM
rem (docs/posready-2009-2026-10-10.md). Runs from \USOS\POSR on the FAT16
rem Setup partition: installs the XP x86 X470 driver set (community ACPI,
rem GenAHCI + StorPort, KMDF 1.11 + USB3 xHCI), writes DONE.TXT next to
rem itself and shuts the VM down. The community acpi.sys also goes into
rem dllcache first, so Windows File Protection cannot put the stock one back.
set S=%~dp0
echo USOS POSReady first logon > "%S%FIRST.LOG"
if exist %SystemRoot%\system32\dllcache\acpi.sys copy /y "%S%DRV\acpi.sys" %SystemRoot%\system32\dllcache\acpi.sys >> "%S%FIRST.LOG"
copy /y "%S%DRV\*.sys" %SystemRoot%\system32\drivers\ >> "%S%FIRST.LOG"
copy /y "%S%DRV\*.inf" %SystemRoot%\inf\ >> "%S%FIRST.LOG"
regedit /s "%S%X470.REG"
echo regedit %ERRORLEVEL% >> "%S%FIRST.LOG"
fc /b "%S%DRV\acpi.sys" %SystemRoot%\system32\drivers\acpi.sys > nul
if errorlevel 1 echo ACPI MISMATCH >> "%S%FIRST.LOG"
if not errorlevel 1 echo done> "%S%DONE.TXT"
shutdown -s -f -t 0
