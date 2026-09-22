#!/bin/sh
# Best-effort inspection through read-only loop devices. Failure means unknown.
set -eu
TARGET_DEVICE=${TARGET_DEVICE:?}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/target_disk_identity.sh"
. "$SCRIPT_DIR/xp_detect_system.sh"
overview_work=$(mktemp -d)
overview_loop=''; overview_mounted=no
cleanup() {
    if [ "$overview_mounted" = yes ]; then umount "$overview_work/mount" || return; fi
    [ -z "$overview_loop" ] || losetup -d "$overview_loop" || true
    rm -f "$overview_work/nodes" "$overview_work/extents" "$overview_work/parts"
    rmdir "$overview_work/mount" "$overview_work" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir "$overview_work/mount"
lsblk -nrpo NAME,TYPE "$TARGET_DEVICE" > "$overview_work/nodes"
: > "$overview_work/extents"; : > "$overview_work/parts"
overview_busy=no; overview_count=0; overview_known=0; overview_used=0; overview_free=0
while read -r overview_node overview_type; do
    [ -b "$overview_node" ] || continue
    overview_node_busy=no
    if findmnt -rn -S "$overview_node" >/dev/null 2>&1 || awk -v node="$overview_node" 'NR>1 && $1==node {f=1} END {exit !f}' /proc/swaps; then overview_node_busy=yes; fi
    for overview_holder in "/sys/class/block/${overview_node##*/}/holders/"*; do
        [ ! -e "$overview_holder" ] || overview_node_busy=yes
    done
    [ "$overview_node_busy" = no ] || overview_busy=yes
    [ "$overview_type" = part ] || continue
    overview_count=$((overview_count+1))
    overview_start=$(cat "/sys/class/block/${overview_node##*/}/start")
    overview_sectors=$(cat "/sys/class/block/${overview_node##*/}/size")
    printf '%s %s\n' "$overview_start" "$((overview_start+overview_sectors))" >> "$overview_work/extents"
    overview_fs=$(lsblk -dnro FSTYPE "$overview_node" | head -n1)
    overview_label=$(lsblk -dno LABEL "$overview_node" | head -n1 | tr -cd '[:alnum:] ._- ' | cut -c1-18)
    overview_system='System unknown'; overview_space='Used/free: unknown'
    overview_mount_type=''
    case "$overview_fs" in ntfs) overview_mount_type=ntfs3; overview_options=ro ;; vfat) overview_mount_type=vfat; overview_options=ro ;; ext2|ext3|ext4) overview_mount_type=ext4; overview_options=ro,noload ;; esac
    if [ "$overview_node_busy" = yes ]; then
        overview_system='IN USE - inspection skipped'
    elif [ -n "$overview_mount_type" ]; then
        modprobe loop 2>/dev/null || true
        modprobe "$overview_mount_type" 2>/dev/null || true
        overview_loop=$(losetup -f 2>/dev/null || true)
        if [ -n "$overview_loop" ] && losetup -r "$overview_loop" "$overview_node" 2>/dev/null; then
            if mount -t "$overview_mount_type" -o "$overview_options" "$overview_loop" "$overview_work/mount" 2>/dev/null; then
                overview_mounted=yes
                overview_values=$(df -kP "$overview_work/mount" | awk 'NR==2 {print $3 " " $4}')
                set -- $overview_values
                if [ "$#" = 2 ]; then
                    overview_used=$((overview_used+$1)); overview_free=$((overview_free+$2)); overview_known=$((overview_known+1))
                    overview_space="Used: $(($1/1024)) MiB, free: $(($2/1024)) MiB"
                fi
                overview_system=$(usos_xp_detect_system "$overview_work/mount")
                umount "$overview_work/mount" || exit 1
                overview_mounted=no
            fi
            losetup -d "$overview_loop" || exit 1
        fi
        overview_loop=''
    fi
    if [ "$overview_count" -le 4 ]; then
        printf '%s: %s %s (%s MiB)\n  %s; %s\n' "${overview_node##*/}" "${overview_fs:-unknown}" "$overview_label" "$((overview_sectors/2048))" "$overview_space" "$overview_system" >> "$overview_work/parts"
    fi
done < "$overview_work/nodes"
overview_allocated=$(sort -n "$overview_work/extents" | awk 'BEGIN {e=0;s=0} {if($1>=e){s+=$2-$1;e=$2}else if($2>e){s+=$2-e;e=$2}} END {printf "%.0f",s}')
overview_size=$(usos_disk_size "$TARGET_DEVICE")
printf 'Disk: %s\nS/N: %s\nSize: %s GiB\n' "$(usos_disk_model "$TARGET_DEVICE")" "$(usos_disk_serial "$TARGET_DEVICE")" "$((overview_size/1073741824))"
if [ "$overview_busy" = yes ]; then printf 'Status: IN USE - formatting is blocked.\n'; else printf 'Status: not currently in use.\n'; fi
printf 'Partitions: %s; unallocated: approx. %s MiB\n' "$overview_count" "$(((overview_size/512-overview_allocated)/2048))"
if [ "$overview_known" -gt 0 ]; then
    printf 'Readable file systems: %s; used %s MiB, free %s MiB\n' "$overview_known" "$((overview_used/1024))" "$((overview_free/1024))"
else
    printf 'Used/free space in file systems: unknown.\n'
fi
cat "$overview_work/parts"
[ "$overview_count" -le 4 ] || printf '(Other partitions: %s)\n' "$((overview_count-4))"
printf 'File detection does not verify whether a system works.\n'
