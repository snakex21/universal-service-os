#!/bin/sh
# Windows 95/98/Me from the UEFI menu on a PC without firmware CSM
# (profile w9x-uefi-csmwrap, experimental; docs/win9x-modern-2026-09-30.md
# section 4c). Called by tools/w9x_csmwrap_prepare.sh after the user picked
# and confirmed the disk.
#
# Writes ONLY $TARGET_DEVICE:
#   MBR     USOS MBR code (boots the active partition), new disk signature
#   slot 1  FAT32 (type 0Ch, LBA), active, from LBA 2048, at most 32 GiB
#           (Microsoft cluster sizes: 4/8/16 KiB, FAT below 16 MiB for the
#           16-bit ScanDisk), 255 heads / 63 sectors like the BIOS Core path
#   slot 2  CSMWrap ESP, 64 MiB at the end (tools/xp_csmwrap_esp.sh, unchanged)
# Files on C:
#   \WIN98 (\WIN9X for Me, \WIN95)  the Setup folder of the CD (files only)
#   \USOS9X  INSTALL.BAT (dos_startup.cmd), U9ENV.BAT, MSBATCH.INF, the USOS 9x
#            helpers (U9FIX, VESA driver, USB bridge, VBADOS), Patcher9x +
#            CWSDPMI, MEMDISK and BOOT.IMG = the CD's own El Torito boot floppy
#            (95: the user's BOOTDISK.IMG) with our AUTOEXEC.BAT / CONFIG.SYS
#   syslinux (GPL-2.0-or-later, Alpine's mtools installer) in the boot sector
#            and LDLINUX.SYS/.C32 + SYSLINUX.CFG: starts MEMDISK with BOOT.IMG
# First boot: firmware -> this disk's BOOTX64.EFI (CSMWrap) -> SeaBIOS -> MBR
# -> syslinux -> MEMDISK -> DOS from the CD floppy (A:) -> INSTALL.BAT in disk
# mode: SYS C: (98/95; the Microsoft boot sector replaces syslinux, Me's Setup
# makes C: bootable itself), the syslinux files are deleted, the existing
# U9FIX / Patcher9x / USB bridge steps, then SETUP from C:. Setup's restarts
# boot C: through the same CSMWrap ESP.
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
SOURCE_ISO=${W9X_SOURCE_ISO:?W9X_SOURCE_ISO is required}
SETUP_FOLDER=${W9X_SETUP_FOLDER:?W9X_SETUP_FOLDER is required}
SYSTEM_TAG=${W9X_TAG:?W9X_TAG is required}
ANSWER_INF=${W9X_ANSWER_INF:?W9X_ANSWER_INF is required}
ANSWER_KIND=${W9X_ANSWER_KIND:-USOS}
BOOT_FLOPPY=${W9X_BOOT_FLOPPY:-}
USB_DIR=${W9X_USB_DIR:-}
SIZE_GIB=${W9X_SIZE_GIB:-32}
# 1: Setup phase 1 runs in a VM on this machine (tools/w9x_phase1_qemu.sh):
# U9ENV.BAT gets U9VM=1 (Setup /P I) and USOSVESA.INF this PC's display IDs.
VM_PHASE1=${W9X_VM_PHASE1:-0}
# The 9x zone key of MSBATCH.INF [Setup] TimeZone (USOS default answer only):
# 95 / 98 / 98 SE also get C:\USOS9X\TZFIX.BAT for the first-boot Date/Time
# step (95: the key as Windows 95 names it, e.g. Warsaw).
TIME_ZONE=${W9X_TIME_ZONE:-}
PCI_ROOT=${W9X_PCI_ROOT:-/sys/bus/pci/devices}
ESP_DIR=${W9X_ESP_DIR:-/mnt/esp/EFI/USOS}
# 98 SE native USB (xhci98 + the user's USB 2.0 stack) is opt-in: only with
# this flag file. On the X470, xhci98 takes the xHCI controller from
# SeaBIOS/CSMWrap, so the USOSKEY bridge (BIOS USB keyboard) dies, and native
# USB HID does not work yet: no keyboard/mouse in Setup's final phase.
XHCI98_FLAG=${W9X_XHCI98_FLAG:-$ESP_DIR/win9x/xhci98.flag}
# Real-hardware diagnostics (USOSDIAG BOOT before every Windows start) are
# opt-in too; the files are in C:\USOS9X either way.
DIAG_FLAG=${W9X_DIAG_FLAG:-$ESP_DIR/win9x/diag.flag}
# 1: the target is NVMe and DATA has the 9x nvme-experimental.txt
# (tools/w9x_csmwrap_prepare.sh): usosnvme.mpd (tools/w9x_nvme.sh) instead
# of MS-DOS compatibility mode, unless the disk fails w9x_nvme_check.
NVME_DRIVER=${W9X_NVME_DRIVER:-0}
# With usosnvme.mpd the boot disk is the only BIOS hard disk (csmwrap.ini
# int13_boot_disk_only = true, CSMWrap patch 0014): a USB stick or another
# disk with a BIOS number shifts the 9x INT 13h units / DOS letters (X470: Me
# stops with "cannot find KRNL386.EXE") and gets IOS MBR stamps written at
# every boot (docs/usb9x-hotswap-design-2026-10-19.md section 2). This empty
# flag on the USOS stick keeps the old mapping (the stick through INT 13h).
INT13_ALL_FLAG=${W9X_INT13_ALL_FLAG:-$ESP_DIR/win9x/int13-all-disks.flag}
# 1: DATA has the 9x usb-storage-experimental.txt (tools/w9x_csmwrap_prepare.sh):
# USB sticks in Windows through USOSUSB.MPD (tools/nt/usosusb9x, stage 1 of
# docs/usb9x-hotswap-design-2026-10-19.md; no hardware pass yet). It talks to
# the SeaBIOS USB disk service of CSMWrap >= 3.1.2-usos16 and only offers
# sticks without a BIOS number, so the boot disk becomes the only BIOS hard
# disk on SATA targets too. Never together with xhci98 (one xHCI owner).
USB_STORAGE=${W9X_USB_STORAGE:-0}
# Services\Class\SCSIAdapter\<n> of USOSUSB's Root devnode (@CLASSIDX@ in
# USOSUSB.REG). The 9x class installer gives each new SCSI adapter the lowest
# free number from 0000; 0090 is reached only after 90 SCSI adapter instances,
# so it cannot meet one Setup or a later driver install writes. Fixed, so a
# second import overwrites the same key instead of adding one.
USOSUSB_CLASSIDX=0090
LIB=${USOS_LIB_DIR:-/usr/lib/usos}
ESP_TAIL=133120
MIN_SECTORS=4194304

MTOOLS_SKIP_CHECK=1
export MTOOLS_SKIP_CHECK
log() { printf '[W9X_CSMWRAP] %s\n' "$*"; }
fail() { printf '[W9X_CSMWRAP] STOP: %s\n' "$1" >&2; exit 1; }
# The first Microsoft cabinet ("MSCF", 4 reserved zero bytes, version 1.3)
# inside an IExpress EXE: offset by scanning, length from the CFHEADER.
w9x_carve_cab() {
    off=$(od -An -v -tu1 "$1" | awk '
        { for (i = 1; i <= NF; i++) { w = w " " $i; n++; if (n > 8) sub(/^ [0-9]+/, "", w)
              if (w == " 77 83 67 70 0 0 0 0") { print pos - 7; exit } pos++ } }')
    [ -n "$off" ] || return 1
    size=$(od -An -tu4 -j $((off + 8)) -N4 "$1" | tr -d ' \n')
    [ "$(od -An -tu1 -j $((off + 24)) -N2 "$1" | tr -s ' ' | sed 's/^ //')" = '3 1' ] || return 1
    [ "$size" -gt 0 ] && [ $((off + size)) -le "$(wc -c < "$1")" ] || return 1
    tail -c +$((off + 1)) "$1" | head -c "$size" > "$2" || return 1
    [ "$(wc -c < "$2" | tr -d ' ')" = "$size" ]
}

# vendor:device (lower-case hex) of every display controller (class 03xxxx)
# under the sysfs PCI folder $1, one per line.
w9x_display_ids() {
    for device in "$1"/*; do
        case "$(cat "$device/class" 2>/dev/null)" in 0x03*) ;; *) continue ;; esac
        printf '%s:%s\n' "$(sed 's/^0x//' "$device/vendor")" "$(sed 's/^0x//' "$device/device")"
    done | tr 'ABCDEF' 'abcdef' | sort -u
}
# USOSVESA.INF (stdin -> stdout) with one U9FIX-style hardware ID line per
# id of $1 right after [Mfg.VM]; ids already listed are skipped.
w9x_add_display_ids() {
    awk -v ids="$1" '
        { sub(/\r$/, ""); lines[++count] = $0; text = text "\n" tolower($0) }
        END {
            n = split(ids, list, "\n"); bs = sprintf("%c", 92)
            for (i = 1; i <= count; i++) {
                printf "%s\r\n", lines[i]
                if (lines[i] !~ /^\[Mfg\.VM\]/) continue
                for (j = 1; j <= n; j++) {
                    split(list[j], v, ":")
                    if (index(text, "pci" bs "ven_" v[1] "&dev_" v[2])) continue
                    printf "\"vesa (vmdisp9x) %s\"=VESA, PCI%sVEN_%s&DEV_%s\r\n", list[j], bs, v[1], v[2]
                }
            }
        }'
}

for tool in dd od mkfs.fat mcopy mmd mdel mattrib mdir syslinux mount umount losetup blockdev awk sync wc; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
HELPERS="$ESP_DIR/dos-native/win9x"
PATCH="$ESP_DIR/dos-native/ram-patch"
for file in "$LIB/xp-geometry-fix-mbr-440.bin" "$LIB/xp_csmwrap_esp.sh" "$ESP_DIR/dos-native/memdisk" \
    "$PATCH/INSTALL.BAT" "$PATCH/PATCH9X.EXE" "$PATCH/CWSDPMI.EXE" "$HELPERS/U9FIX.COM" "$HELPERS/USOSKEY.DRV" "$ANSWER_INF" "$SOURCE_ISO"; do
    [ -r "$file" ] || fail "missing: $file"
done
[ "$(wc -c < "$LIB/xp-geometry-fix-mbr-440.bin" | tr -d ' ')" = 440 ] || fail 'USOS MBR code must be 440 bytes'
case "$SYSTEM_TAG" in 98SE|98|ME|95) ;; *) fail "unknown Windows 9x release: $SYSTEM_TAG" ;; esac
case "$SETUP_FOLDER" in WIN98|WIN9X|WIN95) ;; *) fail "unexpected Setup folder: $SETUP_FOLDER" ;; esac
case "$SIZE_GIB" in 2|8|32) ;; *) fail "unexpected partition size: $SIZE_GIB" ;; esac
if awk -v d="$TARGET_DEVICE" 'index($1, d) == 1 { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts; then
    fail 'a partition of the selected disk is mounted; no disk was changed'
fi

work=/run/w9x-csmwrap
rm -rf "$work"
mkdir -p "$work/iso" "$work/c"
cleanup() {
    umount "$work/c" 2>/dev/null || true
    umount "$work/iso" 2>/dev/null || true
    [ -z "${part_loop:-}" ] || losetup -d "$part_loop" 2>/dev/null || true
    [ -z "${iso_loop:-}" ] || losetup -d "$iso_loop" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------- the source
iso_loop=$(losetup -f) || fail 'no free loop device for the ISO'
losetup -r "$iso_loop" "$SOURCE_ISO" || fail 'cannot attach the Windows 9x ISO'
mount -t iso9660 -o ro "$iso_loop" "$work/iso" || fail 'cannot mount the Windows 9x ISO'
setup_dir=''
for name in "$SETUP_FOLDER" "$(printf '%s' "$SETUP_FOLDER" | tr '[:upper:]' '[:lower:]')"; do
    [ -f "$work/iso/$name/SETUP.EXE" ] || [ -f "$work/iso/$name/setup.exe" ] || continue
    setup_dir="$work/iso/$name"
    break
done
[ -n "$setup_dir" ] || fail "the ISO has no $SETUP_FOLDER\\SETUP.EXE"

floppy="$work/BOOT.IMG"
if [ -n "$BOOT_FLOPPY" ]; then
    # Windows 95 CDs do not boot: the user's startup disk image (bridge).
    [ "$(wc -c < "$BOOT_FLOPPY" | tr -d ' ')" = 1474560 ] || fail 'BOOTDISK.IMG must be a 1.44 MB floppy image'
    dd if="$BOOT_FLOPPY" of="$floppy" bs=512 2>/dev/null || fail 'cannot read BOOTDISK.IMG'
else
    # The CD's El Torito 1.44 MB floppy emulation image (Boot Record Volume
    # Descriptor at sector 17, boot catalog, initial entry).
    brvd="$work/brvd.bin"
    dd if="$SOURCE_ISO" of="$brvd" bs=2048 skip=17 count=1 2>/dev/null || fail 'cannot read the ISO boot record'
    [ "$(dd if="$brvd" bs=1 skip=1 count=5 2>/dev/null)" = CD001 ] || fail 'the ISO has no boot record'
    [ "$(dd if="$brvd" bs=1 skip=7 count=23 2>/dev/null)" = 'EL TORITO SPECIFICATION' ] || fail 'the ISO is not El Torito bootable'
    catalog=$(od -An -tu4 -j71 -N4 "$brvd" | tr -d ' \n')
    entry="$work/catalog.bin"
    dd if="$SOURCE_ISO" of="$entry" bs=2048 skip="$catalog" count=1 2>/dev/null || fail 'cannot read the boot catalog'
    [ "$(od -An -tx1 -j32 -N2 "$entry" | tr -d ' \n')" = 8802 ] || fail 'the CD boot image is not a bootable 1.44 MB floppy'
    rba=$(od -An -tu4 -j40 -N4 "$entry" | tr -d ' \n')
    dd if="$SOURCE_ISO" of="$floppy" bs=2048 skip="$rba" count=720 2>/dev/null || fail 'cannot read the CD boot floppy'
fi
[ "$(od -An -tx1 -j510 -N2 "$floppy" | tr -d ' \n')" = 55aa ] || fail 'the boot floppy has no boot sector'
mdir -a -i "$floppy" ::/IO.SYS >/dev/null 2>&1 || fail 'the boot floppy has no IO.SYS'

# ---------------------------------------------------------------- the disk
size=$(blockdev --getsize64 "$TARGET_DEVICE") || fail 'cannot read the target size'
total=$((size / 512))
[ "$total" -ge "$MIN_SECTORS" ] || fail 'the selected disk is smaller than 2 GiB; no disk was changed'
[ "$total" -le 4294967295 ] || fail 'the selected disk is larger than 2 TiB (MBR); no disk was changed'
esp_start=$(( (total - ESP_TAIL + 2047) / 2048 * 2048 ))
part_start=2048
part_sectors=$((SIZE_GIB * 2097152))
[ $((part_start + part_sectors)) -le "$esp_start" ] || part_sectors=$(( (esp_start - part_start) / 2048 * 2048 ))
[ "$part_sectors" -ge 1048576 ] || fail 'no room for a Windows partition of 512 MiB or more'
if [ "$part_sectors" -le 16777216 ]; then cluster=8; elif [ "$part_sectors" -le 33554432 ]; then cluster=16; else cluster=32; fi
log "disk_sectors=$total part_start=$part_start part_sectors=$part_sectors cluster_sectors=$cluster esp_start=$esp_start"

# Whole-disk mode: both GPT copies and the old MBR go.
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
# CHS fields: 1023/254/63 (beyond CHS), Windows 9x uses the LBA type 0Ch.
{ printf '\200\376\377\377\014\376\377\377'; le32 "$part_start"; le32 "$part_sectors"; } | dd of="$mbr" bs=1 seek=446 count=16 conv=notrunc 2>/dev/null
printf '\125\252' | dd of="$mbr" bs=1 seek=510 count=2 conv=notrunc 2>/dev/null
dd if="$mbr" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the MBR'

# Busybox losetup has no size limit: the loop runs to the disk end, the
# FAT size comes from mkfs.fat's block count (KiB) and then from the BPB.
part_loop=$(losetup -f) || fail 'no free loop device for the new partition'
losetup -o $((part_start * 512)) "$part_loop" "$TARGET_DEVICE" || fail 'cannot attach the new partition'
label=WINDOWS98
[ "$SYSTEM_TAG" != ME ] || label=WINDOWSME
[ "$SYSTEM_TAG" != 95 ] || label=WINDOWS95
mkfs.fat -F 32 -s "$cluster" -R 32 -f 2 -h "$part_start" -g 255/63 -D 0x80 -M 0xF8 -n "$label" "$part_loop" $((part_sectors / 2)) >/dev/null || fail 'cannot format the FAT32 partition'

mount -t vfat -o shortname=winnt,utf8=0 "$part_loop" "$work/c" || fail 'cannot mount the new FAT32 partition'
mkdir -p "$work/c/$SETUP_FOLDER" "$work/c/USOS9X"
copied=0
for file in "$setup_dir"/*; do
    [ -f "$file" ] || continue          # subfolders (TOUR, CHANNELS) are optional extras
    name=$(basename "$file" | tr '[:lower:]' '[:upper:]')
    cp "$file" "$work/c/$SETUP_FOLDER/$name" || fail "cannot copy $name"
    copied=$((copied + 1))
done
[ -f "$work/c/$SETUP_FOLDER/SETUP.EXE" ] || fail 'SETUP.EXE was not copied'
log "setup folder copied: $copied files"
for file in "$HELPERS"/*; do
    [ -f "$file" ] || continue
    cp "$file" "$work/c/USOS9X/$(basename "$file" | tr '[:lower:]' '[:upper:]')" || fail "cannot copy $(basename "$file")"
done
# After the helpers: they include the USOS default MSBATCH.INF, which must
# not replace the chosen answer (a rendered profile or the user's file).
cp "$ANSWER_INF" "$work/c/USOS9X/MSBATCH.INF" || fail 'cannot copy MSBATCH.INF'
for name in INSTALL.BAT PATCH9X.EXE CWSDPMI.EXE; do
    cp "$PATCH/$name" "$work/c/USOS9X/$name" || fail "cannot copy $name"
done
cp "$ESP_DIR/dos-native/memdisk" "$work/c/USOS9X/MEMDISK" || fail 'cannot copy MEMDISK'
# 98 SE: the user's USB 2.0 stack (DATA Drivers/Windows 98 SE/USB) for
# xhci98, native USB keyboard and mouse: the cabinet of its IExpress
# installer EXE (NUSB 3.x) goes to USB\STACK.CAB, which INSTALL.BAT puts next
# to Setup and XHCI98.INF reads usbport.sys/usbhub20.sys from (disk 2).
# Microsoft files: never on the stick, only from the user. Only with
# XHCI98_FLAG (default off: the USOSKEY bridge keeps the keyboard).
USB_NATIVE=0
if [ "$SYSTEM_TAG" = 98SE ] && [ ! -e "$XHCI98_FLAG" ]; then
    log 'usb stack: xhci98 off (no win9x/xhci98.flag), USOSKEY bridge only'
elif [ "$SYSTEM_TAG" = 98SE ] && [ -n "$USB_DIR" ] && [ -d "$USB_DIR" ]; then
    mkdir -p "$work/c/USOS9X/USB"
    for file in "$USB_DIR"/*; do
        [ -f "$file" ] || continue
        case "$(basename "$file" | tr '[:lower:]' '[:upper:]')" in
            *.EXE)
                # CFFILE names are stored uncompressed in the cabinet header.
                w9x_carve_cab "$file" "$work/c/USOS9X/USB/STACK.CAB" &&
                    grep -qi 'usbport\.sys' "$work/c/USOS9X/USB/STACK.CAB" &&
                    grep -qi 'usbhub20\.sys' "$work/c/USOS9X/USB/STACK.CAB" && break
                rm -f "$work/c/USOS9X/USB/STACK.CAB"
                log "usb stack: no USB 2.0 stack cabinet in $(basename "$file")" ;;
        esac
    done
    log "usb stack: $(ls "$work/c/USOS9X/USB" | tr '\n' ' ')"
    if [ -f "$work/c/USOS9X/USB/STACK.CAB" ]; then USB_NATIVE=1; fi
fi
printf 'SET U9SYS=%s\r\nSET U9SRC=%s\r\nSET U9ANS=%s\r\nSET U9CSM=1\r\nSET U9T=C:\\USOS9X\r\nSET U9DISK=1\r\n' \
    "$SYSTEM_TAG" "$SETUP_FOLDER" "$ANSWER_KIND" > "$work/c/USOS9X/U9ENV.BAT"
if [ "$USB_NATIVE" = 1 ]; then printf 'SET U9USB=1\r\n' >> "$work/c/USOS9X/U9ENV.BAT"; fi
if [ -e "$DIAG_FLAG" ]; then printf 'SET U9DIAG=1\r\n' >> "$work/c/USOS9X/U9ENV.BAT"; log 'diagnostics: USOSDIAG BOOT on (win9x/diag.flag)'; fi
if [ "$VM_PHASE1" = 1 ]; then
    printf 'SET U9VM=1\r\n' >> "$work/c/USOS9X/U9ENV.BAT"
    # In the VM, U9FIX /VGA sees QEMU's display card only: the real display
    # controllers (PCI class 03h) get their USOSVESA.INF lines here, in
    # U9FIX's form, so the VESA driver also binds them on the real machine.
    ids=$(w9x_display_ids "$PCI_ROOT")
    if [ -n "$ids" ] && [ -f "$work/c/USOS9X/USOSVESA.INF" ]; then
        w9x_add_display_ids "$ids" < "$work/c/USOS9X/USOSVESA.INF" > "$work/USOSVESA.INF" &&
            cp "$work/USOSVESA.INF" "$work/c/USOS9X/USOSVESA.INF" || fail 'cannot add the display IDs to USOSVESA.INF'
    fi
    log "vm phase 1: U9VM=1, display ids: $(printf '%s' "$ids" | tr '\n' ' ')"
fi

# NVMe target: usosnvme.mpd + USOSNVME.INF stay in C:\USOS9X only when chosen
# and the disk passes the check; INSTALL.BAT (U9NVME=1) puts them next to
# Setup, tools/w9x_csmwrap_prepare.sh into C:\WINDOWS after the VM phase 1.
nvme_ok=0
if [ "$NVME_DRIVER" = 1 ]; then
    if [ ! -f "$work/c/USOS9X/USOSNVME.MPD" ] || [ ! -f "$work/c/USOS9X/USOSNVME.INF" ] ||
        [ ! -r "$LIB/w9x_nvme.sh" ] || ! . "$LIB/w9x_nvme.sh"; then
        log 'nvme: usosnvme.mpd is not in this payload; Windows uses the disk in MS-DOS compatibility mode'
    elif ! nvme_reason=$(w9x_nvme_check "$TARGET_DEVICE"); then
        log "nvme: usosnvme.mpd refused: $nvme_reason; Windows uses the disk in MS-DOS compatibility mode"
    else
        nvme_id=$(w9x_nvme_hwid "$TARGET_DEVICE" || true)
        w9x_nvme_inf_add_id "$nvme_id" < "$work/c/USOS9X/USOSNVME.INF" > "$work/USOSNVME.INF" &&
            cp "$work/USOSNVME.INF" "$work/c/USOS9X/USOSNVME.INF" || fail 'cannot add the NVMe ID to USOSNVME.INF'
        printf 'SET U9NVME=1\r\n' >> "$work/c/USOS9X/U9ENV.BAT"
        nvme_ok=1
        log "nvme: usosnvme.mpd (experimental, nvme-experimental.txt) for ${nvme_id:-PCI\\CC_010802}"
    fi
fi
[ "$nvme_ok" = 1 ] || rm -f "$work/c/USOS9X/USOSNVME.MPD" "$work/c/USOS9X/USOSNVME.INF"
# USB sticks through USOSUSB.MPD (usb-storage-experimental.txt): USOSUSB.MPD,
# .INF and .REG (class instance filled in) stay in C:\USOS9X, U9ENV.BAT gets
# U9UDS=1 (U9USB is xhci98's). INSTALL.BAT then: 95/98/98 SE: AUTOEXEC.BAT
# calls USBREG.BAT, which once Setup made the registry copies the MPD into
# C:\WINDOWS\SYSTEM\IOSUBSYS and imports USOSUSB.REG with real-mode REGEDIT
# (one attempt, USBREG.RUN / USBREG.OK); Me (no real-mode AUTOEXEC.BAT): the
# MPD into IOSUBSYS before Setup, the REG by machine RunOnce regedit /s.
uds_ok=0
if [ "$USB_STORAGE" = 1 ]; then
    if [ -e "$XHCI98_FLAG" ]; then
        log 'usb storage: USOSUSB.MPD skipped: win9x/xhci98.flag chose xhci98 (one xHCI owner); no USB stick in Windows'
    elif [ "$SYSTEM_TAG:$ANSWER_KIND" = ME:USER ]; then
        # Me imports USOSUSB.REG through INSTALL.BAT's lines in the USOS answer.
        log "usb storage: USOSUSB.MPD skipped: Windows Me with the user's own answer file (no RunOnce import)"
    elif [ ! -f "$work/c/USOS9X/USOSUSB.MPD" ] || [ ! -f "$work/c/USOS9X/USOSUSB.INF" ] ||
        [ ! -f "$work/c/USOS9X/USOSUSB.REG" ]; then
        log 'usb storage: USOSUSB.MPD is not in this payload; no USB stick in Windows'
    elif ! head -n 1 "$work/c/USOS9X/USOSUSB.REG" | grep -q '^REGEDIT4'; then
        log 'usb storage: USOSUSB.REG is not a REGEDIT4 file; USOSUSB.MPD skipped'
    else
        sed "s/@CLASSIDX@/$USOSUSB_CLASSIDX/g" "$work/c/USOS9X/USOSUSB.REG" > "$work/USOSUSB.REG" &&
            cp "$work/USOSUSB.REG" "$work/c/USOS9X/USOSUSB.REG" || fail 'cannot write USOSUSB.REG'
        if [ "$SYSTEM_TAG" != ME ]; then
            U='C:\USOS9X\'
            A='C:\WINDOWS\COMMAND\ATTRIB.EXE'
            R='REGEDIT /L:SYSTEM.DAT /R:USER.DAT'
            sed 's/$/\r/' > "$work/c/USOS9X/USBREG.BAT" <<EOF || fail 'cannot write USBREG.BAT'
@ECHO OFF
REM USOS: USB stick miniport USOSUSB.MPD (experimental, usb-storage-experimental.txt).
REM Runs from AUTOEXEC.BAT before Windows starts, at most once (USBREG.RUN).
IF EXIST ${U}USBREG.OK GOTO END
IF EXIST ${U}USBREG.RUN GOTO END
IF NOT EXIST ${U}USOSUSB.REG GOTO END
IF NOT EXIST ${U}USOSUSB.MPD GOTO END
IF NOT EXIST C:\WINDOWS\REGEDIT.EXE GOTO END
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END
IF NOT EXIST C:\WINDOWS\SYSTEM\IOSUBSYS\NUL GOTO END
IF NOT EXIST $A GOTO END
COPY /Y ${U}USOSUSB.MPD C:\WINDOWS\SYSTEM\IOSUBSYS > NUL
IF NOT EXIST C:\WINDOWS\SYSTEM\IOSUBSYS\USOSUSB.MPD GOTO END
ECHO run> ${U}USBREG.RUN
C:
CD \WINDOWS
$A -S -R -H SYSTEM.DAT
$A -S -R -H USER.DAT
$R ${U}USOSUSB.REG
$R /E ${U}USBCHK.REG HKEY_LOCAL_MACHINE\Enum\Root\SCSIAdapter
$A +S +R +H SYSTEM.DAT
$A +S +R +H USER.DAT
ECHO ok> ${U}USBREG.OK
CD \\
:END
EOF
        fi
        printf 'SET U9UDS=1\r\n' >> "$work/c/USOS9X/U9ENV.BAT"
        uds_ok=1
        log 'usb storage: USOSUSB.MPD (experimental, usb-storage-experimental.txt), Services\Class\SCSIAdapter\'"$USOSUSB_CLASSIDX"'; needs CSMWrap >= 3.1.2-usos16 (USB disk service) on this disk'
    fi
fi
[ "$uds_ok" = 1 ] || rm -f "$work/c/USOS9X/USOSUSB.MPD" "$work/c/USOS9X/USOSUSB.INF" "$work/c/USOS9X/USOSUSB.REG"
# The boot disk is the only BIOS hard disk with usosnvme.mpd (NVMe) and with
# USOSUSB.MPD (every target: it offers only sticks without a BIOS number).
int13_only=off
if [ "$nvme_ok" = 1 ] || [ "$uds_ok" = 1 ]; then
    if [ -e "$INT13_ALL_FLAG" ]; then
        log 'int13: every disk keeps a BIOS number (win9x/int13-all-disks.flag)'
        [ "$uds_ok" != 1 ] || log 'usb storage: USOSUSB.MPD will offer no stick: with win9x/int13-all-disks.flag the stick is a BIOS disk (INT 13h owns it)'
    else
        int13_only=on
        log 'int13: only the boot disk is a BIOS hard disk (csmwrap.ini int13_boot_disk_only)'
    fi
fi

case "$SYSTEM_TAG:$TIME_ZONE" in
    98SE:?*|98:?*|95:?*)
        if [ -r "$LIB/w9x_tzfix.sh" ] && . "$LIB/w9x_tzfix.sh" && w9x_tzfix_write "$TIME_ZONE" "$work/c/USOS9X"; then
            log "time zone: TZFIX.BAT for '$TIME_ZONE' (first-boot Date/Time step)"
        else
            rm -f "$work/c/USOS9X/TZFIX.BAT" "$work/c/USOS9X/TZFIX.REG" "$work/c/USOS9X/TZRO1.REG" "$work/c/USOS9X/TZRO2.REG"
            log "time zone: no TZFIX for '$TIME_ZONE' (MSBATCH TimeZone only)"
        fi ;;
esac
# Windows 95 never enumerates PCI under SeaBIOS (VM phase 1 or CSMWrap), so
# Setup leaves the display on Standard VGA: C:\USOS9X\VESA95.BAT
# (tools/w9x_vesa95.sh) moves it to the vmdisp9x VESA driver at the first
# start, the end state 98 gets from Setup.
if [ "$SYSTEM_TAG" = 95 ]; then
    if [ -r "$LIB/w9x_vesa95.sh" ] && . "$LIB/w9x_vesa95.sh" && w9x_vesa95_write "$work/c/USOS9X"; then
        log 'display: VESA95.BAT (vmdisp9x VESA at the first start, 16-bit 1024x768)'
    else
        rm -f "$work/c/USOS9X/VESA95.BAT" "$work/c/USOS9X/VESA95.REG"
        log 'display: no VESA95.BAT (Standard VGA stays)'
    fi
fi

# The boot floppy runs INSTALL.BAT from C: (A: stays the CD's DOS: SYS,
# EXTRACT, ATTRIB). CREGFIX.SYS from C: first (control registers after
# CSMWrap, before Setup's mini-Windows), then HIMEM with /M:2 under CSMWrap;
# the Me floppy has no HIMEM.
printf '@ECHO OFF\r\nCALL C:\\USOS9X\\U9ENV.BAT\r\nC:\\USOS9X\\INSTALL.BAT\r\n' > "$work/AUTOEXEC.BAT"
: > "$work/CONFIG.SYS"
[ ! -f "$work/c/USOS9X/CREGFIX.SYS" ] || printf 'DEVICE=C:\\USOS9X\\CREGFIX.SYS\r\n' >> "$work/CONFIG.SYS"
if mdir -i "$floppy" ::/HIMEM.SYS >/dev/null 2>&1; then
    printf 'DEVICE=A:\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n' >> "$work/CONFIG.SYS"
fi
printf 'FILES=40\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\n' >> "$work/CONFIG.SYS"
for name in AUTOEXEC.BAT CONFIG.SYS; do
    mattrib -i "$floppy" -r -h -s "::/$name" >/dev/null 2>&1 || true
    mcopy -o -i "$floppy" "$work/$name" "::/$name" || fail "cannot write $name into the boot floppy"
done
# JO.SYS: the CD's "CD-ROM Startup Menu" (boot from hard disk / CD), which
# IO.SYS runs when it is on the boot drive; its default boots the hard disk,
# i.e. this loader again. The BIOS Core leaves it out of its RAM disk too.
mattrib -i "$floppy" -r -h -s ::/JO.SYS >/dev/null 2>&1 || true
mdel -i "$floppy" ::/JO.SYS >/dev/null 2>&1 || true
cp "$floppy" "$work/c/USOS9X/BOOT.IMG" || fail 'cannot copy BOOT.IMG'
printf 'DEFAULT w9x\nPROMPT 0\nTIMEOUT 0\nLABEL w9x\n  LINUX /USOS9X/MEMDISK\n  INITRD /USOS9X/BOOT.IMG\n  APPEND floppy\n' > "$work/c/SYSLINUX.CFG"
sync
umount "$work/c" || fail 'cannot unmount the new partition'

# syslinux into the partition (its boot sector keeps mkfs.fat's BPB).
syslinux --install "$part_loop" || fail 'syslinux could not make the partition bootable'
mdir -a -i "$part_loop" ::/LDLINUX.SYS >/dev/null 2>&1 || fail 'read-back: LDLINUX.SYS missing'
mdir -i "$part_loop" ::/USOS9X/BOOT.IMG >/dev/null 2>&1 || fail 'read-back: BOOT.IMG missing'
losetup -d "$part_loop"; part_loop=''
sync
blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true

# The CSMWrap ESP at the disk end (slot 2), the XP/Vista writer. Windows 9x
# has no IRQ steering miniport for current chipsets and takes PCI IRQs from
# the BIOS, so CSMWrap routes PCI INTx to 8259 IRQs for it (csmwrap.ini
# pci_irq_routing = true, CSMWrap 3.1.2-usos12 patch 0015).
TARGET_DEVICE=$TARGET_DEVICE USOS_XP_ESP_TAIL_SECTORS=$ESP_TAIL USOS_PCI_IRQ_ROUTING=on USOS_INT13_BOOT_DISK_ONLY=$int13_only sh "$LIB/xp_csmwrap_esp.sh" || fail 'the CSMWrap ESP could not be written'
dd if="$TARGET_DEVICE" of="$mbr" bs=512 count=1 2>/dev/null || fail 'cannot read back the MBR'
[ "$(od -An -tu1 -j450 -N1 "$mbr" | tr -d ' \n')" = 12 ] || fail 'read-back: the Windows partition type differs'
[ "$(od -An -tu1 -j446 -N1 "$mbr" | tr -d ' \n')" = 128 ] || fail 'read-back: the Windows partition is not active'
log "PASS target=$TARGET_DEVICE release=$SYSTEM_TAG answer=$ANSWER_KIND; next boot: this disk's UEFI entry -> CSMWrap -> Windows $SYSTEM_TAG Setup"
