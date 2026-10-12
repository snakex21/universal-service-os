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

# Media of a (S)ATA disk from ATA IDENTIFY (smartctl --identify=w, read-only,
# never spins a sleeping disk up): "SSD" (word 217 = 1), "SSHD" (rotating,
# word 78 bit 9 "Hybrid Information supported"), "HDD" (rotating) or nothing
# when IDENTIFY is unavailable or word 217 is not reported.
usos_disk_ata_media() {
    command -v "${USOS_SMARTCTL:-smartctl}" >/dev/null 2>&1 || return 1
    LC_ALL=C timeout 10 "${USOS_SMARTCTL:-smartctl}" -n standby,3 --identify=w -- "$1" 2>/dev/null | awk '
        { line = $0; sub(/^[^0-9]*/, "", line); n = split(line, f, /[ \t]+/) }
        # Word rows: "<word> [-] 0x<value> <description>" (the "-" bit
        # column only when bits are listed); bit rows have a bit number there.
        n >= 2 && f[1] ~ /^[0-9]+$/ {
            value = (f[2] == "-") ? f[3] : f[2]
            if (value ~ /^0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) word[f[1] + 0] = value
        }
        function hex(text,   value, digit, k) {
            value = 0
            for (k = 3; k <= length(text); k++) {
                digit = index("0123456789abcdef", tolower(substr(text, k, 1))) - 1
                value = value * 16 + digit
            }
            return value
        }
        END {
            if (!(217 in word)) exit 1
            rate = hex(word[217])
            if (rate == 1) { print "SSD"; exit 0 }
            if (rate < 1025 || rate == 65535) exit 1
            hybrid = (78 in word) ? int(hex(word[78]) / 512) % 2 : 0
            print (hybrid ? "SSHD" : "HDD")
        }'
}

# Disk type for the pickers and confirmation screens: bus plus media when
# known: "M.2 NVMe SSD", "SATA SSD", "SATA HDD", "SATA SSHD", "SATA", "ATA
# SSD/HDD/SSHD", "USB", "SD/MMC", "VirtIO", "SCSI" or "SAS"; prints nothing
# (status 1) when the bus is unknown. The bus comes from lsblk TRAN, else from
# the sysfs device path. Media only for (S)ATA: ATA IDENTIFY first (the only
# way to see an SSHD), then queue/rotational; USB bridges report rotation
# unreliably, so USB shows the bus only. USOS_SYSFS (default /sys) and
# USOS_SMARTCTL let host tests use stubs.
usos_disk_type() {
    usos_dt_device=$1
    usos_dt_sysfs=${USOS_SYSFS:-/sys}
    usos_dt_name=$(usos_disk_name "$usos_dt_device")
    usos_dt_tran=$(usos_disk_trim "$(usos_disk_lsblk_value "$usos_dt_device" TRAN)" | tr 'A-Z' 'a-z')
    if [ -z "$usos_dt_tran" ]; then
        usos_dt_path=$(readlink -f "$usos_dt_sysfs/class/block/$usos_dt_name" 2>/dev/null || true)
        case "$usos_dt_path" in
            */usb[0-9]*) usos_dt_tran=usb ;;
            */nvme*) usos_dt_tran=nvme ;;
            */ata[0-9]*) usos_dt_tran=sata ;;
            */virtio[0-9]*) usos_dt_tran=virtio ;;
            */mmc_host/*) usos_dt_tran=mmc ;;
            *) case "$usos_dt_name" in nvme*) usos_dt_tran=nvme ;; mmcblk*) usos_dt_tran=mmc ;; vd*) usos_dt_tran=virtio ;; esac ;;
        esac
    fi
    case "$usos_dt_tran" in
        nvme) printf 'M.2 NVMe SSD' ;;
        usb) printf 'USB' ;;
        sata|ata)
            usos_dt_prefix=SATA
            [ "$usos_dt_tran" = sata ] || usos_dt_prefix=ATA
            usos_dt_media=$(usos_disk_ata_media "$usos_dt_device" || true)
            if [ -z "$usos_dt_media" ]; then
                case "$(cat "$usos_dt_sysfs/class/block/$usos_dt_name/queue/rotational" 2>/dev/null || true)" in
                    0) usos_dt_media=SSD ;;
                    1) usos_dt_media=HDD ;;
                esac
            fi
            printf '%s%s' "$usos_dt_prefix" "${usos_dt_media:+ $usos_dt_media}" ;;
        mmc) printf 'SD/MMC' ;;
        virtio) printf 'VirtIO' ;;
        sas) printf 'SAS' ;;
        scsi|spi|fc|iscsi) printf 'SCSI' ;;
        *) return 1 ;;
    esac
}

# One picker/overview label: "<type> - <model>" ("<model>" when the type is
# unknown), so every picker shows the bus the same way.
usos_disk_type_model() {
    usos_dt_type=$(usos_disk_type "$1" || true)
    usos_dt_model=$(usos_disk_model "$1")
    if [ -n "$usos_dt_type" ]; then printf '%s - %s' "$usos_dt_type" "${usos_dt_model:-?}"; else printf '%s' "$usos_dt_model"; fi
}

# "Type: <type>" line for the confirmation overviews (after "Disk: <model>");
# nothing when the bus is unknown.
usos_disk_type_line() {
    usos_dt_type=$(usos_disk_type "$1" || true)
    [ -z "$usos_dt_type" ] || printf 'Type: %s\n' "$usos_dt_type"
}
