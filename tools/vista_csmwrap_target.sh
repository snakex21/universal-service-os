#!/bin/sh
# Vista SP2 x64 without firmware CSM (profile vista-x64-sp2-uefi-csmwrap,
# experimental; docs/design/csmwrap-integration.md section 10). Called by
# tools/vista_csmwrap_prepare.sh after the user picked and confirmed the disk.
#
# Writes ONLY $TARGET_DEVICE:
#   MBR     USOS MBR code (boots the active partition), new disk signature
#   slot 1  NTFS "Windows", inactive, from 1 MiB up to the staging partition:
#           Vista Setup installs there (InstallTo; the disk was chosen and
#           confirmed in the USOS menu, so Setup shows no disk page)
#   slot 2  NTFS "USOS-VISTA", active, 1 GiB before the CSMWrap ESP: the PE10
#           donor's BIOS boot files (bootmgr from Windows\Boot\PCAT, boot\bcd,
#           boot\boot.sdi) and its Setup image (sources\boot.wim) with the
#           USOS Vista helpers added to \Windows\System32 (what wimboot
#           injects on the UEFI path)
#   slot 3  CSMWrap ESP, 64 MiB at the end (tools/xp_csmwrap_esp.sh, unchanged)
# Boot chain: firmware -> the disk's \EFI\BOOT\BOOTX64.EFI (CSMWrap) -> SeaBIOS
# (card VBIOS POSTed) -> MBR -> NT60 NTFS boot code -> bootmgr -> PE10 in RAM
# -> USOS Vista installer -> Vista Setup in BIOS mode. The installer clears the
# staging partition's active flag before Setup (so Vista puts its boot files on
# its own partition) and removes the staging partition after a good install.
#
# X86_SELF=1 (profile win-x86-uefi-csmwrap: 32-bit Windows 8.1 / 10, section
# 11 of the design doc): VISTA_DONOR_ISO is the selected Windows ISO itself
# (its own x86 WinPE has USB 3, AHCI and NVMe); bootmgr comes from the ISO
# root; the same layout, the staging partition is "USOS-SETUP" with
# support.cpio and modern-support.cpio (usos-x86-csmwrap).
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
DONOR_ISO=${VISTA_DONOR_ISO:?VISTA_DONOR_ISO is required}
REQUEST_DIR=${VISTA_REQUEST_DIR:?VISTA_REQUEST_DIR is required}
SUPPORT_DIR=${VISTA_SUPPORT_DIR:-/mnt/esp/EFI/USOS/windows-native}
ANSWER_XML=${VISTA_ANSWER_XML:-}
X86_SELF=${X86_SELF:-0}
LIB=${USOS_LIB_DIR:-/usr/lib/usos}
ESP_TAIL=133120
STAGING_SECTORS=2097152
MIN_SECTORS=33554432

log() { printf '[VISTA_CSMWRAP] %s\n' "$*"; }
fail() { printf '[VISTA_CSMWRAP] STOP: %s\n' "$1" >&2; exit 1; }

for tool in dd od cmp sfdisk mkntfs mount umount losetup wimlib-imagex cpio sha256sum blockdev awk mdev; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
if [ "$X86_SELF" = 1 ]; then helpers_cpio="$SUPPORT_DIR/modern-support.cpio"; else helpers_cpio="$SUPPORT_DIR/vista-support.cpio"; fi
for file in "$LIB/xp-geometry-fix-mbr-440.bin" "$LIB/vista-nt60-ntfs.bin" "$LIB/xp_csmwrap_esp.sh" "$REQUEST_DIR/usos-source.ini" "$SUPPORT_DIR/support.cpio" "$helpers_cpio" "$DONOR_ISO"; do
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
windows_start=2048
windows_sectors=$((staging_start - windows_start))
log "disk_sectors=$total staging_start=$staging_start staging_sectors=$staging_sectors esp_start=$esp_start x86_self=$X86_SELF"

work=/run/vista-csmwrap
rm -rf "$work"
mkdir -p "$work/staging" "$work/donor" "$work/inject"
cleanup() {
    umount "$work/donor" 2>/dev/null || true
    [ -z "${loop:-}" ] || losetup -d "$loop" 2>/dev/null || true
    umount "$work/staging" 2>/dev/null || true
    umount "$work/windows" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# Pre-write NVMe package checks: USOS_PE_NVME=usosnvme-modern (8.1 / 10 x86)
# here, the Vista / 2008 x64 amd64 package below.
modern_nvme=0
if [ "${USOS_PE_NVME:-}" = usosnvme-modern ]; then
    [ "$X86_SELF" = 1 ] || fail 'modern NVMe requires the x86 self-boot profile'
    case "$TARGET_DEVICE" in /dev/nvme*) ;; *) fail 'modern NVMe requires an NVMe target' ;; esac
    . "$LIB/w9x_nvme.sh"
    modern_id=$(w9x_nvme_hwid "$TARGET_DEVICE") || fail 'cannot identify the NVMe PCI controller'
    case "$modern_id" in 'PCI\VEN_1344&DEV_5407'|'PCI\VEN_1B36&DEV_0010') ;; *) fail 'modern NVMe package does not cover this PCI hardware ID' ;; esac
    mkdir -p "$work/preflight"
    ( cd "$work/preflight" && cpio -idm < "$helpers_cpio" 2>/dev/null ) || fail 'cannot preflight modern NVMe helpers'
    for file in usos-nvme-modern.exe usos-nvme-modern.cmd modern-usosnvme.inf modern-usosnvme.cat modern-usosnvme.cer modern-usosnvme.sys; do
        [ -s "$work/preflight/$file" ] || fail "missing modern NVMe helper: $file; no disk was changed"
    done
    modern_nvme=1
    USOS_PE_NVME=usosnvme
    log "modern NVMe preflight PASS id=$modern_id"
fi

# NVMe target, Vista / Server 2008 SP2 x64 (USOS_PE_NVME=usosnvme with
# X86_SELF=0, docs/vista-x64-nvme-2026-10-21.md): the test-signed amd64
# usosnvme package must be in vista-support.cpio, and usos-fb-ui must be able
# to switch testsigning on in the staging BCD (the x64 WinPE 10 refuses a
# test-signed boot driver otherwise). Checked before the first write.
nvme64=0
if [ "$X86_SELF" != 1 ] && [ "${USOS_PE_NVME:-}" = usosnvme ]; then
    case "$TARGET_DEVICE" in /dev/nvme*) ;; *) fail 'the amd64 NVMe package requires an NVMe target' ;; esac
    command -v usos-fb-ui >/dev/null 2>&1 || fail 'usos-fb-ui is missing (staging BCD testsigning); no disk was changed'
    mkdir -p "$work/preflight"
    ( cd "$work/preflight" && cpio -idm < "$helpers_cpio" 2>/dev/null ) || fail 'cannot inspect the amd64 NVMe helper package'
    for f in usosnvme-amd64.ready usosnvme-nt6.sys usosnvme.inf usosnvme.cat usosnvme.cer; do
        [ -s "$work/preflight/$f" ] || fail "signed amd64 NVMe package missing: $f; no disk was changed"
    done
    rm -rf "$work/preflight"
    nvme64=1
    log 'amd64 NVMe preflight PASS (test-signed usosnvme, testsigning in the staging BCD)'
fi

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
    printf '\000\376\377\377\007\376\377\377'; le32 "$windows_start"; le32 "$windows_sectors"
    printf '\200\376\377\377\007\376\377\377'; le32 "$staging_start"; le32 "$staging_sectors"
    dd if=/dev/zero bs=32 count=1 2>/dev/null
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
case "$TARGET_DEVICE" in *[0-9]) part_prefix="${TARGET_DEVICE}p" ;; *) part_prefix=$TARGET_DEVICE ;; esac
node="${part_prefix}2"; windows_node="${part_prefix}1"
[ -b "$node" ] || fail 'the staging partition node did not appear'
name=${node##*/}
[ "$(cat "/sys/class/block/$name/start")" = "$staging_start" ] || fail 'staging partition start mismatch'
[ "$(cat "/sys/class/block/$name/size")" = "$staging_sectors" ] || fail 'staging partition size mismatch'

# 2. NTFS with the NT60 boot code (loads BOOTMGR); mkntfs's BPB is kept.
[ -b "$windows_node" ] || fail 'the Windows partition node did not appear'
[ "$(cat "/sys/class/block/${windows_node##*/}/start")" = "$windows_start" ] || fail 'Windows partition start mismatch'
mkntfs -Q -F -s 512 -c 4096 -H 255 -S 63 -p "$windows_start" -L Windows "$windows_node" >/dev/null || fail 'cannot format the Windows partition'
log "Windows partition PASS start=$windows_start sectors=$windows_sectors"
if [ "$X86_SELF" = 1 ]; then staging_label=USOS-SETUP; else staging_label=USOS-VISTA; fi
mkntfs -Q -F -s 512 -c 4096 -H 255 -S 63 -p "$staging_start" -L "$staging_label" "$node" >/dev/null || fail 'cannot format the staging partition'
dd if="$node" of="$work/boot" bs=512 count=16 2>/dev/null
dd if="$LIB/vista-nt60-ntfs.bin" of="$work/boot" bs=1 skip=84 seek=84 count=8108 conv=notrunc 2>/dev/null
dd if="$work/boot" of="$node" bs=512 count=16 conv=notrunc 2>/dev/null
dd if="$work/boot" of="$node" bs=512 count=1 seek=$((staging_sectors - 1)) conv=notrunc 2>/dev/null
sync
dd if="$node" of="$work/boot.readback" bs=512 count=16 2>/dev/null
cmp -s "$work/boot" "$work/boot.readback" || fail 'NT60 boot code readback mismatch'
log 'NT60 NTFS boot code PASS'

# 2b. Display (docs/display-policy.md): Vista / 7 / 2008 / 2008 R2
# install on the Standard VGA driver at 800x600. A USOS answer for them
# registers \USOS\NT6\USOSRES.EXE (autounattend.zig display_helper); its
# request is <!-- USOS-DISPLAY=... --> or, without one, auto (native EDID
# mode, else the highest). Staged into the new Windows partition now:
# Setup installs into it (InstallTo, no format) and leaves the folder. A
# user's own answer file has no registration: nothing staged. Optional:
# any failure keeps Windows' own mode and the preparation goes on.
modprobe ntfs3 2>/dev/null || true
display_request=
if [ -n "$ANSWER_XML" ] && [ -r "$ANSWER_XML" ] && [ -r "$LIB/display_profile.sh" ]; then
    . "$LIB/display_profile.sh"
    if usos_display_nt6_answer "$ANSWER_XML"; then
        display_request=$(usos_display_from_xml "$ANSWER_XML") || { display_request=; log 'DISPLAY duplicate request in the answer; display unchanged'; }
        [ -n "$display_request" ] || display_request=autoxauto
        usos_display_valid "$display_request" || { log "DISPLAY invalid request $display_request; display unchanged"; display_request=; }
    fi
fi
if [ -n "$display_request" ]; then
    mkdir -p "$work/windows"
    if [ ! -f "$LIB/USOSRES.EXE" ]; then
        log 'DISPLAY USOSRES.EXE missing in this build; display unchanged'
    elif ! mount -t ntfs3 "$windows_node" "$work/windows"; then
        log 'DISPLAY cannot mount the Windows partition; display unchanged'
    else
        if mkdir -p "$work/windows/USOS/NT6" && usos_display_stage "$work/windows/USOS/NT6" "$LIB/USOSRES.EXE" "$display_request" &&
            cmp -s "$LIB/USOSRES.EXE" "$work/windows/USOS/NT6/USOSRES.EXE"; then
            log "DISPLAY request=$display_request apply=first-sign-in vm=deferred"
        else
            rm -rf "$work/windows/USOS/NT6"
            log 'DISPLAY staging failed; display unchanged'
        fi
        sync
        umount "$work/windows" || fail 'cannot unmount the Windows partition'
    fi
fi

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
if [ "$X86_SELF" = 1 ]; then
    # The x86 ISO's own BIOS boot manager (its BCD names [boot]\sources\boot.wim).
    root_bootmgr=$(pick /bootmgr)
    [ -n "$root_bootmgr" ] || fail 'the Windows ISO has no bootmgr in its root'
    cp "$root_bootmgr" "$work/pcat/bootmgr" || fail 'cannot take bootmgr from the Windows ISO'
else
    wimlib-imagex extract "$wim" "$boot_index" /Windows/Boot/PCAT/bootmgr --dest-dir="$work/pcat" --no-acls >/dev/null || fail 'cannot take bootmgr from the PE10 donor'
fi
cp "$work/pcat/bootmgr" "$work/staging/bootmgr" && cmp -s "$work/pcat/bootmgr" "$work/staging/bootmgr" || fail 'bootmgr copy failed'
# NVMe target, 32-bit WinPE: truncatememory 0x100000000 in the staging BCD's
# default entry now, so the WinPE starts below 4 GiB from its first boot and
# does not depend on seeing the disk to set it (X470 2026-10-14: no disk in
# the WinPE, so `usos-x86-csmwrap.exe lowmem` could not reach the BCD). The
# WinPE-side lowmem stays as the fallback (it finds the limit set). Edited
# on a copy; any refusal leaves the donor's BCD as it is.
cp "$bcd" "$work/bcd" || fail 'BCD copy failed'
case "$TARGET_DEVICE" in /dev/nvme*)
    if [ "$X86_SELF" = 1 ]; then
        if command -v usos-fb-ui >/dev/null 2>&1; then
            usos-fb-ui --bcd-truncatememory "$work/bcd" | while IFS= read -r line; do log "$line"; done
        else
            log 'BCD_LOWMEM usos-fb-ui missing; the WinPE lowmem step sets the limit'
        fi
    fi ;;
esac
# Vista / 2008 x64 on NVMe: the x64 WinPE 10 boots with testsigning on (the
# installed Vista gets it from usos-vista-install.exe, as for the v11 USB
# backport), so its stornvme service can run the test-signed usosnvme.
if [ "$nvme64" = 1 ]; then
    rc=0
    usos-fb-ui --bcd-testsigning "$work/bcd" > "$work/bcd-testsign.log" || rc=$?
    while IFS= read -r line; do log "$line"; done < "$work/bcd-testsign.log"
    case "$rc" in 0|10) ;; *) fail "staging BCD: testsigning not set (usos-fb-ui exit $rc)" ;; esac
fi
cp "$work/bcd" "$work/staging/boot/bcd" && cmp -s "$work/bcd" "$work/staging/boot/bcd" || fail 'BCD copy failed'
cp "$sdi" "$work/staging/boot/boot.sdi" && cmp -s "$sdi" "$work/staging/boot/boot.sdi" || fail 'boot.sdi copy failed'
log "PE10 boot files PASS boot_index=$boot_index"
wimlib-imagex export "$wim" "$boot_index" "$work/staging/sources/boot.wim" --boot >/dev/null || fail 'cannot copy the PE10 Setup image'

# 4. What the UEFI path's wimboot puts into \Windows\System32 (src/flow/plan.zig
# wimbootPlan .vista): support.cpio, vista-support.cpio, the flags, the source
# binding; plus the CSMWrap flag, the target record and the answer file.
( cd "$work/inject" && cpio -idm < "$SUPPORT_DIR/support.cpio" 2>/dev/null && cpio -idm < "$helpers_cpio" 2>/dev/null ) || fail 'cannot unpack the USOS WinPE helpers'
if [ "$modern_nvme" = 1 ]; then printf '1\r\n' > "$work/inject/usos-nvme-modern.flag"; fi
if [ "$X86_SELF" = 1 ]; then
    [ -r "$work/inject/usos-x86-csmwrap.exe" ] && [ -r "$work/inject/usos-x86-csmwrap.cmd" ] && [ -r "$work/inject/winpeshl.ini" ] || fail 'the USOS WinPE helpers are incomplete'
    printf '1\r\n' > "$work/inject/usos-x86-csmwrap.flag"
    target_ini=usos-csmwrap-target.ini
    helper_check=usos-x86-csmwrap.exe
else
    [ -r "$work/inject/usos-vista-install.exe" ] && [ -r "$work/inject/winpeshl.ini" ] || fail 'the USOS WinPE helpers are incomplete'
    printf '1\r\n' > "$work/inject/usos-modern-vista.flag"
    printf '1\r\n' > "$work/inject/usos-external-pe10.flag"
    printf '1\r\n' > "$work/inject/usos-vista-csmwrap.flag"
    if [ "${VISTA_TESTMODE_WATERMARK_ON:-0}" = 1 ]; then
        : > "$work/inject/usos-testmode-watermark-on.flag"
    fi
    target_ini=usos-vista-target.ini
    helper_check=usos-vista-install.exe
fi
cp "$REQUEST_DIR/usos-source.ini" "$work/inject/usos-source.ini"
# target_bus=nvme: the WinPE nvme step (usos-x86-csmwrap.cmd) gives an
# installed Windows 7 / Vista / Server 2008 x86 its NVMe boot driver
# (docs/nvme-nt6-2026-10-12.md); the gate is in vista_csmwrap_prepare.sh.
case "$TARGET_DEVICE" in /dev/nvme*) target_bus=nvme ;; *) target_bus=other ;; esac
printf 'disk_signature=%s\r\nstaging_start=%s\r\nstaging_sectors=%s\r\nesp_start=%s\r\ndisk_sectors=%s\r\nwindows_start=%s\r\nwindows_sectors=%s\r\ntarget_bus=%s\r\n' "$signature_hex" "$staging_start" "$staging_sectors" "$esp_start" "$total" "$windows_start" "$windows_sectors" "$target_bus" > "$work/inject/$target_ini"
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
# NVMe target, 32-bit Windows 7 / Vista / Server 2008 (USOS_PE_NVME=usosnvme
# from vista_csmwrap_prepare.sh; docs/nvme-nt6-2026-10-12.md section 15):
# the donor's boot-start stornvme service gets usosnvme (polled SCSIPORT
# miniport) as its image, so Microsoft's stornvme never touches the
# controller in the PE (X470 2026-10-13: size / layout error 433, then the
# controller was off PCI until a power-off). Service, INF and the hwcompat
# route stay stornvme.inf; only this PE copy on the target disk changes.
pe_nvme=0
if [ "$target_bus" = nvme ] && [ "${USOS_PE_NVME:-}" = usosnvme ]; then
    [ -r "$work/inject/usosnvme-nt6.sys" ] || fail 'usosnvme-nt6.sys is missing from the USOS WinPE helpers'
    printf 'add "%s" "/Windows/System32/drivers/stornvme.sys"\n' "$work/inject/usosnvme-nt6.sys" >> "$commands"
    pe_nvme=1
fi
wimlib-imagex update "$work/staging/sources/boot.wim" 1 < "$commands" >/dev/null || fail 'cannot add the USOS helpers to the PE10 image'
rm -rf "$work/check"; mkdir -p "$work/check"
wimlib-imagex extract "$work/staging/sources/boot.wim" 1 /Windows/System32/winpeshl.ini "/Windows/System32/$target_ini" "/Windows/System32/$helper_check" --dest-dir="$work/check" --no-acls >/dev/null || fail 'read-back: the helpers are not in the PE10 image'
for file in winpeshl.ini "$target_ini" "$helper_check"; do
    cmp -s "$work/inject/$file" "$work/check/$file" || fail "read-back: $file differs in the PE10 image"
done
if [ "$pe_nvme" = 1 ]; then
    wimlib-imagex extract "$work/staging/sources/boot.wim" 1 /Windows/System32/drivers/stornvme.sys --dest-dir="$work/check" --no-acls >/dev/null || fail 'read-back: no stornvme.sys in the PE10 image'
    cmp -s "$work/inject/usosnvme-nt6.sys" "$work/check/stornvme.sys" || fail 'read-back: the PE10 stornvme.sys is not usosnvme'
    log 'PE10 NVMe: stornvme service runs usosnvme PASS'
fi
rm -f "$work/inject/usos-unattend.xml"
log "PE10 image PASS files=$(wc -l < "$commands" | tr -d ' ')"
sync
umount "$work/donor"; losetup -d "$loop"; loop=''
umount "$work/staging"
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true

# 5. The CSMWrap ESP at the end (the XP script, unchanged: slot 2, 64 MiB).
TARGET_DEVICE=$TARGET_DEVICE USOS_XP_ESP_TAIL_SECTORS=$ESP_TAIL sh "$LIB/xp_csmwrap_esp.sh" || fail 'the CSMWrap ESP could not be created'

# 6. Read back the final table: Windows slot 1 (inactive), the active NTFS
# staging slot 2, the CSMWrap ESP slot 3.
dd if="$TARGET_DEVICE" of="$work/mbr.final" bs=512 count=1 2>/dev/null
s_off=462; e_off=478
[ "$(od -An -tx1 -j$s_off -N1 "$work/mbr.final" | tr -d ' \n')" = 80 ] || fail 'read-back: staging partition is not active'
[ "$(od -An -tu1 -j$((s_off + 4)) -N1 "$work/mbr.final" | tr -d ' \n')" = 7 ] || fail 'read-back: staging partition type'
[ "$(od -An -tu1 -j$((e_off + 4)) -N1 "$work/mbr.final" | tr -d ' \n')" = 239 ] || fail 'read-back: CSMWrap ESP slot'
[ "$(od -An -tu4 -j$((e_off + 8)) -N4 "$work/mbr.final" | tr -d ' \n')" = "$esp_start" ] || fail 'read-back: CSMWrap ESP start'
[ "$(od -An -tx1 -j446 -N1 "$work/mbr.final" | tr -d ' \n')" = 00 ] || fail 'read-back: Windows partition must be inactive'
[ "$(od -An -tu1 -j450 -N1 "$work/mbr.final" | tr -d ' \n')" = 7 ] || fail 'read-back: Windows partition type'
[ "$(od -An -tu4 -j454 -N4 "$work/mbr.final" | tr -d ' \n')" = "$windows_start" ] || fail 'read-back: Windows partition start' 
sync
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true
log "PREPARED PASS signature=$signature_hex windows_sectors=$windows_sectors x86_self=$X86_SELF"
