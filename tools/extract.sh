#!/bin/sh
set -eu

SOURCE_ROOT=${SOURCE_ROOT:?SOURCE_ROOT is required}
WORK_ROOT=${WORK_ROOT:?WORK_ROOT is required}
STATE_FILE=${STATE_FILE:?STATE_FILE is required}
UNATTEND_FILE=${UNATTEND_FILE:-}
SOURCE_LABEL=${SOURCE_LABEL:-Windows ISO}
SELECTED_METHOD=${SELECTED_METHOD:-iso}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[ -r "$SCRIPT_DIR/micro_linux_ui.sh" ] || { printf '[EXTRACT] STOP: micro_linux_ui.sh is missing\n' >&2; exit 1; }
. "$SCRIPT_DIR/micro_linux_ui.sh"
UI_TTY=$USOS_UI_TTY

fail() {
    usos_ui_fail 'Preparation stopped' "$1" || true
    usos_ui_restore_cursor || true
    printf '[EXTRACT] STOP: %s\n' "$1" >&2
    exit 1
}

case "$SELECTED_METHOD" in
    iso|chainload) ;;
    *) fail "unsupported extraction method: $SELECTED_METHOD" ;;
esac

command -v rsync >/dev/null 2>&1 || fail 'rsync is required for extraction progress'
command -v find >/dev/null 2>&1 || fail 'find is required'
command -v stat >/dev/null 2>&1 || fail 'stat is required'
command -v awk >/dev/null 2>&1 || fail 'awk is required'
command -v cmp >/dev/null 2>&1 || fail 'cmp is required'
command -v sync >/dev/null 2>&1 || fail 'sync is required'
command -v mkfifo >/dev/null 2>&1 || fail 'mkfifo is required for extraction progress'
command -v tr >/dev/null 2>&1 || fail 'tr is required for extraction progress'

[ -d "$SOURCE_ROOT" ] || fail "source root is not a directory: $SOURCE_ROOT"
[ -d "$WORK_ROOT" ] || fail "WORK root is not a directory: $WORK_ROOT"
[ -f "$WORK_ROOT/.usos-work" ] || fail 'WORK identity marker .usos-work is missing before extraction'

SOURCE_ROOT=$(cd "$SOURCE_ROOT" && pwd -P)
WORK_ROOT=$(cd "$WORK_ROOT" && pwd -P)
case "$WORK_ROOT" in
    /|'') fail 'refusing unsafe WORK root' ;;
esac
[ "$SOURCE_ROOT" != "$WORK_ROOT" ] || fail 'source and WORK roots are identical'

stats() {
    root=$1
    exclude_marker=$2
    if [ "$exclude_marker" = yes ]; then
        files=$(find "$root" -type f ! -path "$root/.usos-work" | wc -l | awk '{print $1}')
        bytes=$(find "$root" -type f ! -path "$root/.usos-work" -exec stat -c '%s' {} \; | awk '{sum += $1} END {printf "%.0f", sum + 0}')
    else
        files=$(find "$root" -type f | wc -l | awk '{print $1}')
        bytes=$(find "$root" -type f -exec stat -c '%s' {} \; | awk '{sum += $1} END {printf "%.0f", sum + 0}')
    fi
    printf '%s %s\n' "$files" "$bytes"
}

set -- $(stats "$SOURCE_ROOT" no)
SOURCE_FILES=$1
SOURCE_BYTES=$2
printf '[EXTRACT] source files=%s bytes=%s\n' "$SOURCE_FILES" "$SOURCE_BYTES"
printf '[EXTRACT] copying source to WORK with real byte progress method=%s\n' "$SELECTED_METHOD"
usos_ui_stage 4 5 'Copying files' 'Measured byte progress, transfer speed and ETA are now available.'

render_progress() {
    tr '\r' '\n' | awk -v total="$SOURCE_BYTES" -v label="$SOURCE_LABEL" -v method="$SELECTED_METHOD" '
        BEGIN {
            reset = "\033[0m"
            bold = "\033[1m"
            cyan = "\033[1;36m"
            blue = "\033[1;34m"
            green = "\033[1;32m"
            dim = "\033[2m"
            white = "\033[1;37m"
            printf "\033[2J\033[H\033[?25l"
        }
        function human(bytes, value, unit) {
            value = bytes + 0
            unit = "B"
            if (value >= 1073741824) { value /= 1073741824; unit = "GB" }
            else if (value >= 1048576) { value /= 1048576; unit = "MB" }
            else if (value >= 1024) { value /= 1024; unit = "KB" }
            return sprintf("%.1f %s", value, unit)
        }
        function line(text) {
            printf "%s\033[K\n", text
        }
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
        function draw(pct, done, speed, width, filled, i, bar, eta) {
            if (pct < 0) pct = 0
            if (pct > 100) pct = 100
            width = 52
            filled = int((pct * width) / 100)
            bar = ""
            for (i = 0; i < width; i++) {
                if (i < filled) bar = bar cyan "=" reset
                else bar = bar dim "-" reset
            }
            eta = eta_from_speed(done, speed)

            printf "\033[H"
            line("")
            line("      " cyan bold "USOS" reset "  " dim "Universal Service OS" reset)
            line("      " dim "--------------------------------------------------------------" reset)
            line("")
            if (method == "chainload") {
                line("      " white bold "Preparing chainload media" reset)
                line("      " dim "Measured progress - copying boot media files" reset)
            } else {
                line("      " white bold "Preparing Windows installer" reset)
                line("      " dim "Measured progress - copying Windows files" reset)
            }
            line("")
            line("      " dim "Image" reset)
            line("      " white label reset)
            line("")
            line("      [" bar "]")
            line("      " cyan bold sprintf("%3d%%", pct) reset "    " white human(done) reset " " dim "/ " human(total) reset)
            if (speed != "") {
                line("      " dim "Speed" reset "  " white speed reset "      " dim "Estimated remaining" reset "  " white eta reset)
            } else {
                line("")
            }
            line("")
            line("      " blue "[1/5] Starting environment" reset "                    " green "OK" reset)
            line("      " blue "[2/5] Verifying target device (device_guard)" reset "       " green "OK" reset)
            line("      " blue "[3/5] Preparing WORK partition (mkfs.ntfs)" reset "      " green "OK" reset)
            line("      " cyan bold "[4/5] Copying files" reset "                           " cyan "RUNNING" reset)
            line("      " dim "[5/5] Verification and finalization" reset "             waiting")
            line("")
            line("      " dim "Do not disconnect the drive or turn off the computer." reset)
            line("")
            fflush()
        }
        {
            pct = -1
            bytes = $1
            gsub(/,/, "", bytes)
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+%$/) {
                    pct = $i
                    sub(/%$/, "", pct)
                    break
                }
            }
            if (pct >= 0 && pct != last_pct) {
                done = bytes + 0
                if (done < 0 || done > total) done = int((total * pct) / 100)
                speed = (NF >= 3 ? $3 : "")
                draw(pct + 0, done, speed)
                last_pct = pct
            }
        }
        END {
            if (last_pct != 100) draw(100, total, "")
        }
    '
}

render_framebuffer_progress() {
    tr '\r' '\n' | awk -v total="$SOURCE_BYTES" '
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
            pct = -1
            bytes = $1
            gsub(/,/, "", bytes)
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+%$/) {
                    pct = $i
                    sub(/%$/, "", pct)
                    break
                }
            }
            if (pct >= 0 && pct != last_pct) {
                done = bytes + 0
                if (done < 0 || done > total) done = int((total * pct) / 100)
                speed = (NF >= 3 ? speed_bps($3) : 0)
                printf "%d|%.0f|%.0f\n", pct + 0, done, speed
                fflush()
                last_pct = pct
            }
        }
        END {
            if (last_pct != 100) printf "100|%.0f|0\n", total
        }
    ' | while IFS='|' read -r pct done speed_bps; do
        usos_ui_progress 4 5 "$pct" "$done" "$SOURCE_BYTES" "$speed_bps" 'Copying files' 'Measured byte progress, transfer speed and ETA.' "$SOURCE_LABEL"
    done
}

PROGRESS_FIFO="/tmp/usos-rsync-progress.$$"
rm -f "$PROGRESS_FIFO"
mkfifo "$PROGRESS_FIFO" || fail 'cannot create extraction progress FIFO'
if [ "$USOS_FB_ACTIVE" = yes ]; then
    render_framebuffer_progress < "$PROGRESS_FIFO" &
else
    render_progress < "$PROGRESS_FIFO" > "$UI_TTY" &
fi
PROGRESS_PID=$!
usos_perf_mark 'file copy begin'
set +e
rsync -a --info=progress2 --no-inc-recursive --exclude='/.usos-work' "$SOURCE_ROOT/" "$WORK_ROOT/" > "$PROGRESS_FIFO" 2>&1
RSYNC_RC=$?
set -e
wait "$PROGRESS_PID" || true
rm -f "$PROGRESS_FIFO"
usos_perf_mark 'file copy end'
[ "$RSYNC_RC" -eq 0 ] || fail 'rsync extraction failed'
usos_ui_stage 5 5 'Verifying file count' "0 of $SOURCE_FILES files"
usos_perf_mark 'verification and finalization begin'

# Verify the destination by consuming one stat result per copied file. This
# keeps exact byte accounting for the guard/log while exposing a real file
# counter to the UI. Redraws are capped to roughly forty updates.
VERIFY_FIFO="/tmp/usos-verify-stats.$$"
rm -f "$VERIFY_FIFO"
mkfifo "$VERIFY_FIFO" || fail 'cannot create verification FIFO'
find "$WORK_ROOT" -type f ! -path "$WORK_ROOT/.usos-work" -exec stat -c '%s' {} \; > "$VERIFY_FIFO" &
VERIFY_PID=$!
DEST_FILES=0
DEST_BYTES=0
VERIFY_STEP=$((SOURCE_FILES / 40))
[ "$VERIFY_STEP" -gt 0 ] || VERIFY_STEP=1
while IFS= read -r file_bytes; do
    case "$file_bytes" in
        ''|*[!0-9]*) fail "invalid destination file size during verification: $file_bytes" ;;
    esac
    DEST_FILES=$((DEST_FILES + 1))
    DEST_BYTES=$((DEST_BYTES + file_bytes))
    if [ "$DEST_FILES" -eq 1 ] || [ $((DEST_FILES % VERIFY_STEP)) -eq 0 ] || [ "$DEST_FILES" -ge "$SOURCE_FILES" ]; then
        usos_ui_stage 5 5 'Verifying file count' "$DEST_FILES of $SOURCE_FILES files"
    fi
done < "$VERIFY_FIFO"
if wait "$VERIFY_PID"; then
    :
else
    rm -f "$VERIFY_FIFO"
    fail 'failed to enumerate destination files for verification'
fi
rm -f "$VERIFY_FIFO"
usos_ui_stage 5 5 'Verifying file count' "$DEST_FILES of $SOURCE_FILES files"
printf '[EXTRACT] destination files=%s bytes=%s\n' "$DEST_FILES" "$DEST_BYTES"
[ "$DEST_FILES" = "$SOURCE_FILES" ] || fail "file-count mismatch source=$SOURCE_FILES destination=$DEST_FILES"

SOURCE_SIZE_UI=$(usos_ui_format_bytes "$SOURCE_BYTES")
DEST_SIZE_UI=$(usos_ui_format_bytes "$DEST_BYTES")
usos_ui_stage 5 5 'Verifying total size' "$DEST_SIZE_UI of $SOURCE_SIZE_UI"
[ "$DEST_BYTES" = "$SOURCE_BYTES" ] || fail "byte-count mismatch source=$SOURCE_BYTES destination=$DEST_BYTES"
printf '[EXTRACT] completeness PASS\n'

if [ "${WINDOWS7_UEFI:-no}" = yes ]; then
    usos_ui_stage 5 5 'Preparing Windows 7' 'Preparing UEFI startup and USB drivers.'
    sh "$SCRIPT_DIR/prepare_windows7_uefi.sh" || fail 'Windows 7 UEFI preparation failed'
fi

usos_ui_stage 5 5 'Checking boot files' 'Verifying the prepared boot path before committing state.'
if [ "$SELECTED_METHOD" = chainload ]; then
    BOOT_FILE=$(find "$WORK_ROOT" -type f | awk 'tolower($0) ~ /\/efi\/boot\/bootx64\.efi$/ { print; exit }')
    [ -n "$BOOT_FILE" ] || fail 'chainload source has no EFI/BOOT/BOOTX64.EFI'
    printf '[EXTRACT] chainload boot file PASS path=%s\n' "$BOOT_FILE"
else
    INSTALL_WIM=$(find "$WORK_ROOT" -type f | awk 'tolower($0) ~ /\/sources\/install\.(wim|esd)$/ { print; exit }')
    [ -n "$INSTALL_WIM" ] || fail 'Windows installer has no sources/install.wim or install.esd'
    printf '[EXTRACT] Windows installation image PASS path=%s\n' "$INSTALL_WIM"
fi

UNATTEND_COPIED=no
if [ -n "$UNATTEND_FILE" ]; then
    usos_ui_stage 5 5 'Copying unattended file' 'Writing Autounattend.xml to the prepared WORK partition.'
    [ -f "$UNATTEND_FILE" ] || fail "selected unattended file is missing: $UNATTEND_FILE"
    # Windows Setup's implicit media search expects this exact canonical name
    # at the root of the prepared installation drive.
    cp -f "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml" || fail 'failed to copy selected unattended file as Autounattend.xml'
    cmp -s "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml" || fail 'copied Autounattend.xml does not match selected source'
    UNATTEND_COPIED=yes
    printf '[EXTRACT] unattended PASS source=%s setup=%s\n' "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml"
else
    usos_ui_stage 5 5 'Copying unattended file' 'No unattended file selected - skipped.'
fi

# All installer data and optional unattended data must reach the backing store
# before phase=prepared is made visible to the bootmanager. sync is deliberately
# run in the background only so the UI can show activity; completion is still
# awaited and required before the state transition.
usos_perf_mark 'prepared files flush begin'
usos_ui_sync_with_activity 'Flushing to disk' 'Writing prepared files to the USB drive.' || fail 'sync failed while flushing prepared files'
usos_perf_mark 'prepared files flush end'

usos_ui_stage 5 5 'Writing prepared state' 'Publishing phase=prepared after file data is durable.'
STATE_DIR=$(dirname "$STATE_FILE")
[ -d "$STATE_DIR" ] || fail "state directory does not exist: $STATE_DIR"
STATE_TMP="${STATE_FILE}.tmp.$$"
trap 'rm -f "$STATE_TMP"' EXIT HUP INT TERM
{
    printf 'phase=prepared\n'
    printf 'source_files=%s\n' "$SOURCE_FILES"
    printf 'source_bytes=%s\n' "$SOURCE_BYTES"
    printf 'unattend_copied=%s\n' "$UNATTEND_COPIED"
    printf 'selected_method=%s\n' "$SELECTED_METHOD"
} > "$STATE_TMP" || fail 'failed to write temporary prepared state'
mv -f "$STATE_TMP" "$STATE_FILE" || fail 'failed to publish prepared state'
trap - EXIT HUP INT TERM
usos_perf_mark 'prepared state flush begin'
usos_ui_sync_with_activity 'Flushing to disk' 'Committing prepared state to the USB drive.' || fail 'sync failed while committing prepared state'
usos_perf_mark 'prepared state flush end'
usos_ui_stage 5 5 'Finalization complete' 'File count, total size and prepared state verified.'
usos_perf_mark 'verification and finalization end'
printf '[EXTRACT] phase=prepared PASS state=%s\n' "$STATE_FILE"
