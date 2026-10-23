#!/bin/sh
# MS-DOS 6.22 / Windows 1.x-3.x start files, sourced by dos_csmwrap_target.sh
# (micro-Linux, BusyBox sh) after the helpers were copied to C:\USOSDOS ($1):
#
#   dos_win_name SYSTEM IMAGE      the installed product, for the menus
#   dos_menu_names DIR SYSTEM IMAGE  the W3/W1 start menus name it
#   dos_regional_apply DIR INI     COUNTRY / code page / KEYB from DOS.INI
#                                  (src/flow/answer/dos.zig) into the start
#                                  files; manual: W3PL.KEY is not used
#
# Every file in DIR is CRLF text (tools/build_dos_native_support.py); the
# lines written here are CRLF too. Nothing outside DIR is touched.

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
            # W3AUTO.BAT starts every WfW item in 386 enhanced mode.
            dos_sed "$dmf" -e "s|^menuitem=WINSTD,Windows - tryb standardowy (domyslny)|menuitem=WINSTD,$dmn - tryb rozszerzony 386 (domyslny)|" \
                -e "s|^menuitem=WIN386,Windows - tryb rozszerzony 386 (alternatywny)|menuitem=WIN386,$dmn - tryb 386 z SMARTDRV|"
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
