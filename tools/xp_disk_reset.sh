#!/bin/sh
# Explicit whole-disk reset for a fresh XP installation, never secure erase.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/target_disk_identity.sh"
TARGET_DEVICE=${TARGET_DEVICE:?}
USOS_DISK_DEVICE=${USOS_DISK_DEVICE:?}
XP_RESET_SNAPSHOT=${XP_RESET_SNAPSHOT:?}
fail() { printf '[XP_RESET] STOP: %s\n' "$1" >&2; exit 1; }
value() { awk -F= -v key="$1" '$1==key {sub(/^[^=]*=/, ""); print; found=1; exit} END {if(!found) exit 1}' "$XP_RESET_SNAPSHOT/identity"; }
identity() {
    printf 'model=%s\nserial=%s\nwwn=%s\nsize=%s\nsector=%s\n' \
        "$(usos_disk_model "$1")" "$(usos_disk_serial "$1")" "$(usos_disk_wwn "$1")" \
        "$(usos_disk_size "$1")" "$(usos_disk_logical_sector "$1")"
}
check_target() {
    [ "$(id -u)" = 0 ] || fail 'root required'
    [ -b "$TARGET_DEVICE" ] || fail 'target is not a block device'
    [ "$(readlink -f "$TARGET_DEVICE")" != "$(readlink -f "$USOS_DISK_DEVICE")" ] || fail 'USOS disk cannot be formatted'
    [ "$(lsblk -dnro TYPE "$TARGET_DEVICE")" = disk ] || fail 'whole disk required'
    [ "$(lsblk -dnro RO "$TARGET_DEVICE")" = 0 ] || fail 'read-only target'
    [ "$(lsblk -dnro RM "$TARGET_DEVICE")" = 0 ] || fail 'removable target refused'
    [ "$(usos_disk_logical_sector "$TARGET_DEVICE")" = 512 ] || fail '512-byte sectors required'
    [ -n "$(usos_disk_model "$TARGET_DEVICE")" ] || fail 'missing model'
    [ -n "$(usos_disk_serial "$TARGET_DEVICE")" ] || fail 'missing serial'
    reset_size=$(usos_disk_size "$TARGET_DEVICE")
    case "$reset_size" in ''|*[!0-9]*) fail 'invalid size' ;; esac
    [ "$reset_size" -ge 11811160064 ] && [ "$reset_size" -lt 2199023255040 ] || fail 'XP reset requires 11 GiB to less than 2 TiB'
    [ $((reset_size % 512)) = 0 ] || fail 'unaligned disk size'
    lsblk -nrpo NAME "$TARGET_DEVICE" > "$reset_work/nodes"
    [ -s "$reset_work/nodes" ] || fail 'cannot inspect descendants'
    while IFS= read -r reset_node; do
        if findmnt -rn -S "$reset_node" >/dev/null 2>&1; then fail 'target or partition is mounted'; fi
        if awk -v node="$reset_node" 'NR>1 && $1==node {found=1} END {exit !found}' /proc/swaps; then fail 'target has active swap'; fi
        for reset_holder in "/sys/class/block/${reset_node##*/}/holders/"*; do
            [ ! -e "$reset_holder" ] || fail 'target has active block-device holders'
        done
    done < "$reset_work/nodes"
}
capture() {
    dd if="$TARGET_DEVICE" of="$1/first" bs=512 count=2048 2>/dev/null
    dd if="$TARGET_DEVICE" of="$1/last" bs=512 skip=$((reset_size / 512 - 2048)) count=2048 2>/dev/null
    [ "$(wc -c < "$1/first" | tr -d '[:space:]')" = 1048576 ] || fail 'short metadata read'
    [ "$(wc -c < "$1/last" | tr -d '[:space:]')" = 1048576 ] || fail 'short backup metadata read'
}
reset_work=$(mktemp -d)
trap 'rm -f "$reset_work/identity" "$reset_work/first" "$reset_work/last" "$reset_work/zero" "$reset_work/mbr" "$reset_work/nodes"; rmdir "$reset_work"' EXIT HUP INT TERM
check_target
case "${1:-}" in
    snapshot)
        [ ! -e "$XP_RESET_SNAPSHOT" ] || fail 'reset snapshot already exists'
        umask 077
        mkdir "$XP_RESET_SNAPSHOT"
        identity "$TARGET_DEVICE" > "$XP_RESET_SNAPSHOT/identity"
        capture "$XP_RESET_SNAPSHOT"
        printf '[XP_RESET] SNAPSHOT PASS device=%s\n' "$TARGET_DEVICE"
        ;;
    apply)
        [ -r "$XP_RESET_SNAPSHOT/identity" ] || fail 'reset snapshot missing'
        identity "$TARGET_DEVICE" > "$reset_work/identity"
        cmp -s "$reset_work/identity" "$XP_RESET_SNAPSHOT/identity" || fail 'target identity changed'
        reset_matches=0
        for reset_candidate in $(lsblk -dnpo NAME,TYPE | awk '$2=="disk" {print $1}'); do
            identity "$reset_candidate" > "$reset_work/identity"
            if cmp -s "$reset_work/identity" "$XP_RESET_SNAPSHOT/identity"; then reset_matches=$((reset_matches + 1)); fi
        done
        [ "$reset_matches" = 1 ] || fail 'ambiguous target identity'
        capture "$reset_work"
        cmp -s "$reset_work/first" "$XP_RESET_SNAPSHOT/first" || fail 'disk metadata changed after selection'
        cmp -s "$reset_work/last" "$XP_RESET_SNAPSHOT/last" || fail 'backup metadata changed after selection'
        [ "${XP_RESET_CONFIRMATION:-}" = "FORMATUJ $(value serial)" ] || fail 'whole-disk format confirmation mismatch'
        # Verify identity and eligibility again immediately before the first write.
        check_target
        identity "$TARGET_DEVICE" > "$reset_work/identity"
        cmp -s "$reset_work/identity" "$XP_RESET_SNAPSHOT/identity" || fail 'target changed before reset'
        dd if=/dev/zero of="$reset_work/zero" bs=512 count=2048 2>/dev/null
        dd if=/dev/zero of="$reset_work/mbr" bs=512 count=1 2>/dev/null
        reset_id=$(printf '%s:%s' "$(value serial)" "$reset_size" | cksum | awk '{print $1}')
        [ "$reset_id" -ne 0 ] || reset_id=1
        for reset_shift in 0 8 16 24; do
            printf "\\$(printf '%03o' "$(((reset_id >> reset_shift) & 255))")"
        done | dd of="$reset_work/mbr" bs=1 seek=440 count=4 conv=notrunc 2>/dev/null
        printf '\125\252' | dd of="$reset_work/mbr" bs=1 seek=510 count=2 conv=notrunc 2>/dev/null
        # Remove both GPT copies as well as MBR/superfloppy metadata. New filesystems
        # are created by the normal XP preparer; this is not a full-sector erase.
        dd if="$reset_work/zero" of="$TARGET_DEVICE" bs=512 seek=$((reset_size / 512 - 2048)) count=2048 conv=notrunc 2>/dev/null
        dd if="$reset_work/zero" of="$TARGET_DEVICE" bs=512 count=2048 conv=notrunc 2>/dev/null
        dd if="$reset_work/mbr" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc 2>/dev/null
        sync
        capture "$reset_work"
        dd if="$reset_work/mbr" of="$reset_work/zero" bs=512 count=1 conv=notrunc 2>/dev/null
        cmp -s "$reset_work/first" "$reset_work/zero" || fail 'new MBR readback mismatch'
        dd if=/dev/zero of="$reset_work/zero" bs=512 count=2048 2>/dev/null
        cmp -s "$reset_work/last" "$reset_work/zero" || fail 'backup GPT removal readback mismatch'
        blockdev --rereadpt "$TARGET_DEVICE"
        mdev -s
        printf '[XP_RESET] RESET PASS device=%s all_old_partitions=removed layout=empty-MBR secure_erase=no\n' "$TARGET_DEVICE"
        ;;
    *) fail 'expected snapshot or apply' ;;
esac
