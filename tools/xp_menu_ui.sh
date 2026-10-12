# Shared graphical selection, with evdev keyboard and mouse input.
#
# The stick ESP is read-only while the menu waits for the user (a power-off
# there leaves it clean, tools/stick_write.sh). Every trace write onto the
# ESP (USOS_XP_TRACE_DIR, EFI/USOS-XP for XP / 2000 / 2003 / XP x64) goes
# through usos_stick_write; the renderer's stderr and its own trace
# (src/platform/linux/fb_menu_trace.zig) go to tmpfs during the wait and are
# appended afterwards. X470 2026-10-12 (B261012-104904): xp_stage_set
# menu-launch ran after the read-only remount and the XP flow stopped with
# "cannot write Legacy XP staging status to ESP".
command -v usos_stick_write >/dev/null 2>&1 || usos_stick_write() { "$@"; }
USOS_XP_MENU_RUN=${USOS_XP_MENU_RUN:-/run}
# fb_menu_trace.zig appends to /run/usos-menu-events.log (tests: their own dir).
USOS_XP_MENU_TMP_TRACE=${USOS_XP_MENU_TMP_TRACE:-$USOS_XP_MENU_RUN/usos-menu-events.log}

xp_menu_trace_write() {
    case "$1" in
        state) printf 'menu=%s\n' "$2" >> "$USOS_XP_TRACE_DIR/menu-events.log" && cp "$2" "$USOS_XP_TRACE_DIR/menu-state.txt" ;;
        hardware) cat "$2" > "$USOS_XP_TRACE_DIR/menu-hardware.txt" ;;
        append) cat "$2" >> "$USOS_XP_TRACE_DIR/menu-events.log" ;;
        line) printf '%s\n' "$2" >> "$USOS_XP_TRACE_DIR/menu-events.log" ;;
    esac
}

usos_xp_menu() {
    xp_menu_file=$1
    if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
        xp_stage_set menu-input-init
        usos_stick_write xp_menu_trace_write state "$xp_menu_file" || true
    fi
    enable_emergency_input || true
    USOS_XP_MENU_SHOWN=yes
    xp_menu_err=/dev/console
    if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
        xp_stage_set menu-launch
        {
            cat /proc/fb
            cat /proc/bus/input/devices
            for xp_fb in /sys/class/graphics/fb*; do
                [ -d "$xp_fb" ] || continue
                printf '\nframebuffer=%s\n' "$xp_fb"
                cat "$xp_fb/name" "$xp_fb/virtual_size" "$xp_fb/bits_per_pixel" 2>/dev/null || true
            done
            dmesg
        } > "$USOS_XP_MENU_RUN/usos-menu-hardware.txt" 2>&1
        usos_stick_write xp_menu_trace_write hardware "$USOS_XP_MENU_RUN/usos-menu-hardware.txt" || true
        rm -f "$USOS_XP_MENU_RUN/usos-menu-hardware.txt"
        xp_menu_err=$USOS_XP_MENU_RUN/usos-menu-stderr.log
        : > "$xp_menu_err"
    fi
    : > "$USOS_XP_MENU_TMP_TRACE" 2>/dev/null || true
    # The wait: the ESP read-only, nothing written onto it until
    # the read-write remount below (the renderer only reads the ESP).
    xp_menu_stick=''
    if [ -r "${USOS_LIB_DIR:-/usr/lib/usos}/stick_write.sh" ]; then
        . "${USOS_LIB_DIR:-/usr/lib/usos}/stick_write.sh"
        if [ "$(usos_stick_mode)" = rw ] && usos_stick_ro; then xp_menu_stick=rw; fi
    fi
    xp_menu_result=$("$USOS_FB_UI" --menu "$xp_menu_file" 2>> "$xp_menu_err")
    xp_menu_status=$?
    if [ -n "$xp_menu_stick" ]; then
        usos_stick_rw || stop 'cannot remount the USOS ESP read-write after the menu'
    fi
    if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
        usos_stick_write xp_menu_trace_write append "$USOS_XP_MENU_TMP_TRACE" 2>/dev/null || true
        usos_stick_write xp_menu_trace_write append "$xp_menu_err" || true
        rm -f "$xp_menu_err"
    fi
    rm -f "$USOS_XP_MENU_TMP_TRACE" 2>/dev/null || true
    if [ "$xp_menu_status" = 0 ]; then
        if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
            usos_stick_write xp_menu_trace_write line "menu-return=0 selected=$xp_menu_result" || true
            xp_stage_set menu-selected
        fi
        USOS_MENU_RESULT=$xp_menu_result
        # Back on the progress page (stage 3 of 5, earlier stages done) while
        # the choice is checked, instead of a frozen menu.
        # Vista without CSM: "Choosing the target disk" is stage 3 of 5 too.
        if [ "${USOS_UI_NT5:-no}" = yes ] || [ "${USOS_UI_VISTA:-no}" = yes ]; then
            USOS_UI_CURRENT=3
            usos_ui_render_state stage 3 5 "$(usos_ui_stage_label 3)" '' '' 0 0 0 0 || true
        fi
        return 0
    else
        if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
            usos_stick_write xp_menu_trace_write line "menu-return=$xp_menu_status" || true
            xp_stage_set menu-returned
        fi
        [ "$xp_menu_status" = 1 ] || stop 'Cannot open selection menu'
        return 1
    fi
}

usos_xp_menu_info() {
    while IFS= read -r xp_info_line || [ -n "$xp_info_line" ]; do
        printf 'info=%s\n' "$xp_info_line"
    done < "$1"
}

usos_xp_choose_disk() {
    xp_choice=/run/xp-disk-menu.state
    {
        printf 'title=%s - SELECT DISK\nsubtitle=Select the disk for %s.\n' "${NT5_TITLE:-WINDOWS XP}" "${NT5_NAME:-Windows XP}"
        while IFS='|' read -r index candidate; do
            printf 'item=%s (%s GiB)|S/N: %s\n' "$(usos_disk_type_model "$candidate")" "$(( $(usos_disk_size "$candidate") / 1073741824 ))" "$(usos_disk_serial "$candidate")"
        done < "$CANDIDATES"
        printf 'item=Return to USOS|Restart the computer\n'
        # A path that must say why the disk is chosen here (Vista without CSM).
        [ -z "${USOS_XP_DISK_NOTE:-}" ] || printf 'info=%s\n' "$USOS_XP_DISK_NOTE"
        printf 'info=The disk will only be changed after your confirmation.\n'
    } > "$xp_choice"
    if usos_xp_menu "$xp_choice"; then
        TARGET_DEVICE=$(awk -F'|' -v wanted="$USOS_MENU_RESULT" '$1 == wanted { print $2; exit }' "$CANDIDATES")
        [ -z "$TARGET_DEVICE" ] || return 0
    fi
    if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then xp_stage_set user-return-to-usos; fi
    sync
    sh /usr/lib/usos/stick_release.sh reboot
    while :; do sleep 3600; done
}
