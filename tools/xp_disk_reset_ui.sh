# Sourced by Legacy XP staging after read-only validation of the source ISO.
. /usr/lib/usos/xp_confirmation_ui.sh
usos_xp_disk_mode() {
    # Existing unattended test fixtures retain their old non-destructive policy.
    [ ! -f "$TEST_INI" ] || return 0
    reset_screen=/run/xp-disk-mode.txt
    reset_overview=/run/xp-disk-overview.txt
    usos_ui_stage 2 5 'Inspecting disk' 'Reading partitions, free space and system files.' || true
    sh /usr/lib/usos/xp_disk_overview.sh > "$reset_overview" || stop 'Cannot safely inspect selected disk'
    {
        printf 'title=%s - PREPARE DISK\nsubtitle=Choose how to prepare this disk.\n' "${NT5_TITLE:-WINDOWS XP}"
        printf 'item=Keep existing partitions|Install %s in unallocated space\n' "${NT5_NAME:-Windows XP}"
        printf 'item=Format entire disk|Erase all data and prepare a new %s installation\n' "${NT5_NAME:-Windows XP}"
        printf 'item=Back|Select another disk\n'
        usos_xp_menu_info "$reset_overview"
    } > "$reset_screen"
    usos_xp_menu "$reset_screen" || return 1
    case "$USOS_MENU_RESULT" in 1) return 0 ;; 2) ;; *) return 1 ;; esac
    [ -z "$XP_WINNT_SIF" ] || stop 'Whole-disk XP preparation requires no custom Unattended file'
    XP_RESET_SNAPSHOT="$(mktemp -d /run/xp-reset.XXXXXX)/snapshot"
    export XP_RESET_SNAPSHOT
    xp_run_logged legacy-xp-reset-snapshot.log sh /usr/lib/usos/xp_disk_reset.sh snapshot || stop 'Disk refused whole-disk formatting'
    reset_serial=$(awk -F= '$1=="serial" {sub(/^[^=]*=/, ""); print}' "$XP_RESET_SNAPSHOT/identity")
    {
        printf 'ERASE ALL DATA ON THIS DISK\n\n'
        cat "$reset_overview"
        printf '\n'
        printf 'All partitions, systems and files on this disk will be erased.\nA new %s layout will be created.\n' "${NT5_NAME:-Windows XP}"
    } > "$reset_screen"
    if ! usos_xp_confirm "$reset_screen" 'FORMAT THE ENTIRE DISK?' 'Erase ALL partitions and data on the selected disk'; then
        printf '[LEGACY_XP] Formatting cancelled; no target write occurred\n'
        return 1
    fi
    XP_RESET_CONFIRMATION="FORMATUJ $reset_serial"
    export XP_RESET_CONFIRMATION
    USOS_XP_CHOOSING=no
    xp_stage_set reset-target
    xp_run_logged legacy-xp-reset.log sh /usr/lib/usos/xp_disk_reset.sh apply || stop 'Whole-disk preparation failed'
    unset XP_RESET_CONFIRMATION
    XP_FORMAT_CONFIRMED=yes
}
