#!/bin/sh
# Prepare the shared volume directly as NTFS, avoiding XP's FAT/CHS successor.
# The XP UEFI-CSM profile (USOS_PLAN_PROFILE=xp-x86-sp3-uefi-csm) also integrates
# the driver bundle, stages the PAE helper and verifies the target read-only.
# Windows 2000, Server 2003 and XP x64 from UEFI get the setup-end script, the
# read-only verification and, on NT 5.2, the AHCI driver (nt5_storage_stage.sh)
# and USB on xHCI (xhci98, nt52_usb_stage.sh).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/nt5_profile.sh"
usos_nt5_profile
TARGET_DEVICE=${TARGET_DEVICE:?}
XP_EXPECTED_MBR=${XP_EXPECTED_MBR:?}
XP_WINDOWS_PLAN=${XP_WINDOWS_PLAN:?}
fail() { printf '[XP_NTFS] STOP: %s\n' "$1" >&2; exit 1; }
value() { awk -F= -v key="$2" '$1==key {print $2; exit}' "$1"; }
work=$(mktemp -d)
mounted=no
cleanup() {
    [ "$mounted" = no ] || umount "$work/volume" || true
    rm -f "$work/before" "$work/expected" "$work/after" "$work/boot" "$work/readback" "$work/sector" "$work/accounts.cmd"
    rmdir "$work/volume" "$work" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
slot=$(value "$XP_WINDOWS_PLAN" windows_slot)
start=$(value "$XP_WINDOWS_PLAN" windows_start_lba)
sectors=$(value "$XP_WINDOWS_PLAN" windows_sectors)
dd if="$TARGET_DEVICE" of="$work/before" bs=512 count=1 2>/dev/null
cmp -s "$work/before" "$XP_EXPECTED_MBR" || fail 'MBR changed before NTFS preparation'
cp "$work/before" "$work/expected"
printf '\007' | dd of="$work/expected" bs=1 seek=$((450+(slot-1)*16)) conv=notrunc 2>/dev/null
dd if="$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin" of="$work/expected" bs=440 count=1 conv=notrunc 2>/dev/null
dd if="$work/expected" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc 2>/dev/null
sync
dd if="$TARGET_DEVICE" of="$work/after" bs=512 count=1 2>/dev/null
cmp -s "$work/expected" "$work/after" || fail 'NTFS MBR readback mismatch'
blockdev --rereadpt "$TARGET_DEVICE"
mdev -s
case "$TARGET_DEVICE" in *[0-9]) node="${TARGET_DEVICE}p${slot}" ;; *) node="${TARGET_DEVICE}${slot}" ;; esac
[ -b "$node" ] || fail 'partition node absent'
name=${node##*/}
[ "$(cat "/sys/class/block/$name/start")" = "$start" ] || fail 'partition start mismatch'
[ "$(cat "/sys/class/block/$name/size")" = "$sectors" ] || fail 'partition size mismatch'
[ "$(lsblk -dnro PKNAME "$node")" = "${TARGET_DEVICE##*/}" ] || fail 'partition parent mismatch'
mkntfs -Q -F -s 512 -c 4096 -H "$XP_BIOS_HEADS" -S "$XP_BIOS_SPT" -p "$start" -L Windows "$node"
dd if="$node" of="$work/boot" bs=512 count=16 2>/dev/null
# Retain mkntfs's BPB (disk identity, MFT positions, cluster and volume sizes).
dd if="$SCRIPT_DIR/xp-nt52-ntfs.bin" of="$work/boot" bs=1 skip=84 seek=84 count=8108 conv=notrunc 2>/dev/null
dd if="$work/boot" of="$node" bs=512 count=16 conv=notrunc 2>/dev/null
dd if="$work/boot" of="$node" bs=512 count=1 seek=$((sectors-1)) conv=notrunc 2>/dev/null
sync
dd if="$node" of="$work/readback" bs=512 count=16 2>/dev/null
cmp -s "$work/boot" "$work/readback" || fail 'NT52 NTFS bootstrap readback mismatch'
dd if="$work/boot" of="$work/sector" bs=512 count=1 2>/dev/null
dd if="$node" of="$work/readback" bs=512 skip=$((sectors-1)) count=1 2>/dev/null
cmp -s "$work/sector" "$work/readback" || fail 'NTFS backup boot sector mismatch'
modprobe ntfs3
mkdir "$work/volume"
mount -t ntfs3 "$node" "$work/volume"; mounted=yes
# Typed answer-profile options (src/flow/answer/options.zig): the registry
# set of the rendered profile and usos-reg.exe (tools/windows_usos_reg.c)
# next to usos-users.cmd, which applies and deletes the set at setup end.
usos_nt5_stage_regset() {
    usos_xp_settings_regset "$XP_USER_SETTINGS" "$work/usos-reg.txt" || return 0
    [ -f "$SCRIPT_DIR/usos-reg.exe" ] || fail 'usos-reg.exe is missing from this build'
    cp "$SCRIPT_DIR/usos-reg.exe" "$1/usos-reg.exe" && cp "$work/usos-reg.txt" "$1/usos-reg.txt" || fail 'cannot stage the registry set'
    cmp -s "$SCRIPT_DIR/usos-reg.exe" "$1/usos-reg.exe" && cmp -s "$work/usos-reg.txt" "$1/usos-reg.txt" || fail 'registry set readback mismatch'
    printf '[NT5] registry set staged: %s entries for usos-reg.exe\n' "$(grep -vc '^;' "$work/usos-reg.txt")"
    rm -f "$work/usos-reg.txt"
}
export XP_TARGET_ROOT="$work/volume" MTOOLS_IMAGE="$node"
sh "$SCRIPT_DIR/prepare_xp_local_source.sh"
if [ "${USOS_PLAN_PROFILE:-}" = xp-x86-sp3-uefi-csm ] || [ "${USOS_PLAN_PROFILE:-}" = w2k3-x86-sp2-uefi-csm ]; then
sh "$SCRIPT_DIR/xp_driver_stage.sh" apply || fail 'XP driver integration failed'
elif usos_nt5_uefi_generic_profile && [ "$NT5_SYSTEM" = windows-xp-x64 ]; then
sh "$SCRIPT_DIR/nt5_storage_stage.sh" apply || fail 'NT 5.2 AHCI driver integration failed'
elif [ "${USOS_PLAN_PROFILE:-}" = w2k-x86-sp4-uefi-csm ]; then
# Windows 2000: AHCINT (ScsiPort, polling) and ACPI off (w2k_stage.sh).
sh "$SCRIPT_DIR/w2k_stage.sh" apply || fail 'Windows 2000 AHCI/ACPI integration failed'
# The USOS gap marker at LBA 2046 (AHCINT usos2+'s target check and trace ring,
# LBA 2040-2045 cleared); the partition starts at 2048, the gap is USOS's.
. "$SCRIPT_DIR/w2k_stage.sh"
disk_sig=$(dd if="$TARGET_DEVICE" bs=1 skip=440 count=4 2>/dev/null | od -An -tx4 | tr -d ' \n')
dd if=/dev/zero of="$TARGET_DEVICE" bs=512 seek=2040 count=6 conv=notrunc,fsync 2>/dev/null || fail 'cannot clear the USOS gap trace sectors'
usos_w2k_gap_marker "$disk_sig" > "$work/gap-marker"
dd if="$work/gap-marker" of="$TARGET_DEVICE" bs=512 seek=2046 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the USOS gap marker'
dd if="$TARGET_DEVICE" of="$work/gap-readback" bs=512 skip=2046 count=1 2>/dev/null
cmp -s "$work/gap-marker" "$work/gap-readback" || fail 'USOS gap marker readback mismatch'
printf '[W2K_STAGE] USOS gap marker PASS lba=2046 disk_signature=%s (AHCINT trace ring 2040-2043, test 2045)\n' "$disk_sig"
fi
# NT 5.2 (Server 2003 x86, XP x64) and Windows 2000: USB 2.0 input/storage on
# xHCI through xhci98 (nt52_usb_stage.sh), after the storage step. XP x86
# keeps its bundle.
# Windows 2000 before SP3/SP4 (the Server RTM media) has no usbport.sys,
# which xhci98 imports: skipped, the installed system keeps its own USB.
case "${USOS_PLAN_PROFILE:-}" in w2k3-x86-sp2-uefi-csm|xp-x64-sp2-uefi-csm|w2k-x86-sp4-uefi-csm)
if [ "$NT5_SYSTEM" = windows-2000 ] && [ -z "$(find "$work/volume/\$WIN_NT\$.~LS/I386" -maxdepth 1 -type f \( -iname usbport.sys -o -iname usbport.sy_ \) | head -n 1)" ]; then
printf '[NT52_USB] SKIP: this Windows 2000 source has no usbport.sys (before SP3); no xhci98\n'
else
sh "$SCRIPT_DIR/nt52_usb_stage.sh" apply || fail 'NT 5.2 USB (xhci98) integration failed'
fi ;;
esac
XP_EXPECTED_MBR="$work/expected" sh "$SCRIPT_DIR/prepare_xp_windows_partition.sh"
if [ "${USOS_PLAN_PROFILE:-}" = xp-x86-sp3-uefi-csm ]; then
mkdir -p "$work/volume/USOS/XP"
cp "$SCRIPT_DIR/xp-pae.exe" "$work/volume/USOS/XP/pae.exe"
cp "$SCRIPT_DIR/xp-pae-LICENSE.txt" "$work/volume/USOS/XP/LICENSE.txt"
cmp -s "$SCRIPT_DIR/xp-pae.exe" "$work/volume/USOS/XP/pae.exe" || fail 'PAE helper readback mismatch'
# usos-xp.ini accounts: pae.exe runs this hidden at setup end and deletes it.
if [ -n "${XP_USER_SETTINGS:-}" ] && [ -z "${XP_CUSTOM_SIF:-}" ]; then
. "$SCRIPT_DIR/xp_user_settings.sh"
usos_xp_settings_accounts "$XP_USER_SETTINGS" "$work/accounts.cmd" || fail 'cannot render usos-xp.ini accounts'
cp "$work/accounts.cmd" "$work/volume/USOS/XP/usos-users.cmd"
cmp -s "$work/accounts.cmd" "$work/volume/USOS/XP/usos-users.cmd" || fail 'usos-users.cmd readback mismatch'
rm -f "$work/accounts.cmd"
printf '[XP_PAE] usos-users.cmd staged (accounts from usos-xp.ini, run hidden by pae.exe)\n'
usos_nt5_stage_regset "$work/volume/USOS/XP"
fi
# Installer-chosen language (only that one is on the ESP); pae.exe falls back to English.
if [ -f /mnt/esp/EFI/USOS/lang-xp.ini ]; then
cp /mnt/esp/EFI/USOS/lang-xp.ini "$work/volume/USOS/XP/pae-strings.ini"
cmp -s /mnt/esp/EFI/USOS/lang-xp.ini "$work/volume/USOS/XP/pae-strings.ini" || fail 'PAE strings readback mismatch'
printf '[XP_PAE] strings=lang-xp.ini
'
else
printf '[XP_PAE] strings=built-in English (no lang-xp.ini on ESP)
'
fi
sync
umount "$work/volume"; mounted=no
blockdev --flushbufs "$TARGET_DEVICE" || fail 'cannot flush target disk buffers'
# Read-only remount: refuse zero-filled staged files, then flush again.
sh "$SCRIPT_DIR/xp_verify_target.sh" "$node" "$SCRIPT_DIR/xp-pae.exe" || fail 'post-write read-only verification failed'
elif usos_nt5_uefi_generic_profile; then
# Windows 2000, Server 2003 and XP x64 from UEFI: no pae.exe, no XP driver
# bundle. NT 5.2 gets GenAHCI on its own StorPort (nt5_storage_stage.sh).
# usos-setup.cmd runs at setup end ([SetupParams] UserExecute of the
# system's automatic answer) and creates the usos-xp.ini accounts; on Server
# 2003 it also adds /PAE to boot.ini and hides "Manage Your Server".
setup_dir="$work/volume/USOS/$NT5_SETUP_DIR"
mkdir -p "$setup_dir"
{
    printf '@echo off\r\n'
    printf 'rem USOS: %s setup end (UserExecute).\r\n' "$NT5_NAME"
    printf 'set USOS_DIR=%%SystemDrive%%\\USOS\\%s\r\n' "$NT5_SETUP_DIR"
    printf 'set USOS_LOG=%%SystemRoot%%\\usos-setup.log\r\n'
    printf 'if exist "%%USOS_DIR%%\\usos-users.cmd" call "%%USOS_DIR%%\\usos-users.cmd"\r\n'
    printf 'if exist "%%USOS_DIR%%\\usos-users.cmd" del /f /q "%%USOS_DIR%%\\usos-users.cmd"\r\n'
    if [ "$NT5_SYSTEM" = windows-server-2003 ]; then
        printf 'rem Enterprise/Datacenter: /PAE on the installed entry (without it SP2 uses PAE only with DEP).\r\n'
        printf 'bootcfg /raw "/PAE" /A /ID 1 >> "%%USOS_LOG%%" 2>&1\r\n'
        printf 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\CurrentVersion\\MYS" /v DisableShowAtLogon /t REG_DWORD /d 1 /f >> "%%USOS_LOG%%" 2>&1\r\n'
    fi
    printf 'exit /b 0\r\n'
} > "$setup_dir/usos-setup.cmd"
# Windows 2000 Server: the first logon's [GuiRunOnce] imports srvwiz.reg
# ("Configure Your Server" off; w2k_stage.sh usos_w2k_server_sif).
if [ "$NT5_SYSTEM" = windows-2000 ]; then
. "$SCRIPT_DIR/w2k_stage.sh"
if usos_w2k_server_source "$work/volume/\$WIN_NT\$.~LS/I386/TXTSETUP.SIF"; then
usos_w2k_server_reg > "$setup_dir/srvwiz.reg"
printf '[NT5] srvwiz.reg staged in USOS/%s (Windows 2000 Server: Configure Your Server off at the first logon)\n' "$NT5_SETUP_DIR"
fi
fi
if [ -n "${XP_USER_SETTINGS:-}" ] && [ -z "${XP_CUSTOM_SIF:-}" ]; then
. "$SCRIPT_DIR/xp_user_settings.sh"
usos_xp_settings_accounts "$XP_USER_SETTINGS" "$work/accounts.cmd" || fail 'cannot render usos-xp.ini accounts'
cp "$work/accounts.cmd" "$setup_dir/usos-users.cmd"
cmp -s "$work/accounts.cmd" "$setup_dir/usos-users.cmd" || fail 'usos-users.cmd readback mismatch'
rm -f "$work/accounts.cmd"
printf '[NT5] usos-users.cmd staged in USOS/%s (accounts from usos-xp.ini, run by usos-setup.cmd at setup end)\n' "$NT5_SETUP_DIR"
usos_nt5_stage_regset "$setup_dir"
fi
sync
umount "$work/volume"; mounted=no
blockdev --flushbufs "$TARGET_DEVICE" || fail 'cannot flush target disk buffers'
sh "$SCRIPT_DIR/xp_verify_target.sh" "$node" || fail 'post-write read-only verification failed'
else
sync
umount "$work/volume"; mounted=no
fi
printf '[XP_NTFS] PREPARED PASS native-NTFS=yes bootstrap=Microsoft-NT52 source-and-Windows=C:\n'
