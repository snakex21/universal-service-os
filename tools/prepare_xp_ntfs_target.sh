#!/bin/sh
# Prepare the shared volume directly as NTFS, avoiding XP's FAT/CHS successor.
# The XP UEFI-CSM profile (USOS_PLAN_PROFILE=xp-x86-sp3-uefi-csm) also integrates
# the driver bundle, stages the PAE helper and verifies the target read-only.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
TARGET_DEVICE=${TARGET_DEVICE:?}
XP_EXPECTED_MBR=${XP_EXPECTED_MBR:?}
XP_WINDOWS_PLAN=${XP_WINDOWS_PLAN:?}
fail() { printf '[XP_NTFS] STOP: %s\n' "$1" >&2; exit 1; }
value() { awk -F= -v key="$2" '$1==key {print $2; exit}' "$1"; }
work=$(mktemp -d)
mounted=no
cleanup() {
    [ "$mounted" = no ] || umount "$work/volume" || true
    rm -f "$work/before" "$work/expected" "$work/after" "$work/boot" "$work/readback" "$work/sector" "$work/accounts.cmd"
    rmdir "$work/volume" "$work" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
slot=$(value "$XP_WINDOWS_PLAN" windows_slot)
start=$(value "$XP_WINDOWS_PLAN" windows_start_lba)
sectors=$(value "$XP_WINDOWS_PLAN" windows_sectors)
dd if="$TARGET_DEVICE" of="$work/before" bs=512 count=1 2>/dev/null
cmp -s "$work/before" "$XP_EXPECTED_MBR" || fail 'MBR changed before NTFS preparation'
cp "$work/before" "$work/expected"
printf '\007' | dd of="$work/expected" bs=1 seek=$((450+(slot-1)*16)) conv=notrunc 2>/dev/null
dd if="$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin" of="$work/expected" bs=440 count=1 conv=notrunc 2>/dev/null
dd if="$work/expected" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc 2>/dev/null
sync
dd if="$TARGET_DEVICE" of="$work/after" bs=512 count=1 2>/dev/null
cmp -s "$work/expected" "$work/after" || fail 'NTFS MBR readback mismatch'
blockdev --rereadpt "$TARGET_DEVICE"
mdev -s
case "$TARGET_DEVICE" in *[0-9]) node="${TARGET_DEVICE}p${slot}" ;; *) node="${TARGET_DEVICE}${slot}" ;; esac
[ -b "$node" ] || fail 'partition node absent'
name=${node##*/}
[ "$(cat "/sys/class/block/$name/start")" = "$start" ] || fail 'partition start mismatch'
[ "$(cat "/sys/class/block/$name/size")" = "$sectors" ] || fail 'partition size mismatch'
[ "$(lsblk -dnro PKNAME "$node")" = "${TARGET_DEVICE##*/}" ] || fail 'partition parent mismatch'
mkntfs -Q -F -s 512 -c 4096 -H "$XP_BIOS_HEADS" -S "$XP_BIOS_SPT" -p "$start" -L Windows "$node"
dd if="$node" of="$work/boot" bs=512 count=16 2>/dev/null
# Retain mkntfs's BPB (disk identity, MFT positions, cluster and volume sizes).
dd if="$SCRIPT_DIR/xp-nt52-ntfs.bin" of="$work/boot" bs=1 skip=84 seek=84 count=8108 conv=notrunc 2>/dev/null
dd if="$work/boot" of="$node" bs=512 count=16 conv=notrunc 2>/dev/null
dd if="$work/boot" of="$node" bs=512 count=1 seek=$((sectors-1)) conv=notrunc 2>/dev/null
sync
dd if="$node" of="$work/readback" bs=512 count=16 2>/dev/null
cmp -s "$work/boot" "$work/readback" || fail 'NT52 NTFS bootstrap readback mismatch'
dd if="$work/boot" of="$work/sector" bs=512 count=1 2>/dev/null
dd if="$node" of="$work/readback" bs=512 skip=$((sectors-1)) count=1 2>/dev/null
cmp -s "$work/sector" "$work/readback" || fail 'NTFS backup boot sector mismatch'
modprobe ntfs3
mkdir "$work/volume"
mount -t ntfs3 "$node" "$work/volume"; mounted=yes
export XP_TARGET_ROOT="$work/volume" MTOOLS_IMAGE="$node"
sh "$SCRIPT_DIR/prepare_xp_local_source.sh"
if [ "${USOS_PLAN_PROFILE:-}" = xp-x86-sp3-uefi-csm ]; then
sh "$SCRIPT_DIR/xp_driver_stage.sh" apply || fail 'XP driver integration failed'
fi
XP_EXPECTED_MBR="$work/expected" sh "$SCRIPT_DIR/prepare_xp_windows_partition.sh"
if [ "${USOS_PLAN_PROFILE:-}" = xp-x86-sp3-uefi-csm ]; then
mkdir -p "$work/volume/USOS/XP"
cp "$SCRIPT_DIR/xp-pae.exe" "$work/volume/USOS/XP/pae.exe"
cp "$SCRIPT_DIR/xp-pae-LICENSE.txt" "$work/volume/USOS/XP/LICENSE.txt"
cmp -s "$SCRIPT_DIR/xp-pae.exe" "$work/volume/USOS/XP/pae.exe" || fail 'PAE helper readback mismatch'
# usos-xp.ini accounts: pae.exe runs this hidden at setup end and deletes it.
if [ -n "${XP_USER_SETTINGS:-}" ] && [ -z "${XP_CUSTOM_SIF:-}" ]; then
. "$SCRIPT_DIR/xp_user_settings.sh"
usos_xp_settings_accounts "$XP_USER_SETTINGS" "$work/accounts.cmd" || fail 'cannot render usos-xp.ini accounts'
cp "$work/accounts.cmd" "$work/volume/USOS/XP/usos-users.cmd"
cmp -s "$work/accounts.cmd" "$work/volume/USOS/XP/usos-users.cmd" || fail 'usos-users.cmd readback mismatch'
rm -f "$work/accounts.cmd"
printf '[XP_PAE] usos-users.cmd staged (accounts from usos-xp.ini, run hidden by pae.exe)\n'
fi
# Installer-chosen language (only that one is on the ESP); pae.exe falls back to English.
if [ -f /mnt/esp/EFI/USOS/lang-xp.ini ]; then
cp /mnt/esp/EFI/USOS/lang-xp.ini "$work/volume/USOS/XP/pae-strings.ini"
cmp -s /mnt/esp/EFI/USOS/lang-xp.ini "$work/volume/USOS/XP/pae-strings.ini" || fail 'PAE strings readback mismatch'
printf '[XP_PAE] strings=lang-xp.ini
'
else
printf '[XP_PAE] strings=built-in English (no lang-xp.ini on ESP)
'
fi
sync
umount "$work/volume"; mounted=no
blockdev --flushbufs "$TARGET_DEVICE" || fail 'cannot flush target disk buffers'
# Read-only remount: refuse zero-filled staged files, then flush again.
sh "$SCRIPT_DIR/xp_verify_target.sh" "$node" "$SCRIPT_DIR/xp-pae.exe" || fail 'post-write read-only verification failed'
else
sync
umount "$work/volume"; mounted=no
fi
printf '[XP_NTFS] PREPARED PASS native-NTFS=yes bootstrap=Microsoft-NT52 source-and-Windows=C:\n'
