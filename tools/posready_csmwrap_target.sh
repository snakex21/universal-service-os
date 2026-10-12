#!/bin/sh
# Windows Embedded POSReady 2009: target disk for the install VM
# (docs/posready-2009-2026-10-10.md).
#
# The POSReady 2009 disc is not a classic XP text-mode source: I386 is a
# Windows PE 2005 (Server 2003 SP1 PE, I386\TXTSETUP.SIF MajorVersion 5.2)
# that starts Setup\SetupLauncher.exe (winpeshl.ini), which runs the .NET
# Setup.exe. Setup applies Setup\WIM\setup.wim ("WESCore", XP SP3 5512
# Embedded core), the optional components (I386\WOC*.CAB), offline PnP from
# sp3.cab/driver.cab/wocdrvrs.cab, the registry and the boot files; the first
# boot of the installed system runs the First Boot Agent (FBA), which reads
# the Setup files again (the USB-install docs: "FBA requires additional
# POSReady Setup files").
#
# SetupLauncher reads unattended.xml / presetup.cmd / postsetup.cmd from the
# Setup folder of the media it runs from. A CD cannot take them without a
# remaster, so this script writes the PE onto the target disk itself (the
# Windows PE hard-disk layout: \MININT = I386, \NTLDR = I386\SETUPLDR.BIN,
# \NTDETECT.COM, \Setup with our unattended.xml, \I386 for Setup's cabs).
# QEMU 2026-10-10: PE starts (drive X:), SetupLauncher runs Setup
# /unattended, the answer file validates; Setup then stops at
# "Invalid product key" without a real POSReady key.
#
#   partition 1  FAT16 (0E), active, the PE + Setup files (also FBA's
#                source on the first boot); syslinux -> chain.c32 ntldr=/NTLDR;
#   partition 2  type 07, empty: Setup formats it NTFS (ModifyPartition 2)
#                and installs POSReady there.
#
# The install VM (posready_vm_install, tools/posready_qemu_install.sh) boots
# this disk. Never run from Windows; scratch or the selected target only.
#
# Env: TARGET_DEVICE (block device), POSR_SOURCE_ISO, POSR_UNATTENDED (xml),
# POSR_WIN_SECTORS (size of partition 2, default: up to POSR_VISIBLE_SECTORS),
# optional POSR_PRESETUP / POSR_POSTSETUP (Setup\presetup.cmd / postsetup.cmd).
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
SOURCE_ISO=${POSR_SOURCE_ISO:?POSR_SOURCE_ISO is required}
UNATTENDED=${POSR_UNATTENDED:?POSR_UNATTENDED is required}
POSTSETUP=${POSR_POSTSETUP:-}
PRESETUP=${POSR_PRESETUP:-}
PAYLOAD=${POSR_PAYLOAD_DIR:-/usr/lib/usos/posready}
SYSLINUX_DIR=${POSR_SYSLINUX_DIR:-/usr/share/syslinux}
LIB=${USOS_LIB_DIR:-/usr/lib/usos}
PART_START=63
# The PE partition (FAT16, < 2 GiB): I386 twice (~495 MiB each), Setup (~160 MiB).
PE_SECTORS=${POSR_PE_SECTORS:-4000000}
MIN_SECTORS=8388608
# The VM sees only the first POSR_VISIBLE_SECTORS (default 32 GiB).
VISIBLE_SECTORS=${POSR_VISIBLE_SECTORS:-67108864}

log() { printf '[POSREADY] %s\n' "$*"; }
fail() { printf '[POSREADY] STOP: %s\n' "$1" >&2; exit 1; }

for tool in dd od mkfs.fat mdir syslinux mount umount losetup blockdev awk sync wc tr cp; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
for file in "$LIB/xp-geometry-fix-mbr-440.bin" "$SYSLINUX_DIR/chain.c32" "$SYSLINUX_DIR/libcom32.c32" "$SYSLINUX_DIR/libutil.c32" "$UNATTENDED" "$SOURCE_ISO" "$PAYLOAD/FIRST.CMD" "$PAYLOAD/LOGON.CMD" "$PAYLOAD/X470.REG" "$PAYLOAD/LOGON.REG" "$PAYLOAD/DRV/acpi.sys" "$PAYLOAD/DRV/genahci.sys"; do
    [ -r "$file" ] || fail "missing: $file"
done
if awk -v d="$TARGET_DEVICE" 'index($1, d) == 1 { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts; then
    fail 'a partition of the selected disk is mounted; no disk was changed'
fi
# NVMe target gate (docs/nvme-nt6-2026-10-12.md): usosnvme is not wired into
# the POSReady flow yet, the installed system would stop with 0x7B.
case "$TARGET_DEVICE" in /dev/nvme*) fail 'no NVMe driver for POSReady 2009 in this flow yet; pick a SATA disk. No disk was changed' ;; esac

work=/run/posready
rm -rf "$work"
mkdir -p "$work/iso" "$work/pe"
cleanup() {
    umount "$work/pe" 2>/dev/null || true
    umount "$work/iso" 2>/dev/null || true
    [ -z "${pe_loop:-}" ] || losetup -d "$pe_loop" 2>/dev/null || true
    [ -z "${iso_loop:-}" ] || losetup -d "$iso_loop" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------- the source
iso_loop=$(losetup -f) || fail 'no free loop device for the ISO'
losetup -r "$iso_loop" "$SOURCE_ISO" || fail 'cannot attach the POSReady ISO'
mount -t iso9660 -o ro "$iso_loop" "$work/iso" || fail 'cannot mount the POSReady ISO'
pick() { for n in "$@"; do [ -e "$work/iso/$n" ] && { printf '%s\n' "$work/iso/$n"; return 0; }; done; return 1; }
i386=$(pick I386 i386) || fail 'the ISO has no I386 folder'
setup=$(pick Setup SETUP setup) || fail 'the ISO has no Setup folder (not POSReady 2009 media)'
pick win51.pos WIN51.POS >/dev/null || fail 'the ISO has no WIN51.POS tag (not POSReady 2009 media)'
wim=''
for n in WIM/setup.wim WIM/SETUP.WIM wim/setup.wim; do [ -f "$setup/$n" ] && wim="$setup/$n" && break; done
[ -n "$wim" ] || fail 'the ISO has no Setup\WIM\setup.wim'
# The PE loader: I386\SETUPLDR.BIN as \NTLDR (it starts \MININT; QEMU
# 2026-10-10: the disc's Setup\USB\ntldr is a plain NTLDR, it wanted \WINDOWS).
ufd_ldr=''
for n in SETUPLDR.BIN setupldr.bin; do [ -f "$i386/$n" ] && ufd_ldr="$i386/$n" && break; done
ufd_det=''
for n in USB/NTDETECT.COM USB/ntdetect.com; do [ -f "$setup/$n" ] && ufd_det="$setup/$n" && break; done
[ -n "$ufd_ldr" ] && [ -n "$ufd_det" ] || fail 'the ISO has no I386\SETUPLDR.BIN / Setup\USB\NTDETECT.COM (PE loader for disk start)'
log "source ok: wim=$(wc -c < "$wim" | tr -d ' ') bytes"

# ---------------------------------------------------------------- the disk
size=$(blockdev --getsize64 "$TARGET_DEVICE") || fail 'cannot read the target size'
total=$((size / 512))
[ "$total" -ge "$MIN_SECTORS" ] || fail 'the selected disk is smaller than 4 GiB; no disk was changed'
[ "$total" -le 4294967295 ] || fail 'the selected disk is larger than 2 TiB (MBR); no disk was changed'
# The last 133120 sectors stay free for the CSMWrap ESP (xp_csmwrap_esp.sh).
visible=$((total - 133120 - 2048))
[ "$visible" -le "$VISIBLE_SECTORS" ] || visible=$VISIBLE_SECTORS
# Partition 1 = PE (FAT16, from sector 63; QEMU 2026-10-10: at the disk end
# SYSLINUX 6.04 loaded LDLINUX.SYS but read no SYSLINUX.CFG), partition 2 =
# Windows from the next cylinder to the end of the visible area.
pe_start=$PART_START
pe_sectors=$(( ((PART_START + PE_SECTORS + 16064) / 16065) * 16065 - PART_START ))
win_start=$(( pe_start + pe_sectors ))
win_end=$(( (visible / 16065) * 16065 ))
win_sectors=${POSR_WIN_SECTORS:-$(( win_end - win_start ))}
[ $(( win_start + win_sectors )) -le "$visible" ] || fail 'the Windows partition does not fit'
[ "$win_sectors" -ge 4194304 ] || fail 'less than 2 GiB left for Windows'
log "disk_sectors=$total visible=$visible pe=$pe_start+$pe_sectors win=$win_start+$win_sectors"

dd if=/dev/zero of="$TARGET_DEVICE" bs=512 count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the disk start'
mbr="$work/mbr.bin"
dd if=/dev/zero of="$mbr" bs=512 count=1 2>/dev/null
# The USOS MBR (also NT 4.0 / XP): boots the active partition.
dd if="$LIB/xp-geometry-fix-mbr-440.bin" of="$mbr" bs=440 count=1 conv=notrunc 2>/dev/null
dd if=/dev/urandom of="$mbr" bs=1 seek=440 count=4 conv=notrunc 2>/dev/null
le32() {
    v=$1
    printf "\\$(printf %03o $((v & 255)))\\$(printf %03o $(((v >> 8) & 255)))\\$(printf %03o $(((v >> 16) & 255)))\\$(printf %03o $(((v >> 24) & 255)))"
}
# 1: active, type 0E (FAT16 LBA); 2: type 07. CHS fields saturated (LBA).
{ printf '\200\376\377\377\016\376\377\377'; le32 "$pe_start"; le32 "$pe_sectors"; } | dd of="$mbr" bs=1 seek=446 count=16 conv=notrunc 2>/dev/null
{ printf '\000\376\377\377\007\376\377\377'; le32 "$win_start"; le32 "$win_sectors"; } | dd of="$mbr" bs=1 seek=462 count=16 conv=notrunc 2>/dev/null
printf '\125\252' | dd of="$mbr" bs=1 seek=510 count=2 conv=notrunc 2>/dev/null
dd if="$mbr" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the MBR'
# Setup must find partition 2 without an old file system.
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 seek="$win_start" count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear partition 2'

pe_loop=$(losetup -f) || fail 'no free loop device for the PE partition'
losetup -o $((pe_start * 512)) "$pe_loop" "$TARGET_DEVICE" || fail 'cannot attach the PE partition'
mkfs.fat -F 16 -s 64 -R 1 -f 2 -r 512 -h "$pe_start" -g 255/63 -D 0x80 -M 0xF8 -n USOS-POSRDY "$pe_loop" $((pe_sectors / 2)) >/dev/null || fail 'cannot format the PE partition'
# syslinux and the boot files first, low in the partition (QEMU 2026-10-10:
# written after the 650 MiB copy, SYSLINUX 6.04 stopped with "EDD Load
# error - Boot error", then with "No DEFAULT or UI configuration directive
# found" for a SYSLINUX.CFG at 700 MiB into the partition).
syslinux --install "$pe_loop" || fail 'syslinux could not make the PE partition bootable'
mount -t vfat -o utf8=0,shortname=mixed "$pe_loop" "$work/pe" || fail 'cannot mount the PE partition'
printf 'DEFAULT pe\nPROMPT 0\nTIMEOUT 0\nLABEL pe\n  COM32 /CHAIN.C32\n  APPEND boot ntldr=/NTLDR\n' > "$work/pe/SYSLINUX.CFG"
for file in "$SYSLINUX_DIR/chain.c32" "$SYSLINUX_DIR/libcom32.c32" "$SYSLINUX_DIR/libutil.c32"; do
    cp "$file" "$work/pe/$(basename "$file" | tr '[:lower:]' '[:upper:]')" || fail "cannot copy $(basename "$file")"
done
cp "$ufd_ldr" "$work/pe/NTLDR" || fail 'cannot copy NTLDR'
cp "$ufd_det" "$work/pe/NTDETECT.COM" || fail 'cannot copy NTDETECT.COM'
sync

# \I386: Setup's DriversFolder (..\i386 from \Setup: sp3/driver/WOC cabs).
# \MININT: the disc's UFD NTLDR is a SETUPLDR that starts Windows PE from
# \MININT (TXTSETUP.SIF builds the SYSTEM hive; QEMU 2026-10-10: a BOOT.INI
# with \I386 /MININT stopped on the missing \I386\SYSTEM32\CONFIG\SYSTEM).
# Setup itself reads ..\i386, so the folder exists twice.
cp -r "$i386" "$work/pe/MININT" || fail 'cannot copy I386 to MININT'
cp -r "$i386" "$work/pe/I386" || fail 'cannot copy I386'
cp -r "$setup" "$work/pe/Setup" || fail 'cannot copy Setup'
for d in "Program Files" Documentation; do
    [ ! -d "$work/iso/$d" ] || cp -r "$work/iso/$d" "$work/pe/$d" || fail "cannot copy $d"
done
for f in "$work/iso"/win51* "$work/iso"/WIN51* "$work/iso"/winbom.ini; do
    [ ! -f "$f" ] || cp "$f" "$work/pe/" || fail "cannot copy $(basename "$f")"
done
cp "$UNATTENDED" "$work/pe/Setup/unattended.xml" || fail 'cannot copy unattended.xml'
[ -z "$POSTSETUP" ] || cp "$POSTSETUP" "$work/pe/Setup/postsetup.cmd" || fail 'cannot copy postsetup.cmd'
[ -z "$PRESETUP" ] || cp "$PRESETUP" "$work/pe/Setup/presetup.cmd" || fail 'cannot copy presetup.cmd'
# Debug (POSR_DEBUG_SHELL=1): no winpeshl.ini, so PE opens startnet.cmd's
# command prompt in \Setup instead of SetupLauncher.
[ "${POSR_DEBUG_SHELL:-0}" != 1 ] || rm -f "$work/pe/MININT/system32/winpeshl.ini" "$work/pe/MININT/SYSTEM32/WINPESHL.INI"
# \USOS\POSR: FIRST.CMD (the RunOnce of the first logon in the VM), the X470
# registry values and the XP path's community driver set.
mkdir -p "$work/pe/USOS/POSR/DRV" || fail 'cannot create \USOS\POSR'
cp "$PAYLOAD/FIRST.CMD" "$PAYLOAD/LOGON.CMD" "$PAYLOAD/X470.REG" "$PAYLOAD/LOGON.REG" "$work/pe/USOS/POSR/" || fail 'cannot copy the \USOS\POSR scripts'
cp "$PAYLOAD"/DRV/* "$work/pe/USOS/POSR/DRV/" || fail 'cannot copy the X470 drivers'

sync
umount "$work/pe" || fail 'cannot unmount the PE partition'
mdir -a -i "$pe_loop" ::/LDLINUX.SYS >/dev/null 2>&1 || fail 'read-back: LDLINUX.SYS missing'
mdir -i "$pe_loop" ::/Setup/unattended.xml >/dev/null 2>&1 || fail 'read-back: unattended.xml missing'
losetup -d "$pe_loop"; pe_loop=''
sync
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true
log "PASS target=$TARGET_DEVICE pe_start=$pe_start; next: POSReady Setup in the VM"
