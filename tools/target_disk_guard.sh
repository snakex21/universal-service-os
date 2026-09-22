#!/bin/sh
set -eu

MODE=${1:-snapshot}
TARGET_SNAPSHOT=${TARGET_SNAPSHOT:?TARGET_SNAPSHOT is required}
USOS_DISK_DEVICE=${USOS_DISK_DEVICE:?USOS_DISK_DEVICE is required}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[ -r "$SCRIPT_DIR/target_disk_identity.sh" ] || { printf '[TARGET_DISK_GUARD] STOP: target_disk_identity.sh is missing\n' >&2; exit 1; }
. "$SCRIPT_DIR/target_disk_identity.sh"

XPSETUP_SECTORS=4194304
ALIGN_SECTORS=2048
MBR_ENTRY_OFFSET=446
MBR_ENTRY_BYTES=16

fail() {
    printf '[TARGET_DISK_GUARD] STOP: %s\n' "$1" >&2
    exit 1
}

trim() {
    printf '%s' "$1" | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); printf "%s", $0 }'
}

lsblk_value() {
    device=$1
    column=$2
    lsblk -b -dnro "$column" "$device" 2>/dev/null | head -n 1
}

canonical_device() {
    readlink -f "$1" 2>/dev/null || return 1
}

check_tools() {
    [ "$(id -u)" -eq 0 ] || fail 'root privileges are required'
    for tool in lsblk findmnt readlink dd od awk tr sort cksum mktemp cmp; do
        command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
    done
}

check_not_mounted_or_swap() {
    device=$1
    lsblk -nrpo NAME "$device" 2>/dev/null | while IFS= read -r node; do
        [ -n "$node" ] || continue
        if findmnt -rn -S "$node" >/dev/null 2>&1; then
            fail "target or descendant is mounted: $node"
        fi
        if [ -r /proc/swaps ] && awk -v node="$node" 'NR > 1 && $1 == node { found=1 } END { exit(found ? 0 : 1) }' /proc/swaps; then
            fail "target or descendant is active swap: $node"
        fi
    done
}

read_u8() {
    od -An -tu1 -j "$2" -N 1 "$1" 2>/dev/null | awk '{print $1; exit}'
}

read_u16_le() {
    set -- $(od -An -tu1 -j "$2" -N 2 "$1" 2>/dev/null)
    [ "$#" -eq 2 ] || return 1
    printf '%s' $(( $1 + $2 * 256 ))
}

read_u32_le() {
    set -- $(od -An -tu1 -j "$2" -N 4 "$1" 2>/dev/null)
    [ "$#" -eq 4 ] || return 1
    printf '%s' $(( $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 ))
}

is_reusable_xpsetup() {
    device=$1
    start=$2
    sectors=$3
    ptype=$4
    [ "$ptype" -eq 12 ] || return 1
    [ "$sectors" -eq "$XPSETUP_SECTORS" ] || return 1
    [ $((start % ALIGN_SECTORS)) -eq 0 ] || return 1

    offset=$((start * 512))
    sig=$(od -An -tx1 -j $((offset + 510)) -N2 "$device" 2>/dev/null | tr -d ' \n\r')
    [ "$sig" = 55aa ] || return 1
    bps=$(read_u16_le "$device" $((offset + 11))) || return 1
    spc=$(read_u8 "$device" $((offset + 13))) || return 1
    reserved=$(read_u16_le "$device" $((offset + 14))) || return 1
    fats=$(read_u8 "$device" $((offset + 16))) || return 1
    hidden=$(read_u32_le "$device" $((offset + 28))) || return 1
    total=$(read_u32_le "$device" $((offset + 32))) || return 1
    label_hex=$(od -An -tx1 -j $((offset + 71)) -N11 "$device" 2>/dev/null | tr -d ' \n\r')
    [ "$bps" -eq 512 ] || return 1
    [ "$spc" -eq 8 ] || return 1
    [ "$reserved" -eq 32 ] || return 1
    [ "$fats" -eq 2 ] || return 1
    [ "$hidden" -eq "$start" ] || return 1
    [ "$total" -gt 0 ] && [ "$total" -le "$sectors" ] || return 1
    [ "$label_hex" = 5850534554555020202020 ] || return 1
    return 0
}

entry_hex() {
    offset=$((MBR_ENTRY_OFFSET + ($2 - 1) * MBR_ENTRY_BYTES))
    od -An -tx1 -j "$offset" -N "$MBR_ENTRY_BYTES" "$1" 2>/dev/null | tr -d ' \n\r'
}

mbr_cksum() {
    dd if="$1" bs=512 count=1 2>/dev/null | cksum | awk '{printf "%s:%s", $1, $2}'
}

align_up() {
    value=$1
    printf '%s' $(( (value + ALIGN_SECTORS - 1) / ALIGN_SECTORS * ALIGN_SECTORS ))
}

analyze_mbr() {
    device=$1
    type=$(trim "$(lsblk_value "$device" TYPE)")
    [ "$type" = disk ] || fail "target is not a whole disk: $device type=${type:--}"

    target_real=$(canonical_device "$device") || fail "cannot resolve target device: $device"
    usos_real=$(canonical_device "$USOS_DISK_DEVICE") || fail "cannot resolve USOS disk: $USOS_DISK_DEVICE"
    [ "$target_real" != "$usos_real" ] || fail 'USOS USB is never an eligible target disk'

    rm=$(trim "$(lsblk_value "$device" RM)")
    ro=$(trim "$(lsblk_value "$device" RO)")
    [ "$rm" = 0 ] || fail 'removable media is not eligible as an XP target'
    [ "$ro" = 0 ] || fail 'read-only disk is not eligible as an XP target'
    check_not_mounted_or_swap "$device"

    logical=$(usos_disk_logical_sector "$device")
    [ "$logical" = 512 ] || fail "XP v1 requires 512-byte logical sectors; got ${logical:--}"
    size=$(usos_disk_size "$device")
    case "$size" in ''|*[!0-9]*) fail 'invalid target size' ;; esac
    [ "$size" -ge 3221225472 ] || fail 'target is too small for an existing layout plus 2 GiB XPSETUP'
    [ "$size" -lt 2199023255040 ] || fail 'XP v1 target exceeds supported MBR size (<2 TiB)'
    [ $((size % 512)) -eq 0 ] || fail 'target size is not sector aligned'
    total_sectors=$((size / 512))
    [ "$total_sectors" -le 4294967295 ] || fail 'target exceeds 32-bit MBR LBA range'

    signature=$(od -An -tx1 -j 510 -N 2 "$device" 2>/dev/null | tr -d ' \n\r')
    pttype=$(trim "$(lsblk_value "$device" PTTYPE)")
    EMPTY_MBR=no
    if [ "${XP_ALLOW_EMPTY:-no}" = yes ] && [ "$signature" = 0000 ] && [ -z "$pttype" ]; then
        # Accept only an uninitialised layout: no partition/filesystem signature,
        # and zero-filled metadata regions at both ends (including backup GPT).
        command -v blkid >/dev/null 2>&1 || fail 'blkid required to inspect blank disk'
        detected=$(blkid -p "$device" 2>/dev/null || true)
        [ -z "$detected" ] || fail 'unpartitioned target contains a filesystem signature'
        blank_check=$(mktemp -d)
        dd if=/dev/zero of="$blank_check/zero" bs=512 count=2048 2>/dev/null
        dd if="$device" of="$blank_check/first" bs=512 count=2048 2>/dev/null
        dd if="$device" of="$blank_check/last" bs=512 skip=$((total_sectors - 2048)) count=2048 2>/dev/null
        if ! cmp -s "$blank_check/zero" "$blank_check/first" || ! cmp -s "$blank_check/zero" "$blank_check/last"; then
            rm -f "$blank_check/zero" "$blank_check/first" "$blank_check/last"; rmdir "$blank_check"
            fail 'uninitialised disk has nonzero metadata; refusing automatic MBR creation'
        fi
        rm -f "$blank_check/zero" "$blank_check/first" "$blank_check/last"; rmdir "$blank_check"
        EMPTY_MBR=yes
        MBR_DISK_ID_DEC=$(printf '%s:%s' "$(usos_disk_serial "$device")" "$size" | cksum | awk '{print $1}')
        [ "$MBR_DISK_ID_DEC" -ne 0 ] || MBR_DISK_ID_DEC=1
    else
        [ "$signature" = 55aa ] || fail 'valid DOS MBR signature required; unrecognised disk metadata'
        [ "$pttype" = dos ] || fail "XP requires DOS/MBR; got ${pttype:--none}"
        MBR_DISK_ID_DEC=$(read_u32_le "$device" 440) || fail 'cannot read MBR disk signature'
        [ "$MBR_DISK_ID_DEC" -ne 0 ] || fail 'MBR disk signature is zero; stable nonzero signature required'
    fi
    MBR_DISK_ID_HEX=$(printf '%08x' "$MBR_DISK_ID_DEC")
    MBR_CHECKSUM=$(mbr_cksum "$device")

    occupied=$(mktemp)
    trap 'rm -f "$occupied"' EXIT HUP INT TERM
    : > "$occupied"
    XPSETUP_SLOT=0
    XPSETUP_REUSE=no
    REUSABLE_XPSETUP_SLOT=0
    REUSABLE_XPSETUP_START=0
    EMPTY_XPSETUP_SLOT=0
    ACTIVE_SLOTS=''
    ACTIVE_COUNT=0
    slot=1
    while [ "$slot" -le 4 ]; do
        hex=$(entry_hex "$device" "$slot")
        [ "${#hex}" -eq 32 ] || fail "cannot read MBR partition entry $slot"
        eval "MBR_ENTRY_${slot}_HEX=\$hex"
        status=$(read_u8 "$device" $((MBR_ENTRY_OFFSET + (slot - 1) * MBR_ENTRY_BYTES)))
        ptype=$(read_u8 "$device" $((MBR_ENTRY_OFFSET + (slot - 1) * MBR_ENTRY_BYTES + 4)))
        start=$(read_u32_le "$device" $((MBR_ENTRY_OFFSET + (slot - 1) * MBR_ENTRY_BYTES + 8))) || fail "cannot read partition $slot start"
        sectors=$(read_u32_le "$device" $((MBR_ENTRY_OFFSET + (slot - 1) * MBR_ENTRY_BYTES + 12))) || fail "cannot read partition $slot size"

        if [ "$hex" = 00000000000000000000000000000000 ]; then
            [ "$EMPTY_XPSETUP_SLOT" -ne 0 ] || EMPTY_XPSETUP_SLOT=$slot
        else
            [ "$ptype" -ne 0 ] || fail "MBR entry $slot is nonzero but has type 0"
            [ "$ptype" -ne 238 ] || fail 'protective GPT entry detected; 32-bit XP target must be MBR, not GPT'
            [ "$status" -eq 0 ] || [ "$status" -eq 128 ] || fail "invalid boot flag in MBR entry $slot"
            if [ "$status" -eq 128 ]; then
                ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
                if [ -z "$ACTIVE_SLOTS" ]; then ACTIVE_SLOTS=$slot; else ACTIVE_SLOTS="$ACTIVE_SLOTS,$slot"; fi
            fi
            [ "$start" -ge 1 ] || fail "invalid start LBA in MBR entry $slot"
            [ "$sectors" -gt 0 ] || fail "invalid sector count in MBR entry $slot"
            end=$((start + sectors))
            [ "$end" -gt "$start" ] || fail "MBR entry $slot overflows"
            [ "$end" -le "$total_sectors" ] || fail "MBR entry $slot extends beyond target disk"
            printf '%s %s %s\n' "$start" "$end" "$slot" >> "$occupied"
            if is_reusable_xpsetup "$device" "$start" "$sectors" "$ptype"; then
                [ "$REUSABLE_XPSETUP_SLOT" -eq 0 ] || fail 'multiple reusable XPSETUP partitions detected; refusing ambiguous target'
                REUSABLE_XPSETUP_SLOT=$slot
                REUSABLE_XPSETUP_START=$start
            fi
        fi
        slot=$((slot + 1))
    done
    if [ "$REUSABLE_XPSETUP_SLOT" -ne 0 ]; then
        XPSETUP_SLOT=$REUSABLE_XPSETUP_SLOT
        XPSETUP_START_LBA=$REUSABLE_XPSETUP_START
        XPSETUP_REUSE=yes
    else
        XPSETUP_SLOT=$EMPTY_XPSETUP_SLOT
        [ "$XPSETUP_SLOT" -ne 0 ] || fail 'no empty primary MBR partition entry is available for XPSETUP'
    fi

    # Reject malformed overlapping primary entries before we reason about free space.
    previous_end=0
    sort -n "$occupied" | while read -r start end slot; do
        [ "$start" -ge "$previous_end" ] || fail "existing MBR partitions overlap near entry $slot"
        previous_end=$end
    done

    if [ "$XPSETUP_REUSE" = yes ]; then
        rm -f "$occupied"
        trap - EXIT HUP INT TERM
        XPSETUP_END_LBA=$((XPSETUP_START_LBA + XPSETUP_SECTORS))
        return 0
    fi

    XPSETUP_START_LBA=0
    cursor=$ALIGN_SECTORS
    while read -r start end slot; do
        [ -n "$start" ] || continue
        aligned=$(align_up "$cursor")
        if [ "$XPSETUP_START_LBA" -eq 0 ] && [ "$start" -ge "$aligned" ] && [ $((start - aligned)) -ge "$XPSETUP_SECTORS" ]; then
            XPSETUP_START_LBA=$aligned
        fi
        [ "$end" -le "$cursor" ] || cursor=$end
    done <<EOF
$(sort -n "$occupied")
EOF
    if [ "$XPSETUP_START_LBA" -eq 0 ]; then
        aligned=$(align_up "$cursor")
        if [ "$total_sectors" -ge $((aligned + XPSETUP_SECTORS)) ]; then
            XPSETUP_START_LBA=$aligned
        fi
    fi
    rm -f "$occupied"
    trap - EXIT HUP INT TERM
    [ "$XPSETUP_START_LBA" -ne 0 ] || fail 'no contiguous 2 GiB unallocated extent is available for XPSETUP'
    XPSETUP_END_LBA=$((XPSETUP_START_LBA + XPSETUP_SECTORS))
}

write_snapshot() {
    device=$1
    analyze_mbr "$device"
    model=$(usos_disk_model "$device")
    serial=$(usos_disk_serial "$device" || true)
    wwn=$(usos_disk_wwn "$device")
    size=$(usos_disk_size "$device")
    logical=$(usos_disk_logical_sector "$device")
    [ -n "$model" ] || fail 'target model is empty'
    [ -n "$serial" ] || fail 'target serial is empty; XP v1 refuses disks without a stable serial'

    umask 077
    cat > "$TARGET_SNAPSHOT" <<EOF
version=2
model=$model
serial=$serial
wwn=$wwn
size_bytes=$size
logical_sector_bytes=$logical
mbr_cksum=$MBR_CHECKSUM
mbr_disk_id=0x$MBR_DISK_ID_HEX
mbr_entry1=$MBR_ENTRY_1_HEX
mbr_entry2=$MBR_ENTRY_2_HEX
mbr_entry3=$MBR_ENTRY_3_HEX
mbr_entry4=$MBR_ENTRY_4_HEX
xpsetup_slot=$XPSETUP_SLOT
xpsetup_start_lba=$XPSETUP_START_LBA
xpsetup_sectors=$XPSETUP_SECTORS
xpsetup_reuse=$XPSETUP_REUSE
active_slots=$ACTIVE_SLOTS
empty_mbr=$EMPTY_MBR
EOF
    printf '[TARGET_DISK_GUARD] SNAPSHOT PASS device=%s model=%s serial=%s mbr=0x%s\n' "$device" "$model" "$serial" "$MBR_DISK_ID_HEX"
    if [ "$XPSETUP_REUSE" = yes ]; then
        printf '[TARGET_DISK_GUARD] XPSETUP REUSE slot=%s start=%s sectors=%s label=XPSETUP fat32=validated\n' "$XPSETUP_SLOT" "$XPSETUP_START_LBA" "$XPSETUP_SECTORS"
    else
        printf '[TARGET_DISK_GUARD] XPSETUP RESERVATION slot=%s start=%s sectors=%s (2 GiB unallocated)\n' "$XPSETUP_SLOT" "$XPSETUP_START_LBA" "$XPSETUP_SECTORS"
    fi
    if [ -n "$ACTIVE_SLOTS" ]; then
        old_ifs=$IFS
        IFS=,
        for active_slot in $ACTIVE_SLOTS; do
            printf '[TARGET_DISK_GUARD] WARNING: Partycja %s jest obecnie aktywna. Po przygotowaniu XPSETUP komputer bedzie startowal z instalatora XP.\n' "$active_slot"
        done
        IFS=$old_ifs
    else
        printf '[TARGET_DISK_GUARD] ACTIVE PARTITION: none; XPSETUP will become the active boot partition\n'
    fi
    if [ "$XPSETUP_REUSE" = yes ]; then
        printf 'CONFIRMATION=REUSE XPSETUP %s %s\n' "$model" "$serial"
    else
        printf 'CONFIRMATION=CREATE XPSETUP %s %s\n' "$model" "$serial"
    fi
}

snapshot_value() {
    key=$1
    awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$TARGET_SNAPSHOT"
}

resolve_snapshot_disk() {
    expected_model=$1
    expected_serial=$2
    expected_wwn=$3
    expected_size=$4
    expected_logical=$5
    found=''
    count=0
    for sys in /sys/class/block/*; do
        [ -e "$sys" ] || continue
        name=${sys##*/}
        device="/dev/$name"
        [ -b "$device" ] || continue
        [ "$(trim "$(lsblk_value "$device" TYPE)")" = disk ] || continue
        model=$(usos_disk_model "$device")
        serial=$(usos_disk_serial "$device" || true)
        wwn=$(usos_disk_wwn "$device")
        size=$(usos_disk_size "$device")
        logical=$(usos_disk_logical_sector "$device")
        [ "$model" = "$expected_model" ] || continue
        [ "$serial" = "$expected_serial" ] || continue
        [ "$wwn" = "$expected_wwn" ] || continue
        [ "$size" = "$expected_size" ] || continue
        [ "$logical" = "$expected_logical" ] || continue
        found=$device
        count=$((count + 1))
    done
    [ "$count" -eq 1 ] || fail "snapshot identity resolves to $count disks; expected exactly one"
    printf '%s' "$found"
}

pre_write() {
    [ -f "$TARGET_SNAPSHOT" ] || fail "snapshot is missing: $TARGET_SNAPSHOT"
    [ "$(snapshot_value version)" = 2 ] || fail 'unsupported target snapshot version'
    model=$(snapshot_value model) || fail 'snapshot model missing'
    serial=$(snapshot_value serial) || fail 'snapshot serial missing'
    wwn=$(snapshot_value wwn) || fail 'snapshot WWN missing'
    size=$(snapshot_value size_bytes) || fail 'snapshot size missing'
    logical=$(snapshot_value logical_sector_bytes) || fail 'snapshot logical sector size missing'
    expected_mbr=$(snapshot_value mbr_cksum) || fail 'snapshot MBR checksum missing'
    expected_disk_id=$(snapshot_value mbr_disk_id) || fail 'snapshot MBR disk ID missing'
    expected_slot=$(snapshot_value xpsetup_slot) || fail 'snapshot XPSETUP slot missing'
    expected_start=$(snapshot_value xpsetup_start_lba) || fail 'snapshot XPSETUP start missing'
    expected_sectors=$(snapshot_value xpsetup_sectors) || fail 'snapshot XPSETUP size missing'
    expected_reuse=$(snapshot_value xpsetup_reuse) || fail 'snapshot XPSETUP reuse state missing'
    expected_active_slots=$(snapshot_value active_slots) || fail 'snapshot active partition state missing'
    expected_empty_mbr=$(snapshot_value empty_mbr 2>/dev/null || printf no)

    device=$(resolve_snapshot_disk "$model" "$serial" "$wwn" "$size" "$logical")
    analyze_mbr "$device"
    [ "$MBR_CHECKSUM" = "$expected_mbr" ] || fail 'MBR changed after target selection; refusing XPSETUP creation'
    [ "0x$MBR_DISK_ID_HEX" = "$expected_disk_id" ] || fail 'MBR disk signature changed after target selection'
    [ "$XPSETUP_SLOT" = "$expected_slot" ] || fail 'reserved XPSETUP MBR slot changed after target selection'
    [ "$XPSETUP_START_LBA" = "$expected_start" ] || fail 'reserved XPSETUP free extent changed after target selection'
    [ "$XPSETUP_SECTORS" = "$expected_sectors" ] || fail 'reserved XPSETUP size changed after target selection'
    [ "$XPSETUP_REUSE" = "$expected_reuse" ] || fail 'XPSETUP reuse state changed after target selection'
    [ "$ACTIVE_SLOTS" = "$expected_active_slots" ] || fail 'active partition state changed after target selection'
    [ "$EMPTY_MBR" = "$expected_empty_mbr" ] || fail 'blank MBR state changed after target selection'

    slot_hex=$(eval "printf '%s' \"\$MBR_ENTRY_${expected_slot}_HEX\"")
    if [ "$expected_reuse" = yes ]; then
        snapshot_slot_hex=$(snapshot_value "mbr_entry$expected_slot") || fail 'snapshot reusable XPSETUP MBR entry missing'
        [ "$slot_hex" = "$snapshot_slot_hex" ] || fail 'reusable XPSETUP MBR entry changed after target selection'
        is_reusable_xpsetup "$device" "$expected_start" "$expected_sectors" 12 || fail 'existing XPSETUP no longer matches strict reusable FAT32 contract'
        expected="REUSE XPSETUP $model $serial"
    else
        [ "$slot_hex" = 00000000000000000000000000000000 ] || fail 'reserved XPSETUP MBR entry is no longer empty'
        expected="CREATE XPSETUP $model $serial"
    fi
    printf '[TARGET_DISK_GUARD] CREATE CONFIRMATION REQUIRED\n' >&2
    printf 'MODEL=%s\nSERIAL=%s\nXPSETUP_SLOT=%s\nXPSETUP_START_LBA=%s\nXPSETUP_SECTORS=%s\nXPSETUP_REUSE=%s\n' "$model" "$serial" "$expected_slot" "$expected_start" "$expected_sectors" "$expected_reuse" >&2
    if [ -n "$expected_active_slots" ]; then
        old_ifs=$IFS
        IFS=,
        for active_slot in $expected_active_slots; do
            printf 'WARNING: Partycja %s jest obecnie aktywna. Po przygotowaniu XPSETUP komputer bedzie startowal z instalatora XP.\n' "$active_slot" >&2
        done
        IFS=$old_ifs
    fi
    printf 'Type exactly: %s\n> ' "$expected" >&2
    if [ -n "${TARGET_CONFIRMATION:-}" ]; then
        answer=$TARGET_CONFIRMATION
        printf '%s\n' "$answer" >&2
    else
        IFS= read -r answer || fail 'XPSETUP creation confirmation not provided'
    fi
    [ "$answer" = "$expected" ] || fail 'XPSETUP creation confirmation mismatch'

    printf '[TARGET_DISK_GUARD] PRE-WRITE PASS device=%s model=%s serial=%s\n' "$device" "$model" "$serial"
    printf 'TARGET_DEVICE=%s\n' "$device"
    printf 'XPSETUP_SLOT=%s\n' "$expected_slot"
    printf 'XPSETUP_START_LBA=%s\n' "$expected_start"
    printf 'XPSETUP_SECTORS=%s\n' "$expected_sectors"
    printf 'XPSETUP_REUSE=%s\n' "$expected_reuse"
    printf 'PREVIOUS_ACTIVE_SLOTS=%s\n' "$expected_active_slots"
    printf 'MBR_DISK_ID=%s\n' "$expected_disk_id"
}

check_tools
case "$MODE" in
    snapshot)
        TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required for snapshot}
        write_snapshot "$TARGET_DEVICE"
        ;;
    pre-write)
        pre_write
        ;;
    *)
        fail "unknown mode: $MODE (expected snapshot or pre-write)"
        ;;
esac
