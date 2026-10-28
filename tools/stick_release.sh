#!/bin/sh
# Close every writable FAT / exFAT / NTFS mount before micro-Linux restarts
# or powers off (X470 2026-10-11: Windows 10 x86 phase 2 showed "Scanning
# and repairing drive" for the USOS stick).
#
# Linux vfat (and ntfs3 / exfat) mark a volume dirty while it is mounted
# read-write and clear the mark only on a clean remount read-only or
# unmount. `reboot -f` / `poweroff -f` do neither, so a session that ended
# with the stick ESP still mounted rw left its FAT32 dirty flag set
# (boot sector byte 0x41, bit 0) and the next Windows started autochk on the
# stick. Every restart / power-off of micro-Linux goes through this script.
#
#   stick_release.sh reboot|poweroff   close the mounts, then restart / power off
#   stick_release.sh ro                only remount read-only (stop(): the
#                                      emergency shell keeps reading the logs)
#   stick_release.sh list              print the mounts it would close (tests;
#                                      USOS_STICK_MOUNTS = another mounts file)
#
# Each remount / unmount runs in the background and is waited for at most
# 10 s (an unmount of DATA once hung in QEMU, tools/vista_disk_prepare.sh):
# the restart always happens.
action=${1:-ro}
mounts=${USOS_STICK_MOUNTS:-/proc/mounts}

usos_bounded() {
    "$@" >/dev/null 2>&1 &
    _pid=$!
    _n=0
    while kill -0 "$_pid" 2>/dev/null; do
        [ "$_n" -ge 20 ] && { printf '[STICK_RELEASE] %s still running after 10 s; continuing\n' "$*"; return 1; }
        sleep 0.5 2>/dev/null || sleep 1
        _n=$((_n + 1))
    done
    wait "$_pid"
}

# Writable FAT / exFAT / NTFS mount points, deepest first.
usos_writable_mounts() {
    [ -r "$mounts" ] || return 0
    awk '($3 == "vfat" || $3 == "msdos" || $3 == "exfat" || $3 == "ntfs3" || $3 == "ntfs" || $3 == "fuseblk") && ("," $4 ",") ~ /,rw,/ { print $2 }' "$mounts" |
        awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }'
}

if [ "$action" = list ]; then
    usos_writable_mounts
    exit 0
fi
sync
for mp in $(usos_writable_mounts); do
    mp=$(printf '%b' "$mp")
    if usos_bounded mount -o remount,ro "$mp"; then
        printf '[STICK_RELEASE] %s remounted read-only\n' "$mp"
    else
        printf '[STICK_RELEASE] %s could not be remounted read-only\n' "$mp"
    fi
    [ "$action" = ro ] && continue
    usos_bounded umount "$mp" && printf '[STICK_RELEASE] %s unmounted\n' "$mp"
done
sync

case "$action" in
    reboot)
        reboot -f 2>/dev/null || true
        sleep 3
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
        echo b > /proc/sysrq-trigger 2>/dev/null || true
        ;;
    poweroff)
        poweroff -f 2>/dev/null || true
        sleep 2
        halt -f 2>/dev/null || true
        ;;
esac
exit 0
