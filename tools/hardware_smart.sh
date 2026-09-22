#!/bin/sh
# SMART queries only. Never enable SMART, start tests or change drive settings.

usos_smart_read() {
    local device=$1 report=$2 status=0 base
    base=${device#/dev/}
    case "$device:$base" in /dev/*:*) ;; *) return 2 ;; esac
    case "$base" in ''|*[!a-zA-Z0-9]*) return 2 ;; esac
    LC_ALL=C timeout 20 smartctl -a -n standby,3 -- "$device" > "$report" 2>&1 || status=$?
    USOS_SMART_EXIT=$status
}

usos_smart_summary() {
    local status=$1 report=$2
    case "$status" in
        ''|*[!0-9]*) printf '%s' 'SMART result unavailable'; return ;;
        124|137|143) printf '%s' 'SMART read timed out'; return ;;
    esac
    if [ "$status" -eq 3 ] && grep -Eq '(STANDBY|SLEEP).*([Ee]xit|[Mm]ode)|[Dd]evice is in (STANDBY|SLEEP)' "$report"; then
        printf '%s' 'Disk asleep - SMART not read'
    elif [ "$((status & 8))" -ne 0 ]; then
        printf '%s' 'SMART reports a failing health status'
    elif [ "$((status & 7))" -ne 0 ]; then
        printf '%s' 'SMART unavailable or incomplete - see details'
    elif [ "$((status & 240))" -ne 0 ]; then
        printf '%s' 'SMART warnings or recorded errors - see details'
    elif grep -Eq '^SMART (overall-health self-assessment test result: PASSED|Health Status: OK)' "$report"; then
        printf '%s' 'SMART reports PASSED (not a full surface test)'
    else
        printf '%s' 'No supported SMART health result'
    fi
}

usos_smart_table() {
    LC_ALL=C awk -f "${USOS_SMART_TABLE_AWK:-/usr/lib/usos/hardware_smart_table.awk}" "$1"
}
