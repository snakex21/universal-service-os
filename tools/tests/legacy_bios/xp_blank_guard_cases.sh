#!/bin/sh
set -eu
fail() { echo "[BLANK_GUARD_TEST] FAIL: $1"; exit 1; }
. /usr/lib/usos/target_disk_identity.sh
[ "$(usos_disk_serial /dev/sdb)" = XP-TARGET-A ] || fail 'fixture identity'
export TARGET_DEVICE=/dev/sdb USOS_DISK_DEVICE=/dev/sda TARGET_SNAPSHOT=/run/blank.snapshot XP_ALLOW_EMPTY=yes
guard=/usr/lib/usos/target_disk_guard.sh
reject() {
    if sh "$guard" "$1" > /run/rejection.log 2>&1; then fail "$2 was accepted"; fi
    grep -q "$3" /run/rejection.log || { cat /run/rejection.log; fail "$2 wrong rejection"; }
    printf '[BLANK_GUARD_TEST] PASS %s\n' "$2"
}
XP_ALLOW_EMPTY=no
reject snapshot disabled 'valid DOS MBR'
XP_ALLOW_EMPTY=yes
sh "$guard" snapshot
cp "$TARGET_SNAPSHOT" /run/original.snapshot
export TARGET_CONFIRMATION=NO
reject pre-write confirmation 'confirmation mismatch'
sed 's/^serial=.*/serial=WRONG/' /run/original.snapshot > "$TARGET_SNAPSHOT"
reject pre-write identity 'resolves to 0 disks'
cp /run/original.snapshot "$TARGET_SNAPSHOT"
printf '\001' | dd of=/dev/sdb bs=1 seek=100 conv=notrunc 2>/dev/null
reject pre-write changed-mbr 'nonzero metadata'
printf '\000' | dd of=/dev/sdb bs=1 seek=100 conv=notrunc 2>/dev/null
printf 'EFI PART' | dd of=/dev/sdb bs=1 seek=512 conv=notrunc 2>/dev/null
reject snapshot gpt-header 'nonzero metadata'
dd if=/dev/zero of=/dev/sdb bs=1 seek=512 count=8 conv=notrunc 2>/dev/null
size=$(usos_disk_size /dev/sdb)
printf '\001' | dd of=/dev/sdb bs=1 seek=$((size - 512)) conv=notrunc 2>/dev/null
reject snapshot backup-metadata 'nonzero metadata'
printf '\000' | dd of=/dev/sdb bs=1 seek=$((size - 512)) conv=notrunc 2>/dev/null
sh "$guard" snapshot
cmp -s "$TARGET_SNAPSHOT" /run/original.snapshot || fail 'snapshot changed after rejection cases'
printf '[BLANK_GUARD_TEST] ALL PASS\n'
sync
