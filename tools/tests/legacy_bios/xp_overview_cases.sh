#!/bin/sh
set -eu
fail() { echo "[OVERVIEW_TEST] FAIL: $1"; exit 1; }
. /usr/lib/usos/target_disk_identity.sh
. /usr/lib/usos/xp_detect_system.sh
[ "$(usos_disk_serial /dev/sdb)" = XP-TARGET-A ] || fail fixture
export TARGET_DEVICE=/dev/sdb
overview=/usr/lib/usos/xp_disk_overview.sh
mkdir /mnt/overview-test
mkfs.fat -F 16 /dev/sdb1
mount -t vfat /dev/sdb1 /mnt/overview-test
mkdir -p /mnt/overview-test/WINDOWS/system32/config
echo kernel > /mnt/overview-test/WINDOWS/system32/ntoskrnl.exe
echo registry > /mnt/overview-test/WINDOWS/system32/config/SYSTEM
sh "$overview" > /run/overview-busy
grep -q 'Status: IN USE' /run/overview-busy || fail busy
umount /mnt/overview-test
before=$(sha256sum /dev/sdb1)
sh "$overview" > /run/overview-free
cat /run/overview-free
grep -q 'Windows (system files)' /run/overview-free || fail windows
grep -q 'Readable file systems: 1' /run/overview-free || fail space
[ "$before" = "$(sha256sum /dev/sdb1)" ] || fail readonly
mkfs.ntfs -F -Q /dev/sdb1
mount -t ntfs3 /dev/sdb1 /mnt/overview-test
touch /mnt/overview-test/ntldr
umount /mnt/overview-test
before=$(sha256sum /dev/sdb1)
sh "$overview" > /run/overview-ntfs
cat /run/overview-ntfs
grep -q 'Windows boot files' /run/overview-ntfs || fail ntfs
[ "$before" = "$(sha256sum /dev/sdb1)" ] || fail ntfs-readonly
mkdir -p /run/detect-test/etc
printf 'PRETTY_NAME="Test Linux"\n' > /run/detect-test/etc/os-release
[ "$(usos_xp_detect_system /run/detect-test)" = 'Linux: Test Linux' ] || fail linux
rm /run/detect-test/etc/os-release
[ "$(usos_xp_detect_system /run/detect-test)" = 'No system detected' ] || fail empty
mkdir '/run/detect-test/$WIN_NT$.~LS'
[ "$(usos_xp_detect_system /run/detect-test)" = 'XP installation files' ] || fail source
echo '[OVERVIEW_TEST] ALL PASS'
