#!/bin/sh
set -eu

TARGET_SNAPSHOT=${TARGET_SNAPSHOT:?TARGET_SNAPSHOT is required}
USOS_DISK_DEVICE=${USOS_DISK_DEVICE:?USOS_DISK_DEVICE is required}
SOURCE_ROOT=${SOURCE_ROOT:?SOURCE_ROOT is required}
XP_READY_FILE=${XP_READY_FILE:?XP_READY_FILE is required}
XPSETUP_MOUNT=${XPSETUP_MOUNT:-/mnt/xpsetup}
XP_WINNT_SIF=${XP_WINNT_SIF:-}
XP_WINDOWS_PLAN=${XP_WINDOWS_PLAN:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

fail() {
    printf '[XP_TARGET] STOP: %s\n' "$1" >&2
    exit 1
}

for tool in mkfs.fat mcopy mdir dd od sync awk tr cmp mktemp wc sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[ -x "$SCRIPT_DIR/target_disk_guard.sh" ] || fail 'target_disk_guard.sh is missing'
[ -r "$SCRIPT_DIR/target_disk_identity.sh" ] || fail 'target_disk_identity.sh is missing'
[ -x "$SCRIPT_DIR/prepare_xp_local_source.sh" ] || fail 'prepare_xp_local_source.sh is missing'
[ -r "$SCRIPT_DIR/probe_nt5_source.sh" ] || fail 'probe_nt5_source.sh is missing'
[ -r "$SCRIPT_DIR/xp-nt52-vbr-tail.bin" ] || fail 'xp-nt52-vbr-tail.bin is missing'
[ -r "$SCRIPT_DIR/xp-nt52-stage2.bin" ] || fail 'xp-nt52-stage2.bin is missing'
[ -r "$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin" ] || fail 'Strategy B MBR artifact is missing'
[ "$(wc -c < "$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin" | tr -d '[:space:]')" = 440 ] || fail 'Strategy B MBR artifact must be exactly 440 bytes'
if [ -n "$XP_WINNT_SIF" ]; then
    [ -f "$XP_WINNT_SIF" ] || fail 'selected user WINNT.SIF is missing before XP target write'
fi
. "$SCRIPT_DIR/target_disk_identity.sh"

if [ -n "$XP_WINDOWS_PLAN" ]; then
    [ -z "$XP_WINNT_SIF" ] || fail 'automatic partition placement cannot override a user WINNT.SIF'
    [ -r "$SCRIPT_DIR/prepare_xp_windows_partition.sh" ] || fail 'Windows partition preparer missing'
    [ -r "$SCRIPT_DIR/xp_selected_partition.sif" ] || fail 'automatic WINNT.SIF missing'
    [ -r "$SCRIPT_DIR/xp_drive_letters.awk" ] || fail 'drive letter mapper missing'
    [ -r "$SCRIPT_DIR/prepare_xp_ntfs_target.sh" ] || fail 'NTFS preparer missing'
    [ -r "$SCRIPT_DIR/xp_source_io.sh" ] || fail 'source I/O module missing'
    [ "$(wc -c < "$SCRIPT_DIR/xp-nt52-ntfs.bin" | tr -d '[:space:]')" = 8192 ] || fail 'NT52 NTFS bootstrap missing'
    for tool in mkntfs blockdev mdev mount umount; do command -v "$tool" >/dev/null || fail "$tool is required"; done
    case "${XP_BIOS_HEADS:-}:${XP_BIOS_SPT:-}" in *[!0-9:]*|:*) fail 'missing BIOS geometry for shared Windows volume' ;; esac
    [ "$XP_BIOS_HEADS" -ge 1 ] && [ "$XP_BIOS_HEADS" -le 256 ] || fail 'invalid BIOS head count'
    [ "$XP_BIOS_SPT" -ge 1 ] && [ "$XP_BIOS_SPT" -le 63 ] || fail 'invalid BIOS sectors per track'
    plan_check=$(mktemp)
    awk -f "$SCRIPT_DIR/xp_windows_partition_plan.awk" "$TARGET_SNAPSHOT" > "$plan_check" || fail 'invalid Windows partition reservation'
    cmp -s "$plan_check" "$XP_WINDOWS_PLAN" || fail 'Windows partition reservation changed'
    rm -f "$plan_check"
fi

# Validate the actual 32-bit XP source before the first write. The probe accepts
# WIN51 plus any WIN51I* edition/channel marker and treats service-pack markers
# as optional, so RTM/Home/Media Center media are not tied to WIN51IP.SP?.
XP_SOURCE_PROBE=$(SOURCE_ROOT="$SOURCE_ROOT" sh "$SCRIPT_DIR/probe_nt5_source.sh") || fail 'NT5 source validation failed'
XP_SOURCE_MARKERS=$(printf '%s\n' "$XP_SOURCE_PROBE" | awk -F= '$1 == "markers" { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }') || fail 'XP source probe returned no WIN51I* markers'
XP_SP_MARKER=$(printf '%s\n' "$XP_SOURCE_PROBE" | awk -F= '$1 == "service_pack_markers" { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }') || fail 'XP source probe returned no service-pack state'
printf '[XP_TARGET] I386 SOURCE PASS markers=%s service_pack_marker=%s required text-mode files present\n' "$XP_SOURCE_MARKERS" "$XP_SP_MARKER"

# Re-resolve the selected physical identity and prove that both the MBR and the
# reserved 2 GiB free extent are byte-for-byte the same as at snapshot time.
guard_log=$(mktemp)
trap 'rm -f "$guard_log"' EXIT HUP INT TERM
if ! sh "$SCRIPT_DIR/target_disk_guard.sh" pre-write >"$guard_log" 2>&1; then
    cat "$guard_log" >&2
    fail 'target_disk_guard pre-write refused XPSETUP creation'
fi
cat "$guard_log"
TARGET_DEVICE=$(awk -F= '$1 == "TARGET_DEVICE" { print $2; found=1; exit } END { if (!found) exit 1 }' "$guard_log") || fail 'guard did not return TARGET_DEVICE'
XPSETUP_SLOT=$(awk -F= '$1 == "XPSETUP_SLOT" { print $2; found=1; exit } END { if (!found) exit 1 }' "$guard_log") || fail 'guard did not return XPSETUP_SLOT'
XPSETUP_START=$(awk -F= '$1 == "XPSETUP_START_LBA" { print $2; found=1; exit } END { if (!found) exit 1 }' "$guard_log") || fail 'guard did not return XPSETUP_START_LBA'
XPSETUP_SECTORS=$(awk -F= '$1 == "XPSETUP_SECTORS" { print $2; found=1; exit } END { if (!found) exit 1 }' "$guard_log") || fail 'guard did not return XPSETUP_SECTORS'
XPSETUP_REUSE=$(awk -F= '$1 == "XPSETUP_REUSE" { print $2; found=1; exit } END { if (!found) exit 1 }' "$guard_log") || fail 'guard did not return XPSETUP_REUSE'
PREVIOUS_ACTIVE_SLOTS=$(awk -F= '$1 == "PREVIOUS_ACTIVE_SLOTS" { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$guard_log") || fail 'guard did not return previous active partition state'
MBR_DISK_ID=$(awk -F= '$1 == "MBR_DISK_ID" { print $2; found=1; exit } END { if (!found) exit 1 }' "$guard_log") || fail 'guard did not return MBR_DISK_ID'
rm -f "$guard_log"
trap - EXIT HUP INT TERM

TARGET_SIZE=$(usos_disk_size "$TARGET_DEVICE")
TARGET_LOGICAL=$(usos_disk_logical_sector "$TARGET_DEVICE")
TARGET_MODEL=$(usos_disk_model "$TARGET_DEVICE")
TARGET_SERIAL=$(usos_disk_serial "$TARGET_DEVICE" || true)
[ "$TARGET_LOGICAL" = 512 ] || fail "XP v1 requires 512-byte logical sectors; got $TARGET_LOGICAL"
[ "$XPSETUP_SECTORS" = 4194304 ] || fail "unexpected XPSETUP size: $XPSETUP_SECTORS sectors"
if [ -n "$XP_WINDOWS_PLAN" ]; then
    [ "$(awk -F= '$1=="windows_slot" {print $2}' "$XP_WINDOWS_PLAN")" = "$XPSETUP_SLOT" ] || fail 'shared volume slot differs'
    [ "$(awk -F= '$1=="windows_start_lba" {print $2}' "$XP_WINDOWS_PLAN")" = "$XPSETUP_START" ] || fail 'shared volume start differs'
    XPSETUP_SECTORS=$(awk -F= '$1=="windows_sectors" {print $2}' "$XP_WINDOWS_PLAN")
fi
case "$XPSETUP_SLOT" in 1|2|3|4) ;; *) fail "invalid XPSETUP primary slot: $XPSETUP_SLOT" ;; esac
case "$XPSETUP_REUSE" in yes|no) ;; *) fail "invalid XPSETUP reuse state: $XPSETUP_REUSE" ;; esac

pre_mbr=$(mktemp)
post_mbr=$(mktemp)
entry_file=$(mktemp)
post_entry=$(mktemp)
mbr_before_strategy=$(mktemp)
mbr_after_strategy=$(mktemp)
mbr_tail_before=$(mktemp)
mbr_tail_after=$(mktemp)
mbr_code_readback=$(mktemp)
trap 'rm -f "$pre_mbr" "$post_mbr" "$entry_file" "$post_entry" "$mbr_before_strategy" "$mbr_after_strategy" "$mbr_tail_before" "$mbr_tail_after" "$mbr_code_readback"' EXIT HUP INT TERM
dd if="$TARGET_DEVICE" of="$pre_mbr" bs=512 count=1 2>/dev/null || fail 'cannot capture MBR before XPSETUP creation'
empty_mbr=$(awk -F= '$1=="empty_mbr" {print $2}' "$TARGET_SNAPSHOT")
if [ "$empty_mbr" = yes ]; then
    [ -n "$XP_WINDOWS_PLAN" ] || fail 'empty MBR initialisation requires automatic Windows plan'
    [ "$(od -An -tx1 "$pre_mbr" | tr -d ' 0\n\r*')" = '' ] || fail 'blank MBR changed immediately before initialisation'
    disk_id_value=$((MBR_DISK_ID))
    for shift in 0 8 16 24; do
        printf "\\$(printf '%03o' "$(((disk_id_value >> shift) & 255))")"
    done > "$entry_file"
    dd if="$entry_file" of="$pre_mbr" bs=1 seek=440 count=4 conv=notrunc 2>/dev/null
    printf '\125\252' | dd of="$pre_mbr" bs=1 seek=510 count=2 conv=notrunc 2>/dev/null
    dd if="$pre_mbr" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc 2>/dev/null
    sync
    dd if="$TARGET_DEVICE" of="$post_mbr" bs=512 count=1 2>/dev/null
    cmp -s "$pre_mbr" "$post_mbr" || fail 'blank MBR initialisation readback mismatch'
    printf '[XP_TARGET] EMPTY MBR INITIALISED PASS id=%s\n' "$MBR_DISK_ID"
fi
[ "$(od -An -tx1 -j 510 -N 2 "$pre_mbr" | tr -d ' \n\r')" = 55aa ] || fail 'MBR signature disappeared before XPSETUP creation'

pre_entry_1=$(od -An -tx1 -j 446 -N 16 "$pre_mbr" | tr -d ' \n\r')
pre_entry_2=$(od -An -tx1 -j 462 -N 16 "$pre_mbr" | tr -d ' \n\r')
pre_entry_3=$(od -An -tx1 -j 478 -N 16 "$pre_mbr" | tr -d ' \n\r')
pre_entry_4=$(od -An -tx1 -j 494 -N 16 "$pre_mbr" | tr -d ' \n\r')
eval "reserved_before=\$pre_entry_$XPSETUP_SLOT"
if [ "$XPSETUP_REUSE" = yes ]; then
    [ "$reserved_before" != 00000000000000000000000000000000 ] || fail 'reusable XPSETUP MBR slot became empty immediately before write'
    printf '[XP_TARGET] REUSE EXISTING XPSETUP slot=%s start=%s sectors=%s; contents will be reformatted in place\n' "$XPSETUP_SLOT" "$XPSETUP_START" "$XPSETUP_SECTORS"
else
    [ "$reserved_before" = 00000000000000000000000000000000 ] || fail 'reserved XPSETUP MBR slot is not empty immediately before write'
fi

write_byte() {
    byte_value=$1
    printf "\\$(printf '%03o' "$byte_value")"
}
write_le32() {
    le_value=$1
    write_byte $((le_value & 255))
    write_byte $(((le_value >> 8) & 255))
    write_byte $(((le_value >> 16) & 255))
    write_byte $(((le_value >> 24) & 255))
}
write_mbr_chs_canonical() {
    chs_lba=$1

    # Strategy B deliberately removes the staging-time dependency on the
    # target BIOS translation. Keep the on-disk partition metadata internally
    # consistent with the conventional 255/63 LBA-assisted geometry used by
    # the FAT32/NT52 staging volume. The production MBR measures AH=08 at boot,
    # patches only the in-memory FAT32 BPB when needed, and then hands off to
    # Microsoft's VBR. Nothing here predicts the future machine's BIOS heads.
    chs_heads=255
    chs_spt=63
    if [ -n "$XP_WINDOWS_PLAN" ]; then
        chs_heads=$XP_BIOS_HEADS
        chs_spt=$XP_BIOS_SPT
    fi
    chs_per_cylinder=$((chs_heads * chs_spt))
    chs_cyl=$((chs_lba / chs_per_cylinder))
    chs_rem=$((chs_lba % chs_per_cylinder))
    chs_head=$((chs_rem / chs_spt))
    chs_sector=$((chs_rem % chs_spt + 1))

    if [ "$chs_cyl" -gt 1023 ] || [ "$chs_head" -gt 254 ]; then
        # Canonical saturated LBA-assisted CHS: C=1023 H=254 S=63 -> FEFFFF.
        write_byte 254
        write_byte 255
        write_byte 255
        return
    fi

    write_byte "$chs_head"
    write_byte $((chs_sector | ((chs_cyl >> 2) & 192)))
    write_byte $((chs_cyl & 255))
}
slot_was_active() {
    wanted=$1
    case ",${PREVIOUS_ACTIVE_SLOTS}," in
        *",${wanted},"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Build exactly one new 16-byte primary MBR entry. XPSETUP becomes the sole
# active partition so that after removing the USOS USB the target disk boots
# the NT52 installer naturally as BIOS drive 0x80. If an existing partition
# was active, only its one-byte boot flag is cleared; every other byte remains
# bit-for-bit unchanged and is verified below.
XPSETUP_END=$((XPSETUP_START + XPSETUP_SECTORS - 1))
{
    write_byte 128               # active (0x80): direct target-disk boot after removing USOS USB
    write_mbr_chs_canonical "$XPSETUP_START"
    write_byte 12                # FAT32 LBA (0x0C)
    write_mbr_chs_canonical "$XPSETUP_END"
    write_le32 "$XPSETUP_START"
    write_le32 "$XPSETUP_SECTORS"
} > "$entry_file"
[ "$(wc -c < "$entry_file" | tr -d '[:space:]')" = 16 ] || fail 'internal MBR entry generator did not produce 16 bytes'

entry_offset=$((446 + (XPSETUP_SLOT - 1) * 16))
printf '[XP_TARGET] preparing XPSETUP: device=%s slot=%s start=%s sectors=%s active=0x80 previous_active=%s reuse=%s\n' "$TARGET_DEVICE" "$XPSETUP_SLOT" "$XPSETUP_START" "$XPSETUP_SECTORS" "${PREVIOUS_ACTIVE_SLOTS:-none}" "$XPSETUP_REUSE"
# Clear prior active flags first, but touch no geometry/type bytes. pre-write
# already proved this active-slot set is identical to the state the user saw
# before confirmation. Reuse keeps the existing XPSETUP active flag in place;
# only other previously-active partitions are cleared.
CLEARED_ACTIVE_SLOTS=''
if [ -n "$PREVIOUS_ACTIVE_SLOTS" ]; then
    old_ifs=$IFS
    IFS=,
    for active_slot in $PREVIOUS_ACTIVE_SLOTS; do
        if [ "$active_slot" = "$XPSETUP_SLOT" ]; then
            [ "$XPSETUP_REUSE" = yes ] || fail 'reserved XPSETUP slot unexpectedly appears in previous active state'
            continue
        fi
        active_offset=$((446 + (active_slot - 1) * 16))
        printf '\000' | dd of="$TARGET_DEVICE" bs=1 seek="$active_offset" count=1 conv=notrunc 2>/dev/null || fail "cannot clear previous active flag in MBR entry $active_slot"
        if [ -z "$CLEARED_ACTIVE_SLOTS" ]; then CLEARED_ACTIVE_SLOTS=$active_slot; else CLEARED_ACTIVE_SLOTS="$CLEARED_ACTIVE_SLOTS,$active_slot"; fi
    done
    IFS=$old_ifs
fi
dd if="$entry_file" of="$TARGET_DEVICE" bs=1 seek="$entry_offset" count=16 conv=notrunc 2>/dev/null || fail 'cannot write active XPSETUP MBR entry'
sync
# Do not ask the kernel to re-read or register the new partition at all. The
# FAT32 filesystem is created and populated through an explicit byte/sector
# offset inside the already-guarded extent. BIOS/SETUP will parse the MBR after
# reboot, while Linux never needs a /dev/sdXN node for XPSETUP.
dd if="$TARGET_DEVICE" of="$post_mbr" bs=512 count=1 2>/dev/null || fail 'cannot read MBR after XPSETUP entry creation'
# Bytes 0..445 include MBR boot code + disk signature. Bytes 510..511 are the
# signature. Both regions must be unchanged. In the partition table, the only
# permitted changes are: the new XPSETUP entry and boot-flag byte 0x80->0x00
# for partitions explicitly recorded as active before confirmation.
if ! cmp -s -n 446 "$pre_mbr" "$post_mbr"; then
    fail 'MBR boot code or disk signature changed while creating XPSETUP'
fi
pre_sig=$(od -An -tx1 -j 510 -N 2 "$pre_mbr" | tr -d ' \n\r')
post_sig=$(od -An -tx1 -j 510 -N 2 "$post_mbr" | tr -d ' \n\r')
[ "$pre_sig" = "$post_sig" ] || fail 'MBR 55AA signature changed while creating XPSETUP'

slot=1
while [ "$slot" -le 4 ]; do
    pre_hex=$(eval "printf '%s' \"\$pre_entry_$slot\"")
    post_hex=$(od -An -tx1 -j $((446 + (slot - 1) * 16)) -N 16 "$post_mbr" | tr -d ' \n\r')
    if [ "$slot" -eq "$XPSETUP_SLOT" ]; then
        dd if="$post_mbr" of="$post_entry" bs=1 skip="$entry_offset" count=16 2>/dev/null
        cmp -s "$entry_file" "$post_entry" || fail 'XPSETUP MBR entry readback differs from the exact active 16 bytes written'
    elif slot_was_active "$slot"; then
        expected_hex="00${pre_hex#??}"
        [ "$post_hex" = "$expected_hex" ] || fail "existing active MBR entry $slot changed beyond its boot flag"
    else
        [ "$pre_hex" = "$post_hex" ] || fail "existing MBR partition entry $slot changed while creating XPSETUP"
    fi
    slot=$((slot + 1))
done
post_start=$(od -An -tu4 -j $((entry_offset + 8)) -N4 "$post_mbr" | tr -d '[:space:]')
post_count=$(od -An -tu4 -j $((entry_offset + 12)) -N4 "$post_mbr" | tr -d '[:space:]')
post_start_chs=$(od -An -tx1 -j $((entry_offset + 1)) -N3 "$post_mbr" | tr -d ' \n\r')
post_end_chs=$(od -An -tx1 -j $((entry_offset + 5)) -N3 "$post_mbr" | tr -d ' \n\r')
[ "$post_start" = "$XPSETUP_START" ] || fail "XPSETUP MBR start semantic readback mismatch: $post_start"
[ "$post_count" = "$XPSETUP_SECTORS" ] || fail "XPSETUP MBR size semantic readback mismatch: $post_count"
printf '[XP_TARGET] MBR CHS PASS start_lba=%s start_chs=%s end_lba=%s end_chs=%s geometry=%s/%s runtime_fix=Strategy-B\n' "$post_start" "$post_start_chs" "$XPSETUP_END" "$post_end_chs" "$chs_heads" "$chs_spt"
post_active=''
slot=1
while [ "$slot" -le 4 ]; do
    status=$(od -An -tu1 -j $((446 + (slot - 1) * 16)) -N1 "$post_mbr" | tr -d '[:space:]')
    if [ "$status" = 128 ]; then
        if [ -z "$post_active" ]; then post_active=$slot; else post_active="$post_active,$slot"; fi
    elif [ "$status" != 0 ]; then
        fail "invalid post-write active flag in MBR entry $slot: $status"
    fi
    slot=$((slot + 1))
done
[ "$post_active" = "$XPSETUP_SLOT" ] || fail "XPSETUP is not the sole active MBR partition after write: active=${post_active:-none}"
printf '[XP_TARGET] ACTIVE FLAG SWITCH PASS previous=%s now=%s(XPSETUP) other_entry_bytes=unchanged\n' "${PREVIOUS_ACTIVE_SLOTS:-none}" "$XPSETUP_SLOT"
printf '[XP_TARGET] MBR READBACK PASS xpsetup_entry=%s active=0x80 previous_active_flags_cleared=%s other_entries=bitwise-unchanged disk_signature=unchanged start=%s sectors=%s start_chs=%s end_chs=%s\n' "$XPSETUP_SLOT" "${CLEARED_ACTIVE_SLOTS:-none}" "$post_start" "$post_count" "$post_start_chs" "$post_end_chs"

if [ -n "$XP_WINDOWS_PLAN" ]; then
    export TARGET_DEVICE XP_WINDOWS_PLAN SOURCE_ROOT
    STRATEGY_B_SHA256=$(sha256sum "$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin" | awk '{print $1}')
    XP_EXPECTED_MBR="$post_mbr" sh "$SCRIPT_DIR/prepare_xp_ntfs_target.sh" || fail 'native NTFS preparation failed'
else
XPSETUP_OFFSET_BYTES=$((XPSETUP_START * 512))
XPSETUP_BLOCKS_KIB=$((XPSETUP_SECTORS / 2))
XPSETUP_SECTORS_PER_CLUSTER=8
XP_BOOT_FILES_RESERVE_BYTES=33554432
[ "$XPSETUP_BLOCKS_KIB" -ge 2097152 ] || fail 'staging filesystem too small'

# Format exactly the validated extent. --offset prevents mkfs.fat from
# touching sectors before XPSETUP, while BLOCK-COUNT prevents it from growing
# beyond the extent into later unallocated space or another partition.
#
# Force 4 KiB clusters. Without -s, mkfs.fat chooses the cluster size from the
# size of the *whole backing disk* even though BLOCK-COUNT bounds the filesystem.
# A 120 GB target therefore produced 64 sectors/cluster inside this 2 GiB
# extent, leaving only 65518 data clusters: below Microsoft's documented FAT32
# minimum of 65527 clusters. Linux/mtools accepted that forced-FAT32 volume, while XP
# Text Mode displayed 0 MB free on C:. The same extent on a 4 GB disk happened
# to get 8 sectors/cluster and worked. Keep the partition layout unchanged and
# make the filesystem geometry deterministic instead.
volume_label=XPSETUP
[ -z "$XP_WINDOWS_PLAN" ] || volume_label=Windows
mkfs.fat -I -F 32 -s "$XPSETUP_SECTORS_PER_CLUSTER" -R 32 -h "$XPSETUP_START" --offset "$XPSETUP_START" -n "$volume_label" "$TARGET_DEVICE" "$XPSETUP_BLOCKS_KIB" >/tmp/usos-xp-mkfs-fat.log 2>&1 || {
    cat /tmp/usos-xp-mkfs-fat.log >&2 || true
    fail 'mkfs.fat failed for XPSETUP reserved extent'
}

BPS=$(od -An -tu2 -j $((XPSETUP_OFFSET_BYTES + 11)) -N2 "$TARGET_DEVICE" | tr -d '[:space:]')
SPC=$(od -An -tu1 -j $((XPSETUP_OFFSET_BYTES + 13)) -N1 "$TARGET_DEVICE" | tr -d '[:space:]')
RESERVED=$(od -An -tu2 -j $((XPSETUP_OFFSET_BYTES + 14)) -N2 "$TARGET_DEVICE" | tr -d '[:space:]')
FAT_COUNT=$(od -An -tu1 -j $((XPSETUP_OFFSET_BYTES + 16)) -N1 "$TARGET_DEVICE" | tr -d '[:space:]')
HIDDEN=$(od -An -tu4 -j $((XPSETUP_OFFSET_BYTES + 28)) -N4 "$TARGET_DEVICE" | tr -d '[:space:]')
TOTAL_FS_SECTORS=$(od -An -tu4 -j $((XPSETUP_OFFSET_BYTES + 32)) -N4 "$TARGET_DEVICE" | tr -d '[:space:]')
FAT_SECTORS=$(od -An -tu4 -j $((XPSETUP_OFFSET_BYTES + 36)) -N4 "$TARGET_DEVICE" | tr -d '[:space:]')
[ "$BPS" = 512 ] || fail "FAT32 bytes/sector mismatch: $BPS"
[ "$SPC" = "$XPSETUP_SECTORS_PER_CLUSTER" ] || fail "FAT32 sectors/cluster mismatch: got $SPC expected $XPSETUP_SECTORS_PER_CLUSTER"
[ "$RESERVED" -ge 32 ] || fail "FAT32 reserved sectors too small: $RESERVED"
[ "$FAT_COUNT" = 2 ] || fail "FAT32 FAT count mismatch: $FAT_COUNT"
[ "$HIDDEN" = "$XPSETUP_START" ] || fail "FAT32 hidden-sector BPB mismatch: $HIDDEN"
DATA_SECTORS=$((TOTAL_FS_SECTORS - RESERVED - FAT_COUNT * FAT_SECTORS))
DATA_CLUSTERS=$((DATA_SECTORS / SPC))
[ "$DATA_CLUSTERS" -ge 65527 ] || fail "invalid FAT32 cluster count: $DATA_CLUSTERS (<65527)"
printf '[XP_TARGET] FAT32 GEOMETRY PASS bps=%s spc=%s cluster_bytes=%s reserved=%s fats=%s fat_sectors=%s data_clusters=%s\n' "$BPS" "$SPC" $((BPS * SPC)) "$RESERVED" "$FAT_COUNT" "$FAT_SECTORS" "$DATA_CLUSTERS"

boot_tmp=/tmp/usos-xp-vbr.bin
dd if="$TARGET_DEVICE" of="$boot_tmp" bs=512 skip="$XPSETUP_START" count=1 2>/dev/null
# When Setup installs Windows on its boot volume, it replaces the MBR/VBR.
# Persist the selected machine's AH=08 geometry in the BPB for that successor
# loader; a RAM-only correction in Strategy B cannot survive its replacement.
if [ -n "$XP_WINDOWS_PLAN" ]; then
    { write_byte "$XP_BIOS_SPT"; write_byte 0; write_byte $((XP_BIOS_HEADS & 255)); write_byte $((XP_BIOS_HEADS >> 8)); } > "$entry_file"
    dd if="$entry_file" of="$boot_tmp" bs=1 seek=24 count=4 conv=notrunc 2>/dev/null
    printf '[XP_TARGET] SHARED VOLUME BIOS GEOMETRY heads=%s spt=%s source=selected-target-INT13-AH08\n' "$XP_BIOS_HEADS" "$XP_BIOS_SPT"
fi
# Preserve the real mkfs.fat BPB/EBPB (bytes 0..89), including HiddenSectors
# and BPB.DrvNum. Replace only the executable tail with the NT52 FAT32 loader
# extracted from bootsect.exe. Its secondary 512-byte loader lives at
# partition-relative sector 12 and performs the proven NTLDR/SETUPLDR handoff.
[ "$(wc -c < "$SCRIPT_DIR/xp-nt52-vbr-tail.bin" | tr -d '[:space:]')" = 420 ] || fail 'XP NT52 VBR tail size mismatch'
[ "$(wc -c < "$SCRIPT_DIR/xp-nt52-stage2.bin" | tr -d '[:space:]')" = 512 ] || fail 'XP NT52 stage2 size mismatch'
dd if="$SCRIPT_DIR/xp-nt52-vbr-tail.bin" of="$boot_tmp" bs=1 seek=90 count=420 conv=notrunc 2>/dev/null
dd if="$boot_tmp" of="$TARGET_DEVICE" bs=512 seek="$XPSETUP_START" count=1 conv=notrunc 2>/dev/null
dd if="$boot_tmp" of="$TARGET_DEVICE" bs=512 seek=$((XPSETUP_START + 6)) count=1 conv=notrunc 2>/dev/null
dd if="$SCRIPT_DIR/xp-nt52-stage2.bin" of="$TARGET_DEVICE" bs=512 seek=$((XPSETUP_START + 12)) count=1 conv=notrunc 2>/dev/null
dd if="$TARGET_DEVICE" of="$entry_file" bs=512 skip="$XPSETUP_START" count=1 2>/dev/null
cmp -s "$boot_tmp" "$entry_file" || fail 'primary VBR readback mismatch'
dd if="$TARGET_DEVICE" of="$entry_file" bs=512 skip=$((XPSETUP_START + 6)) count=1 2>/dev/null
cmp -s "$boot_tmp" "$entry_file" || fail 'backup VBR readback mismatch'
rm -f "$boot_tmp"
sync
printf '[XP_TARGET] FAT32 NT52 VBR/STAGE2 PASS slot=%s start=%s stage2_sector=12 no-kernel-partition-node=yes\n' "$XPSETUP_SLOT" "$XPSETUP_START"

MTOOLS_IMAGE="$TARGET_DEVICE@@$XPSETUP_OFFSET_BYTES"
mdir -i "$MTOOLS_IMAGE" ::/ >/dev/null 2>&1 || fail 'mtools cannot open XPSETUP FAT32 at reserved offset'
export MTOOLS_IMAGE SOURCE_ROOT
printf '[XP_TARGET] preparing WINNT32-compatible local source on bounded XPSETUP FAT32\n'
sh "$SCRIPT_DIR/prepare_xp_local_source.sh" || fail 'local XP source preparation failed'
sync

for required in \
    'NTLDR' 'NTDETECT.COM' 'TXTSETUP.SIF' '$LDR$' \
    '$WIN_NT$.~BT/SETUPLDR.BIN' '$WIN_NT$.~BT/TXTSETUP.SIF' '$WIN_NT$.~BT/WINNT.SIF' \
    '$WIN_NT$.~LS/I386/SETUPLDR.BIN' '$WIN_NT$.~LS/I386/NTLDR' \
    '$WIN_NT$.~LS/I386/TXTSETUP.SIF' '$WIN_NT$.~LS/I386/SYSTEM32/SMSS.EXE'; do
    mdir -i "$MTOOLS_IMAGE" "::/$required" >/dev/null 2>&1 || fail "prepared XPSETUP missing: $required"
done
printf '[XP_TARGET] LOCAL SOURCE READBACK PASS markers=%s service_pack_marker=%s\n' "$XP_SOURCE_MARKERS" "$XP_SP_MARKER"

# XP writes NTLDR/NTDETECT.COM/BOOT.INI to the active system partition during
# text-mode setup. Verify the staged FAT32 still has a real safety margin after
# all local-source files have been copied. FSInfo is checked against the known
# deterministic cluster geometry; the later QEMU regression also proves XP's
# own free-space check crosses this point.
printf '[XP_TARGET] FREE SPACE CHECK begin offset=%s\n' "$XPSETUP_OFFSET_BYTES"
FSINFO_SECTOR=$(od -An -tu2 -j $((XPSETUP_OFFSET_BYTES + 48)) -N2 "$TARGET_DEVICE" | tr -d '[:space:]')
printf '[XP_TARGET] FREE SPACE CHECK fsinfo_sector=%s\n' "$FSINFO_SECTOR"
case "$FSINFO_SECTOR" in ''|*[!0-9]*) fail 'invalid FAT32 FSInfo sector' ;; esac
FREE_CLUSTERS=$(od -An -tu4 -j $((XPSETUP_OFFSET_BYTES + FSINFO_SECTOR * BPS + 488)) -N4 "$TARGET_DEVICE" | tr -d '[:space:]')
printf '[XP_TARGET] FREE SPACE CHECK free_clusters_raw=%s\n' "$FREE_CLUSTERS"
case "$FREE_CLUSTERS" in ''|*[!0-9]*) fail 'invalid FAT32 FSInfo free-cluster count' ;; esac
[ "$FREE_CLUSTERS" -ne 4294967295 ] || fail 'FAT32 FSInfo free-cluster count is unknown'
[ "$FREE_CLUSTERS" -le "$DATA_CLUSTERS" ] || fail "FAT32 FSInfo free-cluster count exceeds data clusters: $FREE_CLUSTERS > $DATA_CLUSTERS"
FREE_BYTES=$((FREE_CLUSTERS * BPS * SPC))
[ "$FREE_BYTES" -ge "$XP_BOOT_FILES_RESERVE_BYTES" ] || fail "XPSETUP free-space reserve too small after staging: $FREE_BYTES bytes"
printf '[XP_TARGET] FREE SPACE PASS free_clusters=%s free_bytes=%s reserve_bytes=%s\n' "$FREE_CLUSTERS" "$FREE_BYTES" "$XP_BOOT_FILES_RESERVE_BYTES"

# Production Strategy B is committed only after the complete XP local source
# and FAT32 safety checks have passed. Replace exactly MBR bytes 0..439; keep
# the disk signature/reserved bytes, partition table and 55AA tail (440..511)
# bit-for-bit. This makes the next target-only boot independent of the BIOS
# heads translation: the MBR measures AH=08 at runtime and adjusts only the
# in-memory FAT32 BPB before entering Microsoft's NT52 VBR.
dd if="$TARGET_DEVICE" of="$mbr_before_strategy" bs=512 count=1 2>/dev/null || fail 'cannot capture MBR before Strategy B install'
# Nothing is allowed to have changed the partition table after its semantic
# readback above. Verify the complete 64-byte table plus signature immediately
# before touching executable MBR bytes.
dd if="$mbr_before_strategy" of="$mbr_tail_before" bs=1 skip=440 count=72 2>/dev/null || fail 'cannot capture Strategy B preserved MBR tail'
dd if="$post_mbr" of="$mbr_tail_after" bs=1 skip=440 count=72 2>/dev/null || fail 'cannot capture expected MBR tail'
cmp -s "$mbr_tail_before" "$mbr_tail_after" || fail 'MBR tail changed after XPSETUP creation before Strategy B install'

STRATEGY_B_SHA256=$(sha256sum "$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin" | awk '{print $1}') || fail 'cannot hash Strategy B MBR artifact'
dd if="$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin" of="$TARGET_DEVICE" bs=440 count=1 conv=notrunc 2>/dev/null || fail 'cannot install Strategy B MBR code'
sync
dd if="$TARGET_DEVICE" of="$mbr_after_strategy" bs=512 count=1 2>/dev/null || fail 'cannot read back MBR after Strategy B install'
dd if="$mbr_after_strategy" of="$mbr_code_readback" bs=1 count=440 2>/dev/null || fail 'cannot capture Strategy B MBR code readback'
cmp -s "$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin" "$mbr_code_readback" || fail 'Strategy B MBR code readback mismatch'
dd if="$mbr_after_strategy" of="$mbr_tail_after" bs=1 skip=440 count=72 2>/dev/null || fail 'cannot capture Strategy B MBR tail readback'
cmp -s "$mbr_tail_before" "$mbr_tail_after" || fail 'Strategy B changed MBR bytes 440..511'
[ "$(od -An -tx1 -j 510 -N 2 "$mbr_after_strategy" | tr -d ' \n\r')" = 55aa ] || fail 'Strategy B MBR readback lost 55AA signature'
STRATEGY_B_READBACK_SHA256=$(sha256sum "$mbr_code_readback" | awk '{print $1}') || fail 'cannot hash Strategy B MBR readback'
[ "$STRATEGY_B_READBACK_SHA256" = "$STRATEGY_B_SHA256" ] || fail 'Strategy B MBR SHA256 readback mismatch'
printf '[XP_TARGET] STRATEGY B MBR PASS code_bytes=440 sha256=%s preserved=440..511 runtime_geometry=INT13-AH08\n' "$STRATEGY_B_SHA256"

fi

ready_tmp="$XP_READY_FILE.tmp"
cat > "$ready_tmp" <<EOF
version=2
model=$TARGET_MODEL
serial=$TARGET_SERIAL
size_bytes=$TARGET_SIZE
mbr_disk_id=$MBR_DISK_ID
bios_partition=$XPSETUP_SLOT
partition_start_lba=$XPSETUP_START
mbr_code_sha256=$STRATEGY_B_SHA256
runtime_geometry_fix=strategy-b-ah08
EOF
mv "$ready_tmp" "$XP_READY_FILE"
sync
rm -f "$pre_mbr" "$post_mbr" "$entry_file" "$post_entry" "$mbr_before_strategy" "$mbr_after_strategy" "$mbr_tail_before" "$mbr_tail_after" "$mbr_code_readback"
trap - EXIT HUP INT TERM
printf '[XP_TARGET] PREPARED PASS target=%s mbr=%s XPSETUP_slot=%s start=%s reuse=%s existing_partitions=preserved\n' "$TARGET_DEVICE" "$MBR_DISK_ID" "$XPSETUP_SLOT" "$XPSETUP_START" "$XPSETUP_REUSE"
