#!/bin/sh
# Prepare only the guarded WORK copy. The selected original ISO stays read-only.
set -eu
mode=${1:-prepare}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fail() { printf '[WINDOWS7_UEFI] STOP: %s\n' "$1" >&2; exit 1; }
wim_xml_text() {
 # $1 = wim path; prints UTF-16LE-decoded XML to stdout. Validates plain (flags 0/2) XML range.
 _wim_path="$1"
 [ "$(dd if="$_wim_path" bs=1 count=5 2>/dev/null)" = MSWIM ] || return 1
 _hdr=$(od -An -tu4 -j72 -N24 "$_wim_path") || return 1
 _bytes=$(printf '%s' "$_hdr" | awk '{print $1}')
 _flags=$(printf '%s' "$_hdr" | awk '{print $2}')
 _offset=$(printf '%s' "$_hdr" | awk '{print $3}')
 _high=$(printf '%s' "$_hdr" | awk '{print $4}')
 _raw=$(printf '%s' "$_hdr" | awk '{print $5}')
 _raw_high=$(printf '%s' "$_hdr" | awk '{print $6}')
 [ -n "$_bytes" ] && [ -n "$_offset" ] || return 1
 [ "$_high" = 0 ] && [ "$_raw_high" = 0 ] || return 1
 case "$_flags" in 0|33554432) ;; *) return 1 ;; esac
 [ "$_bytes" = "$_raw" ] && [ "$_bytes" -ge 2 ] && [ "$_bytes" -le 1048576 ] && [ "$_offset" -ge 208 ] && [ "$((_offset+_bytes))" -le "$(stat -c %s "$_wim_path")" ] || return 1
 dd if="$_wim_path" bs=4096 skip="$((_offset/4096))" count="$(((_offset%4096+_bytes+4095)/4096))" 2>/dev/null |
  dd bs=1 skip="$((_offset%4096))" count="$_bytes" 2>/dev/null | od -An -v -tu2 |
  awk '{for(i=1;i<=NF;i++)if($i>0&&$i<128)printf "%c",$i;else printf "?"}'
}
root=${SOURCE_ROOT:?SOURCE_ROOT is required}
boot=$(find "$root" -type f | awk 'tolower($0) ~ /\/sources\/boot\.wim$/ {print; exit}')
install=$(find "$root" -type f | awk 'tolower($0) ~ /\/sources\/install\.wim$/ {print; exit}')
[ -n "$boot" ] && [ -n "$install" ] || fail 'Windows 7 needs sources/boot.wim and sources/install.wim'
command -v wimlib-imagex >/dev/null 2>&1 || fail 'wimlib is missing'
[ "$(dd if="$boot" bs=1 count=5 2>/dev/null)" = MSWIM ] || fail 'invalid boot WIM'
set -- $(od -An -tu4 -j72 -N24 "$boot")
[ "$#" = 6 ] || fail 'truncated WIM header'
bytes=$1; flags=$2; offset=$3; high=$4; raw=$5; raw_high=$6
[ "$high" = 0 ] && [ "$raw_high" = 0 ] || fail 'unsupported WIM XML offset'
case "$flags" in 0|33554432) ;; *) fail 'compressed WIM XML is unsupported' ;; esac
[ "$bytes" = "$raw" ] && [ "$bytes" -ge 2 ] && [ "$bytes" -le 1048576 ] && [ "$offset" -ge 208 ] && [ "$((offset+bytes))" -le "$(stat -c %s "$boot")" ] || fail 'invalid WIM XML range'
index=$(od -An -tu4 -j120 -N4 "$boot" | tr -d ' \n')
case "$index" in ''|*[!0-9]*|0) fail 'WIM has no boot image' ;; esac
metadata=$(wim_xml_text "$boot" | awk -v boot_index="$index" -f "$SCRIPT_DIR/windows_wim_version.awk") || fail 'cannot read WIM metadata'
install_targets=$(wim_xml_text "$install" | awk -f "$SCRIPT_DIR/windows7_install_targets.awk") || fail 'cannot read install WIM metadata'
[ -n "${install_targets:-}" ] || fail 'install WIM has no images'
# WORK preparation still requires native Win7 SP1; PE10 selection belongs to the UEFI ISO backend.
[ "$metadata" = '9 6 1' ] || fail 'WORK path requires original Windows 7 x64 Setup (WinPE 6.1)'
printf '%s\n' "$install_targets" | awk 'NF!=4{exit 1} !($1==9&&$2==6&&$3==1&&$4==7601){exit 1}' || fail 'WORK path requires all install images 6.1.7601 x64 (SP1)'
for required in win7-wrapper.efi UefiSeven.efi uefiseven-LICENSE.txt usos-win7-finalize.exe usos-launch-x86_64.exe usos-source-x86_64.exe imdisk-x86_64.exe imdisk-x86_64.sys imdisk-x86_64.cpl windows7_uefi_startup.cmd prepare_windows7_nvme.sh pe-file-version usos-win7-nvme.exe usos-win7-unattend.exe windows7-nvme/files.tsv windows7-nvme/paths.txt; do
 [ -f "$SCRIPT_DIR/$required" ] || fail "missing component: $required"
done
[ "$mode" != --check ] || { printf '[WINDOWS7_UEFI] preflight PASS\n'; exit 0; }

work=${WORK_ROOT:?WORK_ROOT is required}
[ "$work" != / ] && [ -f "$work/.usos-work" ] || fail 'guarded WORK marker is missing'
nonce=$(awk -F= '$1=="nonce" {print $2;exit}' "$work/.usos-work")
case "$nonce" in ''|*[!a-zA-Z0-9-]*) fail 'invalid WORK nonce' ;; esac
case "${WORK_PARTUUID:-}" in ''|*[!a-fA-F0-9-]*) fail 'invalid WORK partition identity' ;; esac
stage="$work/.usos-win7-stage"
mkdir "$stage" || fail 'staging directory already exists'
mkdir "$stage/USOS" "$stage/manager"
u="$stage/USOS"
wimlib-imagex extract "$install" 1 Windows/Boot/EFI/bootmgfw.efi --dest-dir="$stage/manager" --no-acls || fail 'cannot extract the original Windows EFI loader'
original="$stage/manager/bootmgfw.efi"
[ -s "$original" ] || fail 'original Windows EFI loader is missing'
cp "$original" "$u/win7.original.efi"
cp "$SCRIPT_DIR/win7-wrapper.efi" "$u/win7-wrapper.efi"
cp "$SCRIPT_DIR/UefiSeven.efi" "$u/win7.efi"
cp "$SCRIPT_DIR/uefiseven-LICENSE.txt" "$u/uefiseven-LICENSE.txt"
cp "$SCRIPT_DIR/usos-win7-finalize.exe" "$u/usos-win7-finalize.exe"
cp "$SCRIPT_DIR/usos-launch-x86_64.exe" "$u/usos-launch.exe"
cp "$SCRIPT_DIR/usos-source-x86_64.exe" "$u/usos-source.exe"
for ext in exe cpl sys; do cp "$SCRIPT_DIR/imdisk-x86_64.$ext" "$u/imdisk.$ext"; done
printf 'work_partuuid=%s\r\n' "$WORK_PARTUUID" > "$u/usos-source.ini"
printf '[config]\r\nverbose=0\r\nlogfile=0\r\nskiperrors=0\r\n' > "$u/UefiSeven.ini"
sed "s/@USOS_NONCE@/$nonce/g" "$SCRIPT_DIR/windows7_uefi_startup.cmd" > "$u/usos-start.cmd"
drivers=${WINDOWS7_DRIVERS_ROOT:-/mnt/data/Systems/Windows/Windows 7/Drivers/x64}
mkdir "$u/drivers"
if [ -d "$drivers" ]; then
 cp -R "$drivers/." "$u/drivers/"
 mkdir -p "$work/\$WinPEDriver\$"
 cp -R "$drivers/." "$work/\$WinPEDriver\$/"
fi
# USOS Win7 x64 SHA-2 queue: Updates/KB4474419*.msu staged obok drivers; kolejnosc sztywna: Add-Package PRZED Add-Driver. Brak pliku = warning, nie fail.
updates_root=${WINDOWS7_UPDATES_ROOT:-/mnt/data/Systems/Windows/Windows 7/Updates}
mkdir -p "$u/updates"
if ls "$updates_root"/KB4474419*.msu >/dev/null 2>&1; then
 cp "$updates_root"/KB4474419*.msu "$u/updates/"
 printf '[WINDOWS7_UEFI] SHA-2 queued: KB4474419 staged, Add-Package before Add-Driver\n'
else
 printf '[WINDOWS7_UEFI] WARNING: brak KB4474419*.msu w Updates - SHA-2 queue pominieta, dalej Add-Driver\n'
fi
# USOS Win7 x64 opt-in: ACPI_MOD.sys tylko po BSOD A5 (backup + rollback), domyslnie OFF.
# Ustaw USOS_WIN7_ACPI_MOD=1 aby zastosowac; wymaga wczesniej odlozonego pliku ACPI_MOD.sys w $u/drivers (nie dolaczamy binariow).
if [ "${USOS_WIN7_ACPI_MOD:-0}" = "1" ]; then
 printf '[WINDOWS7_UEFI] ACPI_MOD opt-in ON (po BSOD A5): backup acpi.sys + rollback dostepny\n'
 printf 'acpi_mod=on backup=acpi.sys.original rollback=yes\n' > "$u/acpi-mod.flag"
else
 printf '[WINDOWS7_UEFI] ACPI_MOD OFF (domyslnie; wlacz tylko po BSOD A5)\n'
fi
# USOS Win7 x64 opt-in: UEFISEVEN tylko czyste UEFI Class 3 bez CSM, SecureBoot Off.
# Backup: bootmgfw.efi -> bootmgfw.original.efi (juz: win7.original.efi). Na X470 z CSM Video=Legacy domyslnie OFF.
# Ustaw USOS_WIN7_UEFISEVEN=1 aby wymusic; =0 aby pominac; auto = OFF gdy wykryto CSM (tutaj: domyslnie OFF, staging decyduje).
if [ "${USOS_WIN7_UEFISEVEN:-0}" = "1" ]; then
 cp "$original" "$u/bootmgfw.original.efi"
 printf '[WINDOWS7_UEFI] UEFISEVEN opt-in ON (Class 3 bez CSM, SecureBoot Off; backup bootmgfw.original.efi)\n'
 printf 'uefiseven=on backup=bootmgfw.original.efi secureboot=off\n' > "$u/uefiseven.flag"
else
 printf '[WINDOWS7_UEFI] UEFISEVEN OFF (domyslnie; na X470 z CSM Video=Legacy zostaw OFF)\n'
fi
printf '[LaunchApps]\r\n%%SYSTEMROOT%%\\System32\\wpeinit.exe\r\nX:\\USOS\\usos-launch.exe\r\n' > "$stage/winpeshl.ini"
work_boot=$(find "$work" -type f | awk 'tolower($0) ~ /\/sources\/boot\.wim$/ {print;exit}')
[ -n "$work_boot" ] || fail 'WORK boot WIM missing'
sh "$SCRIPT_DIR/prepare_windows7_nvme.sh" "$boot" "$index" "$stage" || fail 'cannot stage native NVMe support'
{ cat "$stage/nvme-update.txt"; printf 'add "%s" /USOS\nadd "%s" /Windows/System32/winpeshl.ini\n' "$u" "$stage/winpeshl.ini"; } |
 wimlib-imagex update "$work_boot" "$index" || fail 'cannot prepare the WinPE startup'
efi_root=$(find "$work" -mindepth 1 -maxdepth 1 -type d | awk 'tolower($0) ~ /\/efi$/ {print;exit}')
[ -n "$efi_root" ] || efi_root="$work/efi"
mkdir -p "$efi_root"
# The chain lives in EFI/USOS-WORK, never in the removable-media EFI/BOOT:
# firmware lists every partition with EFI/BOOT/BOOTX64.EFI as a boot option.
# win7-wrapper.efi and UefiSeven resolve win7.efi/win7.original.efi and
# UefiSeven.ini next to themselves, and bootmgfw reads the device-absolute
# \EFI\Microsoft\Boot\BCD, so the directory name does not matter to them.
efi=$(find "$efi_root" -mindepth 1 -maxdepth 1 -type d | awk 'tolower($0) ~ /\/usos-work$/ {print;exit}')
[ -n "$efi" ] || efi="$efi_root/USOS-WORK"
mkdir -p "$efi"
entry=$(find "$efi" -mindepth 1 -maxdepth 1 -type f | awk 'tolower($0) ~ /\/bootx64\.efi$/ {print;exit}')
[ -n "$entry" ] || entry="$efi/BOOTX64.EFI"
cp "$u/win7-wrapper.efi" "$entry"
for file in win7.original.efi win7.efi UefiSeven.ini uefiseven-LICENSE.txt; do cp "$u/$file" "$efi/$file"; done
cmp "$u/win7-wrapper.efi" "$entry" || fail 'EFI loader readback failed'
# The staging path is fixed below the already guarded WORK root.
rm -rf "$stage"
printf '[WINDOWS7_UEFI] prepared x64 Setup, driver staging and target EFI finalizer\n'
