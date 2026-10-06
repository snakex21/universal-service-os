# Windows 98 / 98 SE under CSMWrap: the first-boot time zone step, second
# line of defence next to MSBATCH.INF [Setup] TimeZone (docs/win9x-modern-
# 2026-09-30.md section 4e). Sourced by tools/w9x_csmwrap_target.sh.
#
# w9x_tzfix_write <9x zone key> <C:\USOS9X folder> [month 1-12]
# writes TZFIX.BAT, TZFIX.REG and TZRO1.REG / TZRO2.REG there; AUTOEXEC.BAT
# (src/platform/bios/dos_startup.cmd) calls TZFIX.BAT before every Windows
# start. TZFIX.BAT acts once, in real-mode DOS, when the registry exists:
#   1. backs up SYSTEM.DAT / USER.DAT (C:\USOS9X\SYSTEM.TB / USER.TB),
#   2. only if RunOnce\Setup still holds the Date/Time step (TIMEDATE.CPL /f,
#      SETUPC.INF [NewWin.AddReg]): imports TimeZoneInformation for the zone
#      and replaces that step with a harmless command (value name per CD
#      language: "Strefa czasowa" on Polish CDs, "Time Zone" on English ones),
#   3. checks the zone with REGEDIT /E + FIND; on a failed import it restores
#      the backup (TZFIX.RUN: one attempt, never repeated after a crash).
#      Result in C:\USOS9X\TZFIX.OK or TZFIX.BAD.
# Proven by hand on the X470 (98 SE PL OEM, 2026-10-06, TZFIX.OK ok-deleted).
#
# Zone data (TZI) from the Windows 98 SE CD's TIMEZONE.INF (Time Zones\<key>
# in the installed registry); the Windows 98 CD (4.10.1998, PL) has the same
# TZI for both zones and the same RunOnce\Setup step names (SETUPC.INF). Only the zones of the menu's default languages
# so far; any other zone returns 1 and MSBATCH TimeZone stays alone.

w9x_tzfix_hex4() {
    v=$1
    [ "$v" -ge 0 ] || v=$((v + 4294967296))
    printf '%02x,%02x,%02x,%02x' $((v & 255)) $(((v >> 8) & 255)) $(((v >> 16) & 255)) $(((v >> 24) & 255))
}

w9x_tzfix_write() {
    zone=$1 dir=$2 month=${3:-$(date +%m 2>/dev/null || echo 1)}
    month=${month#0}
    # bias (minutes, UTC = local + bias), daylight bias, StandardStart,
    # DaylightStart (SYSTEMTIME: month, day-of-week, week 1-5, hour), names
    # (Windows-1250 bytes; cosmetic, Date/Time shows the zone list's text).
    case "$zone" in
        'Central European')
            bias=-60 dbias=-60
            std='00,00,0a,00,00,00,05,00,03,00,00,00,00,00,00,00'
            dlt='00,00,03,00,00,00,05,00,02,00,00,00,00,00,00,00'
            sname='Europa \214rodkowa (czas stand.)' dname='Europa \214rodkowa (czas letni)'
            dst_from=4 dst_to=10 ;;
        Eastern)
            bias=300 dbias=-60
            std='00,00,0a,00,00,00,05,00,02,00,00,00,00,00,00,00'
            dlt='00,00,04,00,00,00,01,00,02,00,00,00,00,00,00,00'
            sname='Eastern Standard Time' dname='Eastern Daylight Time'
            dst_from=4 dst_to=10 ;;
        *) return 1 ;;
    esac
    active=$bias
    if [ "$month" -ge "$dst_from" ] && [ "$month" -le "$dst_to" ]; then active=$((bias + dbias)); fi
    key='HKEY_LOCAL_MACHINE\System\CurrentControlSet\control\TimeZoneInformation'
    run='HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce\Setup'
    harmless='RUNDLL32.EXE SHELL32.DLL,Control_FillCache_RunDLL'
    {
        printf 'REGEDIT4\r\n\r\n[%s]\r\n' "$key"
        printf '"StandardName"="'; printf "$sname"; printf '"\r\n'
        printf '"DaylightName"="'; printf "$dname"; printf '"\r\n'
        printf '"Bias"=hex:%s\r\n"StandardBias"=hex:00,00,00,00\r\n"DaylightBias"=hex:%s\r\n' "$(w9x_tzfix_hex4 "$bias")" "$(w9x_tzfix_hex4 "$dbias")"
        printf '"StandardStart"=hex:%s\r\n"DaylightStart"=hex:%s\r\n' "$std" "$dlt"
        printf '"ActiveTimeBias"=hex:%s\r\n\r\n' "$(w9x_tzfix_hex4 "$active")"
    } > "$dir/TZFIX.REG" || return 1
    printf 'REGEDIT4\r\n\r\n[%s]\r\n"Strefa czasowa"="%s"\r\n\r\n' "$run" "$harmless" > "$dir/TZRO1.REG" || return 1
    printf 'REGEDIT4\r\n\r\n[%s]\r\n"Time Zone"="%s"\r\n\r\n' "$run" "$harmless" > "$dir/TZRO2.REG" || return 1
    U='C:\USOS9X\'
    R='REGEDIT /L:SYSTEM.DAT /R:USER.DAT'
    F='C:\WINDOWS\COMMAND\FIND.EXE'
    A='C:\WINDOWS\COMMAND\ATTRIB.EXE'
    check=${std%,00,00,00,00,00,00,00}
    sed 's/$/\r/' > "$dir/TZFIX.BAT" <<EOF || return 1
@ECHO OFF
REM USOS: first-boot time zone step (tools/w9x_tzfix.sh), zone "$zone".
REM Runs from AUTOEXEC.BAT before Windows starts, at most once.
REM Undo: copy ${U}SYSTEM.TB / USER.TB back over C:\WINDOWS\*.DAT.
IF EXIST ${U}TZFIX.OK GOTO END
IF EXIST ${U}TZFIX.BAD GOTO END
IF EXIST ${U}TZFIX.RUN GOTO END
IF NOT EXIST ${U}TZFIX.REG GOTO END
IF NOT EXIST C:\WINDOWS\REGEDIT.EXE GOTO END
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END
IF NOT EXIST $F GOTO END
IF NOT EXIST $A GOTO END
C:
CD \WINDOWS
$A -R -H SYSTEM.DAT
$A -R -H USER.DAT
$R /E TZ0.CHK $run
IF NOT EXIST TZ0.CHK GOTO ATTR
$F /I "TIMEDATE" TZ0.CHK > NUL
IF NOT ERRORLEVEL 1 GOTO PENDING
ECHO not-pending> ${U}TZFIX.OK
GOTO ATTR
REM One attempt only: a crash in the middle never repeats it.
:PENDING
ECHO run> ${U}TZFIX.RUN
COPY /Y SYSTEM.DAT ${U}SYSTEM.TB > NUL
COPY /Y USER.DAT ${U}USER.TB > NUL
IF NOT EXIST ${U}SYSTEM.TB GOTO ATTR
IF NOT EXIST ${U}USER.TB GOTO ATTR
$R ${U}TZFIX.REG
$R /E TZ1.CHK $key
IF NOT EXIST TZ1.CHK GOTO BAD
$F "$check" TZ1.CHK > NUL
IF ERRORLEVEL 1 GOTO BAD
$F "Strefa czasowa" TZ0.CHK > NUL
IF NOT ERRORLEVEL 1 $R ${U}TZRO1.REG
$F "Time Zone" TZ0.CHK > NUL
IF NOT ERRORLEVEL 1 $R ${U}TZRO2.REG
$R /E TZ2.CHK $run
IF NOT EXIST TZ2.CHK GOTO BAD
$F /I "TIMEDATE" TZ2.CHK > NUL
IF ERRORLEVEL 1 GOTO OKSTEP
ECHO ok-zone-only> ${U}TZFIX.OK
GOTO ATTR
:OKSTEP
ECHO ok> ${U}TZFIX.OK
GOTO ATTR
:BAD
ECHO USOS: time zone registry change failed, restoring the registry backup.
COPY /Y ${U}SYSTEM.TB SYSTEM.DAT > NUL
COPY /Y ${U}USER.TB USER.DAT > NUL
ECHO bad> ${U}TZFIX.BAD
REM SYSTEM.DAT / USER.DAT stay as Setup left them otherwise.
:ATTR
FOR %%F IN (TZ0 TZ1 TZ2) DO IF EXIST %%F.CHK DEL %%F.CHK
$A +R +H SYSTEM.DAT
$A +R +H USER.DAT
CD \\
:END
EOF
}
