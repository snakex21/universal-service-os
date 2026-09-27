#!/bin/sh
# User-supplied NT 5.2 drivers (Server 2003 x86, XP x64; UEFI profiles
# w2k3-x86-sp2-uefi-csm / xp-x64-sp2-uefi-csm), docs/drivers.md:
#   DATA\Drivers\<system>\Storage\ USB\ Other\ (and INF folders directly in
#   DATA\Drivers\<system>\, treated as Other)
# Each folder holding an .inf is one package (its sub-folders belong to it).
# Packages for the target architecture ([Manufacturer] NTamd64 for x64;
# NTx86 or undecorated for x86) are copied to C:\USOS\Drivers\User\<Class>-NN\
# and named in WINNT.SIF [Unattended] OemPnPDriversPath, so GUI-mode Setup's
# device installation and the installed system use them (for example an xHCI
# driver: USB keyboard and mouse in GUI Setup). Text-mode (F6-style) storage
# integration of user packages is not done here. Nothing is installed when
# the folders are empty; XP x86 and Windows 2000 never call this.
#
#   usos_nt5_user_drivers_stage DRIVERS_DIR TARGET_ROOT ARCH   -> prints the
#       OemPnPDriversPath value (empty: none) on stdout, log lines on stderr
#   usos_nt5_user_drivers_sif SIF VALUE   (stdin SIF -> stdout with the key)

usos_nt5_user_drivers_log() { printf '[NT5_USER_DRIVERS] %s\n' "$*" >&2; }

# 0 when the INF targets ARCH (x86 | amd64): [Manufacturer] model decorations.
usos_nt5_user_drivers_arch_ok() {
    awk -v arch="$2" '
        { line = tolower($0); sub(/\r$/, "", line); sub(/;.*/, "", line) }
        line ~ /^\[/ { section = line; next }
        section == "[manufacturer]" && index(line, "=") {
            n++
            decorated = (line ~ /nt(x86|amd64|ia64)/)
            if (arch == "amd64" && line ~ /ntamd64/) ok = 1
            if (arch == "x86" && (!decorated || line ~ /ntx86/)) ok = 1
        }
        END { exit !(n > 0 && ok) }
    ' "$1"
}

usos_nt5_user_drivers_stage() {
    _ud_root=$1
    _ud_target=$2
    _ud_arch=$3
    _ud_paths=''
    [ -d "$_ud_root" ] || { usos_nt5_user_drivers_log "no folder $_ud_root"; return 0; }
    _ud_n=0
    for _ud_class in Storage USB Other; do
        _ud_base=$_ud_root/$_ud_class
        [ "$_ud_class" != Other ] || _ud_base=$_ud_root
        [ -d "$_ud_base" ] || continue
        # Package roots: folders that hold an .inf; loose INFs in the OS or
        # class folder itself are skipped (they would swallow unrelated folders).
        if [ "$_ud_class" = Other ]; then
            _ud_list=$( { find "$_ud_root/Other" -type f -iname '*.inf' 2>/dev/null; find "$_ud_root" -mindepth 2 -type f -iname '*.inf' 2>/dev/null | grep -v -e "^$_ud_root/Storage/" -e "^$_ud_root/USB/" -e "^$_ud_root/Other/"; } | sed 's|/[^/]*$||' | sort -u)
        else
            _ud_list=$(find "$_ud_base" -mindepth 2 -type f -iname '*.inf' 2>/dev/null | sed 's|/[^/]*$||' | sort -u)
        fi
        _ud_prev=''
        for _ud_pkg in $(printf '%s\n' "$_ud_list" | tr ' ' '\001'); do
            _ud_pkg=$(printf '%s' "$_ud_pkg" | tr '\001' ' ')
            [ -n "$_ud_pkg" ] || continue
            [ "$_ud_pkg" != "$_ud_root/Other" ] || { usos_nt5_user_drivers_log "skipped loose INF in Other (put each package in its own folder)"; continue; }
            # A package owns its sub-folders: skip folders inside the previous one.
            case "$_ud_pkg/" in "$_ud_prev"/*) [ -n "$_ud_prev" ] && continue ;; esac
            _ud_ok=no
            for _ud_inf in "$_ud_pkg"/*.[iI][nN][fF]; do
                [ -f "$_ud_inf" ] || continue
                if usos_nt5_user_drivers_arch_ok "$_ud_inf" "$_ud_arch"; then _ud_ok=yes; fi
            done
            if [ "$_ud_ok" != yes ]; then
                usos_nt5_user_drivers_log "skipped ${_ud_pkg#$_ud_root/}: no INF for $_ud_arch"
                _ud_prev=$_ud_pkg
                continue
            fi
            _ud_n=$((_ud_n + 1))
            _ud_name=$(printf '%s-%02d' "$_ud_class" "$_ud_n")
            _ud_dest=$_ud_target/USOS/Drivers/User/$_ud_name
            mkdir -p "$_ud_dest" && cp -R "$_ud_pkg"/. "$_ud_dest"/ || { usos_nt5_user_drivers_log "cannot copy ${_ud_pkg#$_ud_root/}"; return 1; }
            (cd "$_ud_pkg" && find . -type f | sort | while IFS= read -r f; do cmp -s "$f" "$_ud_dest/$f" || exit 1; done) || { usos_nt5_user_drivers_log "readback mismatch ${_ud_pkg#$_ud_root/}"; return 1; }
            usos_nt5_user_drivers_log "staged ${_ud_pkg#$_ud_root/} -> USOS\\Drivers\\User\\$_ud_name ($_ud_arch)"
            _ud_paths=${_ud_paths:+$_ud_paths;}USOS\\Drivers\\User\\$_ud_name
            _ud_prev=$_ud_pkg
        done
    done
    [ "${#_ud_paths}" -le 4000 ] || { usos_nt5_user_drivers_log 'too many packages for OemPnPDriversPath'; return 1; }
    printf '%s' "$_ud_paths"
}

usos_nt5_user_drivers_sif() {
    # ENVIRON, not -v: awk would read the backslashes as escapes.
    USOS_UD_VALUE=$1 awk '
        BEGIN { value = ENVIRON["USOS_UD_VALUE"] }
        { line = $0; sub(/\r$/, "", line) }
        tolower(line) ~ /^oempnpdriverspath[ \t]*=/ { next }
        { print }
        tolower(line) == "[unattended]" && !done { print "OemPnPDriversPath=\"" value "\""; done = 1 }
        END { if (!done) exit 3 }
    '
}
