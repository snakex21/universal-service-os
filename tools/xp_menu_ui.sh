# Shared graphical selection, with evdev keyboard and mouse input.
usos_xp_menu() {
    xp_menu_file=$1
    if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
        xp_stage_set menu-input-init
        printf 'menu=%s\n' "$xp_menu_file" >> "$USOS_XP_TRACE_DIR/menu-events.log"
        cp "$xp_menu_file" "$USOS_XP_TRACE_DIR/menu-state.txt"
        sync
    fi
    enable_emergency_input || true
    USOS_XP_MENU_SHOWN=yes
    xp_menu_log=/dev/console
    if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
        xp_stage_set menu-launch
        xp_menu_log="$USOS_XP_TRACE_DIR/menu-events.log"
        {
            cat /proc/fb
            cat /proc/bus/input/devices
            for xp_fb in /sys/class/graphics/fb*; do
                [ -d "$xp_fb" ] || continue
                printf '\nframebuffer=%s\n' "$xp_fb"
                cat "$xp_fb/name" "$xp_fb/virtual_size" "$xp_fb/bits_per_pixel" 2>/dev/null || true
            done
            dmesg
        } > "$USOS_XP_TRACE_DIR/menu-hardware.txt" 2>&1
        sync
    fi
    if xp_menu_result=$("$USOS_FB_UI" --menu "$xp_menu_file" 2>> "$xp_menu_log"); then
        if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
            printf 'menu-return=0 selected=%s\n' "$xp_menu_result" >> "$xp_menu_log"
            xp_stage_set menu-selected
        fi
        USOS_MENU_RESULT=$xp_menu_result
        # Back on the progress page (stage 3 of 5, earlier stages done) while
        # the choice is checked, instead of a frozen menu.
        if [ "${USOS_UI_NT5:-no}" = yes ]; then
            USOS_UI_CURRENT=3
            usos_ui_render_state stage 3 5 "$(usos_ui_stage_label 3)" '' '' 0 0 0 0 || true
        fi
        return 0
    else
        xp_menu_status=$?
        if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then
            printf 'menu-return=%s\n' "$xp_menu_status" >> "$xp_menu_log"
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
            printf 'item=%s (%s GiB)|S/N: %s\n' "$(usos_disk_model "$candidate")" "$(( $(usos_disk_size "$candidate") / 1073741824 ))" "$(usos_disk_serial "$candidate")"
        done < "$CANDIDATES"
        printf 'item=Return to USOS|Restart the computer\n'
        printf 'info=The disk will only be changed after your confirmation.\n'
    } > "$xp_choice"
    if usos_xp_menu "$xp_choice"; then
        TARGET_DEVICE=$(awk -F'|' -v wanted="$USOS_MENU_RESULT" '$1 == wanted { print $2; exit }' "$CANDIDATES")
        [ -z "$TARGET_DEVICE" ] || return 0
    fi
    if [ -n "${USOS_XP_TRACE_DIR:-}" ]; then xp_stage_set user-return-to-usos; fi
    sync
    reboot -f
    while :; do sleep 3600; done
}
