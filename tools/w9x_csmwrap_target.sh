#!/bin/sh
# Windows 95/98/Me from the UEFI menu on a PC without firmware CSM
# (profile w9x-uefi-csmwrap, experimental; docs/win9x-modern-2026-09-30.md
# section 4c). Called by tools/w9x_csmwrap_prepare.sh after the user picked
# and confirmed the disk.
#
# Writes ONLY $TARGET_DEVICE:
#   MBR     USOS MBR code (boots the active partition), new disk signature
#   slot 1  FAT32 (type 0Ch, LBA), active, from LBA 2048, at most 32 GiB;
#           95 RTM/OSR1: FAT16 type 06h, at most 2047 MiB, real CHS fields
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
# The 9x zone key of MSBATCH.INF [Setup] TimeZone (USOS default answer; a
# profile run takes the answer's own TimeZone below): 95 / 98 / 98 SE also
# get C:\USOS9X\TZFIX.BAT for the first-boot Date/Time step (95: the key as
# Windows 95 names it, e.g. Warsaw on OSR2.1, Lisbon Warsaw on 950).
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
# 1 (tools/w9x_csmwrap_prepare.sh: the default, 0 with DATA's 9x
# usb-storage-off.txt): USB sticks in Windows through USOSUSB.MPD
# (tools/nt/usosusb9x, docs/usb9x-hotswap-design-2026-10-19.md; X470 Windows
# Me PASS 2026-10-19 with hot-swap). It talks to the SeaBIOS USB disk service
# of CSMWrap >= 3.1.2-usos17 and only offers sticks without a BIOS number, so
# the boot disk becomes the only BIOS hard disk on SATA targets too. Never
# together with xhci98 (one xHCI owner). Windows 95: on as well (same
# SCSIPORT miniport and real-mode REGEDIT import as 98; not run on 95 yet).
USB_STORAGE=${W9X_USB_STORAGE:-0}
# 1 (prepare.sh default, 0 with DATA's vmd-off.txt): the USB mouse in MS-DOS
# boxes through USOSVMD.VXD, a VMOUSE minidriver (docs/dos-mouse-2026-10-18.md;
# X470 Windows Me PASS 2026-10-19 with v3.1, 98 FE / 98 SE PASS later). 95 /
# 98 / 98 SE / Me with the USOS or a profile answer, not a user's own file.
VMD=${W9X_VMD:-0}
# 1 (prepare.sh default, 0 with DATA's logging-off.txt): USOSLOG.EXE, the
# silent logger (docs/usoslog.md), starts with Windows from the machine Run
# key and writes C:\USOS9X\LOGS (USOS answer only).
LOGGING=${W9X_LOGGING:-0}
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
# Device Manager name for a display id vendor:device (lower-case hex) and
# the CD language ($2: PL, else English): "<model> (VESA)" for common cards,
# else the plain VESA adapter name. No raw PCI ids (user request 2026-10-25).
w9x_display_name() {
    case "$1" in
        1002:67df) printf 'AMD Radeon RX 470/480/570/580 (VESA)' ;;
        1002:67ef) printf 'AMD Radeon RX 460/560 (VESA)' ;;
        1002:67ff) printf 'AMD Radeon RX 550/560 (VESA)' ;;
        1002:699f) printf 'AMD Radeon RX 550 (VESA)' ;;
        1002:687f) printf 'AMD Radeon RX Vega (VESA)' ;;
        1002:7340) printf 'AMD Radeon RX 5500 (VESA)' ;;
        1002:731f) printf 'AMD Radeon RX 5600/5700 (VESA)' ;;
        10de:128b) printf 'NVIDIA GeForce GT 710 (VESA)' ;;
        10de:1d01) printf 'NVIDIA GeForce GT 1030 (VESA)' ;;
        10de:1401) printf 'NVIDIA GeForce GTX 960 (VESA)' ;;
        10de:13c2) printf 'NVIDIA GeForce GTX 970 (VESA)' ;;
        10de:13c0) printf 'NVIDIA GeForce GTX 980 (VESA)' ;;
        10de:1c81) printf 'NVIDIA GeForce GTX 1050 (VESA)' ;;
        10de:1c82) printf 'NVIDIA GeForce GTX 1050 Ti (VESA)' ;;
        10de:1c02|10de:1c03) printf 'NVIDIA GeForce GTX 1060 (VESA)' ;;
        10de:1b81) printf 'NVIDIA GeForce GTX 1070 (VESA)' ;;
        10de:1b80) printf 'NVIDIA GeForce GTX 1080 (VESA)' ;;
        10de:1b06) printf 'NVIDIA GeForce GTX 1080 Ti (VESA)' ;;
        10de:1f82) printf 'NVIDIA GeForce GTX 1650 (VESA)' ;;
        10de:2184) printf 'NVIDIA GeForce GTX 1660 (VESA)' ;;
        10de:2182) printf 'NVIDIA GeForce GTX 1660 Ti (VESA)' ;;
        10de:21c4) printf 'NVIDIA GeForce GTX 1660 SUPER (VESA)' ;;
        *) if [ "${2:-}" = PL ]; then printf 'Karta graficzna VESA'; else printf 'VESA Display Adapter'; fi ;;
    esac
}
# USOSVESA.INF (stdin -> stdout) with one U9FIX-style hardware ID line per
# id of $1 right after [Mfg.VM]; ids already listed are skipped. $2 = CD
# language for the device name (w9x_display_name).
w9x_add_display_ids() {
    _wd_names=''
    for _wd_id in $1; do _wd_names="$_wd_names$_wd_id=$(w9x_display_name "$_wd_id" "${2:-}")
"; done
    awk -v ids="$1" -v names="$_wd_names" '
        BEGIN { m = split(names, nl, "\n"); for (k = 1; k <= m; k++) if (nl[k] != "") { e = index(nl[k], "="); name[substr(nl[k], 1, e - 1)] = substr(nl[k], e + 1) } }
        { sub(/\r$/, ""); lines[++count] = $0; text = text "\n" tolower($0) }
        END {
            n = split(ids, list, "\n"); bs = sprintf("%c", 92)
            for (i = 1; i <= count; i++) {
                printf "%s\r\n", lines[i]
                if (lines[i] !~ /^\[Mfg\.VM\]/) continue
                for (j = 1; j <= n; j++) {
                    split(list[j], v, ":")
                    if (index(text, "pci" bs "ven_" v[1] "&dev_" v[2])) continue
                    printf "\"%s\"=VESA, PCI%sVEN_%s&DEV_%s\r\n", name[list[j]], bs, v[1], v[2]
                }
            }
        }'
}
# MSBATCH.INF $1 -> stdout with [USOS.ChannelBar] (98 FE, IE 4) in the
# [Install] AddReg list, placed before [USOS.Csm] (INSTALL.BAT appends to
# the end). Fails without exactly one AddReg line in [Install].
w9x_98fe_channelbar_answer() {
    awk 'function add() {if(done++)return
             bs = sprintf("%c", 92)
             printf "[USOS.ChannelBar]\r\nHKCU,\"Software%sMicrosoft%sInternet Explorer%sMain\",Show_ChannelBand,,\"no\"\r\n\r\n", bs, bs, bs}
         {sub(/\r$/, ""); low=tolower($0)}
         /^\[/ {install=(low=="[install]"); if(low=="[usos.csm]")add()}
         install && low~/^addreg=/ {if(low!~/usos\.channelbar/)$0=$0 ",USOS.ChannelBar";n++}
         {printf "%s\r\n",$0}
         END {if(n!=1)exit 1; if(!done){printf "\r\n";add()}}' "$1"
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
case "$SETUP_FOLDER" in WIN98|WIN9X|WIN95) ;; WINME) [ "$SYSTEM_TAG" = ME ] || fail "WINME needs the Me flow" ;; *) fail "unexpected Setup folder: $SETUP_FOLDER" ;; esac
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

. "$LIB/w9x_filesystem.sh"
setup_version=''
if [ "$SYSTEM_TAG" = 95 ]; then
    setup_launcher=''
    for name in SETUP.EXE setup.exe; do
        [ ! -f "$work/iso/$name" ] || setup_launcher="$work/iso/$name"
    done
    [ -n "$setup_launcher" ] || fail 'Windows 95 needs its original root SETUP.EXE to identify FAT16/FAT32 support; no disk was changed'
    setup_version=$("$LIB/pe-file-version" "$setup_launcher") || fail 'cannot read the Windows 95 launcher version; no disk was changed'
fi
usos_w9x_fs_select "$SYSTEM_TAG" "$setup_version" || fail 'unknown Windows 95 source version; refusing to guess filesystem support; no disk was changed'
log "source_setup_version=${setup_version:-not-required} filesystem=FAT$W9X_FAT_BITS partition_type=$W9X_MBR_TYPE"
# For the caller (w9x_csmwrap_prepare.sh): the Windows 95 Setup phase-1 input
# controller is chosen by this version (950 = event controller, OSR2 = timed).
printf 'setup_version=%s\n' "$setup_version" > "${W9X_TARGET_RESULT:-/run/w9x-target.result}" 2>/dev/null || true

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
usos_w9x_fs_layout "$part_sectors" || fail 'cannot choose filesystem geometry'
part_sectors=$W9X_FS_SECTORS cluster=$W9X_FS_CLUSTER
log "disk_sectors=$total part_start=$part_start part_sectors=$part_sectors cluster_sectors=$cluster esp_start=$esp_start"

# Whole-disk mode: both GPT copies and the old MBR go.
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the disk start'
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 seek=$((total - 2048)) count=2048 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the disk end'
mbr="$work/mbr.bin"
dd if=/dev/zero of="$mbr" bs=512 count=1 2>/dev/null
dd if="$LIB/xp-geometry-fix-mbr-440.bin" of="$mbr" bs=440 count=1 conv=notrunc 2>/dev/null
dd if=/dev/urandom of="$mbr" bs=1 seek=440 count=4 conv=notrunc 2>/dev/null
# FAT32 retains sentinel CHS; RTM FAT16 gets real 255/63 CHS and type 06h.
usos_w9x_partition_entry "$W9X_FAT_BITS" "$part_start" "$part_sectors" | dd of="$mbr" bs=1 seek=446 count=16 conv=notrunc 2>/dev/null
printf '\125\252' | dd of="$mbr" bs=1 seek=510 count=2 conv=notrunc 2>/dev/null
dd if="$mbr" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the MBR'

# Busybox losetup has no size limit: the loop runs to the disk end, the
# FAT size comes from mkfs.fat's block count (KiB) and then from the BPB.
part_loop=$(losetup -f) || fail 'no free loop device for the new partition'
losetup -o $((part_start * 512)) "$part_loop" "$TARGET_DEVICE" || fail 'cannot attach the new partition'
label=WINDOWS98
[ "$SYSTEM_TAG" != ME ] || label=WINDOWSME
[ "$SYSTEM_TAG" != 95 ] || label=WINDOWS95
mkfs.fat -F "$W9X_FAT_BITS" -s "$cluster" -R "$W9X_FAT_RESERVED" -f 2 -h "$part_start" -g 255/63 -D 0x80 -M 0xF8 -n "$label" "$part_loop" $((part_sectors / 2)) >/dev/null || fail "cannot format the FAT$W9X_FAT_BITS partition"

mount -t vfat -o shortname=winnt,utf8=0 "$part_loop" "$work/c" || fail "cannot mount the new FAT$W9X_FAT_BITS partition"
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
# Time zone: 950's TIMEZONE.INF names zones differently from OSR2.1 (the menu
# and profiles render OSR2.1 keys): the [Setup] TimeZone becomes the 950 key.
# A profile run has no W9X_TIME_ZONE: TZFIX takes the answer's TimeZone.
[ -r "$LIB/w9x_tzfix.sh" ] && . "$LIB/w9x_tzfix.sh" || fail 'missing time zone helper'
tz_source=''
if [ "$SYSTEM_TAG:${setup_version:-}" = '95:4 0 0 950' ]; then
    tz_source=950
    w9x_msbatch_tz950 "$work/c/USOS9X/MSBATCH.INF" || fail 'cannot map the time zone to the 950 key'
    TIME_ZONE=''
fi
if [ -z "$TIME_ZONE" ]; then
    TIME_ZONE=$(sed -n 's/^TimeZone="\([^"]*\)".*$/\1/p' "$work/c/USOS9X/MSBATCH.INF" | head -n 1)
fi
log "time zone: answer TimeZone=${TIME_ZONE:-none}${tz_source:+ (950 key)}"
# The pinned MIT VESA driver's unregister call stalls RTM shutdown. Patch
# only this newly staged target copy for the exact 950 source, never OSR2.
if [ "$SYSTEM_TAG:${setup_version:-}" = '95:4 0 0 950' ]; then
    [ -r "$LIB/w9x_vesa950.sh" ] || fail 'missing 950 VESA compatibility helper'
    . "$LIB/w9x_vesa950.sh"
    w9x_vesa950_prepare "$work/c/USOS9X" "$setup_version" || fail 'cannot prepare the pinned 950 VESA compatibility driver'
    log 'display: pinned MIT VESA 950 unregister workaround, target copy only'
fi
# Windows 95 with a native phase 1: SUWIN drops the whole MSBATCH.INF when
# [Setup] ProductID has 18 or more characters (an OEM ID overwrites the batch
# file path; tools/w9x_pid95.sh). Such an ID goes (Setup then asks for the
# key; on 950 the batch ID never filled that page anyway); WINSETUP.BIN is
# never patched. Retail IDs (11 characters) stay. The VM phase 1 keeps its
# answer as it is (its page controller types the key). A user's own answer
# file stays 1:1. The key itself is never logged.
# SETUP 4.00.950 (RTM / OSR1) and OSR2 (4.00.1068..1216, the versions
# w9x_filesystem.sh knows): before the drop, an OEM ID goes to
# C:\USOS9X\USOSPID.KEY, and USOSPID.DRV (Setup's mini-Windows, the step
# below) types it into the Product ID page once (950: its one field; OSR2:
# the COA page's three fields) and presses Next; the driver deletes the file
# when it loads, after phase 1 in any case W950POST.BAT (950) or
# C:\AUTOEXEC.BAT (INSTALL.BAT, once C:\WINDOWS\WIN.COM exists).
# Without a staged key USOSPID.DRV leaves C:\USOS9X: the page waits for the
# user as before.
pid_key=none
if [ "$SYSTEM_TAG" = 95 ] && [ "$VM_PHASE1" != 1 ]; then
    [ -r "$LIB/w9x_pid95.sh" ] && . "$LIB/w9x_pid95.sh" || fail 'missing Windows 95 product ID helper'
    if [ "$ANSWER_KIND" = USER ]; then
        pid_value=$(w9x_pid95_value "$work/c/USOS9X/MSBATCH.INF")
        [ "${#pid_value}" -le 17 ] || log 'warning: the answer file ProductID has 18+ characters; Windows 95 Setup will ignore the whole file'
        pid_value=
    else
        case "${setup_version:-}" in
            '4 0 0 950'|'4 0 0 1068'|'4 0 0 1111'|'4 0 0 1212'|'4 0 0 1214'|'4 0 0 1216') pid_page=1 ;;
            *) pid_page=0 ;;
        esac
        if [ "$pid_page" = 1 ] && [ -f "$work/c/USOS9X/USOSPID.DRV" ]; then
            pid_key=$(w9x_pid95_stage_key "$work/c/USOS9X/MSBATCH.INF" "$work/c/USOS9X/USOSPID.KEY") ||
                fail 'cannot stage the Windows 95 product ID for Setup'
        fi
        pid_result=$(w9x_pid95_prepare "$work/c/USOS9X/MSBATCH.INF") ||
            fail 'cannot prepare the Windows 95 product ID'
        log "product id: $pid_result (MSBATCH.INF stays readable for Windows 95 Setup)"
        [ "$pid_key" != staged ] || log 'product id: staged for the Product ID page (USOSPID.DRV in the mini-Windows)'
    fi
fi
[ "$pid_key" = staged ] || rm -f "$work/c/USOS9X/USOSPID.DRV" "$work/c/USOS9X/USOSPID.KEY"
# Display: the answer's ;USOS-DISPLAY= request, else (user decision
# 2026-10-20) auto = the native (EDID) mode, else the highest validated one, capped at 1920x1080 on 9x (docs/display-policy.md), for every
# USOS-made answer. A user's own answer file (copied 1:1) gets no request.
# Setup and the first start keep the INF's safe mode; USOSRES applies the
# mode at the first hardware sign-in (CDS_TEST, rollback; defers in the VM).
display_request=
if grep -q '^;USOS-DISPLAY=' "$ANSWER_INF"; then
    . "$LIB/display_profile.sh"
    display_request=$(usos_display_from_answer "$ANSWER_INF") || fail 'invalid display request'
elif [ "$ANSWER_KIND" != USER ] && [ -f "$LIB/w9x-display/USOSRES.EXE" ] && [ -f "$LIB/w9x-display/USOSVBI.EXE" ]; then
    . "$LIB/display_profile.sh"
    display_request=autoxauto
    log 'display: no request in the answer, default auto (native EDID mode up to 1920x1080)'
fi
# Keep (profile display=keep or DATA's display-keep.txt): no USOSRES /
# USOSVBI; the vmdisp9x VESA driver stays at its INF / VESA95 first mode.
if [ -n "$display_request" ] && usos_display_keep "$display_request"; then
    log 'display: keep (profile display=keep or display-keep.txt): USOSRES not staged, the first mode stays'
    display_request=
fi
if [ -n "$display_request" ]; then
    usos_display_stage "$work/c/USOS9X" "$LIB/w9x-display/USOSRES.EXE" "$display_request" || fail 'cannot stage 9x display request'
    cp "$LIB/w9x-display/USOSVBI.EXE" "$work/c/USOS9X/USOSVBI.EXE" || fail 'cannot stage VBE reader'
    usos_display_9x_answer "$work/c/USOS9X/MSBATCH.INF" > "$work/display-answer.inf" || fail 'cannot register hardware display request'
    cp "$work/display-answer.inf" "$work/c/USOS9X/MSBATCH.INF" || fail 'cannot stage display answer'
    log "display: request=$display_request, validated VBE/INF mode at hardware logon"
fi
# Me, stock user USOS: the empty-password list (tools/w9x_logon.sh), so the
# first start after Setup signs in without the Windows password dialog.
# INSTALL.BAT copies C:\USOS9X\USOS.PWL into C:\WINDOWS before Setup.
rm -f "$work/c/USOS9X/USOS.PWL"
if [ -f "$LIB/w9x_logon.sh" ] && [ -f "$LIB/w9x/USOSME.PWL" ]; then
    . "$LIB/w9x_logon.sh"
    if usos_w9x_pwl_wanted "$work/c/USOS9X/MSBATCH.INF" "$SYSTEM_TAG" "$ANSWER_KIND"; then
        usos_w9x_pwl_answer "$work/c/USOS9X/MSBATCH.INF" > "$work/pwl-answer.inf" || fail 'cannot add the password list to the answer'
        cp "$work/pwl-answer.inf" "$work/c/USOS9X/MSBATCH.INF" && cp "$LIB/w9x/USOSME.PWL" "$work/c/USOS9X/USOS.PWL" ||
            fail 'cannot stage the password list'
        log 'logon: Me user USOS, empty-password list staged (no first-start password dialog)'
    fi
fi
. "$LIB/network_setup.sh"
usos_net_answer_config "$ANSWER_INF" "$SYSTEM_TAG" > "$work/network.ini" || fail 'invalid LAN metadata'
USOS_NET_W95_VERSION=$setup_version usos_net_stage "$work/network.ini" "$work/c" "$LIB" "${W9X_PCI_ROOT:-/sys/bus/pci/devices}" || fail 'cannot stage LAN defaults'
rm -f "$work/network.ini"
# 95 RTM / OSR1: Setup installs no network (no [Network] section: no NETDI
# defaults, no adapter picker); the USOS LAN comes from NET95.REG after
# Setup (tools/network_setup.sh usos_net_w950_msbatch). OSR2 / 98 / Me and a
# user's own file: unchanged.
if [ "$ANSWER_KIND" != USER ] && [ "$SYSTEM_TAG:${setup_version:-}" = '95:4 0 0 950' ]; then
    usos_net_w950_msbatch "$work/c/USOS9X/MSBATCH.INF" || fail 'cannot clear the 950 Setup network components'
    log 'network: 950 Setup without network components ([Network] staged as [USOS.Network]); USOS LAN after Setup'
fi
. "$LIB/legacy_addons.sh"
usos_addons_config "$ANSWER_INF" > "$work/addons.ini" || fail 'invalid addon selection'
addon_os=$SYSTEM_TAG;[ "$addon_os" != 98 ] || addon_os=98FE
addon_lang=XX
if [ -x "$LIB/addons/legacy-stage-plan" ]; then addon_lang=$("$LIB/addons/legacy-stage-plan" language "$work/c/$SETUP_FOLDER/SETUP.TXT") || addon_lang=XX; fi
usos_addons_stage "$work/addons.ini" "$work/c" "$LIB" "${USOS_ADDONS_DIR:-/mnt/data/Addons}" "$addon_os" "$addon_lang" || fail 'cannot stage legacy pack'
rm -f "$work/addons.ini"
if [ ! -f "$work/c/USOS/ADDONS/USOSADD.EXE" ]; then
    sed '/^HKLM,.*USOSAddons,,/d' "$work/c/USOS9X/MSBATCH.INF" > "$work/MSBATCH.NEW" && mv "$work/MSBATCH.NEW" "$work/c/USOS9X/MSBATCH.INF" || fail 'cannot drop missing addon runner'
fi
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
        w9x_add_display_ids "$ids" "${addon_lang:-}" < "$work/c/USOS9X/USOSVESA.INF" > "$work/USOSVESA.INF" &&
            cp "$work/USOSVESA.INF" "$work/c/USOS9X/USOSVESA.INF" || fail 'cannot add the display IDs to USOSVESA.INF'
    fi
    log "vm phase 1: U9VM=1, display ids: $(printf '%s' "$ids" | tr '\n' ' ')"
fi

# Setup's own mini-Windows on this PC (native phase 1): SETUP unpacks
# MINI.CAB into C:\WININST0.400 and runs it in standard mode (DOSX +
# KRNL386, no VxD) for its licence, key and wizard pages. Its VGA.DRV is the
# Windows 3.1 driver, so the RX 560 latch fault breaks its drawing like
# Windows 3.1's (docs/win3x-vga-redraw-2026-10-23.md), and its KEYBOARD.DRV /
# MSMOUS31.DRV read only i8042 ports, which CSMWrap does not emulate.
# usos-fb-ui --w9x-setup-mini (src/compat/win3x/w9x_mini.zig) patches VGA.DRV
# in the cabinet (the 3.1 plan, 94 sites) and adds the Windows 3.1
# standard-mode USB bridge: USOSKEY.DRV (drivers=) + VBMOUSE.DRV
# (mouse.drv=); INSTALL.BAT (U9MINI=1) loads USOSKEY.COM and VBMOUSE.EXE
# before SETUP. The VM phase 1 (QEMU VGA and PS/2) keeps MINI.CAB as it is;
# win9x/setup-mini-off.flag on the stick ESP switches the step off.
SETUP_MINI_OFF_FLAG=${W9X_SETUP_MINI_OFF_FLAG:-$ESP_DIR/win9x/setup-mini-off.flag}
mini_bridge=0
if [ "$VM_PHASE1" = 1 ]; then
    log 'setup mini-Windows: phase 1 in the VM, MINI.CAB unchanged'
elif [ -e "$SETUP_MINI_OFF_FLAG" ]; then
    log 'setup mini-Windows: off (win9x/setup-mini-off.flag), MINI.CAB unchanged'
elif [ ! -f "$work/c/$SETUP_FOLDER/MINI.CAB" ]; then
    log "setup mini-Windows: no $SETUP_FOLDER\\MINI.CAB"
elif ! command -v usos-fb-ui >/dev/null 2>&1; then
    log 'setup mini-Windows: usos-fb-ui missing, MINI.CAB unchanged'
else
    usos-fb-ui --w9x-setup-mini "$work/c/$SETUP_FOLDER" "$work/c/USOS9X" 2>&1 | while IFS= read -r line; do log "$line"; done
    if tr -d '\r' < "$work/c/USOS9X/USOSMINI.TXT" 2>/dev/null | grep -qx 'bridge=on' &&
        [ -f "$work/c/USOS9X/USOSKEY.COM" ] && [ -f "$work/c/USOS9X/VBMOUSE.EXE" ]; then
        mini_bridge=1
    fi
fi
if [ "$mini_bridge" = 1 ]; then
    printf 'SET U9MINI=1\r\n' >> "$work/c/USOS9X/U9ENV.BAT"
    log 'setup mini-Windows: U9MINI=1 (USOSKEY.COM + VBMOUSE.EXE before SETUP)'
fi
# The staged Product ID (above) only with USOSPID.DRV in this MINI.CAB and
# the bridge loaded; otherwise the key leaves the disk and Setup asks.
if [ -f "$work/c/USOS9X/USOSPID.KEY" ]; then
    if [ "$mini_bridge" = 1 ] && tr -d '\r' < "$work/c/USOS9X/USOSMINI.TXT" 2>/dev/null | grep -qx 'pid=on'; then
        log 'product id: USOSPID.DRV in the mini-Windows types it into the Product ID page'
    else
        rm -f "$work/c/USOS9X/USOSPID.KEY" "$work/c/USOS9X/USOSPID.DRV"
        log 'product id: no mini-Windows helper; key removed, Setup asks for it'
    fi
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
# USB sticks through USOSUSB.MPD (default; off: usb-storage-off.txt): USOSUSB.MPD,
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
REM USOS: USB stick miniport USOSUSB.MPD (off: DATA usb-storage-off.txt).
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
        log 'usb storage: USOSUSB.MPD (default; usb-storage-off.txt turns it off), Services\Class\SCSIAdapter\'"$USOSUSB_CLASSIDX"'; needs CSMWrap >= 3.1.2-usos17 (USB disk service, hot-swap) on this disk'
    fi
fi
[ "$uds_ok" = 1 ] || rm -f "$work/c/USOS9X/USOSUSB.MPD" "$work/c/USOS9X/USOSUSB.INF" "$work/c/USOS9X/USOSUSB.REG"
# The mouse in MS-DOS boxes (VMD=1): USOSVMD.VXD stays in C:\USOS9X with the
# switch file USOSVMD.ON (USOSMOUS.DRV enters VMOUSE mode only with it) and
# USOSVMD.INF, which machine RunOnce runs once after Setup (MSBATCH.INF
# [USOS.CsmReg], INSTALL.BAT): SYSTEM.INI [386Enh] device=*vmouse and
# device=C:\USOS9X\USOSVMD.VXD, the X470 Me end state. Effective from the next
# start, like the Me mouse.drv switch. U9FIX /CSM (95/98) deletes only
# mouse=*vmouse lines, never these. Off on the installed system: delete the
# two device= lines (USOSVMD.ON alone only switches USOSMOUS's VMOUSE mode).
# Windows 95 ignores MSBATCH.INF [Install] AddReg, so the RunOnce value comes
# from REG95.REG instead (w9x_reg95.sh, below), which also keeps VMOUSE off
# the PS/2 mouse devnode 95 Setup detects (VMOUSE's own PS/2 init). Without
# REG95.BAT the VMD files are removed again there.
vmd_ok=0
if [ "$VMD" = 1 ]; then
    if [ "$ANSWER_KIND" = USER ]; then
        log "dos-box mouse: USOSVMD.VXD skipped: the user's own answer file (no RunOnce for USOSVMD.INF)"
    elif [ ! -f "$work/c/USOS9X/USOSVMD.VXD" ] || [ ! -f "$work/c/USOS9X/USOSMOUS.DRV" ]; then
        log 'dos-box mouse: USOSVMD.VXD or USOSMOUS.DRV is not in this payload'
    else
        printf 'USOSVMD.VXD (VMOUSE mode) on. Delete this file to switch USOSMOUS off; the VxD itself loads from the SYSTEM.INI device= lines.\r\n' \
            > "$work/c/USOS9X/USOSVMD.ON" || fail 'cannot write USOSVMD.ON'
        sed 's/$/\r/' > "$work/c/USOS9X/USOSVMD.INF" <<'EOF' || fail 'cannot write USOSVMD.INF'
; USOS: the USB mouse in MS-DOS boxes (USOSVMD.VXD, a VMOUSE minidriver).
; Machine RunOnce runs it once after Setup; effective from the next start.
; Off: delete both device= lines in SYSTEM.INI [386Enh].
[Version]
Signature="$CHICAGO$"
[DefaultInstall]
UpdateInis=USOS.Vmd.Ini
[USOS.Vmd.Ini]
system.ini,386Enh,,"device=*vmouse"
system.ini,386Enh,,"device=C:\USOS9X\USOSVMD.VXD"
EOF
        printf 'SET U9VMD=1\r\n' >> "$work/c/USOS9X/U9ENV.BAT"
        vmd_ok=1
        if [ "$SYSTEM_TAG" = 95 ]; then
            log 'dos-box mouse: USOSVMD.VXD + USOSVMD.ON, SYSTEM.INI device= lines by RunOnce USOSVMD.INF from REG95.REG, PS/2 mouse devnode off (default; vmd-off.txt turns it off)'
        else
            log 'dos-box mouse: USOSVMD.VXD + USOSVMD.ON, SYSTEM.INI device= lines by RunOnce USOSVMD.INF (default; vmd-off.txt turns it off)'
        fi
    fi
fi
[ "$vmd_ok" = 1 ] || rm -f "$work/c/USOS9X/USOSVMD.VXD" "$work/c/USOS9X/USOSVMD.ON" "$work/c/USOS9X/USOSVMD.INF"
# The silent logger (LOGGING=1, USOS answer): USOSLOG.EXE starts from the
# machine Run key (MSBATCH.INF [USOS.CsmReg], INSTALL.BAT) at every start, no
# window; C:\USOS9X\LOGS. A Run value, not a Startup folder shortcut: the
# folder name depends on the Windows language and exists only after Setup.
log_ok=0
if [ "$LOGGING" = 1 ]; then
    if [ "$ANSWER_KIND" = USER ]; then
        log "logging: USOSLOG.EXE not started automatically: the user's own answer file"
    elif [ ! -f "$work/c/USOS9X/USOSLOG.EXE" ]; then
        log 'logging: USOSLOG.EXE is not in this payload'
    else
        printf 'SET U9LOG=1\r\n' >> "$work/c/USOS9X/U9ENV.BAT"
        log_ok=1
        log 'logging: USOSLOG.EXE from the machine Run key, C:\USOS9X\LOGS (default; logging-off.txt turns it off)'
    fi
fi
[ "$log_ok" = 1 ] || log 'logging: USOSLOG.EXE stays in C:\USOS9X (not started)'
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
        tz_lang=PL; [ "${addon_lang:-}" != EN ] || tz_lang=EN
        # Local wall time: the RTC keeps local time and the prep kernel reads
        # it as UTC with no TZ set, so `date` shows the local clock
        # (tools/w9x_tzfix.sh). It decides the first boot's ActiveTimeBias.
        tz_when=$(date '+%Y-%m-%d %H:%M' 2>/dev/null || :)
        if [ -r "$LIB/w9x_tzfix.sh" ] && . "$LIB/w9x_tzfix.sh" && w9x_tzfix_write "$TIME_ZONE" "$work/c/USOS9X" "$tz_when" "${tz_source:-}" "$tz_lang"; then
            log "time zone: TZFIX.BAT for '$TIME_ZONE' (first-boot Date/Time step, local time ${tz_when:-unknown})"
        else
            rm -f "$work/c/USOS9X/TZFIX.BAT" "$work/c/USOS9X/TZFIX.REG" "$work/c/USOS9X/TZRO1.REG" "$work/c/USOS9X/TZRO2.REG" "$work/c/USOS9X/TZDST.REG" "$work/c/USOS9X/TZPR1.REG" "$work/c/USOS9X/TZPR2.REG"
            log "time zone: no TZFIX for '$TIME_ZONE' (MSBATCH TimeZone only)"
        fi ;;
esac
# The early legacy path leaves the display on Standard VGA: VESA95.BAT
# (tools/w9x_vesa95.sh) moves it to the vmdisp9x VESA driver at the first
# start, the end state 98 gets from Setup. Source950 can also enumerate a
# later PCI display; its post-Setup hook binds that actual existing device.
if [ "$SYSTEM_TAG" = 95 ]; then
    vesa95_source=''
    [ "$ANSWER_KIND" = USER ] || vesa95_source=${setup_version:-}
    if [ -r "$LIB/w9x_vesa95.sh" ] && . "$LIB/w9x_vesa95.sh" && w9x_vesa95_write "$work/c/USOS9X" 16 1024,768 "$vesa95_source"; then
        log 'display: VESA95.BAT (vmdisp9x VESA at the first start, 16-bit 1024x768)'
    else
        [ "$vesa95_source" != '4 0 0 950' ] || fail 'cannot prepare the 950 post-Setup display binding'
        rm -f "$work/c/USOS9X/VESA95.BAT" "$work/c/USOS9X/VESA95.REG"
        log 'display: no VESA95.BAT (Standard VGA stays)'
    fi
    # 95 Setup ignores MSBATCH.INF [Install] AddReg (X470 2026-10-20: no
    # USOSRES / USOSLAN / USOSLOG Run value, no IE/ICW defaults): REG95.BAT
    # (tools/w9x_reg95.sh) imports the same values once before the first
    # desktop. A user's own answer file gets none (as on 98, 1:1).
    rm -f "$work/c/USOS9X/REG95.BAT" "$work/c/USOS9X/REG95.REG" "$work/c/USOS9X/REG95LGN.REG"
    if [ "$ANSWER_KIND" = USER ]; then
        log "answer registry: none for the user's own answer file"
        [ ! -f "$work/c/USOS9X/NET/NET95.REG" ] || log 'usosnet4: NET95.REG unused (no REG95); the card comes from PnP + USOSNET.INF'
    else
        reg95_log=
        [ "$log_ok" != 1 ] || reg95_log='C:\USOS9X\USOSLOG.EXE'
        reg95_vmd=
        [ "$vmd_ok" != 1 ] || reg95_vmd='C:\USOS9X\USOSVMD.INF'
        # usosnet4 adapter + TCP/IP + client (tools/network_setup.sh
        # usos_net_w95_stage): imported with REG95.REG, checked into NET.
        reg95_net=
        [ ! -f "$work/c/USOS9X/NET/NET95.REG" ] || reg95_net="$work/c/USOS9X/NET/NET95.REG"
        if [ -r "$LIB/w9x_reg95.sh" ] && . "$LIB/w9x_reg95.sh" && w9x_reg95_write "$work/c/USOS9X" "$work/c/USOS9X/MSBATCH.INF" "$reg95_log" "$reg95_vmd" "$reg95_net" "${setup_version:-}"; then
            log "answer registry: REG95.BAT ($(grep -c -e '^"' -e '^@' "$work/c/USOS9X/REG95.REG") values, real-mode REGEDIT once; Network Logon: Windows Logon)"
            [ -z "$reg95_net" ] || log 'usosnet4: NET95.REG imported with REG95 (evidence C:\USOS9X\NET\C1..C3.REG, NET95.OK / NET95.ERR)'
        else
            if [ -n "$reg95_net" ] && [ "${setup_version:-}" = '4 0 0 950' ]; then
                fail 'RTM/OSR1 network files and registry helpers could not be prepared; target start withheld'
            fi
            rm -f "$work/c/USOS9X/REG95.BAT" "$work/c/USOS9X/REG95.REG" "$work/c/USOS9X/REG95LGN.REG"
            log 'answer registry: no REG95.BAT (95 keeps Setup defaults)'
            if [ "$vmd_ok" = 1 ]; then
                vmd_ok=0
                rm -f "$work/c/USOS9X/USOSVMD.VXD" "$work/c/USOS9X/USOSVMD.ON" "$work/c/USOS9X/USOSVMD.INF"
                log 'dos-box mouse: USOSVMD.VXD removed again (no REG95.BAT for its RunOnce and the PS/2 devnode)'
            fi
        fi
    fi
fi
if [ "$ANSWER_KIND" != USER ] &&
   [ "$SYSTEM_TAG:${setup_version:-}" = '95:4 0 0 950' ]; then
    [ -r "$LIB/w9x_firstboot.sh" ] && . "$LIB/w9x_firstboot.sh" &&
        w9x_firstboot_write "$work/c/USOS9X" "$setup_version" || fail 'cannot stage source950 first-desktop coordinator'
    log 'first desktop: source950 ordinary RunOnce coordinator, one final post-addons restart'
fi
# Source950 with a native phase 1: the VM path's post-phase-1 steps
# (w9x_csmwrap_prepare.sh: w9x_950_post_inject, PHASE1.OK) need the files
# Setup copies, after the prep system is gone: W950POST.BAT does them DOS-side
# before the first GUI start (tools/w9x_950_post.sh). The VM path keeps its own.
rm -f "$work/c/USOS9X/W950POST.BAT"
if [ "${VM_PHASE1:-0}" != 1 ] && [ "$SYSTEM_TAG:${setup_version:-}" = '95:4 0 0 950' ]; then
    [ -r "$LIB/w9x_950_post.sh" ] && . "$LIB/w9x_950_post.sh" &&
        w9x_950_post_dos_write "$work/c/USOS9X" || fail 'cannot stage the 950 native post-phase-1 fixes'
    log 'native phase 1: W950POST.BAT (SETUP.INI progman.only, MONITOR.INF VESADDC MaxRes, PHASE1.OK) before the first GUI start'
fi
# Windows 98 FE (IE 4): no Channel Bar at the first sign-in. shdocvw.dll
# 4.72 (98 FE PL CD) reads HKCU\...\Internet Explorer\Main Show_ChannelBand
# (REG_SZ, "yes"/"no", the value its own checkbox writes); 98 SE is not
# changed here. A user's own answer file stays 1:1.
if [ "$SYSTEM_TAG" = 98 ] && [ "$ANSWER_KIND" != USER ]; then
    if w9x_98fe_channelbar_answer "$work/c/USOS9X/MSBATCH.INF" > "$work/channelbar-answer.inf"; then
        cp "$work/channelbar-answer.inf" "$work/c/USOS9X/MSBATCH.INF" || fail 'cannot stage the Channel Bar answer'
        log 'IE 4: Channel Bar off at the first sign-in (Show_ChannelBand=no)'
    else
        log 'IE 4: Channel Bar left as Setup sets it (no [Install] AddReg line)'
    fi
    rm -f "$work/channelbar-answer.inf"
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
[ "$(od -An -tu1 -j450 -N1 "$mbr" | tr -d ' \n')" = "$W9X_MBR_TYPE" ] || fail 'read-back: the Windows partition type differs'
[ "$(od -An -tu1 -j446 -N1 "$mbr" | tr -d ' \n')" = 128 ] || fail 'read-back: the Windows partition is not active'
log "PASS target=$TARGET_DEVICE release=$SYSTEM_TAG answer=$ANSWER_KIND; next boot: this disk's UEFI entry -> CSMWrap -> Windows $SYSTEM_TAG Setup"
