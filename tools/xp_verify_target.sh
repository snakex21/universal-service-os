#!/bin/sh
# Experimental XP (UEFI -> CSM) only. Runs AFTER the prepared NTFS volume was
# unmounted: flush block buffers, drop caches, remount READ-ONLY and refuse the
# target if any non-empty staged file reads back as all zeros (the signature of
# writes lost before reaching the disk). Finally unmount and flush again so the
# target can be powered off / moved safely. Never writes to the volume.
set -eu
node=${1:?partition node required}
expected_helper=${2:-}
fail() { printf '[XP_VERIFY] STOP: %s\n' "$1" >&2; exit 1; }
[ -b "$node" ] || fail 'partition node absent'
sync
blockdev --flushbufs "$node" || fail 'cannot flush partition buffers'
# Ensure the read-back below comes from the device, not from the page cache.
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
mnt=$(mktemp -d)
list=$(mktemp)
mounted=no
cleanup() {
    [ "$mounted" = no ] || umount "$mnt" || true
    rm -f "$list"
    rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mount -t ntfs3 -o ro "$node" "$mnt" || fail 'read-only remount failed'
mounted=yes
if [ -n "$expected_helper" ]; then
    cmp -s "$expected_helper" "$mnt/USOS/XP/pae.exe" || fail 'PAE helper differs after remount'
fi
find "$mnt" -type f -size +0 > "$list"
count=0
zero=0
while IFS= read -r file; do
    count=$((count + 1))
    # A file is all zeros when deleting NUL bytes leaves nothing.
    if [ "$(tr -d '\000' < "$file" | head -c 1 | wc -c)" -eq 0 ]; then
        printf '[XP_VERIFY] zero-filled: %s\n' "${file#"$mnt"}" >&2
        zero=$((zero + 1))
    fi
done < "$list"
[ "$count" -gt 0 ] || fail 'no staged files found on read-only remount'
umount "$mnt"; mounted=no
sync
blockdev --flushbufs "$node" || fail 'cannot flush partition buffers after verification'
[ "$zero" -eq 0 ] || fail "$zero staged file(s) read back as all zeros; do not boot this target"
printf '[XP_VERIFY] PASS files=%s zero_filled=0 remount=ro flushed=yes\n' "$count"
