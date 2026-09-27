#!/bin/sh
# Vista SP2 x64 without firmware CSM (profile vista-x64-sp2-uefi-csmwrap,
# experimental; docs/design/csmwrap-integration.md section 10). Called by
# tools/vista_csmwrap_prepare.sh after the user picked and confirmed the disk.
#
# Writes ONLY $TARGET_DEVICE:
#   MBR     USOS MBR code (boots the active partition), new disk signature
#   slot 1  NTFS "USOS-VISTA", active, 1 GiB before the CSMWrap ESP: the PE10
#           donor's BIOS boot files (bootmgr from Windows\Boot\PCAT, boot\bcd,
#           boot\boot.sdi) and its Setup image (sources\boot.wim) with the
#           USOS Vista helpers added to \Windows\System32 (what wimboot
#           injects on the UEFI path)
#   slot 2  CSMWrap ESP, 64 MiB at the end (tools/xp_csmwrap_esp.sh, unchanged)
#   the space before slot 1 stays unallocated: Vista Setup installs there.
# Boot chain: firmware -> the disk's \EFI\BOOT\BOOTX64.EFI (CSMWrap) -> SeaBIOS
# (card VBIOS POSTed) -> MBR -> NT60 NTFS boot code -> bootmgr -> PE10 in RAM
# -> USOS Vista installer -> Vista Setup in BIOS mode. The installer clears the
# staging partition's active flag before Setup (so Vista puts its boot files on
# its own partition) and removes the staging partition after a good install.
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
DONOR_ISO=${VISTA_DONOR_ISO:?VISTA_DONOR_ISO is required}
REQUEST_DIR=${VISTA_REQUEST_DIR:?VISTA_REQUEST_DIR is required}
SUPPORT_DIR=${VISTA_SUPPORT_DIR:-/mnt/esp/EFI/USOS/windows-native}
ANSWER_XML=${VISTA_ANSWER_XML:-}
LIB=${USOS_LIB_DIR:-/usr/lib/usos}
ESP_TAIL=133120
STAGING_SECTORS=2097152
MIN_SECTORS=33554432

log() { printf '[VISTA_CSMWRAP] %s\n' "$*"; }
fail() { printf '[VISTA_CSMWRAP] STOP: %s\n' "$1" >&2; exit 1; }

for tool in dd od cmp sfdisk mkntfs mount umount losetup wimlib-imagex cpio sha256sum blockdev awk mdev; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
for file in "$LIB/xp-geometry-fix-mbr-440.bin" "$LIB/vista-nt60-ntfs.bin" "$LIB/xp_csmwrap_esp.sh" "$REQUEST_DIR/usos-source.ini" "$SUPPORT_DIR/support.cpio" "$SUPPORT_DIR/vista-support.cpio" "$DONOR_ISO"; do
    [ -r "$file" ] || fail "missing: $file"
done
[ "$(wc -c < "$LIB/xp-geometry-fix-mbr-440.bin" | tr -d ' ')" = 440 ] || fail 'USOS MBR code must be 440 bytes'
[ "$(wc -c < "$LIB/vista-nt60-ntfs.bin" | tr -d ' ')" = 8192 ] || fail 'NT60 NTFS boot code must be 8192 bytes'
[ "$(dd if="$REQUEST_DIR/usos-source.ini" bs=8 count=1 2>/dev/null)" = USOSISO1 ] || fail 'usos-source.ini is not a USOS source binding'
if awk -v d="$TARGET_DEVICE" 'index($1, d) == 1 { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts; then
    fail 'a partition of the selected disk is mounted; no disk was changed'
fi

size=$(blockdev --getsize64 "$TARGET_DEVICE") || fail 'cannot read the target size'
total=$((size / 512))
[ "$total" -ge "$MIN_SECTORS" ] || fail 'the selected disk is smaller than 16 GiB; no disk was changed'
# MBR: the Vista partition must end below 2 TiB.
[ "$total" -le 4294967295 ] || fail 'the selected disk is larger than 2 TiB (MBR); no disk was changed'
esp_start=$(( (total - ESP_TAIL + 2047) / 2048 * 2048 ))
staging_start=$(( (esp_start - STAGING_SECTORS) / 2048 * 2048 ))
staging_sectors=$((esp_start - staging_start))
log "disk_sectors=$total staging_start=$staging_start staging_sectors=$staging_sectors esp_start=$esp_start"

work=/run/vista-csmwrap
rm -rf "$work"
mkdir -p "$work/staging" "$work/donor" "$work/inject"
cleanup() {
    umount "$work/donor" 2>/dev/null || true
    [ -z "${loop:-}" ] || losetup -d "$loop" 2>/dev/null || true
    umount "$work/staging" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# 1. Partition table: erase the old one (both GPT copies), then a new MBR.
dd if=/dev/zero of="$TARGET_DEVICE" bs=1048576 count=1 conv=fsync 2>/dev/null || fail 'cannot erase the partition table'
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 seek=$((total - 2048)) count=2048 conv=fsync 2>/dev/null || fail 'cannot erase the backup partition table'
le32() {
    v=$1
    printf "\\$(printf %03o $((v & 255)))\\$(printf %03o $(((v >> 8) & 255)))\\$(printf %03o $(((v >> 16) & 255)))\\$(printf %03o $(((v >> 24) & 255)))"
}
signature=0
while [ "$signature" -eq 0 ]; do
    signature=$(od -An -tu4 -N4 /dev/urandom | tr -d ' \n')
done
mbr=$work/mbr.bin
{
    cat "$LIB/xp-geometry-fix-mbr-440.bin"
    le32 "$signature"
    printf '\000\000'
    printf '\200\376\377\377\007\376\377\377'; le32 "$staging_start"; le32 "$staging_sectors"
    dd if=/dev/zero bs=48 count=1 2>/dev/null
    printf '\125\252'
} > "$mbr"
[ "$(wc -c < "$mbr" | tr -d ' ')" = 512 ] || fail 'internal error: MBR size'
dd if="$mbr" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the MBR'
dd if="$TARGET_DEVICE" of="$work/mbr.readback" bs=512 count=1 2>/dev/null
cmp -s "$mbr" "$work/mbr.readback" || fail 'MBR readback mismatch'
signature_hex=$(od -An -tx4 -j440 -N4 "$mbr" | tr -d ' \n')
log "MBR PASS signature=$signature_hex"
blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true
mdev -s 2>/dev/null || true
sleep 1
case "$TARGET_DEVICE" in *[0-9]) node="${TARGET_DEVICE}p1" ;; *) node="${TARGET_DEVICE}1" ;; esac
[ -b "$node" ] || fail 'the staging partition node did not appear'
name=${node##*/}
[ "$(cat "/sys/class/block/$name/start")" = "$staging_start" ] || fail 'staging partition start mismatch'
[ "$(cat "/sys/class/block/$name/size")" = "$staging_sectors" ] || fail 'staging partition size mismatch'

# 2. NTFS with the NT60 boot code (loads BOOTMGR); mkntfs's BPB is kept.
mkntfs -Q -F -s 512 -c 4096 -H 255 -S 63 -p "$staging_start" -L USOS-VISTA "$node" >/dev/null || fail 'cannot format the staging partition'
dd if="$node" of="$work/boot" bs=512 count=16 2>/dev/null
dd if="$LIB/vista-nt60-ntfs.bin" of="$work/boot" bs=1 skip=84 seek=84 count=8108 conv=notrunc 2>/dev/null
dd if="$work/boot" of="$node" bs=512 count=16 conv=notrunc 2>/dev/null
dd if="$work/boot" of="$node" bs=512 count=1 seek=$((staging_sectors - 1)) conv=notrunc 2>/dev/null
sync
dd if="$node" of="$work/boot.readback" bs=512 count=16 2>/dev/null
cmp -s "$work/boot" "$work/boot.readback" || fail 'NT60 boot code readback mismatch'
log 'NT60 NTFS boot code PASS'

# 3. The PE10 donor's boot files.
modprobe ntfs3 2>/dev/null || true
modprobe udf 2>/dev/null || true
modprobe loop 2>/dev/null || true
mount -t ntfs3 "$node" "$work/staging" || fail 'cannot mount the staging partition'
loop=$(losetup -f) || fail 'no free loop device for the PE10 donor'
losetup -r "$loop" "$DONOR_ISO" || fail 'cannot attach the PE10 donor'
mount -t udf -o ro "$loop" "$work/donor" 2>/dev/null || mount -t iso9660 -o ro "$loop" "$work/donor" || fail 'cannot mount the PE10 donor'
pick() { find "$work/donor" -type f | awk -v want="$1" -v root="$work/donor" 'tolower(substr($0, length(root) + 1)) == want { print; exit }'; }
bcd=$(pick /boot/bcd); sdi=$(pick /boot/boot.sdi); wim=$(pick /sources/boot.wim)
[ -n "$bcd" ] && [ -n "$sdi" ] && [ -n "$wim" ] || fail 'the PE10 donor lacks boot\bcd, boot\boot.sdi or sources\boot.wim'
boot_index=$(wimlib-imagex info "$wim" --header 2>/dev/null | awk -F'[: ]+' 'tolower($0) ~ /^boot index/ { print $NF; exit }')
case "$boot_index" in ''|0|*[!0-9]*) fail 'the PE10 donor boot.wim has no boot image' ;; esac
mkdir -p "$work/staging/boot" "$work/staging/sources" "$work/pcat"
wimlib-imagex extract "$wim" "$boot_index" /Windows/Boot/PCAT/bootmgr --dest-dir="$work/pcat" --no-acls >/dev/null || fail 'cannot take bootmgr from the PE10 donor'
cp "$work/pcat/bootmgr" "$work/staging/bootmgr" && cmp -s "$work/pcat/bootmgr" "$work/staging/bootmgr" || fail 'bootmgr copy failed'
cp "$bcd" "$work/staging/boot/bcd" && cmp -s "$bcd" "$work/staging/boot/bcd" || fail 'BCD copy failed'
cp "$sdi" "$work/staging/boot/boot.sdi" && cmp -s "$sdi" "$work/staging/boot/boot.sdi" || fail 'boot.sdi copy failed'
log "PE10 boot files PASS boot_index=$boot_index"
wimlib-imagex export "$wim" "$boot_index" "$work/staging/sources/boot.wim" --boot >/dev/null || fail 'cannot copy the PE10 Setup image'

# 4. What the UEFI path's wimboot puts into \Windows\System32 (src/flow/plan.zig
# wimbootPlan .vista): support.cpio, vista-support.cpio, the flags, the source
# binding; plus the CSMWrap flag, the target record and the answer file.
( cd "$work/inject" && cpio -idm < "$SUPPORT_DIR/support.cpio" 2>/dev/null && cpio -idm < "$SUPPORT_DIR/vista-support.cpio" 2>/dev/null ) || fail 'cannot unpack the USOS WinPE helpers'
[ -r "$work/inject/usos-vista-install.exe" ] && [ -r "$work/inject/winpeshl.ini" ] || fail 'the USOS WinPE helpers are incomplete'
printf '1\r\n' > "$work/inject/usos-modern-vista.flag"
printf '1\r\n' > "$work/inject/usos-external-pe10.flag"
printf '1\r\n' > "$work/inject/usos-vista-csmwrap.flag"
cp "$REQUEST_DIR/usos-source.ini" "$work/inject/usos-source.ini"
printf 'disk_signature=%s\r\nstaging_start=%s\r\nstaging_sectors=%s\r\nesp_start=%s\r\ndisk_sectors=%s\r\n' "$signature_hex" "$staging_start" "$staging_sectors" "$esp_start" "$total" > "$work/inject/usos-vista-target.ini"
if [ -n "$ANSWER_XML" ]; then
    [ -r "$ANSWER_XML" ] || fail 'the answer file is missing'
    cp "$ANSWER_XML" "$work/inject/usos-unattend.xml"
    log "answer file added ($(wc -c < "$ANSWER_XML" | tr -d ' ') bytes)"
fi
commands=$work/update.txt
: > "$commands"
for file in "$work/inject"/*; do
    [ -f "$file" ] || continue
    printf 'add "%s" "/Windows/System32/%s"\n' "$file" "${file##*/}" >> "$commands"
done
wimlib-imagex update "$work/staging/sources/boot.wim" 1 < "$commands" >/dev/null || fail 'cannot add the USOS helpers to the PE10 image'
rm -rf "$work/check"; mkdir -p "$work/check"
wimlib-imagex extract "$work/staging/sources/boot.wim" 1 /Windows/System32/winpeshl.ini /Windows/System32/usos-vista-csmwrap.flag /Windows/System32/usos-vista-target.ini /Windows/System32/usos-vista-install.exe --dest-dir="$work/check" --no-acls >/dev/null || fail 'read-back: the helpers are not in the PE10 image'
for file in winpeshl.ini usos-vista-target.ini usos-vista-install.exe; do
    cmp -s "$work/inject/$file" "$work/check/$file" || fail "read-back: $file differs in the PE10 image"
done
rm -f "$work/inject/usos-unattend.xml"
log "PE10 image PASS files=$(wc -l < "$commands" | tr -d ' ')"
sync
umount "$work/donor"; losetup -d "$loop"; loop=''
umount "$work/staging"
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true

# 5. The CSMWrap ESP at the end (the XP script, unchanged: slot 2, 64 MiB).
TARGET_DEVICE=$TARGET_DEVICE USOS_XP_ESP_TAIL_SECTORS=$ESP_TAIL sh "$LIB/xp_csmwrap_esp.sh" || fail 'the CSMWrap ESP could not be created'

# 6. Read back the final table: slot 1 active NTFS staging, slot 2 ESP.
dd if="$TARGET_DEVICE" of="$work/mbr.final" bs=512 count=1 2>/dev/null
[ "$(od -An -tx1 -j446 -N1 "$work/mbr.final" | tr -d ' \n')" = 80 ] || fail 'read-back: staging partition is not active'
[ "$(od -An -tu1 -j450 -N1 "$work/mbr.final" | tr -d ' \n')" = 7 ] || fail 'read-back: staging partition type'
[ "$(od -An -tu1 -j466 -N1 "$work/mbr.final" | tr -d ' \n')" = 239 ] || fail 'read-back: CSMWrap ESP is not in slot 2'
[ "$(od -An -tu4 -j470 -N4 "$work/mbr.final" | tr -d ' \n')" = "$esp_start" ] || fail 'read-back: CSMWrap ESP start'
sync
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true
log "PREPARED PASS signature=$signature_hex free_for_vista_sectors=$((staging_start - 2048))"
