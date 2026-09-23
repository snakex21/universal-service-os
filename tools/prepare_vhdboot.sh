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
    usos_ui_fail 'Preparation stopped' "$1" || true
    usos_ui_restore_cursor || true
    printf '[VHDBOOT] STOP: %s\n' "$1" >&2
    exit 1
}

command -v rsync >/dev/null 2>&1 || fail 'rsync is required'
command -v cmp >/dev/null 2>&1 || fail 'cmp is required'
[ -d "$VHD_SHARED" ] || fail "VHDBoot shared directory is missing: $VHD_SHARED"
[ -f "$VHD_BCD" ] || fail "VHDBoot BCD is missing: $VHD_BCD"
[ -f "$WORK_ROOT/.usos-work" ] || fail 'WORK identity marker is missing'
[ -f "$SCRIPT_DIR/work_boot_relocate.sh" ] || fail 'work_boot_relocate.sh is missing'

usos_ui_stage 4 5 'Building native VHD boot environment' 'Copying Windows Boot Manager and the BCD entry for the selected VHD/VHDX.'
usos_perf_mark 'VHD boot files copy begin'
rsync -a "$VHD_SHARED/" "$WORK_ROOT/" || fail 'failed to copy VHDBoot shared files to WORK'
usos_perf_mark 'VHD boot files copy end'
mkdir -p "$WORK_ROOT/EFI/Microsoft/Boot"
cp -f "$VHD_BCD" "$WORK_ROOT/EFI/Microsoft/Boot/BCD" || fail 'failed to copy selected VHDBoot BCD'
usos_ui_stage 5 5 'Verifying VHD boot files' 'Checking the selected BCD and EFI fallback boot manager.'
usos_perf_mark 'VHD verification and finalization begin'
cmp -s "$VHD_BCD" "$WORK_ROOT/EFI/Microsoft/Boot/BCD" || fail 'selected VHDBoot BCD verification failed'

sh "$SCRIPT_DIR/work_boot_relocate.sh" relocate "$WORK_ROOT" || fail 'cannot move the VHDBoot boot manager to EFI/USOS-WORK'
sh "$SCRIPT_DIR/work_boot_relocate.sh" assert "$WORK_ROOT" --require-entry || fail 'VHDBoot EFI boot manager is missing'
[ -s "$WORK_ROOT/EFI/Microsoft/Boot/BCD" ] || fail 'VHDBoot BCD is empty after copy'

usos_perf_mark 'VHD files flush begin'
usos_ui_sync_with_activity 'Flushing to disk' 'Writing the VHD boot environment to the USB drive.' || fail 'VHDBoot file flush failed'
usos_perf_mark 'VHD files flush end'
usos_ui_stage 5 5 'Writing prepared state' 'Publishing phase=prepared after boot files are durable.'
STATE_TMP="${STATE_FILE}.tmp.$$"
trap 'rm -f "$STATE_TMP"' EXIT HUP INT TERM
{
    printf 'phase=prepared\n'
    printf 'selected_method=vhdboot\n'
    if [ -n "$SELECTED_ISO" ]; then printf 'selected_image=%s\n' "$SELECTED_ISO"; fi
} > "$STATE_TMP" || fail 'failed to write prepared VHDBoot state'
mv -f "$STATE_TMP" "$STATE_FILE" || fail 'failed to publish prepared VHDBoot state'
trap - EXIT HUP INT TERM
usos_perf_mark 'VHD state flush begin'
usos_ui_sync_with_activity 'Flushing to disk' 'Committing prepared state to the USB drive.' || fail 'VHDBoot state flush failed'
usos_perf_mark 'VHD state flush end'
usos_ui_stage 5 5 'Finalization complete' 'The VHD/VHDX remains on DATA; WORK contains the verified boot manager and BCD.'
usos_perf_mark 'VHD verification and finalization end'
printf '[VHDBOOT] phase=prepared PASS bcd=%s\n' "$VHD_BCD"
