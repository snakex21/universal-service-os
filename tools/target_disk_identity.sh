#!/bin/sh
# Shared read-only physical disk identity helpers for target selection/guard.
# This file performs no writes and may be sourced by initramfs workflows.

usos_disk_trim() {
    printf '%s' "$1" | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); printf "%s", $0 }'
}

usos_disk_name() {
    basename "$(readlink -f "$1")"
}

usos_disk_lsblk_value() {
    device=$1
    column=$2
    # One column at a time, so normal (non-raw) output is unambiguous and
    # preserves human-readable spaces instead of lsblk raw-mode \\x20 escapes.
    lsblk -b -dno "$column" "$device" 2>/dev/null | head -n 1
}

usos_disk_model() {
    device=$1
    value=$(usos_disk_trim "$(usos_disk_lsblk_value "$device" MODEL)")
    if [ -z "$value" ]; then
        name=$(usos_disk_name "$device")
        if [ -r "/sys/class/block/$name/device/model" ]; then
            value=$(usos_disk_trim "$(cat "/sys/class/block/$name/device/model" 2>/dev/null || true)")
        fi
    fi
    printf '%s' "$value"
}

usos_disk_serial() {
    device=$1
    value=$(usos_disk_trim "$(usos_disk_lsblk_value "$device" SERIAL)")
    [ -n "$value" ] && { printf '%s' "$value"; return 0; }

    name=$(usos_disk_name "$device")
    if [ -r "/sys/class/block/$name/serial" ]; then
        value=$(usos_disk_trim "$(cat "/sys/class/block/$name/serial" 2>/dev/null || true)")
        [ -n "$value" ] && { printf '%s' "$value"; return 0; }
    fi

    sys="/sys/class/block/$name/device"
    if [ -r "$sys/serial" ]; then
        value=$(usos_disk_trim "$(cat "$sys/serial" 2>/dev/null || true)")
        [ -n "$value" ] && { printf '%s' "$value"; return 0; }
    fi

    # SCSI VPD page 0x80 contains the unit serial after the 4-byte page header.
    if [ -r "$sys/vpd_pg80" ]; then
        value=$(dd if="$sys/vpd_pg80" bs=1 skip=4 2>/dev/null | tr -d '\000\r\n' | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); printf "%s", $0 }')
        [ -n "$value" ] && { printf '%s' "$value"; return 0; }
    fi

    # USB/SATA bridges often expose the serial on a parent device rather than
    # the block/SCSI leaf. Walk upward but never invent a serial from model/size.
    path=$(readlink -f "$sys" 2>/dev/null || true)
    while [ -n "$path" ] && [ "$path" != / ] && [ "$path" != /sys ]; do
        if [ -r "$path/serial" ]; then
            value=$(usos_disk_trim "$(cat "$path/serial" 2>/dev/null || true)")
            [ -n "$value" ] && { printf '%s' "$value"; return 0; }
        fi
        parent=$(dirname "$path")
        [ "$parent" != "$path" ] || break
        path=$parent
    done
    return 1
}

usos_disk_wwn() {
    device=$1
    value=$(usos_disk_trim "$(usos_disk_lsblk_value "$device" WWN)")
    if [ -z "$value" ]; then
        name=$(usos_disk_name "$device")
        for candidate in "/sys/class/block/$name/device/wwid" "/sys/class/block/$name/wwid"; do
            if [ -r "$candidate" ]; then
                value=$(usos_disk_trim "$(cat "$candidate" 2>/dev/null || true)")
                [ -n "$value" ] && break
            fi
        done
    fi
    printf '%s' "$value"
}

usos_disk_size() {
    usos_disk_trim "$(usos_disk_lsblk_value "$1" SIZE)"
}

usos_disk_logical_sector() {
    usos_disk_trim "$(usos_disk_lsblk_value "$1" LOG-SEC)"
}
