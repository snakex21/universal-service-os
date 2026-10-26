# Source950 only: ordinary RunOnce coordinator, after original Setup.
# It never creates RunOnce\Setup, which would block the real-mode guards.
# Until FIRSTBT.OK, every boot also replaces HKLM\Network\Logon with the
# REG95LGN.REG export of REG95.BAT: 950 Setup writes PrimaryProvider
# "Microsoft Network" after REG95 (X470 95 RTM PL fresh, 2026-10-26) and
# 950's real-mode REGEDIT has no /D, so VESBIND DELKEY removes the key
# first (SYSTEM.LGN backup restored if it fails while writing). The
# first-logon password-list prompt stays: Windows 95 lists differ from the
# Me list that tools/w9x_logon.sh seeds, and USOS has no verified 95 list.
# The RunOnce import stays on every boot: it is the only first arm, and
# USOSFB's Retry reboots without arm(). It is never fatal: a failure only
# logs to USOSLOG.TXT and writes FIRSTBT.DER (not FIRSTBT.ERR, which would
# stop a coordinator that its own arm() queued), then Windows boots. No
# /E read-back: 950 real-mode REGEDIT /E fails on a ~2 MB hive although
# the key exists (X470 95 RTM after DX8/IE, 2026-10-26), and the old
# :FAILWAIT loop then hung the boot at a blinking cursor.
w9x_firstboot_write() {
    [ "$2" = '4 0 0 950' ] || return 1
    [ -f "$1/USOSFB.EXE" ] || return 1
    printf 'source950 first complete desktop\r\n' > "$1/FIRSTBT.ON" || return 1
    sed 's/$/\r/' > "$1/FIRSTBT.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce]
"USOSFirstBoot"="C:\\USOS9X\\USOSFB.EXE"
EOF
    sed 's/$/\r/' > "$1/FIRSTBT.BAT" <<'EOF'
@ECHO OFF
IF EXIST C:\USOS9X\FIRSTBT.OK GOTO END
IF NOT EXIST C:\USOS9X\PHASE1.OK GOTO END
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END
IF NOT EXIST C:\WINDOWS\USER.DAT GOTO END
IF NOT EXIST C:\USOS9X\USOSFB.EXE GOTO FAIL
C:
CD \WINDOWS
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H USER.DAT
IF NOT EXIST C:\USOS9X\REG95.OK GOTO LGNEND
IF NOT EXIST C:\USOS9X\REG95LGN.REG GOTO LGNEND
IF NOT EXIST C:\USOS9X\VESBIND.EXE GOTO LGNEND
C:\WINDOWS\COMMAND\FIND.EXE "Network\Logon]" C:\USOS9X\REG95LGN.REG > NUL
IF ERRORLEVEL 1 GOTO LGNEND
COPY /Y SYSTEM.DAT C:\USOS9X\SYSTEM.LGN > NUL
IF ERRORLEVEL 1 GOTO LGNEND
C:\USOS9X\VESBIND.EXE DELKEY C:\WINDOWS\SYSTEM.DAT HKEY_LOCAL_MACHINE\Network\Logon C:\USOS9X\LGNDEL.LOG
IF ERRORLEVEL 3 GOTO LGNBACK
IF ERRORLEVEL 2 GOTO LGNLOG
REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\REG95LGN.REG
GOTO LGNEND
:LGNBACK
COPY /Y C:\USOS9X\SYSTEM.LGN SYSTEM.DAT > NUL
:LGNLOG
ECHO FIRSTBT: Network\Logon not replaced, see LGNDEL.LOG>> C:\USOS9X\USOSLOG.TXT
:LGNEND
REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\FIRSTBT.REG
IF ERRORLEVEL 1 GOTO FAIL
GOTO LOCK
:FAIL
ECHO FIRSTBT: RunOnce import failed, Windows started anyway>> C:\USOS9X\USOSLOG.TXT
ECHO RunOnce import failed in real mode> C:\USOS9X\FIRSTBT.DER
:LOCK
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H USER.DAT
:END
EOF
}
