# SPDX-License-Identifier: GPL-3.0-or-later
# Windows 95 only. RFB notifications and wait replace the shared legacy
# controller's timed disk/screen checks. NT uses its existing controller.
W9X_VM_95_EVENTS=${W9X_VM_95_EVENTS:-/usr/lib/usos/win95-rfb-events}
w9x_95_timeout() {
    if command -v timeout >/dev/null 2>&1; then exec timeout "$@"
    else exec /bin/busybox timeout "$@"; fi
}
w9x_95_event_run() {
    target=$1
    accel=${2:-tcg}
    [ -x "$W9X_VM_95_EVENTS" ] &&
        command -v w9x_vm_95_input >/dev/null 2>&1 || return 2
    command -v timeout >/dev/null 2>&1 || [ -x /bin/busybox ] || return 2
    rm -rf "$W9X_VM_RUN"
    mkdir -p "$W9X_VM_RUN"
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    mkfifo "$W9X_VM_RUN/mon.in" "$W9X_VM_RUN/mon.out" "$W9X_VM_RUN/key.in" "$W9X_VM_RUN/key.out" "$W9X_VM_RUN/events" || return 2
    cat 0<> "$W9X_VM_RUN/mon.out" > "$W9X_VM_RUN/monitor.log" 2>/dev/null &
    drain=$!
    cat 0<> "$W9X_VM_RUN/key.out" > /dev/null 2>&1 &
    drain_key=$!
    exec 8<> "$W9X_VM_RUN/events"
    (
        ulimit -c 0
        w9x_95_timeout "$W9X_VM_TIMEOUT" "$W9X_VM_95_EVENTS" --listen "$W9X_VM_RUN/display.sock" &
        receiver=$!
        trap 'kill "$receiver" 2>/dev/null || true; wait "$receiver" || true; exit 0' TERM
        event_rc=0
        wait "$receiver" || event_rc=$?
        printf 'watch-exit %s\n' "$event_rc"
    ) > "$W9X_VM_RUN/events" 2> "$W9X_VM_RUN/event-errors.log" &
    watcher=$!
    IFS=' ' read -r event value <&8
    if [ "$event" != ready ]; then
        wait "$watcher" || true
        kill "$drain" "$drain_key" 2>/dev/null || true
        exec 8>&-
        return 2
    fi
    key=$W9X_VM_KEY
    w95_last_page='' key_tries=0 key_on_screen=0
    W9X_VM_STALLED=0
    start=$(date +%s)
    written0=$(w9x_vm_written "$target")
    set --
    while IFS= read -r arg; do set -- "$@" "$arg"; done <<EOF
$(w9x_vm_args "$target" "$accel")
EOF
    set -- "$@" -vnc "unix:$W9X_VM_RUN/display.sock,reverse=on"
    printf '%s\n' "$W9X_VM_QEMU $*" > "$W9X_VM_RUN/command.txt"
    (
        "$W9X_VM_QEMU" "$@" > "$W9X_VM_RUN/qemu.log" 2>&1 < /dev/null &
        child=$!
        printf 'started %s\n' "$child"
        child_rc=0
        wait "$child" || child_rc=$?
        printf 'exit %s\n' "$child_rc"
    ) > "$W9X_VM_RUN/events" &
    supervisor=$!
    vm='' result='' rc=2
    while IFS=' ' read -r event value <&8; do
        case "$event" in
            started) vm=$value ;;
            page)
                W9X_VM_PAGE=$value
                # Read the copy guard only in response to an actual page event.
                written=$(( ($(w9x_vm_written "$target") - written0) / 2048 ))
                if w9x_vm_95_page_ready; then
                    if ! w9x_vm_95_input; then result=2; break; fi
                fi
                ;;
            watch-exit)
                # EOF is the display closing; wait for the child exit event.
                if [ "$value" != 0 ]; then
                    result=2
                    [ "$value" != 124 ] || result=3
                    break
                fi
                ;;
            exit) rc=$value; break ;;
            *) result=2; break ;;
        esac
    done
    if [ -n "$result" ] && [ -n "$vm" ]; then kill "$vm" 2>/dev/null || true; fi
    wait "$supervisor" || true
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" || true
    kill "$drain" "$drain_key" 2>/dev/null || true
    exec 8>&-
    W9X_VM_ELAPSED=$(( $(date +%s) - start ))
    printf 'rc=%s elapsed=%s accel=%s controller=rfb-blocking-events\n' "$rc" "$W9X_VM_ELAPSED" "$accel" >> "$W9X_VM_RUN/command.txt"
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    [ -z "$result" ] || return "$result"
    [ "$rc" = 0 ] || return 2
}
