#!/bin/sh

usos_lower_ascii() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

usos_partuuid_key() {
    usos_lower_ascii "$1"
}

usos_partuuid_path() {
    printf '/dev/disk/by-partuuid/%s' "$(usos_partuuid_key "$1")"
}

usos_guid_equal() {
    [ "$(usos_lower_ascii "$1")" = "$(usos_lower_ascii "$2")" ]
}

usos_partition_partuuid_from_sysfs() {
    block_dir=$1
    uevent="$block_dir/uevent"
    [ -r "$uevent" ] || return 1
    awk -F= '
        $1 == "PARTUUID" {
            value=$0
            sub(/^[^=]*=/, "", value)
            print value
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' "$uevent"
}

refresh_partuuid_links() {
    sys_block_root=${USOS_SYS_BLOCK_ROOT:-/sys/class/block}
    dev_root=${USOS_DEV_ROOT:-/dev}

    mkdir -p "$dev_root/usos-block" "$dev_root/disk/by-partuuid"
    for marker in "$sys_block_root"/*/partition; do
        [ -f "$marker" ] || continue
        block_dir=${marker%/partition}
        partuuid=$(usos_partition_partuuid_from_sysfs "$block_dir" 2>/dev/null || true)
        [ -n "$partuuid" ] || continue

        major_minor=$(cat "$block_dir/dev" 2>/dev/null || true)
        case "$major_minor" in
            *:*) ;;
            *) continue ;;
        esac
        major=${major_minor%:*}
        minor=${major_minor#*:}
        generic_name="${major}_${minor}"
        generic_path="$dev_root/usos-block/$generic_name"
        [ -e "$generic_path" ] || mknod "$generic_path" b "$major" "$minor" 2>/dev/null || continue

        partuuid_key=$(usos_partuuid_key "$partuuid")
        ln -snf "../../usos-block/$generic_name" "$dev_root/disk/by-partuuid/$partuuid_key"
    done
}
