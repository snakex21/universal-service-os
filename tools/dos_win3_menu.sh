#!/bin/sh
# MS-DOS 6.22 / Windows 1.x-3.x start files, sourced by dos_csmwrap_target.sh
# (micro-Linux, BusyBox sh) after the helpers were copied to C:\USOSDOS ($1):
#
#   dos_win_name SYSTEM IMAGE      the installed product, for the menus
#   dos_menu_names DIR SYSTEM IMAGE  the W3/W1 start menus name it
#   dos_regional_apply DIR INI     COUNTRY / code page / KEYB from DOS.INI
#                                  (src/flow/answer/dos.zig) into the start
#                                  files; manual: W3PL.KEY is not used
#   dos_i18n_apply DIR TEXT LANG CP  the DOS-side texts (menus, batch
#                                  messages) in the profile / USOS menu
#                                  language (after dos_regional_apply,
#                                  before dos_menu_names)
#   dos_winsock_apply DIR INI SRC C [SYSTEM]  Windows 3.1 / 3.11 / WfW only, DOS.INI
#                                  winsock=yes: the opt-in Winsock set (SRC =
#                                  EFI\USOS\dos-native\winsock16) into C:\NET
#                                  (C = mounted target root), queue lines in
#                                  DIR's start files
#
# Every file in DIR is CRLF text (tools/build_dos_native_support.py); the
# lines written here are CRLF too. Nothing outside DIR is touched, except
# C:\NET by dos_winsock_apply.

# The product name of a catalog id; a letter revision in the image or
# folder name is kept (Windows 3.0a EN.iso -> Windows 3.0a).
dos_win_name() {
    case "$1" in
        windows-1-01) dwn='Windows 1.01' ;;
        windows-1-04) dwn='Windows 1.04' ;;
        windows-2-03) dwn='Windows 2.03' ;;
        windows-2-11-286) dwn='Windows/286 2.11' ;;
        windows-2-11-386) dwn='Windows/386 2.11' ;;
        windows-3-0) dwn='Windows 3.0' ;;
        windows-3-1) dwn='Windows 3.1' ;;
        windows-3-11) dwn='Windows 3.11' ;;
        windows-wfw-3-11) dwn='Windows for Workgroups 3.11' ;;
        *) return 1 ;;
    esac
    dwb=$(basename "${2:-}")
    case "$dwb" in
        "$dwn"[a-z]|"$dwn"[a-z][!0-9]*)
            dwn="$dwn$(printf '%s' "$dwb" | cut -c$((${#dwn} + 1)))" ;;
    esac
    printf '%s\n' "$dwn"
}

# sed on one CRLF file in place (BusyBox sed -i).
dos_sed() {
    [ -f "$1" ] || return 0
    dsf=$1; shift
    sed -i "$@" "$dsf"
}

# The start menus show the installed product instead of "Windows".
dos_menu_names() {
    dmn=$(dos_win_name "$2" "${3:-}") || return 0
    # '|' as the sed delimiter: Windows/386 has a slash.
    for dmf in "$1/W3CONFIG.SYS" "$1/W3CONFIG.CSM"; do
        if [ "$2" = windows-wfw-3-11 ]; then
            # W3AUTO.BAT starts every WfW item in 386 enhanced mode. The two
            # texts in the menu language (dos_text, after dos_i18n_apply);
            # awk compares only the ASCII start of a line and prints the
            # others whole (code page bytes).
            dmt1=$(dos_text dos.menu.wfw_enhanced)
            dmt2=$(dos_text dos.menu.wfw_smartdrv)
            [ -n "$dmt1" ] || dmt1='386 enhanced mode (default)'
            [ -n "$dmt2" ] || dmt2='386 mode with SMARTDRV'
            [ ! -f "$dmf" ] || DMN_STD="$dmn - $dmt1" DMN_386="$dmn - $dmt2" \
                awk '{ l = $0; cr = (index(l, "\r") > 0) ? "\r" : ""
                    if (index(l, "menuitem=WINSTD,") == 1) { printf "menuitem=WINSTD,%s%s\n", ENVIRON["DMN_STD"], cr; next }
                    if (index(l, "menuitem=WIN386,") == 1) { printf "menuitem=WIN386,%s%s\n", ENVIRON["DMN_386"], cr; next }
                    print }' "$dmf" > "$dmf.new" && mv "$dmf.new" "$dmf"
        else
            dos_sed "$dmf" -e "s|^menuitem=WINSTD,Windows |menuitem=WINSTD,$dmn |" -e "s|^menuitem=WIN386,Windows |menuitem=WIN386,$dmn |"
        fi
        dos_sed "$dmf" -e "s|^menuitem=WINSET,\\(.*\\) - Windows Setup|menuitem=WINSET,\\1 - $dmn Setup|"
    done
    for dmf in "$1/W1CONFIG.SYS" "$1/W1CONFIG.CSM"; do
        dos_sed "$dmf" -e "s|^menuitem=WINSTD,Windows (|menuitem=WINSTD,$dmn (|"
        # WIN /S exists in Windows 3.0 only (SYSTEM\DOSX.EXE).
        if [ "$2" = windows-3-0 ]; then
            dos_sed "$dmf" -e "s|^menuitem=WINREAL,Windows 3\\.0 |menuitem=WINREAL,$dmn |"
        else
            dos_sed "$dmf" -e '/^menuitem=WINREAL,/d'
        fi
    done
    for dmf in "$1/W3AUTO.BAT" "$1/W3AUTO.CSM"; do
        dos_sed "$dmf" -e "s|^echo Windows 3\\.x - |echo $dmn - |"
    done
}

# One value of DOS.INI (key=value, CRLF).
dos_ini_value() {
    awk -F= -v k="$2" '{ sub(/\r$/, "") } $1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

# DOS.INI -> REGCFG.SYS / REGAUTO.BAT in DIR (INSTALL.BAT appends them to
# the MS-DOS-only start files) and the same lines in the Windows start menus:
# a [common] block at the end of W3CONFIG / W1CONFIG and the AUTOEXEC lines
# after "set TEMP=" of W3AUTO / W1AUTO. Values are checked against fixed
# shapes, so nothing else reaches CONFIG.SYS.
dos_regional_apply() {
    [ -f "$2" ] || return 0
    dra_mode=$(dos_ini_value "$2" mode)
    if [ "$dra_mode" = manual ]; then
        # The regional text pages of Windows 3.1 Setup (W3PL.KEY) are left
        # to the user; nothing is written into the start files.
        rm -f "$1/W3PL.KEY"
        echo 'DOS regional settings: manual (nothing written, Setup pages not answered)'
        return 0
    fi
    dra_country=$(dos_ini_value "$2" country)
    dra_cp=$(dos_ini_value "$2" codepage)
    dra_cpi=$(dos_ini_value "$2" cpi)
    dra_keyb=$(dos_ini_value "$2" keyb)
    dra_kfile=$(dos_ini_value "$2" keybfile)
    case "$dra_country" in [0-9][0-9][0-9]) ;; *) echo 'DOS regional settings: none (no country)'; return 0 ;; esac
    case "$dra_cp" in [0-9][0-9][0-9]) ;; *) echo "DOS regional settings: bad code page $dra_cp" >&2; return 1 ;; esac
    case "$dra_cpi" in ''|EGA.CPI|EGA2.CPI|EGA3.CPI) ;; *) echo "DOS regional settings: bad CPI $dra_cpi" >&2; return 1 ;; esac
    case "$dra_keyb" in ''|[A-Z][A-Z]) ;; *) echo "DOS regional settings: bad KEYB $dra_keyb" >&2; return 1 ;; esac
    case "$dra_kfile" in ''|KEYBOARD.SYS|KEYBRD2.SYS) ;; *) echo "DOS regional settings: bad keyboard file $dra_kfile" >&2; return 1 ;; esac
    {
        printf 'COUNTRY=%s,%s,C:\\DOS\\COUNTRY.SYS\r\n' "$dra_country" "$dra_cp"
        [ -z "$dra_cpi" ] || printf 'DEVICE=C:\\DOS\\DISPLAY.SYS CON=(EGA,,1)\r\n'
    } > "$1/REGCFG.SYS"
    {
        if [ -n "$dra_cpi" ]; then
            printf 'C:\\DOS\\MODE.COM CON CODEPAGE PREPARE=((%s) C:\\DOS\\%s) >nul\r\n' "$dra_cp" "$dra_cpi"
            printf 'C:\\DOS\\MODE.COM CON CODEPAGE SELECT=%s >nul\r\n' "$dra_cp"
        fi
        [ -z "$dra_keyb" ] || printf 'C:\\DOS\\KEYB.COM %s,,C:\\DOS\\%s\r\n' "$dra_keyb" "${dra_kfile:-KEYBOARD.SYS}"
    } > "$1/REGAUTO.BAT"
    for draf in "$1/W3CONFIG.SYS" "$1/W3CONFIG.CSM" "$1/W1CONFIG.SYS" "$1/W1CONFIG.CSM"; do
        [ -f "$draf" ] || continue
        { printf '\r\n; USOS: regional settings of the answer profile (DOS.INI)\r\n[common]\r\n'; cat "$1/REGCFG.SYS"; } >> "$draf"
    done
    if [ -s "$1/REGAUTO.BAT" ]; then
        for draf in "$1/W3AUTO.BAT" "$1/W3AUTO.CSM" "$1/W1AUTO.BAT" "$1/W1AUTO.CSM"; do
            [ -f "$draf" ] || continue
            awk -v f="$1/REGAUTO.BAT" '{ print } !done && /^set TEMP=/ { while ((getline l < f) > 0) print l; done = 1 }' "$draf" > "$draf.new" && mv "$draf.new" "$draf" || return 1
        done
    else
        rm -f "$1/REGAUTO.BAT"
    fi
    echo "DOS regional settings: COUNTRY=$dra_country code page $dra_cp${dra_cpi:+ ($dra_cpi)}${dra_keyb:+ KEYB $dra_keyb}"
}

# Windows 3.1 / 3.11 / WfW 3.11 Winsock (experimental, answer profile
# dos_winsock -> DOS.INI winsock=yes; docs/winsock-etap1-5-2026-10-24.md).
# Without that line nothing here runs and the install is the same as before.
#   C:\NET\WIN16    GETHTTP.EXE, TESTLOAD.EXE, WINSOCK.DLL, WINSOCK.TXT,
#                   STAGE.LOG (written before the first DOS boot)
#   C:\NET          USOSPKTQ.COM; NETSTART.BAT = the queue variant
#                   (INSTALL.BAT copies DIR's NETSTART.BAT there)
#   W3AUTO          "set USOSPKT_QUEUE=1" before the NETSTART call
#   WINMENU.BAT     after Setup: WINSOCK.DLL into C:\WINDOWS unless one is
#                   there already (logged in STAGE.LOG)
#   SETUP.INF       icon "USOS Winsock test (GETHTTP)" in the Main group
#   SYSTEM ($5)     windows-3-1 / windows-3-11: 386 enhanced mode becomes
#                   the default start mode (dos_winsock_enhanced); WfW
#                   3.11 starts every item in 386 enhanced mode already
dos_winsock_apply() {
    [ -f "$2" ] || return 0
    [ "$(dos_ini_value "$2" winsock)" = yes ] || return 0
    for dwf in WINSOCK.DLL GETHTTP.EXE TESTLOAD.EXE USOSPKTQ.COM NETSTART.BAT WINSOCK.TXT; do
        [ -f "$3/$dwf" ] || { echo "Winsock: missing $dwf in the USOS files, option not applied" >&2; return 1; }
    done
    mkdir -p "$4/NET/WIN16" || return 1
    for dwf in WINSOCK.DLL GETHTTP.EXE TESTLOAD.EXE WINSOCK.TXT; do
        cp "$3/$dwf" "$4/NET/WIN16/$dwf" || return 1
    done
    cp "$3/USOSPKTQ.COM" "$4/NET/USOSPKTQ.COM" || return 1
    cp "$3/NETSTART.BAT" "$1/NETSTART.BAT" || return 1
    # Its messages in the menu language, as the default NETSTART.BAT.
    dos_i18n_file "$1/NETSTART.BAT" "$DOS_I18N_437" || return 1
    printf 'USOS Winsock (answer profile): C:\\NET\\WIN16 and C:\\NET\\USOSPKTQ.COM staged before the first boot\r\n' > "$4/NET/WIN16/STAGE.LOG"
    for dwf in "$1/W3AUTO.BAT" "$1/W3AUTO.CSM"; do
        [ -f "$dwf" ] || continue
        awk '!done && /^if exist C:\\NET\\NETSTART\.BAT call / { printf "set USOSPKT_QUEUE=1\r\n"; done = 1 } { print }' "$dwf" > "$dwf.new" && mv "$dwf.new" "$dwf" || return 1
        grep -q '^set USOSPKT_QUEUE=1' "$dwf" || { echo "Winsock: no NETSTART call in $(basename "$dwf")" >&2; return 1; }
    done
    awk '{ print } !done && /^:ini_done/ {
        printf "if exist C:\\WINDOWS\\WINSOCK.DLL echo WINSOCK.DLL: C:\\WINDOWS has one already, kept>>C:\\NET\\WIN16\\STAGE.LOG\r\n"
        printf "if not exist C:\\WINDOWS\\WINSOCK.DLL echo WINSOCK.DLL: copied to C:\\WINDOWS>>C:\\NET\\WIN16\\STAGE.LOG\r\n"
        printf "if not exist C:\\WINDOWS\\WINSOCK.DLL copy C:\\NET\\WIN16\\WINSOCK.DLL C:\\WINDOWS >nul\r\n"
        done = 1 }' "$1/WINMENU.BAT" > "$1/WINMENU.NEW" && mv "$1/WINMENU.NEW" "$1/WINMENU.BAT" || return 1
    grep -q 'WIN16\\WINSOCK.DLL C:\\WINDOWS' "$1/WINMENU.BAT" || { echo 'Winsock: no :ini_done in WINMENU.BAT' >&2; return 1; }
    dwi="$1/WINSETUP/SETUP.INF"
    # Setup creates only the groups it knows (a new [progman.groups] entry
    # is ignored, QEMU 3.1 PL 2026-10-24), so the icon goes into the Main
    # group: the [progman.groups] entry marked ",1" (maximized), group3 in
    # 3.1 / 3.11 / WfW 3.11.
    dwm=$(dos_main_group "$dwi")
    if [ -n "$dwm" ] && grep -qi "^\[$dwm\]" "$dwi" && ! grep -q 'WIN16\\GETHTTP.EXE' "$dwi"; then
        awk -v h="[$dwm]" '{ print } !done { l = $0; sub(/\r$/, "", l) } !done && tolower(l) == tolower(h) {
            printf "\"USOS Winsock test (GETHTTP)\", C:\\NET\\WIN16\\GETHTTP.EXE\r\n"; done = 1 }' "$dwi" > "$dwi.new" && mv "$dwi.new" "$dwi" || return 1
        dwg="icon \"USOS Winsock test (GETHTTP)\" in the Main group ($dwm)"
    else
        dwg='no Main group in SETUP.INF: File > Run C:\NET\WIN16\GETHTTP.EXE'
    fi
    dwe=''
    case "${5:-}" in
        windows-3-1|windows-3-11)
            dos_winsock_enhanced "$1" || return 1
            dwe=', 386 enhanced mode is the default start mode' ;;
    esac
    printf '%s\n' "Winsock (experimental): C:\NET\WIN16 staged, NETSTART queue driver (USOSPKTQ /Q), $dwg$dwe"
}

# Windows 3.1 / 3.11 with the Winsock profile: 386 enhanced mode (WIN /3 /B,
# the existing WIN386 item) becomes the default of the start menu and of
# WIN typed at the DOS prompt; standard mode stays as a menu item and as
# WIN /S. Why: on the X470 (2026-10-24, Windows 3.1 PL, B261024-210648)
# GETHTTP passes in standard mode, but Netscape 3.04 (GPF 002A:A404 in its
# MFC handle map, then a hard freeze) and Opera 3.62 (GPF 000D:4D50) fail
# in standard mode only; in 386 enhanced mode Netscape works. The root cause
# in standard mode (KRNL286/DOSX with 32-bit browser code, or the DLL's
# async path under DOSX) is still being investigated
# (docs/winsock-etap1-5-2026-10-24.md). After dos_menu_names and
# dos_i18n_apply: the menu texts are rewritten in the 437 section of the
# menu language (dos_text), the product name in front of " - " is kept.
dos_winsock_enhanced() {
    dwe_enh=$(dos_text dos.menu.wfw_enhanced)
    dwe_std=$(dos_text dos.menu.winsock_standard)
    [ -n "$dwe_enh" ] || dwe_enh='386 enhanced mode (default)'
    [ -n "$dwe_std" ] || dwe_std='standard mode (alternative)'
    for dwf in "$1/W3CONFIG.SYS" "$1/W3CONFIG.CSM"; do
        [ -f "$dwf" ] || continue
        # Only index()/substr() on the ASCII start of a line (the product
        # name); the texts come from ENVIRON as code page bytes.
        DWE_ENH="$dwe_enh" DWE_STD="$dwe_std" awk '{ l = $0; cr = (index(l, "\r") > 0) ? "\r" : ""
            k = ""
            if (index(l, "menuitem=WINSTD,") == 1) k = "WINSTD"
            if (index(l, "menuitem=WIN386,") == 1) k = "WIN386"
            if (k != "" && index(l, " - ") > 17) {
                n = substr(l, 17, index(l, " - ") - 17)
                printf "menuitem=%s,%s - %s%s\n", k, n, ENVIRON[k == "WINSTD" ? "DWE_STD" : "DWE_ENH"], cr; next }
            if (index(l, "menudefault=WINSTD,") == 1) { sub(/^menudefault=WINSTD,/, "menudefault=WIN386,", l); printf "%s\n", l; next }
            print }' "$dwf" > "$dwf.new" && mv "$dwf.new" "$dwf" || return 1
        grep -q '^menudefault=WIN386,' "$dwf" || { echo "Winsock: no menudefault=WINSTD in $(basename "$dwf")" >&2; return 1; }
    done
    # WIN typed at the DOS prompt (WINRUN.BAT without arguments): 386
    # enhanced mode, as the WfW branch; WIN /S still starts standard mode.
    dwr="$1/WINRUN.BAT"
    [ -f "$dwr" ] || return 0
    awk '!done && /^if exist C:\\WINSETUP\\WFWSETUP\.DL_ goto enhanced/ {
        printf "rem USOS Winsock profile (Windows 3.1 / 3.11): 386 enhanced mode by default.\r\n"
        printf "goto enhanced\r\n"; done = 1 } { print }' "$dwr" > "$dwr.new" && mv "$dwr.new" "$dwr" || return 1
    grep -q '^goto enhanced' "$dwr" || { echo 'Winsock: no WfW line in WINRUN.BAT' >&2; return 1; }
}

# The section name of the Program Manager Main group in a Windows 3.x
# SETUP.INF: the [progman.groups] entry marked ",1" (maximized). Windows
# 3.1 / 3.11 / WfW 3.11: "group3=<name>,1" -> [group3]; Windows 3.0:
# "Main,1" -> [Main]. Nothing when there is none (Windows 1.x/2.x have no
# Program Manager). Byte-safe: group names are code page text (852 in the
# Polish INF); BusyBox awk counts them as UTF-8 (length/substr/regex go
# wrong), so only index() is used before the name part, and a section name
# must be ASCII letters and digits.
dos_main_group() {
    [ -f "$1" ] || return 0
    awk '{ sub(/\r$/, "") } /^\[/ { s = tolower($0) == "[progman.groups]"; next } /^[ \t]*;/ { next }
        s && index($0, ",1") > 1 {
            e = index($0, "="); c = index($0, ",")
            k = ""
            if (e > 1 && e < index($0, ",1")) k = substr($0, 1, e - 1)
            else if (e == 0) k = substr($0, 1, c - 1)
            gsub(/[ \t]/, "", k)
            if (k ~ /^[A-Za-z0-9]+$/) { print k; exit } }' "$1"
}

# Case-insensitive path below BASE: dos_ci_find BASE COMPONENT... prints the
# real path (FAT names from DATA keep their case) or fails.
dos_ci_find() {
    dcf=$1; shift
    for dcc in "$@"; do
        dcn=''
        for dce in "$dcf"/*; do
            [ -e "$dce" ] || continue
            if [ "$(basename "$dce" | tr 'a-z' 'A-Z')" = "$dcc" ]; then dcn=$dce; break; fi
        done
        [ -n "$dcn" ] || return 1
        dcf=$dcn
    done
    printf '%s\n' "$dcf"
}

# Program Manager icons for the staged DOS programs (DATA
# Systems\DOS\MS-DOS\Programs -> DIR/PROGRAMS -> C:\PROGRAMS by INSTALL.BAT).
# Each PROGRAMS\<FOLDER>\USOSICON.TXT may hold lines
#   "Name",C:\PROGRAMS\<FOLDER>\FILE.EXE[,MIN]
# (blank lines and ";" comments ignored). MIN (optional): the oldest Windows
# the program runs on, 3.0, 3.1 or 3.11; when VERSION (dos_program_icons DIR
# VERSION: the installed Windows, same values) is older, the line is skipped
# with a log line (Netscape/Opera need 3.1). No VERSION: MIN only checked
# for its form. A line is used when the name is
# 1-40 printable ASCII characters without " , ( ) [ ] (Setup quotes the name
# and passes it in a Program Manager DDE command), the path stays in its own
# folder, every part is an 8.3 name, the file is .EXE/.COM/.PIF/.BAT, it was
# staged, and SETUP.INF does not list it yet; anything else is skipped with
# a log line. At most 30 icons. They go to the end of the Main group of
# DIR/WINSETUP/SETUP.INF (dos_main_group: Windows 3.0, 3.1, 3.11, WfW 3.11),
# in the shape of Setup's own entries ("File Manager", WINFILE.EXE), so
# Setup creates them; a new group would be ignored (QEMU 3.1 PL 2026-10-24).
# No Main group (Windows 1.x/2.x): logged, nothing written.
dos_program_icons() {
    [ -d "$1/PROGRAMS" ] || return 0
    dpi="$1/WINSETUP/SETUP.INF"
    dpl="$1/USOSICON.LST"
    dpk="$1/USOSICON.CHK"
    dpt=$(printf '\t')
    dpn=0
    : > "$dpl" || return 1
    for dpd in "$1"/PROGRAMS/*; do
        [ -d "$dpd" ] || continue
        dpf=$(dos_ci_find "$dpd" USOSICON.TXT) || continue
        dpu=$(basename "$dpd" | tr 'a-z' 'A-Z')
        if ! printf '%s\n' "$dpu" | awk '{ b = $0; x = ""; i = index($0, ".")
                if (i) { b = substr($0, 1, i - 1); x = substr($0, i + 1) }
                ok = $0 ~ /^[A-Z0-9_~$!#&@-]+(\.[A-Z0-9_~$!#&@-]+)?$/ && length(b) <= 8 && length(x) <= 3
                exit !ok }'; then
            echo "Program icons: folder $(basename "$dpd") is not an 8.3 name, its USOSICON.TXT is skipped"
            continue
        fi
        awk -v dir="$dpu" -v have="${2:-}" '
            function ver(v) { return v == "3.0" ? 300 : v == "3.1" ? 310 : v == "3.11" ? 311 : 0 }
            function part(p, ext,   b, x) {
                if (p !~ /^[A-Z0-9_~$!#&@-]+(\.[A-Z0-9_~$!#&@-]+)?$/) return 0
                b = p; x = ""
                if (index(p, ".")) { b = substr(p, 1, index(p, ".") - 1); x = substr(p, index(p, ".") + 1) }
                if (length(b) > 8 || length(x) > 3) return 0
                if (ext && x != "EXE" && x != "COM" && x != "PIF" && x != "BAT") return 0
                return 1
            }
            { sub(/\r$/, "") }
            /^[ \t]*$/ || /^[ \t]*;/ { next }
            {
                if ($0 !~ /^[ -~\t]*$/) { print "SKIP\t" NR "\tnot plain ASCII"; next }
                if (!match($0, /^[ \t]*"[^"]*"[ \t]*,[ \t]*/)) { print "SKIP\t" NR "\tnot in the shape \"Name\",C:\\PROGRAMS\\" dir "\\FILE.EXE"; next }
                name = substr($0, 1, RLENGTH); path = substr($0, RLENGTH + 1)
                sub(/^[ \t]*"/, "", name); sub(/"[ \t]*,[ \t]*$/, "", name)
                sub(/^ +/, "", name); sub(/ +$/, "", name); sub(/[ \t]+$/, "", path)
                min = ""
                if (index(path, ",")) {
                    min = substr(path, index(path, ",") + 1); path = substr(path, 1, index(path, ",") - 1)
                    gsub(/[ \t]/, "", min); sub(/[ \t]+$/, "", path)
                    if (!ver(min)) { print "SKIP\t" NR "\tminimum Windows version must be 3.0, 3.1 or 3.11"; next }
                }
                if (name == "" || length(name) > 40 || name ~ /[",()\[\]\t]/) { print "SKIP\t" NR "\tbad name (1-40 characters, no \" , ( ) [ ])"; next }
                up = toupper(path)
                head = "C:\\PROGRAMS\\" dir "\\"
                if (substr(up, 1, length(head)) != head || length(up) > 64) { print "SKIP\t" NR "\tpath must be C:\\PROGRAMS\\" dir "\\... (at most 64 characters)"; next }
                # [\\]: a lone backslash is no valid separator regex in BusyBox awk
                n = split(substr(up, length("C:\\PROGRAMS\\") + 1), c, "[\\\\]")
                ok = n >= 2; list = ""
                for (i = 1; i <= n && ok; i++) { ok = part(c[i], i == n); list = list (i > 1 ? " " : "") c[i] }
                if (!ok) { print "SKIP\t" NR "\tnot an 8.3 path to an .EXE, .COM, .PIF or .BAT file"; next }
                if (min != "" && ver(have) && ver(have) < ver(min)) { print "SKIP\t" NR "\tneeds Windows " min ", this is Windows " have; next }
                print "OK\t" NR "\t" name "\t" up "\t" list
            }' "$dpf" > "$dpk" || return 1
        while IFS="$dpt" read -r dps dpno dpa dpb dpc; do
            if [ "$dps" != OK ]; then
                echo "Program icons: $dpu\\USOSICON.TXT line $dpno skipped: $dpa"
                continue
            fi
            # shellcheck disable=SC2086 # dpc: 8.3 parts separated by spaces
            if ! dos_ci_find "$1/PROGRAMS" $dpc > /dev/null; then
                echo "Program icons: $dpu\\USOSICON.TXT line $dpno skipped: $dpb was not staged"
                continue
            fi
            if [ -f "$dpi" ] && tr 'a-z' 'A-Z' < "$dpi" | grep -qF "$dpb"; then
                echo "Program icons: $dpu\\USOSICON.TXT line $dpno skipped: $dpb is in SETUP.INF already"
                continue
            fi
            if grep -qF "$dpb" "$dpl"; then
                echo "Program icons: $dpu\\USOSICON.TXT line $dpno skipped: $dpb listed twice"
                continue
            fi
            if [ "$dpn" -ge 30 ]; then
                echo "Program icons: $dpu\\USOSICON.TXT line $dpno skipped: more than 30 icons"
                continue
            fi
            printf '"%s", %s\n' "$dpa" "$dpb" >> "$dpl" || return 1
            dpn=$((dpn + 1))
            echo "Program icons: \"$dpa\" -> $dpb"
        done < "$dpk"
    done
    rm -f "$dpk"
    if [ "$dpn" -eq 0 ]; then
        rm -f "$dpl"
        return 0
    fi
    dpm=$(dos_main_group "$dpi")
    if [ -z "$dpm" ] || ! grep -qi "^\[$dpm\]" "$dpi"; then
        rm -f "$dpl"
        echo "Program icons: no Program Manager Main group in SETUP.INF (Windows 1.x/2.x), $dpn icon(s) not added"
        return 0
    fi
    # The icons after the last entry of the Main section (blank lines kept
    # in front of the next section header).
    awk -v h="[$dpm]" -v f="$dpl" '
        function icons(   l) { while ((getline l < f) > 0) printf "%s\r\n", l; close(f); done = 1 }
        function blanks(   i) { for (i = 0; i < nb; i++) print bl[i]; nb = 0 }
        { l = $0; sub(/\r$/, "", l) }
        sec && !done && substr(l, 1, 1) == "[" { icons(); blanks(); sec = 0 }
        sec && !done && l == "" { bl[nb++] = $0; next }
        sec && !done && nb > 0 { blanks() }
        { print }
        !done && !sec && tolower(l) == tolower(h) { sec = 1 }
        END { if (sec && !done) { icons(); blanks() } }' "$dpi" > "$dpi.new" && mv "$dpi.new" "$dpi" || return 1
    rm -f "$dpl"
    echo "Program icons: $dpn added to the Main group ($dpm) of SETUP.INF"
}

# DOS-side texts in the profile / USOS menu language (tools/build_dos_i18n.py
# writes EFI\USOS\dos-native\i18n\DOSTEXT.TXT from the dos.* keys of the USOS
# catalogs). The start files are English; dos_i18n_apply replaces the
# English text of their echo / menuitem / submenu / CHOICE lines with the
# section [<language>-<code page>] (a key line, then the text as code page
# bytes). awk never looks into a translated line: it is stored and printed
# whole (BusyBox awk would count code page bytes as UTF-8).
#   dos_i18n_apply DIR TEXTFILE LANGUAGE CODEPAGE
# LANGUAGE: a catalog or locale tag (pl, pl-PL, pt-BR, sr-Latn-RS); CODEPAGE:
# the one DOS.INI switches the console to (437 when none). Files shown before
# that switch (CONFIG.SYS menu, INSTALL / WINMENU / NETSTART) take the 437
# section, the start-menu batch files W3AUTO / W1AUTO and WINRUN the CODEPAGE one; no
# section for the language (Cyrillic or Greek in 437, Ukrainian): English.
DOS_I18N_TEXT=''
DOS_I18N_437=''
DOS_I18N_CP=''

# The first section of TEXTFILE named <tag>-<cp>, tag shortened from the end.
dos_i18n_section() {
    dis_tag=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    while [ -n "$dis_tag" ]; do
        if grep -qx "\[$dis_tag-$3\]" "$1"; then
            printf '%s-%s\n' "$dis_tag" "$3"
            return 0
        fi
        case "$dis_tag" in *-*) dis_tag=${dis_tag%-*} ;; *) dis_tag='' ;; esac
    done
    return 1
}

# One file through the section (nothing when the file or section is empty).
dos_i18n_file() {
    [ -f "$1" ] && [ -n "$2" ] && [ -n "$DOS_I18N_TEXT" ] || return 0
    awk -v want="[$2]" -v tf="$DOS_I18N_TEXT" '
        BEGIN {
            sec = ""; key = ""
            while ((getline l < tf) > 0) {
                if (key == "") {
                    if (substr(l, 1, 1) == ";") continue
                    if (substr(l, 1, 1) == "[") { sec = l; continue }
                    key = l
                    continue
                }
                if (sec == "[en-437]") en[l] = key
                if (sec == want) tr[key] = l
                key = ""
            }
            close(tf)
        }
        {
            line = $0
            cr = sub(/\r$/, "", line)
            p = ""; r = ""
            if (substr(line, 1, 5) == "echo ") { p = "echo "; r = substr(line, 6) }
            else if (match(line, /^(menuitem|submenu)=[A-Za-z0-9_]+,/)) { p = substr(line, 1, RLENGTH); r = substr(line, RLENGTH + 1) }
            else if (match(line, /CHOICE\.COM( \/[^ ]+)* /)) { p = substr(line, 1, RSTART + RLENGTH - 1); r = substr(line, RSTART + RLENGTH) }
            if (p != "" && (r in en) && (en[r] in tr)) {
                printf "%s%s%s\n", p, tr[en[r]], (cr ? "\r" : "")
                next
            }
            print
        }' "$1" > "$1.i18n" && mv "$1.i18n" "$1"
}

# The text of KEY in the 437 section (or English), for the lines this
# script writes itself.
dos_text() {
    [ -n "$DOS_I18N_TEXT" ] || return 0
    awk -v want="[${DOS_I18N_437:-en-437}]" -v k="$1" -v tf="$DOS_I18N_TEXT" '
        BEGIN {
            sec = ""; key = ""; en = ""; out = ""
            while ((getline l < tf) > 0) {
                if (key == "") {
                    if (substr(l, 1, 1) == ";") continue
                    if (substr(l, 1, 1) == "[") { sec = l; continue }
                    key = l
                    continue
                }
                if (key == k && sec == "[en-437]") en = l
                if (key == k && sec == want) out = l
                key = ""
            }
            printf "%s", (out != "" ? out : en)
        }' < /dev/null
}

dos_i18n_apply() {
    [ -f "$2" ] || { echo 'DOS texts: no DOSTEXT.TXT, English'; return 0; }
    DOS_I18N_TEXT=$2
    DOS_I18N_437=$(dos_i18n_section "$2" "${3:-en}" 437) || DOS_I18N_437=''
    DOS_I18N_CP=''
    case "${4:-437}" in
        437) DOS_I18N_CP=$DOS_I18N_437 ;;
        [0-9][0-9][0-9]) DOS_I18N_CP=$(dos_i18n_section "$2" "${3:-en}" "$4") || DOS_I18N_CP='' ;;
    esac
    for dif in W3CONFIG.SYS W3CONFIG.CSM W1CONFIG.SYS W1CONFIG.CSM INSTALL.BAT WINMENU.BAT W3START.BAT W1SETUP.BAT NETSTART.BAT; do
        dos_i18n_file "$1/$dif" "$DOS_I18N_437" || return 1
    done
    # WINRUN.BAT (typed WIN) runs after the start file switched the code page.
    for dif in W3AUTO.BAT W3AUTO.CSM W1AUTO.BAT W1AUTO.CSM WINRUN.BAT; do
        dos_i18n_file "$1/$dif" "$DOS_I18N_CP" || return 1
    done
    echo "DOS texts: ${3:-en} (menus ${DOS_I18N_437:-English 437}, start files ${DOS_I18N_CP:-English 437})"
}
