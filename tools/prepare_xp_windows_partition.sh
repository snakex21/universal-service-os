#!/bin/sh
# Finalize the shared boot/source/Windows volume after its guarded preparation.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
TARGET_DEVICE=${TARGET_DEVICE:?}
TARGET_SNAPSHOT=${TARGET_SNAPSHOT:?}
XP_WINDOWS_PLAN=${XP_WINDOWS_PLAN:?}
XP_EXPECTED_MBR=${XP_EXPECTED_MBR:?}
MTOOLS_IMAGE=${MTOOLS_IMAGE:?}
. "$SCRIPT_DIR/xp_source_io.sh"
. "$SCRIPT_DIR/nt5_profile.sh"
usos_nt5_profile
fail() { printf '[XP_WINDOWS] STOP: %s\n' "$1" >&2; exit 1; }
value() { awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/, ""); print; found=1; exit} END {if(!found) exit 1}' "$1"; }
work=$(mktemp -d)
trap 'rm -f "$work/plan" "$work/mbr" "$work/migrate.inf" "$work/readback" "$work/winnt.sif" "$work/winnt.base"; rmdir "$work"' EXIT HUP INT TERM
awk -f "$SCRIPT_DIR/xp_windows_partition_plan.awk" "$TARGET_SNAPSHOT" > "$work/plan"
printf '[XP_WINDOWS] shared volume plan checked\n'
cmp -s "$work/plan" "$XP_WINDOWS_PLAN" || fail 'Windows reservation changed after confirmation'
dd if="$TARGET_DEVICE" of="$work/mbr" bs=512 count=1 2>/dev/null
cmp -s "$work/mbr" "$XP_EXPECTED_MBR" || fail 'MBR changed after shared volume preparation'
slot=$(value "$XP_WINDOWS_PLAN" windows_slot)
start=$(value "$XP_WINDOWS_PLAN" windows_start_lba)
sectors=$(value "$XP_WINDOWS_PLAN" windows_sectors)
signature=$(od -An -tx1 -j 440 -N4 "$work/mbr" | tr -d ' \n\r')
printf '[XP_WINDOWS] preparing C: mapping\n'
awk -v signature="$signature" -v windows_start="$start" -f "$SCRIPT_DIR/xp_drive_letters.awk" > "$work/migrate.inf" || fail 'invalid drive letter mapping'
put_verified() {
    printf '[XP_WINDOWS] writing %s\n' "$2"
    mcopy -o -i "$MTOOLS_IMAGE" "$1" "::/\$WIN_NT\$.~BT/$2"
    rm -f "$work/readback"
    mcopy -o -i "$MTOOLS_IMAGE" "::/\$WIN_NT\$.~BT/$2" "$work/readback"
    cmp -s "$1" "$work/readback" || fail "$2 readback mismatch"
}
# The XP UEFI-CSM profile has its own automatic answer (PAE at setup end,
# unsigned-driver policy): tools/xp_selected_partition_uefi_csm.sif.
XP_AUTOMATIC_SIF="$SCRIPT_DIR/xp_selected_partition.sif"
[ "${USOS_PLAN_PROFILE:-}" != xp-x86-sp3-uefi-csm ] || XP_AUTOMATIC_SIF="$SCRIPT_DIR/xp_selected_partition_uefi_csm.sif"
# Windows 2000 from UEFI: no PAE, a setup-end script for the usos-xp.ini accounts.
[ "${USOS_PLAN_PROFILE:-}" != w2k-x86-sp4-uefi-csm ] || XP_AUTOMATIC_SIF="$SCRIPT_DIR/w2k_selected_partition_uefi_csm.sif"
# Server 2003 x86 and XP x64 from UEFI: the same, in \WINDOWS.
[ "${USOS_PLAN_PROFILE:-}" != w2k3-x86-sp2-uefi-csm ] || XP_AUTOMATIC_SIF="$SCRIPT_DIR/w2k3_selected_partition_uefi_csm.sif"
[ "${USOS_PLAN_PROFILE:-}" != xp-x64-sp2-uefi-csm ] || XP_AUTOMATIC_SIF="$SCRIPT_DIR/xp64_selected_partition_uefi_csm.sif"
[ -r "$XP_AUTOMATIC_SIF" ] || fail "automatic WINNT.SIF missing: $XP_AUTOMATIC_SIF"
awk -v directory="$NT5_INSTALL_DIR" '
    /^InstallDir=/ { print "InstallDir=\"\\" directory "\""; next }
    /^TargetPath=/ { print "TargetPath=\\" directory; next }
    { sub(/\r$/, ""); print }
' "$XP_AUTOMATIC_SIF" > "$work/winnt.sif"
# A .sif chosen in the menu (XP_CUSTOM_SIF) or usos-xp.ini (XP_USER_SETTINGS),
# both validated by legacy_xp_staging.sh, are merged into the automatic answer.
if [ -n "${XP_CUSTOM_SIF:-}" ] || [ -n "${XP_USER_SETTINGS:-}" ]; then
    . "$SCRIPT_DIR/xp_user_settings.sh"
    mv "$work/winnt.sif" "$work/winnt.base"
    if [ -n "${XP_CUSTOM_SIF:-}" ]; then
        usos_xp_custom_sif "$work/winnt.base" "$XP_CUSTOM_SIF" > "$work/winnt.sif" || fail 'cannot merge the selected .sif into WINNT.SIF'
        printf '[XP_WINDOWS] selected .sif merged into the automatic WINNT.SIF (partition, PAE and driver keys kept)\n'
    else
        usos_xp_settings_sif "$work/winnt.base" "$XP_USER_SETTINGS" > "$work/winnt.sif" || fail 'cannot merge usos-xp.ini into WINNT.SIF'
        printf '[XP_WINDOWS] usos-xp.ini merged: WINNT.SIF unattended\n'
    fi
    rm -f "$work/winnt.base"
fi
# Server 2003 x86 / XP x64 from UEFI: user packages from DATA\Drivers\<system>
# (tools/nt5_user_drivers.sh) for GUI-mode Setup and the installed system.
case "${USOS_PLAN_PROFILE:-}" in
    w2k3-x86-sp2-uefi-csm|xp-x64-sp2-uefi-csm)
        . "$SCRIPT_DIR/nt5_user_drivers.sh"
        user_arch=x86
        [ "${NT5_SOURCE_DIR:-I386}" != AMD64 ] || user_arch=amd64
        user_paths=$(usos_nt5_user_drivers_stage "${USOS_USER_DRIVERS_DIR:-/mnt/data/Drivers/$NT5_NAME}" "${XP_TARGET_ROOT:?}" "$user_arch") || fail 'cannot stage the user drivers from DATA\Drivers'
        if [ -n "$user_paths" ]; then
            mv "$work/winnt.sif" "$work/winnt.base"
            usos_nt5_user_drivers_sif "$user_paths" < "$work/winnt.base" > "$work/winnt.sif" || fail 'cannot add OemPnPDriversPath'
            rm -f "$work/winnt.base"
            printf '[XP_WINDOWS] user drivers: OemPnPDriversPath="%s"\n' "$user_paths"
        fi ;;
esac
put_verified "$work/winnt.sif" WINNT.SIF
put_verified "$work/migrate.inf" MIGRATE.INF
sync
printf '[XP_WINDOWS] PREPARED PASS slot=%s start=%s sectors=%s Windows=C: layout=single-volume filesystem=NTFS existing_partitions=preserved\n' "$slot" "$start" "$sectors"
