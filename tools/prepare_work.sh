#!/bin/sh
set -eu

WORK_PARTUUID=${WORK_PARTUUID:?WORK_PARTUUID is required}
WORK_MOUNT=${WORK_MOUNT:?WORK_MOUNT is required}
SOURCE_ROOT=${SOURCE_ROOT:?SOURCE_ROOT is required}
STATE_FILE=${STATE_FILE:?STATE_FILE is required}
USOS_DEVICE_INI=${USOS_DEVICE_INI:?USOS_DEVICE_INI is required}
UNATTEND_FILE=${UNATTEND_FILE:-}
WORK_FS_DRIVER=${WORK_FS_DRIVER:-ntfs3}
PREFIX='/dev/disk/by-partuuid/'
WORK_PATH="${PREFIX}${WORK_PARTUUID}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

fail() {
    printf '[PREPARE_WORK] STOP: %s\n' "$1" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'root privileges are required'
command -v mkfs.ntfs >/dev/null 2>&1 || fail 'mkfs.ntfs is required'
command -v mount >/dev/null 2>&1 || fail 'mount is required'
command -v umount >/dev/null 2>&1 || fail 'umount is required'
[ -f "$SCRIPT_DIR/device_guard.sh" ] || fail 'device_guard.sh is missing'
[ -f "$SCRIPT_DIR/extract.sh" ] || fail 'extract.sh is missing'
[ -e "$WORK_PATH" ] || fail "WORK PARTUUID path is missing: $WORK_PATH"
[ -f "$STATE_FILE" ] || fail "state file is missing: $STATE_FILE"
REQUEST_PHASE=$(awk -F= '/^[[:space:]]*phase[[:space:]]*=/ { value=$0; sub(/^[^=]*=/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; found=1; exit } END { if (!found) exit 1 }' "$STATE_FILE") || fail 'state file has no phase'
[ "$REQUEST_PHASE" = 'prepare-requested' ] || fail "refusing prepare from phase=$REQUEST_PHASE"

case "$WORK_MOUNT" in
    /|'') fail 'refusing unsafe WORK mount point' ;;
esac

printf '[PREPARE_WORK] phase=prepare-requested\n'
sh "$SCRIPT_DIR/device_guard.sh" pre-format
printf '[PREPARE_WORK] device_guard pre-format PASS\n'

# This is the first destructive operation. It is unreachable unless the guard
# above accepted every topology/identity check or exact first-run confirmation.
mkfs.ntfs -f -F -L USOS_WORK "$WORK_PATH" || fail 'mkfs.ntfs failed'
printf '[PREPARE_WORK] mkfs.ntfs PASS\n'

# Restore and verify .usos-work before mounting or copying any installer file.
sh "$SCRIPT_DIR/device_guard.sh" restore-marker
printf '[PREPARE_WORK] WORK identity restore PASS\n'

mkdir -p "$WORK_MOUNT"
mount -t "$WORK_FS_DRIVER" -o rw,noatime "$WORK_PATH" "$WORK_MOUNT" || fail "failed to mount WORK with $WORK_FS_DRIVER"
mounted=yes
cleanup() {
    if [ "${mounted:-no}" = yes ]; then
        sync || true
        umount "$WORK_MOUNT" || true
    fi
}
trap cleanup EXIT HUP INT TERM

SOURCE_ROOT=$SOURCE_ROOT \
WORK_ROOT=$WORK_MOUNT \
STATE_FILE=$STATE_FILE \
UNATTEND_FILE=$UNATTEND_FILE \
sh "$SCRIPT_DIR/extract.sh"

sync
umount "$WORK_MOUNT" || fail 'failed to unmount prepared WORK'
mounted=no
trap - EXIT HUP INT TERM
printf '[PREPARE_WORK] prepared PASS\n'
