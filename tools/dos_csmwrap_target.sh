#!/bin/sh
# MS-DOS 6.22 and Windows 3.1/3.11 from the UEFI menu on a PC without firmware
# CSM (profile w9x-uefi-csmwrap's DOS recipe, experimental;
# docs/win9x-modern-2026-09-30.md section 4c). Called by
# tools/w9x_csmwrap_prepare.sh after the user picked and confirmed the disk;
# the same shape as tools/w9x_csmwrap_target.sh.
#
# Writes ONLY $TARGET_DEVICE:
#   MBR     USOS MBR code, new disk signature
#   slot 1  FAT16 (type 06h), active, from LBA 2048 (255 heads / 63 sectors)
#   slot 2  CSMWrap ESP, 64 MiB at the end (tools/xp_csmwrap_esp.sh)
# Files on C:
#   IO.SYS, MSDOS.SYS  the first two root entries (copied from the boot
#                      floppy first, so MS-DOS SYS can put its files there)
#   \USOSDOS           INSTALL.BAT and the other EFI\USOS\dos-native\msdos
#                      helpers, CSMWRAP.TAG, DOSFILES = the MS-DOS ISO root,
#                      WINSETUP = the Windows 3.x ISO root (one directory
#                      level kept), EARLY.TAG for Windows 1.0x-3.0,
#                      PROGRAMS (DATA),
#                      MEMDISK and BOOT.IMG = the MS-DOS 6.22 El Torito
#                      floppy with our AUTOEXEC.BAT / CONFIG.SYS
#   syslinux (boot sector, LDLINUX.SYS/.C32, SYSLINUX.CFG): MEMDISK + BOOT.IMG
# First boot: CSMWrap -> syslinux -> MEMDISK -> MS-DOS from A: ->
# C:\USOSDOS\INSTALL.BAT in disk mode (USRC=C:\USOSDOS, USYS=A:\, UDISK=1):
# SYS C:, the syslinux files go, PREPDOS, CONFIG/AUTOEXEC, restart. Windows
# 3.x Setup then starts from C: (W3START.BAT, batch Setup /H:USOS.SHH).
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
DOS_ISO=${W9X_SOURCE_ISO:?W9X_SOURCE_ISO is required}
WIN3_ISO=${DOS_WIN3_ISO:-}
WIN_EARLY=${DOS_WIN_EARLY:-}
PROGRAMS_DIR=${DOS_PROGRAMS_DIR:-}
SIZE_MIB=${DOS_SIZE_MIB:-256}
ESP_DIR=${W9X_ESP_DIR:-/mnt/esp/EFI/USOS}
LIB=${USOS_LIB_DIR:-/usr/lib/usos}
ESP_TAIL=133120

MTOOLS_SKIP_CHECK=1
export MTOOLS_SKIP_CHECK
log() { printf '[DOS_CSMWRAP] %s\n' "$*"; }
fail() { printf '[DOS_CSMWRAP] STOP: %s\n' "$1" >&2; exit 1; }

for tool in dd od mkfs.fat mcopy mdel mattrib mdir syslinux mount umount losetup blockdev awk sync wc; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
HELPERS="$ESP_DIR/dos-native/msdos"
for file in "$LIB/xp-geometry-fix-mbr-440.bin" "$LIB/xp_csmwrap_esp.sh" "$ESP_DIR/dos-native/memdisk" \
    "$HELPERS/INSTALL.BAT" "$HELPERS/PREPDOS.BAT" "$HELPERS/REBOOT.COM" "$HELPERS/VBMOUSE.EXE" "$HELPERS/USOSKEY.COM" "$DOS_ISO"; do
    [ -r "$file" ] || fail "missing: $file"
done
[ -z "$WIN3_ISO" ] || [ -r "$WIN3_ISO" ] || fail "missing: $WIN3_ISO"
case "$SIZE_MIB" in 128|256|512) ;; *) fail "unexpected partition size: $SIZE_MIB" ;; esac
if awk -v d="$TARGET_DEVICE" 'index($1, d) == 1 { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts; then
    fail 'a partition of the selected disk is mounted; no disk was changed'
fi

work=/run/dos-csmwrap
rm -rf "$work"
mkdir -p "$work/dos" "$work/win" "$work/c"
cleanup() {
    umount "$work/c" 2>/dev/null || true
    umount "$work/dos" 2>/dev/null || true
    umount "$work/win" 2>/dev/null || true
    for loop in ${part_loop:-} ${dos_loop:-} ${win_loop:-}; do losetup -d "$loop" 2>/dev/null || true; done
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------- the sources
dos_loop=$(losetup -f) || fail 'no free loop device for the MS-DOS ISO'
losetup -r "$dos_loop" "$DOS_ISO" || fail 'cannot attach the MS-DOS ISO'
mount -t iso9660 -o ro "$dos_loop" "$work/dos" || fail 'cannot mount the MS-DOS ISO'
[ -f "$work/dos/SYS.COM" ] || [ -f "$work/dos/sys.com" ] || fail 'the MS-DOS ISO has no SYS.COM in its root'
if [ -n "$WIN3_ISO" ]; then
    win_loop=$(losetup -f) || fail 'no free loop device for the Windows 3.x ISO'
    losetup -r "$win_loop" "$WIN3_ISO" || fail 'cannot attach the Windows 3.x ISO'
    mount -t iso9660 -o ro "$win_loop" "$work/win" || fail 'cannot mount the Windows 3.x ISO'
    [ -f "$work/win/SETUP.EXE" ] || [ -f "$work/win/setup.exe" ] || fail 'the Windows 3.x ISO has no SETUP.EXE in its root'
fi

floppy="$work/BOOT.IMG"
brvd="$work/brvd.bin"
dd if="$DOS_ISO" of="$brvd" bs=2048 skip=17 count=1 2>/dev/null || fail 'cannot read the ISO boot record'
[ "$(dd if="$brvd" bs=1 skip=7 count=23 2>/dev/null)" = 'EL TORITO SPECIFICATION' ] || fail 'the MS-DOS ISO is not El Torito bootable'
catalog=$(od -An -tu4 -j71 -N4 "$brvd" | tr -d ' \n')
entry="$work/catalog.bin"
dd if="$DOS_ISO" of="$entry" bs=2048 skip="$catalog" count=1 2>/dev/null || fail 'cannot read the boot catalog'
[ "$(od -An -tx1 -j32 -N2 "$entry" | tr -d ' \n')" = 8802 ] || fail 'the CD boot image is not a bootable 1.44 MB floppy'
rba=$(od -An -tu4 -j40 -N4 "$entry" | tr -d ' \n')
dd if="$DOS_ISO" of="$floppy" bs=2048 skip="$rba" count=720 2>/dev/null || fail 'cannot read the CD boot floppy'
[ "$(dd if="$floppy" bs=1 skip=3 count=8 2>/dev/null)" = MSDOS6.2 ] || fail 'the MS-DOS ISO must boot an MS-DOS 6.22 floppy'
for name in IO.SYS MSDOS.SYS COMMAND.COM; do
    mcopy -n -i "$floppy" "::/$name" "$work/$name" 2>/dev/null || fail "the boot floppy has no $name"
done

# ---------------------------------------------------------------- the disk
size=$(blockdev --getsize64 "$TARGET_DEVICE") || fail 'cannot read the target size'
total=$((size / 512))
[ "$total" -le 4294967295 ] || fail 'the selected disk is larger than 2 TiB (MBR); no disk was changed'
esp_start=$(( (total - ESP_TAIL + 2047) / 2048 * 2048 ))
part_start=2048
part_sectors=$((SIZE_MIB * 2048))
[ $((part_start + part_sectors)) -le "$esp_start" ] || fail 'the selected disk is too small; no disk was changed'
log "disk_sectors=$total part_start=$part_start part_sectors=$part_sectors esp_start=$esp_start"

dd if=/dev/zero of="$TARGET_DEVICE" bs=512 count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the disk start'
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 seek=$((total - 2048)) count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the disk end'
mbr="$work/mbr.bin"
dd if=/dev/zero of="$mbr" bs=512 count=1 2>/dev/null
dd if="$LIB/xp-geometry-fix-mbr-440.bin" of="$mbr" bs=440 count=1 conv=notrunc 2>/dev/null
dd if=/dev/urandom of="$mbr" bs=1 seek=440 count=4 conv=notrunc 2>/dev/null
le32() {
    v=$1
    printf "\\$(printf %03o $((v & 255)))\\$(printf %03o $(((v >> 8) & 255)))\\$(printf %03o $(((v >> 16) & 255)))\\$(printf %03o $(((v >> 24) & 255)))"
}
chs() {
    lba=$1
    c=$((lba / (255 * 63))); h=$(( (lba / 63) % 255 )); s=$(( lba % 63 + 1 ))
    printf "\\$(printf %03o "$h")\\$(printf %03o $(( s | ((c >> 2) & 192) )))\\$(printf %03o $((c & 255)))"
}
# MS-DOS 6.22 reads its partition through CHS: type 06h with real CHS values.
{ printf '\200'; chs "$part_start"; printf '\006'; chs $((part_start + part_sectors - 1)); le32 "$part_start"; le32 "$part_sectors"; } | dd of="$mbr" bs=1 seek=446 count=16 conv=notrunc 2>/dev/null
printf '\125\252' | dd of="$mbr" bs=1 seek=510 count=2 conv=notrunc 2>/dev/null
dd if="$mbr" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the MBR'

part_loop=$(losetup -f) || fail 'no free loop device for the new partition'
losetup -o $((part_start * 512)) "$part_loop" "$TARGET_DEVICE" || fail 'cannot attach the new partition'
mkfs.fat -F 16 -h "$part_start" -g 255/63 -D 0x80 -M 0xF8 "$part_loop" $((part_sectors / 2)) >/dev/null || fail 'cannot format the FAT16 partition'
# No volume label (it would take root entry 0). IO.SYS at cluster 2 and as
# root entry 0, MSDOS.SYS next (mtools allocates
# from the start; Linux vfat does not): what the MS-DOS boot sector and SYS
# expect. SYS rewrites both in place.
mcopy -i "$part_loop" "$work/IO.SYS" ::/IO.SYS || fail 'cannot place IO.SYS'
mcopy -i "$part_loop" "$work/MSDOS.SYS" ::/MSDOS.SYS || fail 'cannot place MSDOS.SYS'

mount -t vfat -o shortname=winnt,utf8=0 "$part_loop" "$work/c" || fail 'cannot mount the new FAT16 partition'
U="$work/c/USOSDOS"
mkdir -p "$U/DOSFILES"
for file in "$HELPERS"/*; do
    [ -f "$file" ] || continue
    cp "$file" "$U/$(basename "$file" | tr '[:lower:]' '[:upper:]')" || fail "cannot copy $(basename "$file")"
done
copied=0
for file in "$work/dos"/*; do
    [ -f "$file" ] || continue
    name=$(basename "$file" | tr '[:lower:]' '[:upper:]')
    case "$name" in IO.SYS|MSDOS.SYS|COMMAND.COM|CONFIG.SYS|AUTOEXEC.BAT) continue ;; esac
    cp "$file" "$U/DOSFILES/$name" || fail "cannot copy $name"
    copied=$((copied + 1))
done
log "MS-DOS files copied: $copied"
if [ -n "$WIN3_ISO" ]; then
    mkdir -p "$U/WINSETUP"
    for file in "$work/win"/*; do
        name=$(basename "$file" | tr '[:lower:]' '[:upper:]')
        if [ -d "$file" ]; then
            # One directory level (Windows 1.0x: PIF), as on its diskette.
            mkdir -p "$U/WINSETUP/$name"
            for sub in "$file"/*; do
                [ -f "$sub" ] || continue
                cp "$sub" "$U/WINSETUP/$name/$(basename "$sub" | tr '[:lower:]' '[:upper:]')" || fail "cannot copy $name/$(basename "$sub")"
            done
            continue
        fi
        [ -f "$file" ] || continue
        cp "$file" "$U/WINSETUP/$name" || fail "cannot copy $name"
    done
    log 'Windows 3.x Setup files copied'
    # Windows 1.0x-3.0 (tools/w9x_csmwrap_prepare.sh): INSTALL.BAT copies
    # EARLY.TAG to C:\USOSW3; W3START.BAT runs their Setup from A: (SUBST)
    # and the start menu uses the early variants (no DOS=HIGH, SETVER).
    case "$WIN_EARLY" in
        '')
            # Windows 3.1 / WfW 3.11 batch Setup: the text pages of the Central
            # European editions (W3PL; other editions never show its texts).
            [ ! -f "$U/W3PL.KEY" ] || cp "$U/W3PL.KEY" "$U/SETUP.KEY" || fail 'cannot copy W3PL.KEY'
            rm -f "$U/USOSMS1.DRV" ;;
        windows-1-01|windows-1-04|windows-2-03|windows-2-11-286|windows-2-11-386|windows-3-0)
            printf '%s\r\n' "$WIN_EARLY" > "$U/EARLY.TAG"
            # Setup answers for USOSKBC (src/platform/bios/msdos/keys).
            case "$WIN_EARLY" in
                windows-1-01) key=W101 ;; windows-1-04) key=W104 ;; windows-2-03) key=W203 ;;
                windows-2-11-286) key=W211 ;; windows-2-11-386) key=W386 ;; *) key=W30 ;;
            esac
            [ ! -f "$U/$key.KEY" ] || cp "$U/$key.KEY" "$U/SETUP.KEY" || fail "cannot copy $key.KEY"
            # USOSMS1.DRV (USB mouse through the BIOS) replaces MOUSE.DRV of
            # Windows 1.0x only (INSTALL.BAT); 2.x/3.0 use USOSKBC /M.
            case "$WIN_EARLY" in
                windows-1-01|windows-1-04) ;;
                *) rm -f "$U/USOSMS1.DRV" ;;
            esac
            log "early Windows: $WIN_EARLY (Setup from A: = C:\WINSETUP)" ;;
        *) fail "unexpected DOS_WIN_EARLY: $WIN_EARLY" ;;
    esac
fi
if [ -n "$PROGRAMS_DIR" ] && [ -d "$PROGRAMS_DIR" ]; then
    cp -r "$PROGRAMS_DIR" "$U/PROGRAMS" || fail 'cannot copy the DOS programs from DATA'
fi
printf 'CSMWRAP\r\n' > "$U/CSMWRAP.TAG"
cp "$ESP_DIR/dos-native/memdisk" "$U/MEMDISK" || fail 'cannot copy MEMDISK'

printf '@ECHO OFF\r\nSET USRC=C:\\USOSDOS\r\nSET USYS=A:\\\r\nSET UDISK=1\r\nC:\r\nCD \\\r\nC:\\USOSDOS\\INSTALL.BAT\r\n' > "$work/AUTOEXEC.BAT"
printf 'FILES=40\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\n' > "$work/CONFIG.SYS"
for name in AUTOEXEC.BAT CONFIG.SYS; do
    mattrib -i "$floppy" -r -h -s "::/$name" >/dev/null 2>&1 || true
    mcopy -o -i "$floppy" "$work/$name" "::/$name" || fail "cannot write $name into the boot floppy"
done
cp "$floppy" "$U/BOOT.IMG" || fail 'cannot copy BOOT.IMG'
printf 'DEFAULT dos\nPROMPT 0\nTIMEOUT 0\nLABEL dos\n  LINUX /USOSDOS/MEMDISK\n  INITRD /USOSDOS/BOOT.IMG\n  APPEND floppy\n' > "$work/c/SYSLINUX.CFG"
sync
umount "$work/c" || fail 'cannot unmount the new partition'

syslinux --install "$part_loop" || fail 'syslinux could not make the partition bootable'
mdir -a -i "$part_loop" ::/LDLINUX.SYS >/dev/null 2>&1 || fail 'read-back: LDLINUX.SYS missing'
mdir -i "$part_loop" ::/USOSDOS/BOOT.IMG >/dev/null 2>&1 || fail 'read-back: BOOT.IMG missing'
losetup -d "$part_loop"; part_loop=''
sync
blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true

TARGET_DEVICE=$TARGET_DEVICE USOS_XP_ESP_TAIL_SECTORS=$ESP_TAIL sh "$LIB/xp_csmwrap_esp.sh" || fail 'the CSMWrap ESP could not be written'
dd if="$TARGET_DEVICE" of="$mbr" bs=512 count=1 2>/dev/null || fail 'cannot read back the MBR'
[ "$(od -An -tu1 -j450 -N1 "$mbr" | tr -d ' \n')" = 6 ] || fail 'read-back: the DOS partition type differs'
log "PASS target=$TARGET_DEVICE windows3=$([ -n "$WIN3_ISO" ] && echo yes || echo no); next boot: CSMWrap -> MS-DOS setup"
