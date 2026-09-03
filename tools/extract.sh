#!/bin/sh
set -eu

SOURCE_ROOT=${SOURCE_ROOT:?SOURCE_ROOT is required}
WORK_ROOT=${WORK_ROOT:?WORK_ROOT is required}
STATE_FILE=${STATE_FILE:?STATE_FILE is required}
UNATTEND_FILE=${UNATTEND_FILE:-}
SOURCE_LABEL=${SOURCE_LABEL:-Windows ISO}
UI_TTY=/dev/tty1
[ -w "$UI_TTY" ] || UI_TTY=/dev/console

fail() {
    printf '\033[0m\033[?25h' > "$UI_TTY" 2>/dev/null || true
    printf '[EXTRACT] STOP: %s\n' "$1" >&2
    exit 1
}

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
printf '[EXTRACT] copying installer to WORK with real byte progress\n'

render_progress() {
    tr '\r' '\n' | awk -v total="$SOURCE_BYTES" -v label="$SOURCE_LABEL" '
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
            if (value >= 1073741824) { value /= 1073741824; unit = "GiB" }
            else if (value >= 1048576) { value /= 1048576; unit = "MiB" }
            else if (value >= 1024) { value /= 1024; unit = "KiB" }
            return sprintf("%.1f %s", value, unit)
        }
        function line(text) {
            printf "%s\033[K\n", text
        }
        function draw(pct, done, speed, eta, width, filled, i, bar) {
            if (pct < 0) pct = 0
            if (pct > 100) pct = 100
            width = 52
            filled = int((pct * width) / 100)
            bar = ""
            for (i = 0; i < width; i++) {
                if (i < filled) bar = bar cyan "=" reset
                else bar = bar dim "-" reset
            }

            printf "\033[H"
            line("")
            line("      " cyan bold "USOS" reset "  " dim "Universal Service OS" reset)
            line("      " dim "--------------------------------------------------------------" reset)
            line("")
            line("      " white bold "Przygotowywanie instalatora Windows" reset)
            line("      " dim "Etap 3 z 4  -  kopiowanie plikow instalacyjnych" reset)
            line("")
            line("      " dim "Obraz" reset)
            line("      " white label reset)
            line("")
            line("      [" bar "]")
            line("      " cyan bold sprintf("%3d%%", pct) reset "    " white human(done) reset " " dim "/ " human(total) reset)
            line("")
            if (speed != "" || eta != "") {
                line("      " dim "Predkosc" reset "  " white speed reset "      " dim "Pozostalo" reset "  " white eta reset)
            } else {
                line("")
            }
            line("")
            line("      " blue "[1] Sprawdzenie nosnika" reset "   " green "OK" reset)
            line("      " blue "[2] Przygotowanie WORK" reset "    " green "OK" reset)
            line("      " cyan bold "[3] Kopiowanie ISO" reset "          " cyan "W TOKU" reset)
            line("      " dim "[4] Weryfikacja" reset "            oczekuje")
            line("")
            line("      " dim "Nie odlaczaj nosnika i nie wylaczaj komputera." reset)
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
                eta = (NF >= 4 ? $4 : "")
                draw(pct + 0, done, speed, eta)
                last_pct = pct
            }
        }
        END {
            if (last_pct != 100) draw(100, total, "", "0:00:00")
        }
    '
}

PROGRESS_FIFO="/tmp/usos-rsync-progress.$$"
rm -f "$PROGRESS_FIFO"
mkfifo "$PROGRESS_FIFO" || fail 'cannot create extraction progress FIFO'
render_progress < "$PROGRESS_FIFO" > "$UI_TTY" &
PROGRESS_PID=$!
set +e
rsync -a --info=progress2 --no-inc-recursive --exclude='/.usos-work' "$SOURCE_ROOT/" "$WORK_ROOT/" > "$PROGRESS_FIFO" 2>&1
RSYNC_RC=$?
set -e
wait "$PROGRESS_PID" || true
rm -f "$PROGRESS_FIFO"
[ "$RSYNC_RC" -eq 0 ] || fail 'rsync extraction failed'
{
    printf '\033[H\033[?25l'
    printf '\n'
    printf '      \033[1;36m\033[1mUSOS\033[0m  \033[2mUniversal Service OS\033[0m\033[K\n'
    printf '      \033[2m--------------------------------------------------------------\033[0m\033[K\n\n'
    printf '      \033[1;37m\033[1mPrzygotowywanie instalatora Windows\033[0m\033[K\n'
    printf '      \033[2mEtap 4 z 4  -  weryfikacja plikow\033[0m\033[K\n\n'
    printf '      [\033[1;36m====================================================\033[0m]\033[K\n'
    printf '      \033[1;32m\033[1m100%%\033[0m    Kopiowanie zakonczone\033[K\n\n'
    printf '      \033[1;34m[1] Sprawdzenie nosnika\033[0m   \033[1;32mOK\033[0m\033[K\n'
    printf '      \033[1;34m[2] Przygotowanie WORK\033[0m    \033[1;32mOK\033[0m\033[K\n'
    printf '      \033[1;34m[3] Kopiowanie ISO\033[0m          \033[1;32mOK\033[0m\033[K\n'
    printf '      \033[1;36m\033[1m[4] Weryfikacja\033[0m            \033[1;36mW TOKU\033[0m\033[K\n\n'
    printf '      \033[2mSprawdzanie liczby plikow i rozmiaru danych...\033[0m\033[K\n'
} > "$UI_TTY"

set -- $(stats "$WORK_ROOT" yes)
DEST_FILES=$1
DEST_BYTES=$2
printf '[EXTRACT] destination files=%s bytes=%s\n' "$DEST_FILES" "$DEST_BYTES"

[ "$DEST_FILES" = "$SOURCE_FILES" ] || fail "file-count mismatch source=$SOURCE_FILES destination=$DEST_FILES"
[ "$DEST_BYTES" = "$SOURCE_BYTES" ] || fail "byte-count mismatch source=$SOURCE_BYTES destination=$DEST_BYTES"
printf '[EXTRACT] completeness PASS\n'

UNATTEND_COPIED=no
if [ -n "$UNATTEND_FILE" ]; then
    [ -f "$UNATTEND_FILE" ] || fail "selected unattended file is missing: $UNATTEND_FILE"
    # Windows Setup's implicit media search expects this exact canonical name
    # at the root of the prepared installation drive.
    cp -f "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml" || fail 'failed to copy selected unattended file as Autounattend.xml'
    cmp -s "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml" || fail 'copied Autounattend.xml does not match selected source'
    UNATTEND_COPIED=yes
    printf '[EXTRACT] unattended PASS source=%s setup=%s\n' "$UNATTEND_FILE" "$WORK_ROOT/Autounattend.xml"
fi

# All installer data and optional unattended data must reach the backing store
# before phase=prepared is made visible to the bootmanager.
sync

STATE_DIR=$(dirname "$STATE_FILE")
[ -d "$STATE_DIR" ] || fail "state directory does not exist: $STATE_DIR"
STATE_TMP="${STATE_FILE}.tmp.$$"
trap 'rm -f "$STATE_TMP"' EXIT HUP INT TERM
{
    printf 'phase=prepared\n'
    printf 'source_files=%s\n' "$SOURCE_FILES"
    printf 'source_bytes=%s\n' "$SOURCE_BYTES"
    printf 'unattend_copied=%s\n' "$UNATTEND_COPIED"
} > "$STATE_TMP" || fail 'failed to write temporary prepared state'
mv -f "$STATE_TMP" "$STATE_FILE" || fail 'failed to publish prepared state'
trap - EXIT HUP INT TERM
sync
printf '[EXTRACT] phase=prepared PASS state=%s\n' "$STATE_FILE"
