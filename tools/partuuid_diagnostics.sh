#!/bin/sh

USOS_PARTUUID_DIAG_REPORT=${USOS_PARTUUID_DIAG_REPORT:-/run/usos-partuuid-diagnostic.txt}
USOS_PARTUUID_DIAG_DATA_MOUNT=${USOS_PARTUUID_DIAG_DATA_MOUNT:-/mnt/diag-data}
USOS_PARTUUID_DIAG_ESP_MOUNT=${USOS_PARTUUID_DIAG_ESP_MOUNT:-/mnt/diag-esp}
USOS_PARTUUID_DIAG_DATA_FILE=${USOS_PARTUUID_DIAG_DATA_FILE:-USOS-PARTUUID-DIAGNOSTIC.txt}

usos_diag_make_node() {
    block_name=$1
    sysdev="/sys/class/block/$block_name/dev"
    [ -r "$sysdev" ] || return 1
    major_minor=$(cat "$sysdev" 2>/dev/null) || return 1
    major=${major_minor%:*}
    minor=${major_minor#*:}
    mkdir -p /dev/usos-block
    node="/dev/usos-block/${major}_${minor}"
    [ -e "$node" ] || mknod "$node" b "$major" "$minor" 2>/dev/null || return 1
    printf '%s' "$node"
}

usos_diag_find_partition_by_label() {
    wanted=$1
    lsblk -rno NAME,LABEL,TYPE 2>/dev/null | awk -v label="$wanted" '$2 == label && $3 == "part" { print $1; exit }'
}

usos_diag_config_value() {
    key=$1
    file=$2
    awk -F= -v wanted="$key" '$1 == wanted { value=$0; sub(/^[^=]*=/, "", value); gsub(/\r/, "", value); print value; exit }' "$file" 2>/dev/null
}

usos_diag_print_symlink_origin() {
    path=$1
    target=$(readlink "$path" 2>/dev/null || true)
    case "$target" in
        ../../usos-block/*) origin='USOS refresh_partuuid_links' ;;
        ../../sd*|../../nvme*|../../vd*|../../xvd*|../../mmcblk*) origin='mdev persistent-storage' ;;
        '') origin='not-a-symlink-or-unreadable' ;;
        *) origin='other' ;;
    esac
    printf '%s -> %s [origin=%s]\n' "$path" "${target:--}" "$origin"
}

usos_diag_probe_block() {
    block_name=$1
    sysdir="/sys/class/block/$block_name"
    generic=$(usos_diag_make_node "$block_name" 2>/dev/null || true)
    devnode="/dev/$block_name"
    [ -e "$devnode" ] || devnode=$generic

    printf -- '-- BLOCK %s --\n' "$block_name"
    printf 'sysfs=%s\n' "$sysdir"
    printf 'devnode=%s generic=%s\n' "${devnode:--}" "${generic:--}"
    printf 'sysfs.dev='; cat "$sysdir/dev" 2>/dev/null || printf '-\n'
    printf 'sysfs.partition='; cat "$sysdir/partition" 2>/dev/null || printf '-\n'
    printf 'sysfs.uevent:\n'; cat "$sysdir/uevent" 2>/dev/null || true

    if [ -n "$devnode" ] && [ -e "$devnode" ]; then
        printf 'lsblk.single:\n'
        lsblk -a -o NAME,MAJ:MIN,TYPE,TRAN,SIZE,FSTYPE,LABEL,UUID,PARTUUID "$devnode" 2>&1 || true
        printf 'lsblk.PARTUUID='; lsblk -dnro PARTUUID "$devnode" 2>&1 || true
        printf 'blkid.plain:\n'
        blkid "$devnode" 2>&1 || true
        printf 'blkid.usos_command:\n'
        if probe=$(blkid -p -s PARTUUID -o value "$devnode" 2>&1); then
            printf 'rc=0 value=%s\n' "$probe"
        else
            rc=$?
            printf 'rc=%s output=%s\n' "$rc" "$probe"
        fi
    fi
}

usos_diag_mount_esp_for_config() {
    esp_name=$1
    [ -n "$esp_name" ] || return 1
    esp_node=$(usos_diag_make_node "$esp_name" 2>/dev/null || true)
    [ -n "$esp_node" ] || return 1
    mkdir -p "$USOS_PARTUUID_DIAG_ESP_MOUNT"
    umount "$USOS_PARTUUID_DIAG_ESP_MOUNT" 2>/dev/null || true
    mount -t vfat -o ro,noatime "$esp_node" "$USOS_PARTUUID_DIAG_ESP_MOUNT" 2>/dev/null || return 1
    return 0
}

usos_diag_persist_to_data() {
    report=$1
    data_name=$(usos_diag_find_partition_by_label USOS_DATA 2>/dev/null || true)
    [ -n "$data_name" ] || {
        printf 'persist_result=FAIL reason=USOS_DATA partition not found by label\n' >> "$report"
        return 1
    }
    data_node=$(usos_diag_make_node "$data_name" 2>/dev/null || true)
    [ -n "$data_node" ] || {
        printf 'persist_result=FAIL reason=cannot create raw node for %s\n' "$data_name" >> "$report"
        return 1
    }

    kernel_release=$(uname -r)
    ntfs3_module="/usr/lib/modules/$kernel_release/kernel/fs/ntfs3/ntfs3.ko"
    modprobe nls_utf8 2>/dev/null || true
    if [ -f "$ntfs3_module" ] && [ ! -d /sys/module/ntfs3 ]; then
        insmod "$ntfs3_module" 2>/dev/null || true
    fi

    mkdir -p "$USOS_PARTUUID_DIAG_DATA_MOUNT"
    umount "$USOS_PARTUUID_DIAG_DATA_MOUNT" 2>/dev/null || true
    mount_driver=''
    if mount -t ntfs3 -o rw,noatime "$data_node" "$USOS_PARTUUID_DIAG_DATA_MOUNT" 2>/dev/null; then
        mount_driver='ntfs3'
    elif command -v ntfs-3g >/dev/null 2>&1 && ntfs-3g -o rw "$data_node" "$USOS_PARTUUID_DIAG_DATA_MOUNT" >/dev/null 2>&1; then
        mount_driver='ntfs-3g'
    else
        printf 'persist_result=FAIL reason=cannot mount USOS_DATA node=%s\n' "$data_node" >> "$report"
        return 1
    fi

    destination="$USOS_PARTUUID_DIAG_DATA_MOUNT/$USOS_PARTUUID_DIAG_DATA_FILE"
    printf 'persist_target=%s block=%s node=%s driver=%s\n' "$destination" "$data_name" "$data_node" "$mount_driver" >> "$report"
    if cp "$report" "$destination" 2>/dev/null; then
        printf 'persist_result=PASS\n' >> "$destination"
        sync
        umount "$USOS_PARTUUID_DIAG_DATA_MOUNT" 2>/dev/null || true
        return 0
    fi
    printf 'persist_result=FAIL reason=copy-to-DATA-failed\n' >> "$report"
    sync
    umount "$USOS_PARTUUID_DIAG_DATA_MOUNT" 2>/dev/null || true
    return 1
}

usos_partuuid_diagnostics() {
    wanted_uuid=$1
    waited_seconds=$2
    attempts=$3
    report=$USOS_PARTUUID_DIAG_REPORT
    wanted_path=$(usos_partuuid_path "$wanted_uuid")

    refresh_partuuid_links || true

    {
        printf 'USOS PARTUUID DIAGNOSTICS\n'
        printf 'wanted_esp_partuuid_cmdline=%s\n' "$wanted_uuid"
        printf 'wanted_path=%s\n' "$wanted_path"
        printf 'actual_wait_seconds=%s attempts=%s nominal_sleep=0.1s\n' "$waited_seconds" "$attempts"
        printf 'kernel=%s\n' "$(uname -r 2>/dev/null || printf '?')"
        printf 'uptime=%s\n' "$(cat /proc/uptime 2>/dev/null || printf '?')"

        printf '\n== A. TOOL IDENTITY ==\n'
        printf 'command.blkid=%s\n' "$(command -v blkid 2>/dev/null || printf MISSING)"
        printf 'readlink.blkid=%s\n' "$(readlink -f "$(command -v blkid 2>/dev/null)" 2>/dev/null || printf '?')"
        printf 'blkid.help:\n'
        blkid --help 2>&1 | head -n 30 || true
        printf 'command.lsblk=%s\n' "$(command -v lsblk 2>/dev/null || printf MISSING)"
        printf 'mdev.by-partuuid.rule:\n'
        grep -n 'persistent-storage' /etc/mdev.conf 2>/dev/null || true
        printf 'mdev.helper.PARTUUID.logic:\n'
        grep -n -E 'PARTUUID|by-partuuid|blkid_out' /usr/lib/mdev/persistent-storage 2>/dev/null || true
        printf 'usos.link.builder=refresh_partuuid_links -> sysfs uevent PARTUUID -> /dev/usos-block/MAJ_MIN\n'

        printf '\n== 1. /dev/disk/by-partuuid EXISTS ==\n'
        if [ -d /dev/disk/by-partuuid ]; then printf 'exists=yes\n'; else printf 'exists=no\n'; fi

        printf '\n== 2. FULL /dev/disk/by-partuuid + ORIGIN ==\n'
        ls -la /dev/disk/by-partuuid 2>&1 || true
        for link in /dev/disk/by-partuuid/*; do
            [ -e "$link" ] || [ -L "$link" ] || continue
            usos_diag_print_symlink_origin "$link"
        done

        printf '\n== 3. FULL /dev/disk/by-uuid ==\n'
        ls -la /dev/disk/by-uuid 2>&1 || true
        printf '\n== 3. FULL /dev/disk/by-id ==\n'
        ls -la /dev/disk/by-id 2>&1 || true
        printf '\n== 3b. FULL /dev/disk/by-label ==\n'
        ls -la /dev/disk/by-label 2>&1 || true

        printf '\n== 4. /dev/sd* AND /dev/nvme* ==\n'
        ls -l /dev/sd* /dev/nvme* 2>&1 || true

        printf '\n== 5. lsblk ==\n'
        lsblk -a -o NAME,MAJ:MIN,TYPE,TRAN,SIZE,FSTYPE,LABEL,UUID,PARTUUID 2>&1 || true
        printf '\n== 5. /sys/class/block ==\n'
        ls -la /sys/class/block 2>&1 || true
        printf '\n== 5. EVERY PARTITION RAW PROBE ==\n'
        for marker in /sys/class/block/*/partition; do
            [ -f "$marker" ] || continue
            block_dir=${marker%/partition}
            block_name=${block_dir##*/}
            usos_diag_probe_block "$block_name"
        done

        printf '\n== 5b. KINGSTON LABEL RESOLUTION ==\n'
        esp_name=$(usos_diag_find_partition_by_label USOS_ESP 2>/dev/null || true)
        data_name=$(usos_diag_find_partition_by_label USOS_DATA 2>/dev/null || true)
        work_name=$(usos_diag_find_partition_by_label USOS_WORK 2>/dev/null || true)
        printf 'USOS_ESP block=%s\n' "${esp_name:--}"
        printf 'USOS_DATA block=%s\n' "${data_name:--}"
        printf 'USOS_WORK block=%s\n' "${work_name:--}"
        for pair in "ESP:$esp_name" "DATA:$data_name" "WORK:$work_name"; do
            kind=${pair%%:*}
            name=${pair#*:}
            [ -n "$name" ] || continue
            node=$(usos_diag_make_node "$name" 2>/dev/null || true)
            printf '%s block=%s node=%s lsblk_PARTUUID=' "$kind" "$name" "${node:--}"
            lsblk -dnro PARTUUID "$node" 2>&1 || true
            printf '%s blkid_plain=' "$kind"
            blkid "$node" 2>&1 || true
            if value=$(blkid -p -s PARTUUID -o value "$node" 2>&1); then
                printf '%s blkid_usos_rc=0 value=%s\n' "$kind" "$value"
            else
                rc=$?
                printf '%s blkid_usos_rc=%s output=%s\n' "$kind" "$rc" "$value"
            fi
        done

        printf '\n== 5c. ESP CONFIG COMPARISON ==\n'
        if usos_diag_mount_esp_for_config "$esp_name"; then
            config="$USOS_PARTUUID_DIAG_ESP_MOUNT/EFI/USOS/usos-device.ini"
            printf 'config_path=%s exists=' "$config"
            if [ -f "$config" ]; then
                printf 'yes\n'
                cat "$config"
                config_esp=$(usos_diag_config_value esp_partuuid "$config")
                config_data=$(usos_diag_config_value data_partuuid "$config")
                config_work=$(usos_diag_config_value work_partuuid "$config")
                printf 'config_esp=%s cmdline_esp=%s equal=%s\n' "$config_esp" "$wanted_uuid" "$(usos_guid_equal "$config_esp" "$wanted_uuid" && printf yes || printf no)"
                if [ -n "$esp_name" ]; then
                    esp_node=$(usos_diag_make_node "$esp_name" 2>/dev/null || true)
                    esp_lsblk=$(lsblk -dnro PARTUUID "$esp_node" 2>/dev/null || true)
                    printf 'config_esp=%s lsblk_esp=%s equal=%s\n' "$config_esp" "$esp_lsblk" "$(usos_guid_equal "$config_esp" "$esp_lsblk" && printf yes || printf no)"
                fi
                printf 'config_data=%s\nconfig_work=%s\n' "$config_data" "$config_work"
            else
                printf 'no\n'
            fi
            umount "$USOS_PARTUUID_DIAG_ESP_MOUNT" 2>/dev/null || true
        else
            printf 'raw_esp_mount=FAIL\n'
        fi

        printf '\n== 6. DMESG USB/STORAGE LAST 80 ==\n'
        dmesg 2>&1 | grep -Ei 'usb|xhci|ehci|ohci|uas|scsi|storage|sd[a-z]|mass' | tail -n 80 || true

        printf '\n== 7. LSMOD ==\n'
        lsmod 2>&1 || true

        printf '\n== 8. WAIT RESULT ==\n'
        printf 'actual_wait_seconds=%s attempts=%s target_present=' "$waited_seconds" "$attempts"
        if [ -e "$wanted_path" ]; then printf 'yes\n'; else printf 'no\n'; fi
    } > "$report"

    usos_diag_persist_to_data "$report" || true
    printf '%s' "$report"
}
