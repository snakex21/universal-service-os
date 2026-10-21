# Optional display request transport. Sourced; never runs on import.
usos_display_valid() {
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^(auto|1024x768|1280x1024|1920x1080)x(auto|16|32)$'
}
usos_display_from_answer() {
    awk '/^;USOS-DISPLAY=/ {sub(/^[^=]*=/, ""); sub(/\r$/, ""); value=$0; n++} END {if(n>1) exit 1; if(n) print value}' "$1"
}
# Vista / 7 autounattend.xml (autounattend.zig): <!-- USOS-DISPLAY=... -->.
usos_display_from_xml() {
    awk '{sub(/\r$/, "")} /^<!-- USOS-DISPLAY=[^ ]* -->$/ {sub(/^<!-- USOS-DISPLAY=/, ""); sub(/ -->$/, ""); value=$0; n++}
        END {if(n>1) exit 1; if(n) print value}' "$1"
}
# The answer registers the NT6 helper (autounattend.zig display_helper).
usos_display_nt6_answer() {
    grep -qF '\USOS\NT6\USOSRES.EXE' "$1"
}
usos_display_from_nt5() {
    [ -n "${1:-}" ] && [ -f "$1" ] || return 0
    awk -F= '{sub(/\r$/, "")} $1=="family"{f=$2} $1=="display"{d=$2;n++} $1=="display_bpp"{b=$2;m++}
        END {if(n>1||m>1)exit 1; if(f=="2000" && (n||m)) print (d==""?"auto":d) "x" (b==""?"auto":b)}' "$1"
}
usos_display_stage() {
    display_dir=$1 display_exe=$2 display_request=$3
    [ -n "$display_request" ] || return 0
    usos_display_valid "$display_request" || return 1
    [ -f "$display_exe" ] && [ -d "$display_dir" ] || return 1
    cp "$display_exe" "$display_dir/USOSRES.EXE" || return 1
    printf '%s\r\n' "$display_request" > "$display_dir/DISPLAY.TXT" || return 1
    # The monitor's native size (EDID preferred timing) read by the UEFI
    # menu for this preparation (src/platform/uefi/display_native.zig);
    # USOSRES's auto picks it first. Absent or malformed: highest mode.
    display_native=$(usos_display_native) || display_native=
    [ -z "$display_native" ] || printf 'native=%s\r\n' "$display_native" >> "$display_dir/DISPLAY.TXT" || return 1
}
# The UEFI menu's EDID record: one line WxH (docs/display-policy.md).
usos_display_native() {
    _dn_file=${USOS_DISPLAY_NATIVE_FILE:-/mnt/esp/EFI/USOS/display-native.txt}
    [ -f "$_dn_file" ] || return 1
    _dn=$(head -c 32 "$_dn_file" | tr -d '\r\n')
    # The same bounds as usos_display_parse (tools/display_policy.h).
    printf '%s\n' "$_dn" | LC_ALL=C awk -Fx 'NF==2 && $1~/^[1-9][0-9]*$/ && $2~/^[1-9][0-9]*$/ && $1>=320 && $2>=200 && $1<=8192 && $2<=8192 {ok=1} END {exit !ok}' || return 1
    printf '%s\n' "$_dn"
}
usos_display_run_reg() {
    case "$1" in W2K|NT4|NT3) ;; *) return 1 ;; esac
    printf '%s\r\n' 'REGEDIT4' '' '[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run]'
    printf '"USOSDisplay"="C:\\\\USOS\\\\%s\\\\USOSRES.EXE"\r\n' "$1"
}

# Add only to Setup's [Install] AddReg (not the similarly named driver sections).
# A persistent Run entry survives VM installation; the tool defers until hardware.
# [USOS.Display] goes before [USOS.Csm], which must stay the last section:
# INSTALL.BAT appends Me's usoskey.drv line to it (Me USB keyboard).
usos_display_9x_answer() {
    awk 'function add() {if(done++)return
             printf "[USOS.Display]\r\nHKLM,Software\\Microsoft\\Windows\\CurrentVersion\\Run,USOSDisplay,,\"C:\\USOS9X\\USOSRES.EXE\"\r\n\r\n"}
         {sub(/\r$/, ""); low=tolower($0)}
         /^\[/ {install=(low=="[install]"); if(low=="[usos.csm]")add()}
         install && low~/^addreg=/ {$0=$0 ",USOS.Display";n++}
         {printf "%s\r\n",$0}
         END {if(n!=1)exit 1; if(!done){printf "\r\n";add()}}' "$1"
}
