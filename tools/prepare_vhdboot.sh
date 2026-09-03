#!/bin/sh
set -eu

VHD_SHARED=${VHD_SHARED:?VHD_SHARED is required}
VHD_BCD=${VHD_BCD:?VHD_BCD is required}
WORK_ROOT=${WORK_ROOT:?WORK_ROOT is required}
STATE_FILE=${STATE_FILE:?STATE_FILE is required}
SELECTED_ISO=${SELECTED_ISO:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[ -r "$SCRIPT_DIR/micro_linux_ui.sh" ] || { printf '[VHDBOOT] STOP: micro_linux_ui.sh is missing\n' >&2; exit 1; }
. "$SCRIPT_DIR/micro_linux_ui.sh"

fail() {
    usos_ui_restore_cursor
    printf '[VHDBOOT] STOP: %s\n' "$1" >&2
    exit 1
}

command -v rsync >/dev/null 2>&1 || fail 'rsync is required'
command -v cmp >/dev/null 2>&1 || fail 'cmp is required'
[ -d "$VHD_SHARED" ] || fail "VHDBoot shared directory is missing: $VHD_SHARED"
[ -f "$VHD_BCD" ] || fail "VHDBoot BCD is missing: $VHD_BCD"
[ -f "$WORK_ROOT/.usos-work" ] || fail 'WORK identity marker is missing'

usos_ui_stage 10 10 'Building native VHD boot environment' 'Copying Windows Boot Manager and the BCD entry for the selected VHD/VHDX.'
rsync -a "$VHD_SHARED/" "$WORK_ROOT/" || fail 'failed to copy VHDBoot shared files to WORK'
mkdir -p "$WORK_ROOT/EFI/Microsoft/Boot"
cp -f "$VHD_BCD" "$WORK_ROOT/EFI/Microsoft/Boot/BCD" || fail 'failed to copy selected VHDBoot BCD'
cmp -s "$VHD_BCD" "$WORK_ROOT/EFI/Microsoft/Boot/BCD" || fail 'selected VHDBoot BCD verification failed'

BOOT_FILE=''
for candidate in "$WORK_ROOT/EFI/BOOT/BOOTX64.EFI" "$WORK_ROOT/EFI/BOOT/BOOTAA64.EFI" "$WORK_ROOT/EFI/BOOT/BOOTIA32.EFI"; do
    if [ -s "$candidate" ]; then BOOT_FILE=$candidate; break; fi
done
[ -n "$BOOT_FILE" ] || fail 'VHDBoot fallback EFI boot manager is missing'
[ -s "$WORK_ROOT/EFI/Microsoft/Boot/BCD" ] || fail 'VHDBoot BCD is empty after copy'

sync
STATE_TMP="${STATE_FILE}.tmp.$$"
trap 'rm -f "$STATE_TMP"' EXIT HUP INT TERM
{
    printf 'phase=prepared\n'
    printf 'selected_method=vhdboot\n'
    if [ -n "$SELECTED_ISO" ]; then printf 'selected_image=%s\n' "$SELECTED_ISO"; fi
} > "$STATE_TMP" || fail 'failed to write prepared VHDBoot state'
mv -f "$STATE_TMP" "$STATE_FILE" || fail 'failed to publish prepared VHDBoot state'
trap - EXIT HUP INT TERM
sync
usos_ui_done 'Native VHD boot environment ready' 'The VHD/VHDX remains on DATA; WORK contains only the boot manager and verified BCD.'
printf '[VHDBOOT] phase=prepared PASS bcd=%s\n' "$VHD_BCD"
