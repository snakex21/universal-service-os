#!/bin/sh
set -eu

WIM_FILE=${WIM_FILE:?WIM_FILE is required}
WIM_TEMPLATE=${WIM_TEMPLATE:?WIM_TEMPLATE is required}
WORK_ROOT=${WORK_ROOT:?WORK_ROOT is required}
STATE_FILE=${STATE_FILE:?STATE_FILE is required}
UNATTEND_FILE=${UNATTEND_FILE:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[ -r "$SCRIPT_DIR/micro_linux_ui.sh" ] || { printf '[WIMBOOT] STOP: micro_linux_ui.sh is missing\n' >&2; exit 1; }
. "$SCRIPT_DIR/micro_linux_ui.sh"

fail() {
    usos_ui_restore_cursor
    printf '[WIMBOOT] STOP: %s\n' "$1" >&2
    exit 1
}

command -v rsync >/dev/null 2>&1 || fail 'rsync is required'
command -v cmp >/dev/null 2>&1 || fail 'cmp is required'
command -v stat >/dev/null 2>&1 || fail 'stat is required'
[ -f "$WIM_FILE" ] || fail "selected WIM is missing: $WIM_FILE"
[ -d "$WIM_TEMPLATE" ] || fail "WIMBoot template is missing: $WIM_TEMPLATE"
[ -f "$WIM_TEMPLATE/EFI/BOOT/BOOTX64.EFI" ] || fail 'WIMBoot template has no EFI/BOOT/BOOTX64.EFI'
[ -f "$WIM_TEMPLATE/EFI/Microsoft/Boot/BCD" ] || fail 'WIMBoot template has no BCD'
[ -f "$WIM_TEMPLATE/boot/boot.sdi" ] || fail 'WIMBoot template has no boot/boot.sdi'
[ -f "$WORK_ROOT/.usos-work" ] || fail 'WORK identity marker is missing'

usos_ui_stage 10 10 'Building WIM boot environment' 'Copying Windows boot manager, BCD, boot.sdi and fonts.'
rsync -a "$WIM_TEMPLATE/" "$WORK_ROOT/" || fail 'failed to copy WIMBoot template to WORK'
mkdir -p "$WORK_ROOT/sources"

WIM_BYTES=$(stat -c '%s' "$WIM_FILE")
PROGRESS_FIFO="/tmp/usos-wim-progress.$$"
rm -f "$PROGRESS_FIFO"
mkfifo "$PROGRESS_FIFO" || fail 'cannot create WIM progress FIFO'

tr '\r' '\n' < "$PROGRESS_FIFO" | awk -v total="$WIM_BYTES" '
    BEGIN { printf "\033[2J\033[H\033[?25l" }
    {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+%$/) {
                pct=$i; sub(/%$/, "", pct)
                if (pct != last) {
                    width=52; filled=int((pct*width)/100); bar=""
                    for (j=0; j<width; j++) bar=bar (j<filled ? "=" : "-")
                    printf "\033[H\n      USOS  Universal Service OS\n      --------------------------------------------------------------\n\n"
                    printf "      Preparing WIM boot environment\n      Measured progress - copying boot.wim\n\n"
                    printf "      [%s]\n      %3d%%\n\n", bar, pct
                    printf "      [1] Device checks       OK\n      [2] WORK preparation    OK\n      [3] WIM copy            RUNNING\n      [4] Verification        waiting\n"
                    fflush(); last=pct
                }
                break
            }
        }
    }
' > "$USOS_UI_TTY" &
PROGRESS_PID=$!
set +e
rsync -a --info=progress2 --no-inc-recursive "$WIM_FILE" "$WORK_ROOT/sources/boot.wim" > "$PROGRESS_FIFO" 2>&1
RSYNC_RC=$?
set -e
wait "$PROGRESS_PID" || true
rm -f "$PROGRESS_FIFO"
[ "$RSYNC_RC" -eq 0 ] || fail 'failed to copy WIM to WORK'

cmp -s "$WIM_FILE" "$WORK_ROOT/sources/boot.wim" || fail 'boot.wim verification failed'
[ -s "$WORK_ROOT/EFI/BOOT/BOOTX64.EFI" ] || fail 'fallback EFI boot manager is missing after copy'
[ -s "$WORK_ROOT/EFI/Microsoft/Boot/BCD" ] || fail 'BCD is missing after copy'
[ -s "$WORK_ROOT/boot/boot.sdi" ] || fail 'boot.sdi is missing after copy'

UNATTEND_COPIED=no
if [ -n "$UNATTEND_FILE" ]; then
    [ -f "$UNATTEND_FILE" ] || fail 'selected unattended file is missing'
    cp -f "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml" || fail 'failed to copy Autounattend.xml'
    cmp -s "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml" || fail 'Autounattend.xml verification failed'
    UNATTEND_COPIED=yes
fi

sync
STATE_TMP="${STATE_FILE}.tmp.$$"
trap 'rm -f "$STATE_TMP"' EXIT HUP INT TERM
{
    printf 'phase=prepared\n'
    printf 'selected_method=wimboot\n'
    printf 'source_bytes=%s\n' "$WIM_BYTES"
    printf 'unattend_copied=%s\n' "$UNATTEND_COPIED"
} > "$STATE_TMP" || fail 'failed to write prepared WIMBoot state'
mv -f "$STATE_TMP" "$STATE_FILE" || fail 'failed to publish prepared WIMBoot state'
trap - EXIT HUP INT TERM
sync
usos_ui_done 'WIM boot environment ready' 'Verified boot.wim, BCD, boot.sdi and EFI boot manager.'
printf '[WIMBOOT] phase=prepared PASS wim=%s bytes=%s\n' "$WIM_FILE" "$WIM_BYTES"
