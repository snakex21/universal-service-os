@echo off
if not exist %2\nul md %2
if not exist %2\nul goto end
if exist %2\READY.TAG del %2\READY.TAG
if exist %2\DOSERR.TAG del %2\DOSERR.TAG
for %%e in (COM EXE SYS TXT INI CFG BAT OVL CPI) do call %3\COPYDOS.BAT %1 %2 %%e
for %%e in (GRB VID HLP DLL 386 LST MSG DAT BIN) do call %3\COPYDOS.BAT %1 %2 %%e
for %%f in (%1\*.??_) do call %3\UNPACK.BAT %%f %2 %1\EXPAND.EXE
if exist %2\DOSERR.TAG goto failed
if exist %2\*.EX_ ren %2\*.EX_ *.EXE
if exist %2\*.CO_ ren %2\*.CO_ *.COM
if exist %2\*.SY_ ren %2\*.SY_ *.SYS
if exist %2\*.HL_ ren %2\*.HL_ *.HLP
if exist %2\*.CP_ ren %2\*.CP_ *.CPI
if exist %2\*.GR_ ren %2\*.GR_ *.GRB
if exist %2\*.VI_ ren %2\*.VI_ *.VID
if exist %2\*.IN_ ren %2\*.IN_ *.INI
if exist %2\*.OV_ ren %2\*.OV_ *.OVL
if exist %2\*.TX_ ren %2\*.TX_ *.TXT
if exist %2\*.BA_ ren %2\*.BA_ *.BAS
if exist %2\DRVBOOT.BAS ren %2\DRVBOOT.BAS DRVBOOT.BAT
if exist %2\*.DL_ ren %2\*.DL_ *.DLL
if exist %2\*.DO_ ren %2\*.DO_ *.DOS
if exist %2\*.38_ ren %2\*.38_ *.386
if exist %2\*.LS_ ren %2\*.LS_ *.LST
if not exist %2\HIMEM.SYS goto failed
if not exist %2\MEM.EXE goto failed
if not exist %2\XCOPY.EXE goto failed
if not exist %2\EDIT.COM goto failed
if not exist %2\QBASIC.EXE goto failed
echo READY>%2\READY.TAG
goto end
:failed
echo DOS FILE PREPARATION FAILED
echo PREPARATION FAILED>>%2\DOSERR.TAG
:end
