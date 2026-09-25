#!/bin/sh
# Pipeline step 100: NT5 (XP / 2000) staging. Adapter over the unchanged
# legacy_xp_staging.sh; the code was the xp-staging branch of /usos-init.
usos_step_100_run() {
    if [ "${USOS_PLAN_PROFILE:-}" = xp-x86-sp3-uefi-csm ]; then
        # XP from UEFI through the firmware CSM (formerly text edits of
        # /usos-init by tools/build_xp_uefi_csm_trial.py): UEFI only, and
        # every trace of this session under EFI/USOS-XP.
        [ "$LEGACY_ACTION" = xp-staging ] || stop 'Unexpected experimental action'
        [ -d /sys/firmware/efi ] || stop 'UEFI required'
        mkdir -p /mnt/esp/EFI/USOS-XP
        USOS_XP_ESP_DIR=/mnt/esp/EFI/USOS-XP
        USOS_XP_TRACE_DIR=/mnt/esp/EFI/USOS-XP
        export USOS_XP_ESP_DIR USOS_XP_TRACE_DIR
        # Preserve the preceding attempt, then reset this attempt's diagnostics.
        for trace_name in menu-events.log menu-state.txt menu-hardware.txt legacy-xp-staging-last-error.txt; do
            if [ -f "$USOS_XP_TRACE_DIR/$trace_name" ]; then
                mv "$USOS_XP_TRACE_DIR/$trace_name" "$USOS_XP_TRACE_DIR/$trace_name.previous"
            fi
        done
        printf 'phase=init-mounted\nboot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)" > "$USOS_XP_TRACE_DIR/menu-events.log"
        sync
    fi
    NT5_SYSTEM=windows-xp
    [ "$LEGACY_ACTION" != windows2000-staging ] || NT5_SYSTEM=windows-2000
    export NT5_SYSTEM
    [ -r /usr/lib/usos/legacy_xp_staging.sh ] || stop 'legacy_xp_staging.sh is missing'
    . /usr/lib/usos/legacy_xp_staging.sh
    usos_legacy_xp_staging "$LEGACY_IMAGE_HEX" "$LEGACY_UNATTENDED_HEX"
    stop 'Legacy XP staging returned unexpectedly'
}
