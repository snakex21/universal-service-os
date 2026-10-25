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
# TZI for both zones and the same RunOnce\Setup step names (SETUPC.INF). The
# Windows 95 OSR2.1 PL CD (2026-10-06): the same "Strefa czasowa" step and the
# same TZI under other key names ("Warsaw" for Central European; "Eastern" as
# on 98). Only the zones of the menu's default languages
# so far; any other zone returns 1 and MSBATCH TimeZone stays alone.
#
# Windows 95 RTM / OSR1 (4.00.950; arg 4 = 950, arg 5 = PL / EN CD language):
# its TIMEZONE.INF (PL and EN CDs, the same 51 keys) names Central European
# "Lisbon Warsaw" and still has the pre-1996 EU rule (summer time ends on the
# last Sunday of September: TZI 09/5 02:00, 03/5 01:00). TZFIX.REG then also
# rewrites that zone's TZI to the EU rule, so Date/Time keeps it. Step names:
# "Strefa czasowa" (PL SETUPC.INF), "Time zone" (EN; registry value names are
# case-insensitive, so TZRO2's "Time Zone" replaces it; FIND /I). 950's
# MSPRINT.DLL also queues RunOnce\Setup "Drukarki" (PL) / "Set up printer"
# (EN) = "rundll32.exe sysdm.cpl,InstallDevice_Rundll printer,,0", the Add
# Printer wizard on the first desktop: TZPR1.REG / TZPR2.REG replace it with
# the same harmless command (X470 950 PL SYSTEM.1ST, 2026-10-25).

# w9x_tz950_key KEY: the 950 TIMEZONE.INF key for an OSR2.1 / 98 key
# (src/flow/answer/msbatch.zig timeZoneName95, tools/w9x_csmwrap_prepare.sh
# w9x_release_time_zone); empty when 950 has no such zone (Setup asks).
# E. Australia (Brisbane, no summer time) has no 950 key: dropped.
w9x_tz950_key() {
    case "$1" in
        Warsaw|'Central European') printf 'Lisbon Warsaw' ;;
        'Prague Bratislava'|'Central Europe') printf 'Czech' ;;
        Beijing|China) printf 'China' ;;
        'AUS Eastern') printf 'Sydney' ;;
        GTB|FLE) printf 'GFT' ;;
        'SE Asia') printf 'Bangkok' ;;
        Arab) printf 'Saudi Arabia' ;;
        GMT|'Lisbon Warsaw'|Romance|'W. Europe'|'E. Europe'|Czech|GFT|'E. South America'|Atlantic|Eastern|Central|\
        Mountain|Pacific|Alaskan|Hawaiian|Samoa|'New Zealand'|Sydney|'Cen. Australia'|Tokyo|Taipei|Bangkok|India|\
        Arabian|Iran|'Saudi Arabia'|Israel|Newfoundland|Azores|Mid-Atlantic|Greenwich|'SA Eastern'|'SA Western'|\
        'US Eastern'|'SA Pacific'|'Canada Central'|Mexico|'US Mountain'|Dateline|Fiji|'Central Pacific'|Tasmania|\
        'West Pacific'|'AUS Central'|'Central Asia'|'West Asia'|Afghanistan|Egypt|'South Africa'|Russian) printf '%s' "$1" ;;
    esac
}

# w9x_msbatch_tz950 MSBATCH.INF: [Setup] TimeZone="<OSR2.1 key>" becomes the
# 950 key (the line goes when 950 has no such zone). The UEFI menu and the
# answer profiles render the OSR2.1 name: they do not know the CD's build.
w9x_msbatch_tz950() {
    old=$(sed -n 's/^TimeZone="\([^"]*\)".*$/\1/p' "$1" | head -n 1)
    [ -n "$old" ] || return 0
    new=$(w9x_tz950_key "$old")
    # Keys are letters, digits, spaces, dots and dashes (no sed specials).
    # The file stays CR LF (MSBATCH.INF is a DOS file).
    if [ -n "$new" ]; then tr -d '\r' < "$1" | sed "s/^TimeZone=\"[^\"]*\"/TimeZone=\"$new\"/" | sed 's/$/\r/' > "$1.tz"
    else tr -d '\r' < "$1" | sed '/^TimeZone="/d' | sed 's/$/\r/' > "$1.tz"
    fi && mv "$1.tz" "$1"
}

w9x_tzfix_hex4() {
    v=$1
    [ "$v" -ge 0 ] || v=$((v + 4294967296))
    printf '%02x,%02x,%02x,%02x' $((v & 255)) $(((v >> 8) & 255)) $(((v >> 16) & 255)) $(((v >> 24) & 255))
}

w9x_tzfix_write() {
    zone=$1 dir=$2 month=${3:-$(date +%m 2>/dev/null || echo 1)} src=${4:-} lang=${5:-PL}
    month=${month#0} tzi=''
    # bias (minutes, UTC = local + bias), daylight bias, StandardStart,
    # DaylightStart (SYSTEMTIME: month, day-of-week, week 1-5, hour), names
    # (Windows-1250 bytes; cosmetic, Date/Time shows the zone list's text).
    case "$zone" in
        'Central European'|Warsaw)
            bias=-60 dbias=-60
            std='00,00,0a,00,00,00,05,00,03,00,00,00,00,00,00,00'
            dlt='00,00,03,00,00,00,05,00,02,00,00,00,00,00,00,00'
            sname='Europa \214rodkowa (czas stand.)' dname='Europa \214rodkowa (czas letni)'
            dst_from=4 dst_to=10 ;;
        'Lisbon Warsaw')
            [ "$src" = 950 ] || return 1
            bias=-60 dbias=-60
            std='00,00,0a,00,00,00,05,00,03,00,00,00,00,00,00,00'
            dlt='00,00,03,00,00,00,05,00,02,00,00,00,00,00,00,00'
            if [ "$lang" = EN ]; then sname='Lisbon Warsaw Standard Time' dname='Lisbon Warsaw Daylight Time'
            else sname='Lizbona/Warszawa - czas zimowy' dname='Lizbona/Warszawa - czas letni'; fi
            tzi="c4,ff,ff,ff,00,00,00,00,c4,ff,ff,ff,$std,$dlt"
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
        # 44-byte TZI (Bias, StandardBias, DaylightBias, StandardDate,
        # DaylightDate), wrapped like REGEDIT's own export.
        [ -z "$tzi" ] || printf '[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Time Zones\\%s]\r\n"TZI"=hex:%s,\\\r\n  %s,\\\r\n  %s\r\n\r\n' \
            "$zone" "$(printf '%s' "$tzi" | cut -d, -f1-12)" "$(printf '%s' "$tzi" | cut -d, -f13-28)" "$(printf '%s' "$tzi" | cut -d, -f29-44)"
    } > "$dir/TZFIX.REG" || return 1
    printf 'REGEDIT4\r\n\r\n[%s]\r\n"Strefa czasowa"="%s"\r\n\r\n' "$run" "$harmless" > "$dir/TZRO1.REG" || return 1
    printf 'REGEDIT4\r\n\r\n[%s]\r\n"Time Zone"="%s"\r\n\r\n' "$run" "$harmless" > "$dir/TZRO2.REG" || return 1
    U='C:\USOS9X\'
    R='REGEDIT /L:SYSTEM.DAT /R:USER.DAT'
    F='C:\WINDOWS\COMMAND\FIND.EXE'
    A='C:\WINDOWS\COMMAND\ATTRIB.EXE'
    check=${std%,00,00,00,00,00,00,00}
    rm -f "$dir/TZPR1.REG" "$dir/TZPR2.REG"
    printer='REM -' printer_check='REM -'
    if [ "$src" = 950 ]; then
        printf 'REGEDIT4\r\n\r\n[%s]\r\n"Drukarki"="%s"\r\n\r\n' "$run" "$harmless" > "$dir/TZPR1.REG" || return 1
        printf 'REGEDIT4\r\n\r\n[%s]\r\n"Set up printer"="%s"\r\n\r\n' "$run" "$harmless" > "$dir/TZPR2.REG" || return 1
        printer="REM 950: MSPRINT.DLL's Add Printer wizard step goes too.
$F /I \"Drukarki\" TZ0.CHK > NUL
IF NOT ERRORLEVEL 1 $R ${U}TZPR1.REG
$F /I \"Set up printer\" TZ0.CHK > NUL
IF NOT ERRORLEVEL 1 $R ${U}TZPR2.REG"
        printer_check="$F /I \"InstallDevice_Rundll\" TZ2.CHK > NUL
IF ERRORLEVEL 1 GOTO OKALL
ECHO ok-printer-left> ${U}TZFIX.OK
GOTO ATTR
:OKALL"
    fi
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
$A -S -R -H SYSTEM.DAT
$A -S -R -H USER.DAT
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
$F /I "Time Zone" TZ0.CHK > NUL
IF NOT ERRORLEVEL 1 $R ${U}TZRO2.REG
$printer
$R /E TZ2.CHK $run
IF NOT EXIST TZ2.CHK GOTO BAD
$F /I "TIMEDATE" TZ2.CHK > NUL
IF ERRORLEVEL 1 GOTO OKSTEP
ECHO ok-zone-only> ${U}TZFIX.OK
GOTO ATTR
:OKSTEP
$printer_check
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
$A +S +R +H SYSTEM.DAT
$A +S +R +H USER.DAT
CD \\
:END
EOF
}
