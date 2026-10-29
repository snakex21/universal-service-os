#!/bin/sh
# XP without firmware CSM (profile xp-x86-sp3-uefi-csmwrap, experimental;
# docs/design/csmwrap-integration.md). Runs after prepare_xp_target.sh PASSED
# on the same target: adds a small FAT16 EFI system partition (MBR type 0xEF)
# in the space the Windows plan left free at the end of the disk
# (USOS_XP_ESP_TAIL_SECTORS), with the pinned CSMWrap 3.1.2-usos18 (a MODIFIED
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
PINNED=0188057913ee7b4680027e45c53c45048deb8583c599c3c0672d98748704e0a4
# Windows 2000 diagnostic setup (USOS_W2K_DIAG=on, DATA w2k-diag.txt):
# CSMWrap 3.1.2-usos11-diag (usos11 + 0011 tick watcher + 0013 NMI snapshot,
# tools/vendor/csmwrap/3.1.2-usos11-diag) from the XP/2000 package.
DIAG_DIR=${USOS_W2K_DIR:-/usr/lib/usos/w2k-drivers}/csmwrap-diag
PINNED_DIAG=a100cae3ba4177dde7c4f183f2499b34171cb6f77af68439427003ae02485e7d
# Native NT 3.51 / 3.5 (USOS_NT_BOOTLOG=on, exported by w9x_csmwrap_prepare.sh
# only for a native NT 3.x target): the USOS pre-boot logger (own GPL,
# tools/nt_bootlog, diagnostic) becomes \EFI\BOOT\BOOTX64.EFI, CSMWrap moves
# to \EFI\BOOT\CSMWRAPX.EFI next to csmwrap.ini (the logger chainloads it),
# and \USOS\BOOTLOG.TXT starts empty (the logger sizes its ring on the
# first boot). Every other flow keeps CSMWrap as BOOTX64.EFI.
BOOTLOG_EFI=${USOS_NT_BOOTLOG_EFI:-${USOS_LIB_DIR:-/usr/lib/usos}/nt3/NTBOOTLG.EFI}
PINNED_BOOTLOG=5941eef0791bb3b85abe56fd6bd6db9e9067fddf39db3d9633980025ee5d1459
# The LGPL obligations travel with the binary: licence texts, SOURCES.txt
# (MODIFIED), the complete source archive and the USOS patches.
CSMWRAP_FILES='LICENSE-CSMWrap-LGPL-2.1.txt COPYING-SeaBIOS-LGPLv3.txt COPYING-SeaBIOS-GPLv3.txt SOURCES.txt csmwrap-3.1.2-src.tar.xz'

log() { printf '[XP_CSMWRAP] %s\n' "$*"; }
fail() { printf '[XP_CSMWRAP] STOP: %s\n' "$1" >&2; exit 1; }

for tool in dd od mkfs.fat mmd mcopy mdir sha256sum awk blockdev sync wc; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[ -r "$SRC/csmwrapx64.efi" ] || fail 'CSMWrap is missing on the USOS stick (EFI/USOS/csmwrap)'
[ "$(sha256sum "$SRC/csmwrapx64.efi" | awk '{print $1}')" = "$PINNED" ] || fail 'CSMWrap binary does not match the pinned 3.1.2-usos18 hash'
for file in $CSMWRAP_FILES; do
    [ -r "$SRC/$file" ] || fail "$file is missing next to CSMWrap"
done
ls "$SRC"/patches/*.patch >/dev/null 2>&1 || fail 'the CSMWrap patches are missing next to CSMWrap'
EFI_INPUT="$SRC/csmwrapx64.efi"
if [ "${USOS_W2K_DIAG:-off}" = on ]; then
    [ "${USOS_W2K_ACPI:-}" = on ] || fail 'the Windows 2000 diagnostic CSMWrap needs ACPI on'
    [ -r "$DIAG_DIR/csmwrapx64.efi" ] || fail 'the diagnostic CSMWrap is missing from the package'
    [ "$(sha256sum "$DIAG_DIR/csmwrapx64.efi" | awk '{print $1}')" = "$PINNED_DIAG" ] || fail 'diagnostic CSMWrap does not match the pinned 3.1.2-usos11-diag hash'
    ls "$DIAG_DIR"/patches/*.patch >/dev/null 2>&1 || fail 'the diagnostic CSMWrap patches are missing'
    EFI_INPUT="$DIAG_DIR/csmwrapx64.efi"
    log 'Windows 2000 DIAGNOSTIC CSMWrap 3.1.2-usos11-diag (tick watcher + NMI snapshot)'
fi
ls "$SRC"/licenses/*.txt >/dev/null 2>&1 || fail 'the CSMWrap licence notices are missing next to CSMWrap'
CSMWRAP_NAME=BOOTX64.EFI
if [ "${USOS_NT_BOOTLOG:-off}" = on ]; then
    [ -r "$BOOTLOG_EFI" ] || fail 'the NT pre-boot logger is missing (usr/lib/usos/nt3/NTBOOTLG.EFI)'
    [ "$(sha256sum "$BOOTLOG_EFI" | awk '{print $1}')" = "$PINNED_BOOTLOG" ] || fail 'the NT pre-boot logger does not match its pinned hash'
    CSMWRAP_NAME=CSMWRAPX.EFI
    log 'NT 3.x native: pre-boot logger as BOOTX64.EFI, CSMWrap as CSMWRAPX.EFI, empty USOS/BOOTLOG.TXT'
fi

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
# Windows 2000 with ACPI on (legacy_xp_staging.sh exports USOS_W2K_ACPI only
# in the 2000 flow): the RSDT gets an ACPI 1.0 FADT copy (revision 1, 116
# bytes; CSMWrap 3.1.2-usos11 patch 0006). The 2000 ACPI HALs copy the whole
# FADT into a 0x84-byte buffer, so a revision 3+ FADT overwrites their
# MADT/IOAPIC data in HAL phase 0 (black screen). XP and the rest: unchanged.
if [ "${USOS_W2K_ACPI:-}" = on ]; then
    printf 'acpi_legacy_fadt = true\r\n' >> "$ini"
    log 'csmwrap.ini acpi_legacy_fadt=true (Windows 2000 ACPI)'
fi
# Windows 9x (w9x_csmwrap_target.sh exports USOS_PCI_IRQ_ROUTING only there):
# CSMWrap routes PCI INTA#..INTD# to 8259 IRQs, writes Interrupt Line and
# ELCR and a matching $PIR, as a legacy BIOS POST does (patch 0015). 9x has
# no IRQ steering for current chipsets, so without it every PCI device with
# an interrupt pin gets Code 29. XP/2000/Vista and the rest: unchanged.
if [ "${USOS_PCI_IRQ_ROUTING:-}" = on ]; then
    printf 'pci_irq_routing = true\r\n' >> "$ini"
    log 'csmwrap.ini pci_irq_routing=true (Windows 9x PCI IRQs)'
fi
# Windows 9x (w9x_csmwrap_target.sh exports USOS_INT13_BOOT_DISK_ONLY only
# there; on by default since 2026-10-19): only the disk CSMWrap was loaded
# from gets a BIOS number (patch 0014), so a USB stick never shifts the 9x
# INT 13h units / drive letters and IOS writes no MBR stamp into it; USB
# sticks reach Windows through USOSUSB.MPD and the USB disk service, with
# hot-swap (patch 0022, active only with this key). XP/2000/Vista and the
# rest never get the key, so 0022 stays idle there (no pool, no port watch,
# empty controllers stopped as before).
if [ "${USOS_INT13_BOOT_DISK_ONLY:-}" = on ]; then
    printf 'int13_boot_disk_only = true\r\n' >> "$ini"
    log 'csmwrap.ini int13_boot_disk_only=true (Windows 9x: the boot disk is the only BIOS hard disk)'
fi
if [ "${USOS_W2K_DIAG:-off}" = on ]; then
    printf 'w2k_nmi_snapshot = true\r\n' >> "$ini"
    log 'csmwrap.ini w2k_nmi_snapshot=true (Windows 2000 diagnostic setup)'
fi
mmd -i "$image" ::/EFI ::/EFI/BOOT ::/CSMWRAP ::/CSMWRAP/patches ::/CSMWRAP/licenses || fail 'cannot create ESP folders'
mcopy -i "$image" "$EFI_INPUT" "::/EFI/BOOT/$CSMWRAP_NAME" || fail 'cannot copy CSMWrap'
if [ "$CSMWRAP_NAME" != BOOTX64.EFI ]; then
    mcopy -i "$image" "$BOOTLOG_EFI" ::/EFI/BOOT/BOOTX64.EFI || fail 'cannot copy the NT pre-boot logger'
    mmd -i "$image" ::/USOS || fail 'cannot create the USOS folder on the ESP'
    : > /tmp/csmwrap-bootlog.txt
    mcopy -i "$image" /tmp/csmwrap-bootlog.txt ::/USOS/BOOTLOG.TXT || fail 'cannot create USOS/BOOTLOG.TXT'
fi
mcopy -i "$image" "$ini" ::/EFI/BOOT/csmwrap.ini || fail 'cannot copy csmwrap.ini'
for file in $CSMWRAP_FILES; do
    mcopy -i "$image" "$SRC/$file" "::/CSMWRAP/$file" || fail "cannot copy $file"
done
for file in "$SRC"/patches/*.patch "$SRC"/licenses/*.txt; do
    sub=${file%/*}; sub=${sub##*/}
    mcopy -i "$image" "$file" "::/CSMWRAP/$sub/${file##*/}" || fail "cannot copy $sub/${file##*/}"
done
if [ "${USOS_W2K_DIAG:-off}" = on ]; then
    # The diagnostic binary's own series (same source archive).
    mmd -i "$image" ::/CSMWRAP/patches-diag || fail 'cannot create CSMWRAP/patches-diag'
    for file in "$DIAG_DIR"/patches/*.patch; do
        mcopy -i "$image" "$file" "::/CSMWRAP/patches-diag/${file##*/}" || fail "cannot copy patches-diag/${file##*/}"
    done
fi

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
mcopy -i "$image" "::/EFI/BOOT/$CSMWRAP_NAME" "$readback" || fail "read-back: cannot read $CSMWRAP_NAME"
[ "$(sha256sum "$readback" | awk '{print $1}')" = "$PINNED" ] || fail "read-back: $CSMWRAP_NAME differs"
if [ "$CSMWRAP_NAME" != BOOTX64.EFI ]; then
    rm -f "$readback"
    mcopy -i "$image" ::/EFI/BOOT/BOOTX64.EFI "$readback" || fail 'read-back: cannot read the logger BOOTX64.EFI'
    [ "$(sha256sum "$readback" | awk '{print $1}')" = "$PINNED_BOOTLOG" ] || fail 'read-back: the logger BOOTX64.EFI differs'
    mdir -i "$image" ::/USOS/BOOTLOG.TXT >/dev/null 2>&1 || fail 'read-back: USOS/BOOTLOG.TXT missing'
    log 'read-back: logger BOOTX64.EFI, CSMWRAPX.EFI and USOS/BOOTLOG.TXT PASS'
fi
mdir -i "$image" ::/EFI/BOOT || true
log "CSMWrap ESP PASS slot=$free start=$start; next boots: firmware -> this disk's UEFI entry -> CSMWrap -> XP"
