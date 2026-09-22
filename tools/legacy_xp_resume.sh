#!/bin/sh
# Resume an already staged disk; never copy sources or format partitions.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/target_disk_identity.sh"
STATE=/mnt/esp/EFI/USOS
MARKER=$STATE/xp-resume.ini
exec > "$STATE/legacy-xp-resume.log" 2>&1
fail() { printf '[XP_RESUME] STOP: %s\n' "$1"; sync; exit 1; }
value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); gsub(/\r/, ""); v=$0; n++ } END { if (n != 1) exit 1; print v }' "$2"; }
[ -f "$MARKER" ] || fail 'resume identity is missing'
[ "$(value version "$MARKER")" = 2 ] || fail 'unsupported resume identity'
expected_model=$(value model "$MARKER") || fail 'model missing'
expected_serial=$(value serial "$MARKER") || fail 'serial missing'
expected_size=$(value size_bytes "$MARKER") || fail 'size missing'
[ -n "$expected_model" ] && [ -n "$expected_serial" ] || fail 'empty target identity'
ESP_NODE=$(findmnt -nro SOURCE /mnt/esp) || fail 'ESP mount missing'
ESP_PARENT=$(lsblk -dnro PKNAME "$ESP_NODE" | head -n 1)
[ -n "$ESP_PARENT" ] || fail 'cannot resolve USOS parent'
USOS_DISK_DEVICE=$(readlink -f "/dev/$ESP_PARENT")
TARGET_DEVICE=''
for sys in /sys/class/block/*; do
    device="/dev/${sys##*/}"
    [ -b "$device" ] || continue
    [ "$(usos_disk_lsblk_value "$device" TYPE)" = disk ] || continue
    [ "$(usos_disk_serial "$device" || true)" = "$expected_serial" ] || continue
    [ "$(usos_disk_model "$device")" = "$expected_model" ] || continue
    [ "$(usos_disk_size "$device")" = "$expected_size" ] || continue
    [ -z "$TARGET_DEVICE" ] || fail 'ambiguous target identity'
    TARGET_DEVICE=$device
done
[ -n "$TARGET_DEVICE" ] || fail 'prepared XP target is not attached'
[ "$(readlink -f "$TARGET_DEVICE")" != "$USOS_DISK_DEVICE" ] || fail 'target resolves to USOS USB'
TARGET_SNAPSHOT=/run/xp-resume.snapshot
export TARGET_DEVICE TARGET_SNAPSHOT USOS_DISK_DEVICE
# Shared guard validates mounted/swap descendants, overlaps, FAT32, RM/RO and DOS MBR.
sh "$SCRIPT_DIR/target_disk_guard.sh" snapshot || fail 'target layout guard refused resume'
[ "$(value xpsetup_reuse "$TARGET_SNAPSHOT")" = yes ] || fail 'existing XPSETUP is required'
for key in model serial size_bytes mbr_disk_id; do
    [ "$(value "$key" "$MARKER")" = "$(value "$key" "$TARGET_SNAPSHOT")" ] || fail "target $key changed"
done
slot=$(value bios_partition "$MARKER") || fail 'XPSETUP slot missing'
start=$(value partition_start_lba "$MARKER") || fail 'XPSETUP start missing'
[ "$slot" = "$(value xpsetup_slot "$TARGET_SNAPSHOT")" ] || fail 'XPSETUP slot changed'
[ "$start" = "$(value xpsetup_start_lba "$TARGET_SNAPSHOT")" ] || fail 'XPSETUP start changed'
[ "$slot" = "$(value active_slots "$TARGET_SNAPSHOT")" ] || fail 'XPSETUP must be the only active partition'
code="$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin"
[ "$(wc -c < "$code" | tr -d ' ')" = 440 ] || fail 'invalid MBR artifact length'
[ "$(sha256sum "$code" | awk '{print $1}')" = "$(value mbr_code_sha256 "$MARKER")" ] || fail 'MBR artifact differs from staged version'
mkdir -p /run/xp-resume /mnt/xp-resume-windows
for file in boot.ini ntldr ntdetect.com; do
    mcopy -o -i "$TARGET_DEVICE@@$((start * 512))" "::/$file" "/run/xp-resume/$file" || fail "Text Mode has not installed $file"
    [ -s "/run/xp-resume/$file" ] || fail "empty $file"
done
arc=$(value default /run/xp-resume/boot.ini) || fail 'boot.ini default missing'
# ARC numbers enumerate non-extended primaries first, then logical partitions.
# XP often creates an extended container after XPSETUP; ARC(2) is then Linux sdb5.
windows_arc=$(printf '%s\n' "$arc" | sed -n 's/^multi(0)disk(0)rdisk(0)partition(\([1-9][0-9]*\))\\[A-Za-z0-9_-][A-Za-z0-9_-]*$/\1/p')
case "$windows_arc" in ''|*[!0-9]*) fail 'unsupported Windows ARC path' ;; esac
[ "$windows_arc" -le 128 ] || fail 'Windows ARC partition is out of range'
windows_dir=${arc##*\\}
ordinal=0
windows_partition=0
for primary in 1 2 3 4; do
    entry=$(value "mbr_entry$primary" "$TARGET_SNAPSHOT") || fail 'partition metadata missing'
    ptype=$(printf '%s' "$entry" | cut -c9-10)
    case "$ptype" in 00|05|0f|85) continue ;; esac
    ordinal=$((ordinal + 1))
    if [ "$ordinal" -eq "$windows_arc" ]; then windows_partition=$primary; fi
done
: > /run/xp-resume/partitions
for part in /sys/class/block/"${TARGET_DEVICE##*/}"/*/partition; do
    [ -r "$part" ] || continue
    partdir=${part%/partition}
    printf '%s %s\n' "$(cat "$part")" "/dev/${partdir##*/}" >> /run/xp-resume/partitions
done
for logical in $(sort -n /run/xp-resume/partitions | awk '$1 >= 5 { print $1 }'); do
    ordinal=$((ordinal + 1))
    if [ "$ordinal" -eq "$windows_arc" ]; then windows_partition=$logical; fi
done
[ "$windows_partition" -ne 0 ] && [ "$windows_partition" -ne "$slot" ] || fail 'Windows destination is missing or points to XPSETUP'
windows_device=$(awk -v n="$windows_partition" '$1 == n { print $2; count++ } END { if(count!=1) exit 1 }' /run/xp-resume/partitions) || fail 'ambiguous Windows partition'
[ -b "$windows_device" ] || fail 'Windows partition device is unavailable'
[ "$(blkid -s TYPE -o value "$windows_device")" = ntfs ] || fail 'Windows destination must be NTFS'
modprobe ntfs3 2>/dev/null || fail 'NTFS driver unavailable'
mount -t ntfs3 -o ro "$windows_device" /mnt/xp-resume-windows || fail 'cannot verify Windows destination read-only'
verified=yes
for file in system32/ntoskrnl.exe system32/config/system; do
    [ -s "/mnt/xp-resume-windows/$windows_dir/$file" ] || verified=no
done
umount /mnt/xp-resume-windows || fail 'cannot unmount Windows destination'
[ "$verified" = yes ] || fail 'Text Mode Windows files are incomplete'
before=/run/xp-resume/mbr-before.bin
after=/run/xp-resume/mbr-after.bin
dd if="$TARGET_DEVICE" of="$before" bs=512 count=1 2>/dev/null || fail 'cannot read target MBR'
[ "$(cksum "$before" | awk '{printf "%s:%s",$1,$2}')" = "$(value mbr_cksum "$TARGET_SNAPSHOT")" ] || fail 'MBR changed during validation'
dd if="$before" of=/run/xp-resume/code-before.bin bs=1 count=440 2>/dev/null
old_hash=$(sha256sum /run/xp-resume/code-before.bin | awk '{print $1}')
new_hash=$(sha256sum "$code" | awk '{print $1}')
# Fresh XP SP2 stock MBR, or the same USOS MBR; reject other bootloaders.
case "$old_hash" in
    5431084b7014a6d05ff8632a63ac55fd48d7e6bce3ed22e39db6ab3a674b6677|"$new_hash") ;;
    *) fail 'unrecognized MBR code; refusing another bootloader' ;;
esac
backup="$STATE/xp-resume-mbr-$(sha256sum "$before" | awk '{print $1}').bin"
if [ -e "$backup" ]; then cmp -s "$before" "$backup" || fail 'existing backup differs'; else cp "$before" "$backup" || fail 'cannot persist MBR backup'; fi
sync
cmp -s "$before" "$backup" || fail 'backup readback mismatch'
dd if="$before" of=/run/xp-resume/expected.bin bs=512 count=1 2>/dev/null
dd if="$code" of=/run/xp-resume/expected.bin bs=440 count=1 conv=notrunc 2>/dev/null
if [ "$old_hash" != "$new_hash" ]; then
    dd if="$code" of="$TARGET_DEVICE" bs=440 count=1 conv=notrunc 2>/dev/null || fail 'MBR code write failed'
    sync
fi
dd if="$TARGET_DEVICE" of="$after" bs=512 count=1 2>/dev/null || fail 'cannot read back MBR'
cmp -s /run/xp-resume/expected.bin "$after" || fail 'MBR readback mismatch'
printf '[XP_RESUME] PASS target=%s serial=%s windows=%s written=440 preserved=440..511\n' "$TARGET_DEVICE" "$expected_serial" "$arc"
mv "$MARKER" "$STATE/xp-resume-completed.ini" || fail 'cannot finalize resume state'
sync
