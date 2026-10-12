#!/bin/sh
# Custom OS from the UEFI menu (profile custom-image-uefi, experimental;
# docs/custom-os-2026-10-11.md): Haiku, FreeBSD, ReactOS, KolibriOS, FreeDOS,
# OpenBSD, NetBSD, 9front, Redox and "bring your own image". Called by tools/w9x_csmwrap_prepare.sh (step
# 620) after the user picked and confirmed the disk.
#
# The official image is a hybrid disk image (Haiku anyboot ISO, FreeBSD
# disc1/memstick, ReactOS ISO, KolibriOS raw image, FreeDOS FullUSB image):
# its first bytes are a partition table. USOS writes it unchanged to the
# start of $TARGET_DEVICE, then
#   - GPT image: moves the backup GPT to the real disk end (sfdisk);
#   - image with an EFI system partition: the firmware boots the disk's own
#     UEFI loader;
#   - MBR image without one (BIOS only): adds the CSMWrap ESP in a free MBR
#     slot at the disk end (tools/xp_csmwrap_esp.sh), CSMWrap's SeaBIOS boots
#     the disk as 0x80;
#   - ReactOS / own BIOS image: the ELCR MBR in front of the image's MBR
#     (kept at LBA 1), so PCI interrupts are level-triggered as on a real
#     BIOS (ReactOS stops with 0x7B behind CSMWrap otherwise);
#   - every image: a firmware boot entry named after the system, appended to
#     BootOrder and set as BootNext (tools/uefi_boot_entry.sh, efivarfs);
#   - FreeDOS FullUSB: SETUP.BAT -> SETUP.OFF so the disk starts into the
#     FreeDOS prompt instead of the installer (which aborts on its own disk);
#     the package repository stays on the disk (FDIMPLES).
# An image that cannot start from a hard disk (CD-only ISO such as TempleOS:
# no partition table and no boot code in sector 0) is refused before any
# write. Writes ONLY $TARGET_DEVICE; the rest of the disk stays unallocated.
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
IMAGE=${IMAGE_SOURCE:?IMAGE_SOURCE is required}
SYSTEM=${IMAGE_SYSTEM:-other-os}
LIB=${USOS_LIB_DIR:-/usr/lib/usos}
ESP_TAIL=133120
# The verdict for the caller (written before any disk change).
RESULT=${IMAGE_RESULT_FILE:-/run/image-disk.result}

log() { printf '[IMAGE_DISK] %s\n' "$*"; }
fail() { printf '[IMAGE_DISK] STOP: %s\n' "$1" >&2; printf 'stop=%s\n' "$1" > "$RESULT" 2>/dev/null || true; exit 1; }

MTOOLS_SKIP_CHECK=1
export MTOOLS_SKIP_CHECK
for tool in dd od awk blockdev sync wc sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[ -r "$IMAGE" ] || fail "missing: $IMAGE"
if awk -v d="$TARGET_DEVICE" 'index($1, d) == 1 { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts; then
    fail 'a partition of the selected disk is mounted; no disk was changed'
fi

u8() { od -An -tu1 -j"$2" -N1 "$1" | tr -d ' \n'; }
u32() { od -An -tu4 -j"$2" -N4 "$1" | tr -d ' \n'; }

# Size in bytes without reading the file: BusyBox `wc -c` reads all of it
# (the 1.4 GB Haiku ISO from the stick took long on the X470, 2026-10-12).
# A block device (tests: the image on a virtio disk) through blockdev.
usos_file_bytes() {
    if [ -b "$1" ]; then
        blockdev --getsize64 "$1"
    elif stat -L -c %s "$1" 2>/dev/null; then
        :
    else
        wc -c < "$1" | tr -d ' '
    fi
}

work=/run/image-disk
rm -rf "$work"
mkdir -p "$work"
head="$work/head.bin"
dd if="$IMAGE" of="$head" bs=512 count=64 2>/dev/null || fail 'cannot read the image'
image_bytes=$(usos_file_bytes "$IMAGE") || fail 'cannot read the image size'
[ "$image_bytes" -ge 32768 ] || fail 'the image is too small to be a disk image'

# ---------------------------------------------------------------- classify
signature=$(od -An -tx1 -j510 -N2 "$head" | tr -d ' \n')
gpt=no
[ "$(dd if="$head" bs=1 skip=512 count=8 2>/dev/null)" = 'EFI PART' ] && gpt=yes
mbr_esp=no
mbr_bios=no
free_slot=no
boot_code=$(od -An -tx1 -N440 "$head" | tr -d ' \n' | tr -d 0)
if [ "$signature" = 55aa ]; then
    for slot in 0 1 2 3; do
        type=$(u8 "$head" $((446 + 16 * slot + 4)))
        case "$type" in
            0) free_slot=yes ;;
            239) mbr_esp=yes ;;
            238) ;;
            *) mbr_bios=yes ;;
        esac
    done
fi
gpt_esp=no
if [ "$gpt" = yes ]; then
    entries_lba=$(u32 "$head" $((512 + 72)))
    count=$(u32 "$head" $((512 + 80)))
    entry_size=$(u32 "$head" $((512 + 84)))
    [ "$entries_lba" -ge 2 ] && [ "$entries_lba" -lt 64 ] && [ "$entry_size" -ge 128 ] || fail 'the image has an unexpected GPT'
    [ "$count" -le 256 ] || count=256
    i=0
    while [ "$i" -lt "$count" ]; do
        off=$((entries_lba * 512 + i * entry_size))
        [ $((off + 16)) -le 32768 ] || break
        guid=$(od -An -tx1 -j"$off" -N16 "$head" | tr -d ' \n')
        # C12A7328-F81F-11D2-BA4B-00A0C93EC93B (EFI system partition)
        [ "$guid" != 28732ac11ff8d211ba4b00a0c93ec93b ] || gpt_esp=yes
        i=$((i + 1))
    done
fi
uefi=no
[ "$mbr_esp" = no ] && [ "$gpt_esp" = no ] || uefi=yes
mode=''
if [ "$uefi" = yes ]; then
    mode=uefi
elif [ "$signature" = 55aa ] && [ -n "$boot_code" ] && [ "$gpt" = no ]; then
    # BIOS-only MBR image (ReactOS isohybrid, FreeDOS FullUSB).
    [ "$free_slot" = yes ] || fail 'this BIOS image uses all four MBR slots; there is no room for the CSMWrap partition'
    mode=csmwrap
else
    fail 'this image cannot start from a hard disk (a CD-only ISO without a hybrid partition table, or a GPT image without an EFI system partition); see docs/custom-os-2026-10-11.md'
fi

size=$(blockdev --getsize64 "$TARGET_DEVICE") || fail 'cannot read the target size'
total=$((size / 512))
image_sectors=$(( (image_bytes + 511) / 512 ))
limit=$total
[ "$mode" != csmwrap ] || limit=$(( (total - ESP_TAIL + 2047) / 2048 * 2048 ))
[ "$image_sectors" -le "$limit" ] || fail 'the selected disk is too small for this image; no disk was changed'
[ "$mode" != csmwrap ] || [ "$total" -le 4294967295 ] || fail 'the selected disk is larger than 2 TiB (MBR); no disk was changed'
log "system=$SYSTEM image_bytes=$image_bytes mode=$mode gpt=$gpt mbr_esp=$mbr_esp gpt_esp=$gpt_esp disk_sectors=$total"
printf 'mode=%s\n' "$mode" > "$RESULT"

# ---------------------------------------------------------------- the disk
# Old partition tables at both ends go first (a stale backup GPT at the disk
# end would make the firmware or the OS see the old layout).
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the disk start'
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 seek=$((total - 2048)) count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the disk end'
dd if="$IMAGE" of="$TARGET_DEVICE" bs=4M conv=notrunc,fsync 2>/dev/null || fail 'cannot write the image to the disk'
sync
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true

# Read-back: the first and the last 4 MiB of the image.
chunk=8192
[ "$image_sectors" -ge "$chunk" ] || chunk=$image_sectors
a=$(dd if="$IMAGE" bs=512 count="$chunk" 2>/dev/null | sha256sum | awk '{print $1}')
b=$(dd if="$TARGET_DEVICE" bs=512 count="$chunk" 2>/dev/null | sha256sum | awk '{print $1}')
[ "$a" = "$b" ] || fail 'read-back: the disk start differs from the image'
tail_skip=$((image_bytes / 512 - chunk))
if [ "$tail_skip" -gt 0 ]; then
    a=$(dd if="$IMAGE" bs=512 skip="$tail_skip" count="$chunk" 2>/dev/null | sha256sum | awk '{print $1}')
    b=$(dd if="$TARGET_DEVICE" bs=512 skip="$tail_skip" count="$chunk" 2>/dev/null | sha256sum | awk '{print $1}')
    [ "$a" = "$b" ] || fail 'read-back: the image end differs on the disk'
fi
log 'image written, read-back PASS'

if [ "$gpt" = yes ]; then
    # The image's backup GPT sits at the image end; move it to the disk end.
    if command -v sfdisk >/dev/null 2>&1; then
        sfdisk --relocate gpt-bak-std "$TARGET_DEVICE" >/dev/null 2>&1 && log 'backup GPT moved to the disk end' ||
            log 'backup GPT not moved (sfdisk refused); the primary GPT stays valid'
    fi
fi

# GPT image with a hybrid MBR (KolibriOS raw image: slot 1 = EF ESP, slot 2 =
# EE over LBA 1-2047, disk signature 0): firmware that reads the MBR first
# sees an MBR disk with an MBR ESP, so the boot entry's GPT HD() node
# (uefi_boot_entry.sh) never matches and the entry is skipped (X470,
# B261012-154207: KolibriOS not started first, Haiku's MBR image was). EDK2
# takes the GPT whenever an EE slot starts at LBA 1, so QEMU did not show it.
# UEFI mode needs only the GPT: the partition table area becomes the
# protective MBR of UEFI 2.x 5.2.3 (one EE slot from LBA 1 over the disk),
# the boot code stays. GPT images with a protective MBR are not touched.
pmbr_fix() {
    hybrid=no
    for slot in 0 1 2 3; do
        case "$(u8 "$head" $((446 + 16 * slot + 4)))" in 0|238) ;; *) hybrid=yes ;; esac
    done
    [ "$hybrid" = yes ] || return 0
    pmbr_size=$((total - 1))
    [ "$pmbr_size" -le 4294967295 ] || pmbr_size=4294967295
    pmbr="$work/pmbr.bin"
    # 00 | CHS 00 02 00 | EE | CHS FF FF FF | LBA 1 | size, then three empty slots.
    printf '\000\000\002\000\356\377\377\377\001\000\000\000' > "$pmbr"
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $((pmbr_size & 255)) $((pmbr_size >> 8 & 255)) $((pmbr_size >> 16 & 255)) $((pmbr_size >> 24 & 255)))" >> "$pmbr"
    dd if=/dev/zero bs=48 count=1 2>/dev/null >> "$pmbr"
    [ "$(wc -c < "$pmbr" | tr -d ' ')" = 64 ] || fail 'internal error: protective MBR size'
    dd if="$pmbr" of="$TARGET_DEVICE" bs=1 seek=446 count=64 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the protective MBR'
    [ "$(dd if="$TARGET_DEVICE" bs=1 skip=446 count=64 2>/dev/null | sha256sum | awk '{print $1}')" = "$(sha256sum < "$pmbr" | awk '{print $1}')" ] ||
        fail 'read-back: the protective MBR differs'
    log "hybrid MBR replaced by a protective MBR (EE, LBA 1, $pmbr_size sectors): the firmware uses the GPT"
}
if [ "$gpt" = yes ] && [ "$mode" = uefi ]; then
    pmbr_fix
fi

# FreeDOS FullUSB: start into DOS, not into the installer on its own disk.
freedos_fix() {
    lba=$(u32 "$head" $((446 + 8)))
    type=$(u8 "$head" $((446 + 4)))
    case "$type" in 6|11|12|14) ;; *) return 0 ;; esac
    command -v mren >/dev/null 2>&1 || { log 'mren missing: FreeDOS keeps its installer'; return 0; }
    part="$TARGET_DEVICE@@$((lba * 512))"
    mdir -i "$part" ::/SETUP.BAT >/dev/null 2>&1 || return 0
    mdir -i "$part" ::/KERNEL.SYS >/dev/null 2>&1 || return 0
    mren -i "$part" ::/SETUP.BAT ::/SETUP.OFF || fail 'cannot switch FreeDOS from its installer to the prompt'
    log 'FreeDOS: SETUP.BAT renamed to SETUP.OFF (starts into the prompt)'
}
case "$SYSTEM" in freedos) freedos_fix ;; esac
sync
blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true

if [ "$gpt" = no ] && [ "$(dd if="$TARGET_DEVICE" bs=1 skip=$((17 * 2048 + 7)) count=23 2>/dev/null)" = 'EL TORITO SPECIFICATION' ]; then
    # Hybrid ISO with an MBR (ReactOS, Haiku anyboot): the UEFI partition
    # driver (EDK2 OVMF, QEMU 2026-10-11) sees the El Torito boot record
    # first, makes the whole disk a CD-ROM and never reads the MBR, so the
    # CSMWrap ESP stays invisible and the image's own ESP is no HD()
    # partition the firmware boot entry (uefi_boot_entry.sh) could name.
    # On a hard disk the record has no use (CD boot only; the OS reads the
    # primary volume descriptor at sector 16): one byte of its identifier
    # changes, 'EL TORITO' -> 'XL TORITO'.
    printf 'X' | dd of="$TARGET_DEVICE" bs=1 seek=$((17 * 2048 + 7)) count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot hide the El Torito record'
    log 'hybrid ISO: El Torito boot record hidden (UEFI sees the MBR and its EFI system partition)'
fi
if [ "$mode" = csmwrap ]; then
    TARGET_DEVICE=$TARGET_DEVICE USOS_XP_ESP_TAIL_SECTORS=$ESP_TAIL sh "$LIB/xp_csmwrap_esp.sh" || fail 'the CSMWrap ESP could not be written'
fi

# ReactOS / own BIOS image behind CSMWrap: CSMWrap's SeaBIOS (CSM mode) leaves
# the 8259 ELCR at 00/00, so PCI interrupts look edge-triggered and ReactOS's
# disk driver never sees its (level) AHCI interrupt: STOP 0x7B (QEMU
# 2026-10-11). The ELCR MBR (src/platform/bios/reactos/elcr_mbr.S) marks the
# PCI IRQs level-triggered and chains to the image's own MBR, kept unchanged
# at LBA 1. Only when LBA 1 is empty (ISO system area); FreeDOS does not need it.
elcr_fix() {
    stub="$LIB/elcr-mbr-440.bin"
    [ -r "$stub" ] || { log 'elcr-mbr-440.bin missing: the image MBR stays (0x7B risk behind CSMWrap)'; return 0; }
    [ "$(wc -c < "$stub" | tr -d ' ')" = 440 ] || fail 'internal error: ELCR MBR size'
    if [ -n "$(dd if="$TARGET_DEVICE" bs=512 skip=1 count=1 2>/dev/null | od -An -v -tx1 | tr -d ' \n0')" ]; then
        log 'LBA 1 is in use by the image: no ELCR MBR'
        return 0
    fi
    orig="$work/mbr-image.bin"
    dd if="$TARGET_DEVICE" of="$orig" bs=512 count=1 2>/dev/null || fail 'cannot read the MBR'
    dd if="$orig" of="$TARGET_DEVICE" bs=512 seek=1 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot keep the image MBR at LBA 1'
    dd if="$stub" of="$TARGET_DEVICE" bs=440 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the ELCR MBR'
    sync
    a=$( { cat "$stub"; dd if="$orig" bs=1 skip=440 count=72 2>/dev/null; cat "$orig"; } | sha256sum | awk '{print $1}')
    b=$(dd if="$TARGET_DEVICE" bs=512 count=2 2>/dev/null | sha256sum | awk '{print $1}')
    [ "$a" = "$b" ] || fail 'read-back: the ELCR MBR or the kept image MBR differs'
    log 'ELCR MBR written (PCI IRQs level-triggered); the image MBR kept at LBA 1, read-back PASS'
}
if [ "$mode" = csmwrap ]; then
    case "$SYSTEM" in reactos|other-os) elcr_fix ;; esac
fi
sync
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true

# Firmware boot entry named after the system (BootOrder + BootNext): the
# restart after the flow starts this disk, and the entry stays in the
# firmware boot menu (Haiku had none on the X470, 2026-10-12). Not fatal:
# without it the firmware still finds \EFI\BOOT\BOOTX64.EFI by its
# removable-media scan.
if [ -r "$LIB/uefi_boot_entry.sh" ]; then
    entry_log="$work/boot-entry.log"
    if TARGET_DEVICE=$TARGET_DEVICE ENTRY_NAME="${IMAGE_TITLE:-$SYSTEM}" sh "$LIB/uefi_boot_entry.sh" add > "$entry_log" 2>&1; then
        cat "$entry_log"
        grep '^boot_entry=' "$entry_log" >> "$RESULT" || true
    else
        cat "$entry_log"
        log 'no firmware boot entry written; the disk still starts through the firmware removable-media path'
    fi
else
    log 'uefi_boot_entry.sh missing: no firmware boot entry'
fi
log "PASS target=$TARGET_DEVICE mode=$mode; next boot: $([ "$mode" = uefi ] && echo "the disk's own UEFI loader" || echo 'CSMWrap -> SeaBIOS -> the image MBR')"
