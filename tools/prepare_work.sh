#!/bin/sh
set -eu

WORK_PARTUUID=${WORK_PARTUUID:?WORK_PARTUUID is required}
WORK_MOUNT=${WORK_MOUNT:?WORK_MOUNT is required}
SOURCE_ROOT=${SOURCE_ROOT:?SOURCE_ROOT is required}
STATE_FILE=${STATE_FILE:?STATE_FILE is required}
USOS_DEVICE_INI=${USOS_DEVICE_INI:?USOS_DEVICE_INI is required}
UNATTEND_FILE=${UNATTEND_FILE:-}
WORK_FS_DRIVER=${WORK_FS_DRIVER:-ntfs3}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[ -r "$SCRIPT_DIR/partuuid.sh" ] || { printf '[PREPARE_WORK] STOP: partuuid.sh is missing\n' >&2; exit 1; }
. "$SCRIPT_DIR/partuuid.sh"
WORK_PATH=$(usos_partuuid_path "$WORK_PARTUUID")
[ -r "$SCRIPT_DIR/micro_linux_ui.sh" ] || { printf '[PREPARE_WORK] STOP: micro_linux_ui.sh is missing\n' >&2; exit 1; }
. "$SCRIPT_DIR/micro_linux_ui.sh"

fail() {
    usos_ui_fail 'Preparation stopped' "$1" || true
    printf '[PREPARE_WORK] STOP: %s\n' "$1" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'root privileges are required'
command -v mkfs.ntfs >/dev/null 2>&1 || fail 'mkfs.ntfs is required'
command -v mount >/dev/null 2>&1 || fail 'mount is required'
command -v umount >/dev/null 2>&1 || fail 'umount is required'
[ -f "$SCRIPT_DIR/device_guard.sh" ] || fail 'device_guard.sh is missing'
[ -f "$SCRIPT_DIR/extract.sh" ] || fail 'extract.sh is missing'
[ -f "$SCRIPT_DIR/prepare_wimboot.sh" ] || fail 'prepare_wimboot.sh is missing'
[ -f "$SCRIPT_DIR/prepare_vhdboot.sh" ] || fail 'prepare_vhdboot.sh is missing'
[ -f "$SCRIPT_DIR/work_boot_relocate.sh" ] || fail 'work_boot_relocate.sh is missing'
[ -e "$WORK_PATH" ] || fail "WORK PARTUUID path is missing: $WORK_PATH"
[ -f "$STATE_FILE" ] || fail "state file is missing: $STATE_FILE"
REQUEST_PHASE=$(awk -F= '/^[[:space:]]*phase[[:space:]]*=/ { value=$0; sub(/^[^=]*=/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; found=1; exit } END { if (!found) exit 1 }' "$STATE_FILE") || fail 'state file has no phase'
[ "$REQUEST_PHASE" = 'prepare-requested' ] || fail "refusing prepare from phase=$REQUEST_PHASE"

case "$WORK_MOUNT" in
    /|'') fail 'refusing unsafe WORK mount point' ;;
esac

printf '[PREPARE_WORK] phase=prepare-requested\n'
usos_ui_stage 2 5 'Checking target safety' 'Verifying disk identity and WORK ownership.'
usos_perf_mark 'device_guard pre-format begin'
sh "$SCRIPT_DIR/device_guard.sh" pre-format
usos_perf_mark 'device_guard pre-format end'
printf '[PREPARE_WORK] device_guard pre-format PASS\n'

WINDOWS7_UEFI=no
# DEAD PATH (2026-09-24): the boot menu never requests it. preparation_capability
# resolveBackend() returns null for windows-7 + chainload (test in that file);
# Windows 7 on UEFI uses the native ISO path (src/platform/uefi/windows_native_iso.zig)
# and on BIOS legacy_windows_request.sh (method iso). Known defects to fix before
# re-enabling it: prepare_windows7_uefi.sh stages KB4474419*.msu while
# usos-win7-unattend.exe (tools/windows7_nvme_unattend.c) looks for
# Windows6.1-KB4474419-v3-x64.cab, and its `mkdir -p "$u/updates"` makes the
# later plain `mkdir "$u/updates"` in prepare_windows7_nvme.sh fail.
if [ "${SELECTED_METHOD:-iso}" = chainload ]; then
    case "${SELECTED_ISO:-}" in
        'Systems/Windows/Windows 7/Images/'*)
            sh "$SCRIPT_DIR/prepare_windows7_uefi.sh" --check || fail 'Windows 7 UEFI preflight failed'
            command -v ntfs-3g >/dev/null 2>&1 || fail 'ntfs-3g is required for Windows 7 WORK compatibility'
            WORK_FS_DRIVER=ntfs-3g
            WINDOWS7_UEFI=yes
            ;;
    esac
fi
export WINDOWS7_UEFI

# This is the first destructive operation. It is unreachable unless the guard
# above accepted every topology/identity check or exact first-run confirmation.
case "${SELECTED_METHOD:-iso}" in
    wimboot) usos_ui_stage 3 5 'Formatting WORK' 'Creating a fresh NTFS workspace for the WIM boot environment.' ;;
    vhdboot) usos_ui_stage 3 5 'Formatting WORK' 'Creating a small NTFS workspace for native VHD/VHDX boot files.' ;;
    *) usos_ui_stage 3 5 'Formatting WORK' 'Creating a fresh NTFS workspace for prepared boot media.' ;;
esac
usos_perf_mark 'mkfs.ntfs quick format begin'
# mkfs.ntfs -f is the fast/quick-format mode; -F permits the explicitly guarded block device.
mkfs.ntfs -f -F -L USOS_WORK "$WORK_PATH" || fail 'mkfs.ntfs failed'
usos_perf_mark 'mkfs.ntfs quick format end'
printf '[PREPARE_WORK] mkfs.ntfs PASS\n'

# Restore and verify .usos-work before mounting or copying any installer file.
sh "$SCRIPT_DIR/device_guard.sh" restore-marker
printf '[PREPARE_WORK] WORK identity restore PASS\n'

mkdir -p "$WORK_MOUNT"
case "${SELECTED_METHOD:-iso}" in
    wimboot) usos_ui_stage 3 5 'Opening WORK' 'The WIM boot environment will be assembled next.' ;;
    vhdboot) usos_ui_stage 3 5 'Opening WORK' 'The native VHD boot manager and BCD will be assembled next.' ;;
    *) usos_ui_stage 3 5 'Opening WORK' 'The boot media copy will start next.' ;;
esac
mount -t "$WORK_FS_DRIVER" -o rw,noatime "$WORK_PATH" "$WORK_MOUNT" || fail "failed to mount WORK with $WORK_FS_DRIVER"
mounted=yes
cleanup() {
    if [ "${mounted:-no}" = yes ]; then
        sync || true
        umount "$WORK_MOUNT" || true
    fi
}
trap cleanup EXIT HUP INT TERM

WORK_ROOT=$WORK_MOUNT
export SOURCE_ROOT WORK_ROOT STATE_FILE UNATTEND_FILE SELECTED_METHOD WIM_FILE WIM_TEMPLATE VHD_SHARED VHD_BCD SELECTED_ISO
case "${SELECTED_METHOD:-iso}" in
    wimboot) sh "$SCRIPT_DIR/prepare_wimboot.sh" ;;
    vhdboot) sh "$SCRIPT_DIR/prepare_vhdboot.sh" ;;
    *) sh "$SCRIPT_DIR/extract.sh" ;;
esac

# Final invariant: no partition except the ESP may offer the removable-media
# path EFI/BOOT/BOOTX64.EFI (firmware would list it as an extra boot option).
sh "$SCRIPT_DIR/work_boot_relocate.sh" assert "$WORK_ROOT" || fail 'removable-media EFI boot entry left on WORK'
if [ -d "${DATA_ROOT:-/mnt/data}" ]; then
    sh "$SCRIPT_DIR/work_boot_relocate.sh" check "${DATA_ROOT:-/mnt/data}" || true
fi
usos_ui_sync_with_activity 'Flushing to disk' 'Finishing WORK writes before closing the prepared partition.' || fail 'final WORK sync failed'
usos_ui_stage 5 5 'Closing WORK partition' 'All buffered writes are complete; closing the prepared filesystem.'
umount "$WORK_MOUNT" || fail 'failed to unmount prepared WORK'
mounted=no
trap - EXIT HUP INT TERM
printf '[PREPARE_WORK] prepared PASS\n'
