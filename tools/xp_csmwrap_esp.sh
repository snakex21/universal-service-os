#!/bin/sh
# XP without firmware CSM (profile xp-x86-sp3-uefi-csmwrap, experimental;
# docs/design/csmwrap-integration.md). Runs after prepare_xp_target.sh PASSED
# on the same target: adds a small FAT16 EFI system partition (MBR type 0xEF)
# in the space the Windows plan left free at the end of the disk
# (USOS_XP_ESP_TAIL_SECTORS), with the pinned CSMWrap 3.1.2-usos3 (a MODIFIED
# CSMWrap 3.1.2: quiet unless verbose = true, docs/research/csmwrap.md 6 and 7)
# as \EFI\BOOT\BOOTX64.EFI, its licences, source and patches in \CSMWRAP.
# The firmware then boots the target through
#   UEFI removable path -> CSMWrap -> SeaBIOS -> MBR (DL=80h) -> XP.
# The NTFS Windows partition stays the first MBR entry, so the ARC paths
# (multi(0)disk(0)rdisk(0)partition(1)) of WINNT.SIF, boot.ini and pae.exe are
# unchanged. CSMWrap is unsigned: Secure Boot must be off.
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
TAIL=${USOS_XP_ESP_TAIL_SECTORS:?USOS_XP_ESP_TAIL_SECTORS is required}
SRC=${USOS_CSMWRAP_DIR:-/mnt/esp/EFI/USOS/csmwrap}
ESP_SECTORS=131072
PINNED=bbf05216af896e24e5dd9da21d89bd063c17d1dab42f83561abc8cd49844de5f
# The LGPL obligations travel with the binary: licence texts, SOURCES.txt
# (MODIFIED), the complete source archive and the USOS patches.
CSMWRAP_FILES='LICENSE-CSMWrap-LGPL-2.1.txt COPYING-SeaBIOS-LGPLv3.txt COPYING-SeaBIOS-GPLv3.txt SOURCES.txt csmwrap-3.1.2-src.tar.xz'

log() { printf '[XP_CSMWRAP] %s\n' "$*"; }
fail() { printf '[XP_CSMWRAP] STOP: %s\n' "$1" >&2; exit 1; }

for tool in dd od mkfs.fat mmd mcopy mdir sha256sum awk blockdev sync wc; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[ -r "$SRC/csmwrapx64.efi" ] || fail 'CSMWrap is missing on the USOS stick (EFI/USOS/csmwrap)'
[ "$(sha256sum "$SRC/csmwrapx64.efi" | awk '{print $1}')" = "$PINNED" ] || fail 'CSMWrap binary does not match the pinned 3.1.2-usos3 hash'
for file in $CSMWRAP_FILES; do
    [ -r "$SRC/$file" ] || fail "$file is missing next to CSMWrap"
done
ls "$SRC"/patches/*.patch >/dev/null 2>&1 || fail 'the CSMWrap patches are missing next to CSMWrap'
ls "$SRC"/licenses/*.txt >/dev/null 2>&1 || fail 'the CSMWrap licence notices are missing next to CSMWrap'

size=$(blockdev --getsize64 "$TARGET_DEVICE") || fail 'cannot read the target size'
total=$((size / 512))
start=$(( (total - TAIL + 2047) / 2048 * 2048 ))
end=$((start + ESP_SECTORS))
[ "$end" -le "$total" ] || fail 'no room for the CSMWrap ESP at the end of the disk'

mbr=/tmp/csmwrap-mbr.bin
dd if="$TARGET_DEVICE" of="$mbr" bs=512 count=1 2>/dev/null || fail 'cannot read the MBR'
[ "$(od -An -tx1 -j510 -N2 "$mbr" | tr -d ' \n')" = 55aa ] || fail 'the target MBR has no signature'
free=0
for slot in 1 2 3 4; do
    off=$((446 + 16 * (slot - 1)))
    type=$(od -An -tu1 -j$((off + 4)) -N1 "$mbr" | tr -d ' \n')
    first=$(od -An -tu4 -j$((off + 8)) -N4 "$mbr" | tr -d ' \n')
    count=$(od -An -tu4 -j$((off + 12)) -N4 "$mbr" | tr -d ' \n')
    if [ "$type" = 0 ]; then
        [ "$free" -ne 0 ] || free=$slot
        continue
    fi
    [ "$type" != 239 ] || fail 'the target already has an EFI system partition'
    if [ $((first + count)) -gt "$start" ] && [ "$first" -lt "$end" ]; then
        fail "partition $slot overlaps the CSMWrap ESP area (use the whole-disk mode)"
    fi
    log "MBR slot $slot type=$type start=$first sectors=$count"
done
[ "$free" -ne 0 ] || fail 'no free MBR slot for the CSMWrap ESP'
log "ESP slot=$free start=$start sectors=$ESP_SECTORS disk_sectors=$total"

# Format first, then publish the partition entry.
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 seek="$start" count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the ESP area'
mkfs.fat -I -F 16 -n CSMWRAP --offset "$start" "$TARGET_DEVICE" $((ESP_SECTORS / 2)) >/dev/null || fail 'cannot format the CSMWrap ESP'
image="$TARGET_DEVICE@@$((start * 512))"
ini=/tmp/csmwrap.ini
# Quiet by default (X470 PASS 2026-09-27 with verbose on). Diagnostics: an
# empty EFI\USOS\csmwrap-verbose.flag on the USOS stick turns CSMWrap's
# on-screen log back on for the next prepared target. Serial stays off (no
# port on most boards).
VERBOSE_FLAG=${USOS_CSMWRAP_VERBOSE_FLAG:-/mnt/esp/EFI/USOS/csmwrap-verbose.flag}
verbose=false
[ ! -e "$VERBOSE_FLAG" ] || verbose=true
log "csmwrap.ini verbose=$verbose"
printf 'serial = false\r\nverbose = %s\r\n' "$verbose" > "$ini"
mmd -i "$image" ::/EFI ::/EFI/BOOT ::/CSMWRAP ::/CSMWRAP/patches ::/CSMWRAP/licenses || fail 'cannot create ESP folders'
mcopy -i "$image" "$SRC/csmwrapx64.efi" ::/EFI/BOOT/BOOTX64.EFI || fail 'cannot copy CSMWrap'
mcopy -i "$image" "$ini" ::/EFI/BOOT/csmwrap.ini || fail 'cannot copy csmwrap.ini'
for file in $CSMWRAP_FILES; do
    mcopy -i "$image" "$SRC/$file" "::/CSMWRAP/$file" || fail "cannot copy $file"
done
for file in "$SRC"/patches/*.patch "$SRC"/licenses/*.txt; do
    sub=${file%/*}; sub=${sub##*/}
    mcopy -i "$image" "$file" "::/CSMWRAP/$sub/${file##*/}" || fail "cannot copy $sub/${file##*/}"
done

le32() {
    v=$1
    printf "\\$(printf %03o $((v & 255)))\\$(printf %03o $(((v >> 8) & 255)))\\$(printf %03o $(((v >> 16) & 255)))\\$(printf %03o $(((v >> 24) & 255)))"
}
entry=/tmp/csmwrap-entry.bin
{ printf '\000\376\377\377\357\376\377\377'; le32 "$start"; le32 "$ESP_SECTORS"; } > "$entry"
[ "$(wc -c < "$entry" | tr -d ' ')" = 16 ] || fail 'internal error: MBR entry size'
dd if="$entry" of="$TARGET_DEVICE" bs=1 seek=$((446 + 16 * (free - 1))) count=16 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the ESP partition entry'
sync
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true

# Read back: the entry, and CSMWrap byte-exact from the new FAT.
dd if="$TARGET_DEVICE" of="$mbr" bs=512 count=1 2>/dev/null || fail 'cannot read back the MBR'
off=$((446 + 16 * (free - 1)))
[ "$(od -An -tu1 -j$((off + 4)) -N1 "$mbr" | tr -d ' \n')" = 239 ] || fail 'read-back: ESP type not set'
[ "$(od -An -tu4 -j$((off + 8)) -N4 "$mbr" | tr -d ' \n')" = "$start" ] || fail 'read-back: ESP start differs'
readback=/tmp/csmwrap-readback.efi
rm -f "$readback"
mcopy -i "$image" ::/EFI/BOOT/BOOTX64.EFI "$readback" || fail 'read-back: cannot read BOOTX64.EFI'
[ "$(sha256sum "$readback" | awk '{print $1}')" = "$PINNED" ] || fail 'read-back: BOOTX64.EFI differs'
mdir -i "$image" ::/EFI/BOOT || true
log "CSMWrap ESP PASS slot=$free start=$start; next boots: firmware -> this disk's UEFI entry -> CSMWrap -> XP"
