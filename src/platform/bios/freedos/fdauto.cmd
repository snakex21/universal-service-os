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
call C:\TOOLS.BAT
