# The USOS stick ESP stays read-only during long phases (sourced).
#
# X470 2026-10-11 (B261011-151241): a POSReady install ended by a power-off
# after 1 h left the stick ESP's FAT32 dirty flag set although every restart
# goes through stick_release.sh. Linux vfat sets the flag while the volume is
# mounted read-write and clears it only on a remount read-only or unmount;
# micro-Linux kept /mnt/esp read-write for the whole VM loop (hours). So:
#
#   usos_stick_ro            remount the ESP read-only (sync first)
#   usos_stick_rw            remount it read-write again
#   usos_stick_write CMD...  one write: rw -> CMD -> sync -> back to ro when it
#                            was ro before; the dirty window is seconds
#   usos_stick_mode          rw | ro | none (not mounted)
#
# Long phases (VM loops, waits for the user) call usos_stick_ro first and do
# every later write through usos_stick_write. Each remount is bounded (10 s).
USOS_STICK_ESP=${USOS_STICK_ESP:-/mnt/esp}
USOS_STICK_PROC_MOUNTS=${USOS_STICK_PROC_MOUNTS:-/proc/mounts}

usos_stick_mode() {
    awk -v mp="$USOS_STICK_ESP" '$2 == mp { mode = ("," $4 ",") ~ /,rw,/ ? "rw" : "ro" } END { print (mode == "" ? "none" : mode) }' \
        "$USOS_STICK_PROC_MOUNTS" 2>/dev/null || echo none
}

usos_stick_remount() {
    mount -o "remount,$1" "$USOS_STICK_ESP" >/dev/null 2>&1 &
    _usos_stick_pid=$!
    _usos_stick_n=0
    while kill -0 "$_usos_stick_pid" 2>/dev/null; do
        [ "$_usos_stick_n" -ge 20 ] && { printf '[STICK] remount %s of %s still running after 10 s\n' "$1" "$USOS_STICK_ESP"; return 1; }
        sleep 0.5 2>/dev/null || sleep 1
        _usos_stick_n=$((_usos_stick_n + 1))
    done
    wait "$_usos_stick_pid"
}

usos_stick_ro() {
    sync
    [ "$(usos_stick_mode)" = rw ] || return 0
    usos_stick_remount ro || { printf '[STICK] %s stays read-write (remount ro failed)\n' "$USOS_STICK_ESP"; return 1; }
}

usos_stick_rw() {
    [ "$(usos_stick_mode)" = ro ] || return 0
    usos_stick_remount rw
}

usos_stick_write() {
    _usos_stick_was=$(usos_stick_mode)
    [ "$_usos_stick_was" != ro ] || usos_stick_rw || { printf '[STICK] cannot remount %s read-write\n' "$USOS_STICK_ESP"; return 1; }
    "$@"
    _usos_stick_rc=$?
    sync
    [ "$_usos_stick_was" != ro ] || usos_stick_ro || true
    return "$_usos_stick_rc"
}

# Writers for usos_stick_write (stdin -> one ESP file):
#   { ...; } | usos_stick_write usos_esp_put FILE      replace FILE
#   { ...; } | usos_stick_write usos_esp_append FILE   append to FILE
# Every write onto the stick ESP goes through usos_stick_write
# (tools/tests/test_esp_writes_helper.py): a plain pass-through while the ESP
# is read-write, a short read-write window while it is read-only
# (X470 2026-10-12, B261012-104904: the XP disk picker wrote its traces into
# the read-only ESP and stopped with "cannot write Legacy XP staging status").
usos_esp_put() {
    cat > "$1"
}
usos_esp_append() {
    cat >> "$1"
}
