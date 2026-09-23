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
    usos_ui_fail 'Preparation stopped' "$1" || true
    usos_ui_restore_cursor || true
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
[ -f "$SCRIPT_DIR/work_boot_relocate.sh" ] || fail 'work_boot_relocate.sh is missing'

usos_ui_stage 4 5 'Building WIM boot environment' 'Copying Windows boot manager, BCD, boot.sdi and fonts.'
rsync -a "$WIM_TEMPLATE/" "$WORK_ROOT/" || fail 'failed to copy WIMBoot template to WORK'
mkdir -p "$WORK_ROOT/sources"

WIM_BYTES=$(stat -c '%s' "$WIM_FILE")
PROGRESS_FIFO="/tmp/usos-wim-progress.$$"
rm -f "$PROGRESS_FIFO"
mkfifo "$PROGRESS_FIFO" || fail 'cannot create WIM progress FIFO'
WIM_LABEL=${WIM_FILE##*/}

if [ "$USOS_FB_ACTIVE" = yes ]; then
    tr '\r' '\n' < "$PROGRESS_FIFO" | awk -v total="$WIM_BYTES" '
        function speed_bps(text, value, unit) {
            value = text + 0
            unit = text
            sub(/^[0-9.]+/, "", unit)
            if (unit == "GB/s") return value * 1000000000
            if (unit == "MB/s") return value * 1000000
            if (unit == "kB/s" || unit == "KB/s") return value * 1000
            if (unit == "GiB/s") return value * 1073741824
            if (unit == "MiB/s") return value * 1048576
            if (unit == "KiB/s") return value * 1024
            if (unit == "B/s") return value
            return 0
        }
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+%$/) {
                    pct=$i; sub(/%$/, "", pct)
                    if (pct != last) {
                        done=$1; gsub(/,/, "", done); done += 0
                        speed=(NF >= 3 ? speed_bps($3) : 0)
                        printf "%d|%.0f|%.0f\n", pct + 0, done, speed
                        fflush(); last=pct
                    }
                    break
                }
            }
        }
        END { if (last != 100) printf "100|%.0f|0\n", total }
    ' | while IFS='|' read -r pct done speed_bps; do
        usos_ui_progress 4 5 "$pct" "$done" "$WIM_BYTES" "$speed_bps" 'Copying WIM file' 'Measured byte progress, transfer speed and ETA.' "$WIM_LABEL"
    done &
else
tr '\r' '\n' < "$PROGRESS_FIFO" | awk -v total="$WIM_BYTES" '
    BEGIN { printf "\033[2J\033[H\033[?25l" }
    function speed_bps(text, value, unit) {
        value = text + 0
        unit = text
        sub(/^[0-9.]+/, "", unit)
        if (unit == "GB/s") return value * 1000000000
        if (unit == "MB/s") return value * 1000000
        if (unit == "kB/s" || unit == "KB/s") return value * 1000
        if (unit == "GiB/s") return value * 1073741824
        if (unit == "MiB/s") return value * 1048576
        if (unit == "KiB/s") return value * 1024
        if (unit == "B/s") return value
        return 0
    }
    function eta_from_speed(done, speed, bps, remaining, seconds, hours, minutes, secs) {
        bps = speed_bps(speed)
        if (bps <= 0) return "--:--"
        remaining = total - done
        if (remaining < 0) remaining = 0
        seconds = int((remaining / bps) + 0.5)
        hours = int(seconds / 3600)
        minutes = int((seconds % 3600) / 60)
        secs = seconds % 60
        if (hours > 0) return sprintf("%d:%02d:%02d", hours, minutes, secs)
        return sprintf("%02d:%02d", minutes, secs)
    }
    {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+%$/) {
                pct=$i; sub(/%$/, "", pct)
                if (pct != last) {
                    done=$1; gsub(/,/, "", done); done += 0
                    speed=(NF >= 3 ? $3 : "")
                    eta=eta_from_speed(done, speed)
                    width=52; filled=int((pct*width)/100); bar=""
                    for (j=0; j<width; j++) bar=bar (j<filled ? "=" : "-")
                    printf "\033[H\n      USOS  Universal Service OS\n      --------------------------------------------------------------\n\n"
                    printf "      Preparing WIM boot environment\n      Measured progress - copying boot.wim\n\n"
                    printf "      [%s]\n      %3d%%\n", bar, pct
                    if (speed != "") printf "      Speed  %s      Estimated remaining  %s\n", speed, eta
                    else printf "\n"
                    printf "\n      [1/5] Starting environment                    OK\n      [2/5] Verifying target device (device_guard)       OK\n      [3/5] Preparing WORK partition (mkfs.ntfs)      OK\n      [4/5] Copying files                           RUNNING\n      [5/5] Verification and finalization             waiting\n"
                    fflush(); last=pct
                }
                break
            }
        }
    }
' > "$USOS_UI_TTY" &
fi
PROGRESS_PID=$!
usos_perf_mark 'WIM file copy begin'
set +e
rsync -a --info=progress2 --no-inc-recursive "$WIM_FILE" "$WORK_ROOT/sources/boot.wim" > "$PROGRESS_FIFO" 2>&1
RSYNC_RC=$?
set -e
wait "$PROGRESS_PID" || true
rm -f "$PROGRESS_FIFO"
usos_perf_mark 'WIM file copy end'
[ "$RSYNC_RC" -eq 0 ] || fail 'failed to copy WIM to WORK'

usos_ui_stage 5 5 'Verifying WIM file' 'Comparing the copied boot.wim with the selected source.'
usos_perf_mark 'WIM verification and finalization begin'
cmp -s "$WIM_FILE" "$WORK_ROOT/sources/boot.wim" || fail 'boot.wim verification failed'
usos_ui_stage 5 5 'Verifying boot files' 'Checking BCD, boot.sdi and the EFI fallback boot manager.'
sh "$SCRIPT_DIR/work_boot_relocate.sh" relocate "$WORK_ROOT" || fail 'cannot move the WIMBoot boot manager to EFI/USOS-WORK'
sh "$SCRIPT_DIR/work_boot_relocate.sh" assert "$WORK_ROOT" --require-entry || fail 'EFI boot manager is missing after copy'
[ -s "$WORK_ROOT/EFI/Microsoft/Boot/BCD" ] || fail 'BCD is missing after copy'
[ -s "$WORK_ROOT/boot/boot.sdi" ] || fail 'boot.sdi is missing after copy'

UNATTEND_COPIED=no
if [ -n "$UNATTEND_FILE" ]; then
    usos_ui_stage 5 5 'Copying unattended file' 'Writing Autounattend.xml to the WIM boot environment.'
    [ -f "$UNATTEND_FILE" ] || fail 'selected unattended file is missing'
    cp -f "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml" || fail 'failed to copy Autounattend.xml'
    cmp -s "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml" || fail 'Autounattend.xml verification failed'
    UNATTEND_COPIED=yes
else
    usos_ui_stage 5 5 'Copying unattended file' 'No unattended file selected - skipped.'
fi

usos_perf_mark 'WIM files flush begin'
usos_ui_sync_with_activity 'Flushing to disk' 'Writing the WIM boot environment to the USB drive.' || fail 'WIMBoot file flush failed'
usos_perf_mark 'WIM files flush end'
usos_ui_stage 5 5 'Writing prepared state' 'Publishing phase=prepared after WIM data is durable.'
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
usos_perf_mark 'WIM state flush begin'
usos_ui_sync_with_activity 'Flushing to disk' 'Committing prepared state to the USB drive.' || fail 'WIMBoot state flush failed'
usos_perf_mark 'WIM state flush end'
usos_ui_stage 5 5 'Finalization complete' 'Verified boot.wim, BCD, boot.sdi and EFI boot manager.'
usos_perf_mark 'WIM verification and finalization end'
printf '[WIMBOOT] phase=prepared PASS wim=%s bytes=%s\n' "$WIM_FILE" "$WIM_BYTES"
