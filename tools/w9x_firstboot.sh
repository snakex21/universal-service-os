# Windows 95 RTM / OSR1 (SETUP 4.0.0.950) and OSR2 / OSR2.1 / OSR2.5 (SETUP
# 4.0.0.1068..1216, tools/w9x_filesystem.sh usos_w9x_95_osr2): ordinary
# RunOnce coordinator, after original Setup. OSR2 came under it after its
# native X470 run (OSR2.1 PL, 2026-10-27) took the 98 path (MSBATCH [Install]
# Run USOSAddons at the desktop, no first-desktop hold): the same chain, the
# same real-mode steps, USOSFB's build check accepts 1111 / 1212 / 1214 / 1216.
# Windows 98 FE (4.10.1998) and 98 SE (4.10.2222) too, from the same
# AUTOEXEC.BAT line (98 runs AUTOEXEC.BAT; Me does not and stays outside):
# the caller passes '4 10 0 1998' / '4 10 0 2222' (98 has no root SETUP.EXE
# version read). Their Setup applies MSBATCH [Install] AddReg itself, so the
# REG95 Network\Logon block below is skipped there (no REG95.OK); PHASE1.OK
# comes from W950POST.BAT's 98 mode (tools/w9x_950_post.sh) or the VM path.
# It never creates RunOnce\Setup, which would block the real-mode guards.
# Until FIRSTBT.OK, every boot also replaces HKLM\Network\Logon with
# REG95LGN.REG (tools/w9x_reg95.sh writes it at prep time from REG95.REG,
# never with a PrimaryProvider value): 950 Setup writes PrimaryProvider
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
# Shell restore (before every other step, also after FIRSTBT.OK): USOSFB
# runs the package boots as SYSTEM.INI [boot] shell=C:\USOS9X\USOSFB.EXE
# and writes SHELL.ON while that line is set. If the program is gone, the
# chain is finished (FIRSTBT.OK) or failed (FIRSTBT.ERR), or a shell boot
# ended without USOSFB's own restart (SHELLRUN.FLG still there; SHELL.BAD
# then keeps later boots under Explorer's RunOnce), real mode rebuilds
# SYSTEM.INI as SHELLHDR.INI ("[boot]" + "shell=Explorer.exe") followed by
# the old file without its "[boot]" line and our shell line. USOSFB enters
# shell mode only when SYSTEM.INI starts with [boot] and SHELLHDR.INI exists.
# 950's COPY sets no reliable ERRORLEVEL: results are checked with
# IF EXIST and FIND (0 found, 1 not found), FIND reads stdin (no header).
# Boot sequence diagnostics (X470 98 FE PL 2026-10-28: a package boot died
# early with no record; BOOTLOG.TXT / .PRV only held the two boots before
# the first package that queued WININIT renames, although MSDOS.SYS kept
# BootLog=1, untouched since Setup, in this run and in the 27 Oct runs).
# Every boot until the first one that sees FIRSTBT.OK or FIRSTBT.ERR (which
# writes LOGS\BOOTSEQ.END): LOGS\BOOTSEQ.TXT gets the boot number, the
# FIRSTBT.STA phase and the markers (WININIT.INI pending, MSDOS.SYS
# BootLog=1), and C:\BOOTLOG.TXT as it stands is copied to LOGS\BOOTnn.TXT
# (TYPE: also reads a hidden file; equal consecutive copies = no new log).
# Its DIR /A line (size, date, time) goes to BOOTSEQ.TXT. Change marker
# (X470 98 FE 2026-10-28: identical BOOTnn copies): after the copy a line
# USOS-BOOTSEQ-SEEN is appended to C:\BOOTLOG.TXT; IO.SYS starts a new log
# (the old one becomes BOOTLOG.PRV) before AUTOEXEC, so a C:\BOOTLOG.TXT
# that still has the line was not rewritten and is logged as "stale".
# DOS batch has no arithmetic: LOGS\BOOTNUM.nn is renamed one step per
# boot, the copy twelve boots older is deleted (at most 12 copies), and
# boot 40 is the last one recorded. 98 only (BOOTLOG.ON; 950 rejects the
# line): a MSDOS.SYS without BootLog=1 gets it back (its old BootLog lines
# in LOGS\BOOTLOG.ORG, BOOTLOG.FRC set); the last record puts the profile's
# own lines back. Every GOTO jumps forward. COMMAND.COM opens a line's
# redirection before IF is evaluated, so "IF EXIST x ECHO y> FILE" creates
# an empty FILE even when x is missing (X470 98 FE PL B261028-114842: an
# empty BOOTSEQ.END from boot 1 stopped every later record); BOOTSEQ.END is
# therefore written only behind GOTOs.
w9x_bootseq_block() {
    printf '%s\n' 'IF EXIST C:\USOS9X\LOGS\BOOTSEQ.END GOTO BSDONE' \
        'IF NOT EXIST C:\USOS9X\LOGS\NUL MD C:\USOS9X\LOGS' \
        'IF EXIST C:\USOS9X\LOGS\BOOTNUM.40 GOTO BSDONE'
    n=39
    while [ "$n" -ge 1 ]; do
        printf 'IF EXIST C:\\USOS9X\\LOGS\\BOOTNUM.%02d GOTO BN%02d\n' "$n" $((n + 1)); n=$((n - 1))
    done
    printf '%s\n' ':BN01' 'ECHO USOS boot counter> C:\USOS9X\LOGS\BOOTNUM.01' 'SET U9BN=01' 'GOTO BNGO'
    n=2
    while [ "$n" -le 40 ]; do
        printf ':BN%02d\nREN C:\\USOS9X\\LOGS\\BOOTNUM.%02d BOOTNUM.%02d\nSET U9BN=%02d\n' "$n" $((n - 1)) "$n" "$n"
        [ "$n" -le 12 ] || printf 'IF EXIST C:\\USOS9X\\LOGS\\BOOT%02d.TXT DEL C:\\USOS9X\\LOGS\\BOOT%02d.TXT\n' $((n - 12)) $((n - 12))
        [ "$n" -eq 40 ] || printf 'GOTO BNGO\n'
        n=$((n + 1))
    done
    cat <<'EOF'
:BNGO
ECHO ----- boot %U9BN%: C:\BOOTLOG.TXT now in LOGS\BOOT%U9BN%.TXT; FIRSTBT.STA phase:>> C:\USOS9X\LOGS\BOOTSEQ.TXT
IF EXIST C:\USOS9X\FIRSTBT.STA TYPE C:\USOS9X\FIRSTBT.STA>> C:\USOS9X\LOGS\BOOTSEQ.TXT
IF NOT EXIST C:\USOS9X\FIRSTBT.STA ECHO (no FIRSTBT.STA)>> C:\USOS9X\LOGS\BOOTSEQ.TXT
IF EXIST C:\USOS9X\FIRSTBT.OK ECHO FIRSTBT.OK present: last record>> C:\USOS9X\LOGS\BOOTSEQ.TXT
IF EXIST C:\USOS9X\FIRSTBT.ERR ECHO FIRSTBT.ERR present: last record>> C:\USOS9X\LOGS\BOOTSEQ.TXT
IF EXIST C:\USOS9X\SHELL.ON ECHO SHELL.ON: shell=USOSFB boot>> C:\USOS9X\LOGS\BOOTSEQ.TXT
IF EXIST C:\WINDOWS\WININIT.INI ECHO WININIT.INI pending: WIN.COM runs WININIT this boot>> C:\USOS9X\LOGS\BOOTSEQ.TXT
IF NOT EXIST C:\BOOTLOG.TXT GOTO BMNONE
DIR /A C:\BOOTLOG.TXT> C:\USOS9X\LOGS\BLDIR.TMP
IF NOT EXIST C:\WINDOWS\COMMAND\FIND.EXE GOTO BMCOPY
C:\WINDOWS\COMMAND\FIND.EXE /I "BOOTLOG" < C:\USOS9X\LOGS\BLDIR.TMP>> C:\USOS9X\LOGS\BOOTSEQ.TXT
C:\WINDOWS\COMMAND\FIND.EXE "USOS-BOOTSEQ-SEEN" < C:\BOOTLOG.TXT > NUL
IF ERRORLEVEL 1 GOTO BMFRESH
ECHO C:\BOOTLOG.TXT stale: not rewritten since the last boot>> C:\USOS9X\LOGS\BOOTSEQ.TXT
GOTO BMCOPY
:BMFRESH
ECHO C:\BOOTLOG.TXT new this boot (no USOS-BOOTSEQ-SEEN line)>> C:\USOS9X\LOGS\BOOTSEQ.TXT
:BMCOPY
TYPE C:\BOOTLOG.TXT> C:\USOS9X\LOGS\BOOT%U9BN%.TXT
ECHO USOS-BOOTSEQ-SEEN boot %U9BN%>> C:\BOOTLOG.TXT
GOTO BMDONE
:BMNONE
ECHO (no C:\BOOTLOG.TXT)>> C:\USOS9X\LOGS\BOOTSEQ.TXT
:BMDONE
IF EXIST C:\USOS9X\LOGS\BLDIR.TMP DEL C:\USOS9X\LOGS\BLDIR.TMP
SET U9BN=
IF NOT EXIST C:\USOS9X\BOOTLOG.ON GOTO BLDONE
IF NOT EXIST C:\WINDOWS\COMMAND\FIND.EXE GOTO BLDONE
IF EXIST C:\USOS9X\FIRSTBT.OK GOTO BLREST
IF EXIST C:\USOS9X\FIRSTBT.ERR GOTO BLREST
C:\WINDOWS\COMMAND\FIND.EXE /I "BOOTLOG=1" < C:\MSDOS.SYS > NUL
IF ERRORLEVEL 1 GOTO BLADD
ECHO MSDOS.SYS BootLog=1 present>> C:\USOS9X\LOGS\BOOTSEQ.TXT
GOTO BLDONE
:BLADD
ECHO MSDOS.SYS without BootLog=1: added again until FIRSTBT.OK>> C:\USOS9X\LOGS\BOOTSEQ.TXT
IF EXIST C:\USOS9X\LOGS\BOOTLOG.ORG GOTO BLSAVED
C:\WINDOWS\COMMAND\FIND.EXE /I "BOOTLOG=" < C:\MSDOS.SYS > C:\USOS9X\LOGS\BOOTLOG.ORG
:BLSAVED
C:\WINDOWS\COMMAND\ATTRIB.EXE -H -S -R C:\MSDOS.SYS
C:\WINDOWS\COMMAND\FIND.EXE /V /I "BOOTLOG=" < C:\MSDOS.SYS > C:\USOS9X\MSDOS.BL1
ECHO [Options]>> C:\USOS9X\MSDOS.BL1
ECHO BootLog=1>> C:\USOS9X\MSDOS.BL1
C:\WINDOWS\COMMAND\FIND.EXE /I "WINDIR=" < C:\USOS9X\MSDOS.BL1 > NUL
IF ERRORLEVEL 1 GOTO BLLOCK
COPY /Y C:\USOS9X\MSDOS.BL1 C:\MSDOS.SYS > NUL
ECHO BootLog=1 added by FIRSTBT.BAT> C:\USOS9X\LOGS\BOOTLOG.FRC
GOTO BLLOCK
:BLREST
IF NOT EXIST C:\USOS9X\LOGS\BOOTLOG.FRC GOTO BLDONE
ECHO MSDOS.SYS: the profile's BootLog lines put back>> C:\USOS9X\LOGS\BOOTSEQ.TXT
C:\WINDOWS\COMMAND\ATTRIB.EXE -H -S -R C:\MSDOS.SYS
C:\WINDOWS\COMMAND\FIND.EXE /V /I "BOOTLOG=" < C:\MSDOS.SYS > C:\USOS9X\MSDOS.BL1
COPY /B C:\USOS9X\MSDOS.BL1 + C:\USOS9X\LOGS\BOOTLOG.ORG C:\USOS9X\MSDOS.BL2 > NUL
C:\WINDOWS\COMMAND\FIND.EXE /I "WINDIR=" < C:\USOS9X\MSDOS.BL2 > NUL
IF ERRORLEVEL 1 GOTO BLLOCK
COPY /Y C:\USOS9X\MSDOS.BL2 C:\MSDOS.SYS > NUL
DEL C:\USOS9X\LOGS\BOOTLOG.FRC
:BLLOCK
C:\WINDOWS\COMMAND\ATTRIB.EXE +H +S +R C:\MSDOS.SYS
:BLDONE
IF EXIST C:\USOS9X\FIRSTBT.OK GOTO BSEND
IF NOT EXIST C:\USOS9X\FIRSTBT.ERR GOTO BSDONE
:BSEND
ECHO FIRSTBT.OK or FIRSTBT.ERR seen> C:\USOS9X\LOGS\BOOTSEQ.END
:BSDONE
EOF
}
w9x_firstboot_write() {
    case "$2" in
        '4 0 0 950') fbon='source950 first complete desktop' ;;
        '4 0 0 1068'|'4 0 0 1111'|'4 0 0 1212'|'4 0 0 1214'|'4 0 0 1216') fbon="95 OSR2 ($2) first complete desktop" ;;
        '4 10 0 1998') fbon='98 FE (4 10 0 1998) first complete desktop' ;;
        '4 10 0 2222') fbon='98 SE (4 10 0 2222) first complete desktop' ;;
        *) return 1 ;;
    esac
    [ -f "$1/USOSFB.EXE" ] || return 1
    printf '%s\r\n' "$fbon" > "$1/FIRSTBT.ON" || return 1
    sed 's/$/\r/' > "$1/FIRSTBT.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce]
"USOSFirstBoot"="C:\\USOS9X\\USOSFB.EXE"
EOF
    printf '[boot]\r\nshell=Explorer.exe\r\n' > "$1/SHELLHDR.INI" || return 1
    case "$2" in
        '4 10 0 '*) printf 'MSDOS.SYS BootLog=1 kept until FIRSTBT.OK (98 only)\r\n' > "$1/BOOTLOG.ON" || return 1 ;;
        *) rm -f "$1/BOOTLOG.ON" ;;
    esac
    { cat <<'EOF'
@ECHO OFF
IF NOT EXIST C:\USOS9X\SHELL.ON GOTO SHLEND
IF NOT EXIST C:\WINDOWS\SYSTEM.INI GOTO SHLEND
IF NOT EXIST C:\USOS9X\SHELLHDR.INI GOTO SHLEND
IF EXIST C:\USOS9X\FIRSTBT.OK GOTO SHLFIX
IF EXIST C:\USOS9X\FIRSTBT.ERR GOTO SHLFIX
IF NOT EXIST C:\USOS9X\USOSFB.EXE GOTO SHLFIX
IF NOT EXIST C:\USOS9X\SHELLRUN.FLG GOTO SHLEND
ECHO USOSFB shell boot ended without its own restart> C:\USOS9X\SHELL.BAD
:SHLFIX
C:\WINDOWS\COMMAND\FIND.EXE /I "SHELL=C:\USOS9X\USOSFB.EXE" < C:\WINDOWS\SYSTEM.INI > NUL
IF ERRORLEVEL 1 GOTO SHLOFF
IF EXIST C:\USOS9X\SYSTEM.SHN DEL C:\USOS9X\SYSTEM.SHN
C:\WINDOWS\COMMAND\FIND.EXE /V /I "[boot]" < C:\WINDOWS\SYSTEM.INI > C:\USOS9X\SYSTEM.SH1
C:\WINDOWS\COMMAND\FIND.EXE /V /I "SHELL=C:\USOS9X\USOSFB.EXE" < C:\USOS9X\SYSTEM.SH1 > C:\USOS9X\SYSTEM.SH2
COPY /B C:\USOS9X\SHELLHDR.INI + C:\USOS9X\SYSTEM.SH2 C:\USOS9X\SYSTEM.SHN > NUL
IF NOT EXIST C:\USOS9X\SYSTEM.SHN GOTO SHLLOG
C:\WINDOWS\COMMAND\FIND.EXE /I "[386Enh]" < C:\USOS9X\SYSTEM.SHN > NUL
IF ERRORLEVEL 1 GOTO SHLLOG
C:\WINDOWS\COMMAND\FIND.EXE /I "USOSFB.EXE" < C:\USOS9X\SYSTEM.SHN > NUL
IF NOT ERRORLEVEL 1 GOTO SHLLOG
COPY /Y C:\WINDOWS\SYSTEM.INI C:\USOS9X\SYSTEM.SHO > NUL
COPY /Y C:\USOS9X\SYSTEM.SHN C:\WINDOWS\SYSTEM.INI > NUL
C:\WINDOWS\COMMAND\FIND.EXE /I "USOSFB.EXE" < C:\WINDOWS\SYSTEM.INI > NUL
IF NOT ERRORLEVEL 1 GOTO SHLLOG
ECHO FIRSTBT: SYSTEM.INI shell=Explorer.exe restored in real mode>> C:\USOS9X\USOSLOG.TXT
:SHLOFF
DEL C:\USOS9X\SHELL.ON
IF EXIST C:\USOS9X\SHELLRUN.FLG DEL C:\USOS9X\SHELLRUN.FLG
GOTO SHLEND
:SHLLOG
ECHO FIRSTBT: SYSTEM.INI shell=USOSFB not restored in real mode>> C:\USOS9X\USOSLOG.TXT
:SHLEND
EOF
    w9x_bootseq_block
    cat <<'EOF'
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
    } | sed 's/$/\r/' > "$1/FIRSTBT.BAT"
}
