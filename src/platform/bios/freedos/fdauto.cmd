@echo off
C:
cd \
if not exist C:\TEMP\nul md C:\TEMP
if not exist C:\PROGRAMS\nul md C:\PROGRAMS
if not exist C:\DZCFG\nul md C:\DZCFG
set TEMP=C:\TEMP
set TMP=C:\TEMP
set DZ=C:\DZCFG
set COMSPEC=C:\COMMAND.COM
path C:\;C:\PROGRAMS
prompt $p$g
rem USB/PS/2 mouse for DOS programs through the BIOS (INT 33h, VBADOS).
if exist C:\VBMOUSE.EXE C:\VBMOUSE.EXE
call C:\TOOLS.BAT
