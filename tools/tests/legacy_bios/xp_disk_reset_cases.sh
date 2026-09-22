#!/bin/sh
set -eu
fail() { echo "[RESET_TEST] FAIL: $1"; exit 1; }
. /usr/lib/usos/target_disk_identity.sh
[ "$(usos_disk_serial /dev/sdb)" = XP-TARGET-A ] || fail 'wrong fixture'
export TARGET_DEVICE=/dev/sdb USOS_DISK_DEVICE=/dev/sda XP_RESET_SNAPSHOT=/run/reset-test.snapshot
reset=/usr/lib/usos/xp_disk_reset.sh
reject() {
    if sh "$reset" "$1" >/run/reset-rejection.log 2>&1; then fail "$2 accepted"; fi
    grep -q "$3" /run/reset-rejection.log || { cat /run/reset-rejection.log; fail "$2 wrong refusal"; }
    printf '[RESET_TEST] PASS %s\n' "$2"
}
TARGET_DEVICE=/dev/sda
reject snapshot usos-exclusion 'USOS disk cannot'
TARGET_DEVICE=/dev/sdb1
reject snapshot partition-exclusion 'whole disk required'
TARGET_DEVICE=/dev/sdb
blockdev --setro /dev/sdb
reject snapshot readonly 'read-only target'
blockdev --setrw /dev/sdb
mkfs.fat -F 16 /dev/sdb1
mkdir /mnt/reset-mounted
mount -t vfat /dev/sdb1 /mnt/reset-mounted
reject snapshot mounted 'partition is mounted'
umount /mnt/reset-mounted
sh "$reset" snapshot
cp "$XP_RESET_SNAPSHOT/identity" /run/reset-original-identity
export XP_RESET_CONFIRMATION=NO
reject apply confirmation 'confirmation mismatch'
sed 's/^serial=.*/serial=WRONG/' /run/reset-original-identity > "$XP_RESET_SNAPSHOT/identity"
reject apply changed-identity 'identity changed'
cp /run/reset-original-identity "$XP_RESET_SNAPSHOT/identity"
printf '\001' | dd of=/dev/sdb bs=1 seek=100 conv=notrunc 2>/dev/null
reject apply changed-mbr 'metadata changed after selection'
printf '\000' | dd of=/dev/sdb bs=1 seek=100 conv=notrunc 2>/dev/null
size=$(usos_disk_size /dev/sdb)
printf '\001' | dd of=/dev/sdb bs=1 seek=$((size-512)) conv=notrunc 2>/dev/null
reject apply changed-backup 'backup metadata changed'
printf '\000' | dd of=/dev/sdb bs=1 seek=$((size-512)) conv=notrunc 2>/dev/null
dd if=/dev/sdb of=/run/reset-first bs=512 count=2048 2>/dev/null
dd if=/dev/sdb of=/run/reset-last bs=512 skip=$((size/512-2048)) count=2048 2>/dev/null
cmp -s /run/reset-first "$XP_RESET_SNAPSHOT/first" || fail 'negative cases changed first metadata'
cmp -s /run/reset-last "$XP_RESET_SNAPSHOT/last" || fail 'negative cases changed backup metadata'
XP_RESET_CONFIRMATION='FORMATUJ XP-TARGET-A'
sh "$reset" apply
export TARGET_SNAPSHOT=/run/reset-post.snapshot
sh /usr/lib/usos/target_disk_guard.sh snapshot
grep -q '^xpsetup_start_lba=2048$' "$TARGET_SNAPSHOT" || fail 'not a clean layout'
grep -q '^xpsetup_slot=1$' "$TARGET_SNAPSHOT" || fail 'old partition entry survived'
printf '[RESET_TEST] ALL PASS\n'
sync
