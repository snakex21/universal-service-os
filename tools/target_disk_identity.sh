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

# Bus of a disk as a token for the picker chips (src/platform/linux/
# fb_disk_badge.zig): nvme, sata, ide, scsi, sas, usb, mmc / emmc / sd or
# virtio; status 1 (nothing printed) when unknown. lsblk TRAN first, refined by
# the SCSI host driver (/sys/class/scsi_host/hostN/proc_name): libata on a
# PATA driver or ata_piix / ata_generic (legacy IDE mode) is "ide", SAS HBAs
# (mpt*sas, megaraid_sas is left as SCSI: a RAID volume, not a disk) "sas",
# virtio_scsi "virtio", uas / usb-storage "usb", any other SCSI host "scsi".
# Without TRAN the sysfs device path decides. AHCI in RAID mode stays "sata"
# (the ahci driver; the disks are still SATA). USOS_SYSFS (default /sys) lets
# host tests use a stub tree.
usos_disk_host_driver() {
    usos_dh_path=$(readlink -f "${USOS_SYSFS:-/sys}/class/block/$(usos_disk_name "$1")" 2>/dev/null || true)
    usos_dh_host=$(printf '%s\n' "$usos_dh_path" | tr '/' '\n' | awk '/^host[0-9]+$/ { h = $0 } END { print h }')
    [ -n "$usos_dh_host" ] || return 1
    usos_dh_driver=$(cat "${USOS_SYSFS:-/sys}/class/scsi_host/$usos_dh_host/proc_name" 2>/dev/null || true)
    [ -n "$usos_dh_driver" ] || return 1
    printf '%s' "$usos_dh_driver" | tr 'A-Z' 'a-z'
}

usos_disk_bus() {
    usos_db_sysfs=${USOS_SYSFS:-/sys}
    usos_db_name=$(usos_disk_name "$1")
    usos_db_tran=$(usos_disk_trim "$(usos_disk_lsblk_value "$1" TRAN)" | tr 'A-Z' 'a-z')
    usos_db_driver=$(usos_disk_host_driver "$1" || true)
    usos_db_path=$(readlink -f "$usos_db_sysfs/class/block/$usos_db_name" 2>/dev/null || true)
    if [ -z "$usos_db_tran" ]; then
        case "$usos_db_path" in
            */usb[0-9]*) usos_db_tran=usb ;;
            */nvme*) usos_db_tran=nvme ;;
            */ata[0-9]*) usos_db_tran=sata ;;
            */mmc_host/*) usos_db_tran=mmc ;;
            */virtio[0-9]*) usos_db_tran=virtio ;;
            */host[0-9]*) usos_db_tran=scsi ;;
            *) case "$usos_db_name" in nvme*) usos_db_tran=nvme ;; mmcblk*) usos_db_tran=mmc ;; vd*) usos_db_tran=virtio ;; esac ;;
        esac
    fi
    case "$usos_db_driver" in
        uas|usb-storage) usos_db_tran=usb ;;
        virtio_scsi) usos_db_tran=virtio ;;
        ata_piix|ata_generic|pata_*|pata) usos_db_tran=ide ;;
        mpt*sas|isci|pm80xx|pm8001|hisi_sas*|smartpqi|hpsa|mvsas|aic94xx) usos_db_tran=sas ;;
    esac
    case "$usos_db_tran" in
        nvme|usb|virtio|sas|ide) printf '%s' "$usos_db_tran" ;;
        sata) printf 'sata' ;;
        # lsblk TRAN "ata": libata on a parallel ATA link.
        ata) printf 'ide' ;;
        mmc)
            case "$(cat "$usos_db_sysfs/class/block/$usos_db_name/device/type" 2>/dev/null || true)" in
                MMC) printf 'emmc' ;;
                SD) printf 'sd' ;;
                *) printf 'mmc' ;;
            esac ;;
        scsi|spi|fc|iscsi|srp) printf 'scsi' ;;
        *) return 1 ;;
    esac
}

# Media token: ssd, hdd or sshd; status 1 when unknown. NVMe is always ssd;
# (S)ATA and IDE from ATA IDENTIFY (the only way to see an SSHD), then
# queue/rotational; SAS / SCSI from queue/rotational (the kernel reads the
# SCSI rotation rate VPD page). USB bridges, SD/MMC and VirtIO report rotation
# unreliably: nothing. $2 = the bus token when the caller has it.
usos_disk_media() {
    usos_dm_bus=${2:-$(usos_disk_bus "$1" || true)}
    usos_dm_rot=$(cat "${USOS_SYSFS:-/sys}/class/block/$(usos_disk_name "$1")/queue/rotational" 2>/dev/null || true)
    case "$usos_dm_bus" in
        nvme) printf 'ssd' ;;
        sata|ide)
            usos_dm_media=$(usos_disk_ata_media "$1" || true)
            if [ -n "$usos_dm_media" ]; then printf '%s' "$usos_dm_media" | tr 'A-Z' 'a-z'; return 0; fi
            case "$usos_dm_rot" in 0) printf 'ssd' ;; 1) printf 'hdd' ;; *) return 1 ;; esac ;;
        sas|scsi)
            case "$usos_dm_rot" in 0) printf 'ssd' ;; 1) printf 'hdd' ;; *) return 1 ;; esac ;;
        *) return 1 ;;
    esac
}

# Chip lines for a picker item (tools/xp_menu_ui.sh): "badge=<bus>" and
# "badge=<media>", each only when known.
usos_disk_badges() {
    usos_dg_bus=$(usos_disk_bus "$1" || true)
    [ -n "$usos_dg_bus" ] || return 0
    printf 'badge=%s\n' "$usos_dg_bus"
    usos_dg_media=$(usos_disk_media "$1" "$usos_dg_bus" || true)
    [ -z "$usos_dg_media" ] || printf 'badge=%s\n' "$usos_dg_media"
}

# Readable type for the confirmation overviews and the Hardware list:
# "NVMe SSD", "SATA HDD", "SATA SSHD", "IDE HDD", "SAS HDD", "SCSI", "USB",
# "eMMC", "SD", "SD/MMC", "VirtIO"; status 1 when the bus is unknown.
usos_disk_type() {
    usos_dt_bus=$(usos_disk_bus "$1") || return 1
    case "$usos_dt_bus" in
        nvme) usos_dt_label=NVMe ;; sata) usos_dt_label=SATA ;; ide) usos_dt_label=IDE ;;
        scsi) usos_dt_label=SCSI ;; sas) usos_dt_label=SAS ;; usb) usos_dt_label=USB ;;
        emmc) usos_dt_label=eMMC ;; sd) usos_dt_label=SD ;; mmc) usos_dt_label=SD/MMC ;;
        virtio) usos_dt_label=VirtIO ;; *) return 1 ;;
    esac
    usos_dt_media=$(usos_disk_media "$1" "$usos_dt_bus" || true)
    printf '%s%s' "$usos_dt_label" "${usos_dt_media:+ $(printf '%s' "$usos_dt_media" | tr 'a-z' 'A-Z')}"
}

# Picker name: the model (the kernel name such as "sdb" when the disk reports
# none); the bus and media are chips (usos_disk_badges), not part of the name.
usos_disk_picker_name() {
    usos_dp_model=$(usos_disk_model "$1")
    printf '%s' "${usos_dp_model:-$(usos_disk_name "$1")}"
}

# "Type: <type>" line for the confirmation overviews (after "Disk: <model>");
# nothing when the bus is unknown.
usos_disk_type_line() {
    usos_dt_type=$(usos_disk_type "$1" || true)
    [ -z "$usos_dt_type" ] || printf 'Type: %s\n' "$usos_dt_type"
}
