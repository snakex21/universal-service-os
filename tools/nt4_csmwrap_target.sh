#!/bin/sh
# Windows NT 4.0 Workstation / Server from the UEFI menu without firmware CSM
# (profile nt4-x86-qemu-csmwrap, experimental; docs/nt4-2026-10-07.md).
# Called by tools/w9x_csmwrap_prepare.sh after the user picked and confirmed
# the disk. The whole NT4 install then runs in QEMU on this disk
# (tools/nt4_qemu_install.sh: -cpu pentium3, IDE); the RTM text-mode kernel
# cannot start on a Zen 3 CPUID and the SP6a kernel cannot run text mode, so
# the real machine only ever boots the finished SP6a system through CSMWrap.
#
# Writes ONLY $TARGET_DEVICE:
#   MBR     USOS MBR code (boots the active partition), new disk signature
#   slot 1  FAT16 (type 06), active, LBA 63, 2000 MiB, 32 KiB clusters,
#           255 heads / 63 sectors (the layout of the 2026-10-07 QEMU lab)
#   (slot 2, the CSMWrap ESP, is written after the install: the VM sees only
#   the first NT4_VM_DISK_BYTES of the disk)
# Files on C: (winnt /b layout, all names upper case):
#   \$WIN_NT$.~LS\I386   the CD's I386 tree (local source)
#   \$WIN_NT$.~LS\$OEM$  and \$WIN_NT$.~LS\I386\$OEM$: CMDLINES.TXT
#   \$WIN_NT$.~BT        the top-level I386 files + WINNT.SIF (the answer)
#   \$LDR$, \TXTSETUP.SIF  Setup loader for the hard-disk start
#   \USOS\NT4            POST.CMD (first logon), the .REG files,
#                        AHCINT.SYS + USOSRST.SYS (NT4 builds), USOSOFF.EXE,
#                        SP6I386.EXE (the user's SP6a from DATA)
#   syslinux (GPL-2.0-or-later) in the boot sector, SYSLINUX.CFG starts
#   chain.c32 ntldr=/$LDR$; text-mode Setup replaces the boot sector with
#   its own and the files are deleted after the install.
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
SOURCE_ISO=${NT4_SOURCE_ISO:?NT4_SOURCE_ISO is required}
ANSWER_SIF=${NT4_ANSWER_SIF:?NT4_ANSWER_SIF is required}
ANSWER_KIND=${NT4_ANSWER_KIND:-PROFILE}
SP_EXE=${NT4_SP_EXE:-}
LIB=${USOS_LIB_DIR:-/usr/lib/usos}
SYSLINUX_DIR=${NT4_SYSLINUX_DIR:-/usr/share/syslinux}
PART_START=63
PART_SECTORS=4096000
MIN_SECTORS=8388608

MTOOLS_SKIP_CHECK=1
export MTOOLS_SKIP_CHECK
log() { printf '[NT4_CSMWRAP] %s\n' "$*"; }
fail() { printf '[NT4_CSMWRAP] STOP: %s\n' "$1" >&2; exit 1; }

# Copies the folder $1 to $2 with upper-case names (FAT 8.3, as the CD's
# ISO 9660 names). $3 = "files": top-level files only.
nt4_copy_upper() {
    mkdir -p "$2"
    for item in "$1"/* "$1"/.[!.]*; do
        [ -e "$item" ] || continue
        name=$(basename "$item" | tr '[:lower:]' '[:upper:]')
        if [ -d "$item" ]; then
            [ "${3:-}" = files ] && continue
            nt4_copy_upper "$item" "$2/$name" || return 1
        else
            cp "$item" "$2/$name" || return 1
        fi
    done
}

# The answer file with the USOS time zone marker resolved (stdin -> stdout):
# ";USOS-TZ=<9x zone key>" becomes [GuiUnattended] TimeZone = "<the CD's
# display string>" when the CD's language is known ($1: 0415 Polish, 0409 English),
# otherwise it is dropped (Setup shows the time zone page).
nt4_resolve_time_zone() {
    awk -v BINMODE=3 -v lang="$1" '
        function pl(k) {
            if (k == "Central European" || k == "Central Europe") return "(GMT+01:00) Warszawa, Praga, Budapeszt"
            if (k == "GMT") return "(GMT) Czas Greenwich; Dublin, Edynburg, Londyn, Lizbona"
            if (k == "E. Europe") return "(GMT+02:00) Europa Wschodnia"
            if (k == "Eastern") return "(GMT-05:00) Stany Zjednoczone i Kanada (czas wschodni)"
            if (k == "Pacific") return "(GMT-08:00) Stany Zjednoczone i Kanada (czas pacyficzny); Tijuana"
            if (k == "Atlantic") return "(GMT-04:00) Kanada (czas atlantycki)"
            if (k == "Alaskan") return "(GMT-09:00) Alaska"
            if (k == "Hawaiian") return "(GMT-10:00) Hawaje"
            if (k == "Tokyo") return "(GMT+09:00) Tokio, Osaka, Sapporo, Seul, Jakuck"
            if (k == "Israel") return "(GMT+02:00) Izrael"
            if (k == "Egypt") return "(GMT+02:00) Kair"
            if (k == "India") return "(GMT+05:30) Bombaj, Kalkuta, Madras, Delhi, Kolombo"
            if (k == "New Zealand") return "(GMT+12:00) Wellington, Auckland"
            if (k == "AUS Eastern") return "(GMT+10:00) Brisbane, Melbourne, Sydney"
            if (k == "Iran") return "(GMT+03:30) Tehran"
            if (k == "Arab") return "(GMT+03:00) Bagdad, Kuwejt, Nairobi, Ar-Rijad"
            if (k == "Arabian") return "(GMT+04:00) Abu Zabi, Maskat, Tbilisi"
            return ""
        }
        function en(k) {
            if (k == "Central European" || k == "Central Europe") return "(GMT+01:00) Prague, Warsaw, Budapest"
            if (k == "W. Europe") return "(GMT+01:00) Berlin, Stockholm, Rome, Bern, Brussels, Vienna"
            if (k == "Romance") return "(GMT+01:00) Paris, Madrid, Amsterdam"
            if (k == "GMT") return "(GMT) Greenwich Mean Time; Dublin, Edinburgh, London, Lisbon"
            if (k == "E. Europe") return "(GMT+02:00) Eastern Europe"
            if (k == "GTB" || k == "FLE") return "(GMT+02:00) Athens, Helsinki, Istanbul"
            if (k == "Russian") return "(GMT+03:00) Moscow, St. Petersburg, Kazan, Volgograd"
            if (k == "Eastern") return "(GMT-05:00) Eastern Time (US & Canada)"
            if (k == "Central") return "(GMT-06:00) Central Time (US & Canada)"
            if (k == "Mountain") return "(GMT-07:00) Mountain Time (US & Canada)"
            if (k == "Pacific") return "(GMT-08:00) Pacific Time (US & Canada); Tijuana"
            if (k == "Atlantic") return "(GMT-04:00) Atlantic Time (Canada)"
            if (k == "Alaskan") return "(GMT-09:00) Alaska"
            if (k == "Hawaiian") return "(GMT-10:00) Hawaii"
            if (k == "Tokyo") return "(GMT+09:00) Tokyo, Osaka, Sapporo, Seoul, Yakutsk"
            if (k == "Israel") return "(GMT+02:00) Israel"
            if (k == "Egypt") return "(GMT+02:00) Cairo"
            if (k == "India") return "(GMT+05:30) Bombay, Calcutta, Madras, New Delhi, Colombo"
            if (k == "New Zealand") return "(GMT+12:00) Wellington, Auckland"
            if (k == "AUS Eastern") return "(GMT+10:00) Brisbane, Melbourne, Sydney"
            if (k == "China") return "(GMT+08:00) Beijing, Chongqing, Urumqi"
            return ""
        }
        { line = $0; sub(/\r$/, "", line) }
        line ~ /^;USOS-TZ=/ {
            k = substr(line, 10); v = (lang == "0415") ? pl(k) : (lang == "0409") ? en(k) : ""
            if (v != "") printf "TimeZone = \"%s\"\r\n", v
            next
        }
        { printf "%s\r\n", line }'
}

for tool in dd od mkfs.fat mdir syslinux mount umount losetup blockdev awk sync wc tr; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
for file in "$LIB/xp-geometry-fix-mbr-440.bin" "$LIB/nt4/AHCINT.SYS" "$LIB/nt4/USOSRST.SYS" "$LIB/nt4/USOSOFF.EXE" \
    "$SYSLINUX_DIR/chain.c32" "$SYSLINUX_DIR/libcom32.c32" "$SYSLINUX_DIR/libutil.c32" "$ANSWER_SIF" "$SOURCE_ISO"; do
    [ -r "$file" ] || fail "missing: $file"
done
[ "$(wc -c < "$LIB/xp-geometry-fix-mbr-440.bin" | tr -d ' ')" = 440 ] || fail 'USOS MBR code must be 440 bytes'
[ -z "$SP_EXE" ] || [ -r "$SP_EXE" ] || fail "missing: $SP_EXE"
if awk -v d="$TARGET_DEVICE" 'index($1, d) == 1 { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts; then
    fail 'a partition of the selected disk is mounted; no disk was changed'
fi

work=/run/nt4-csmwrap
rm -rf "$work"
mkdir -p "$work/iso" "$work/c"
cleanup() {
    umount "$work/c" 2>/dev/null || true
    umount "$work/iso" 2>/dev/null || true
    [ -z "${part_loop:-}" ] || losetup -d "$part_loop" 2>/dev/null || true
    [ -z "${iso_loop:-}" ] || losetup -d "$iso_loop" 2>/dev/null || true
    rm -f "$work/WINNT.SIF"
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------- the source
iso_loop=$(losetup -f) || fail 'no free loop device for the ISO'
losetup -r "$iso_loop" "$SOURCE_ISO" || fail 'cannot attach the Windows NT 4.0 ISO'
mount -t iso9660 -o ro "$iso_loop" "$work/iso" || fail 'cannot mount the Windows NT 4.0 ISO'
i386=''
for name in I386 i386; do
    [ -d "$work/iso/$name" ] && i386="$work/iso/$name" && break
done
[ -n "$i386" ] || fail 'the ISO has no I386 folder'
txtsetup=''
for name in TXTSETUP.SIF txtsetup.sif; do [ -f "$i386/$name" ] && txtsetup="$i386/$name" && break; done
setupldr=''
for name in SETUPLDR.BIN setupldr.bin; do [ -f "$i386/$name" ] && setupldr="$i386/$name" && break; done
[ -n "$txtsetup" ] && [ -n "$setupldr" ] || fail 'the ISO has no I386\TXTSETUP.SIF / SETUPLDR.BIN (not an NT 4.0 Setup CD)'
# NT 4.0: [SetupData] MajorVersion = 4 (2000/XP: 5).
major=$(awk '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) == "[setupdata]") } s && tolower($1) == "majorversion" { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }' "$txtsetup")
[ "$major" = 4 ] || fail "the ISO is not Windows NT 4.0 Setup (MajorVersion=${major:-none})"
lang=$(awk '{ sub(/\r$/, "") } tolower($1) == "unicodecasetable" { n = split($0, a, ","); v = a[n]; gsub(/[ \t]/, "", v); print v; exit }' "$txtsetup")
product=$(awk '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) == "[setupdata]") } s && tolower($1) == "producttype" { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }' "$txtsetup")
log "source: NT 4.0 ProductType=${product:-?} language=${lang:-?}"
nt4_resolve_time_zone "${lang:-}" < "$ANSWER_SIF" > "$work/WINNT.SIF" || fail 'cannot prepare WINNT.SIF'
if grep -qi '^TimeZone' "$work/WINNT.SIF"; then log 'time zone: set for this CD language'; else log 'time zone: none (Setup asks)'; fi

# ---------------------------------------------------------------- the disk
size=$(blockdev --getsize64 "$TARGET_DEVICE") || fail 'cannot read the target size'
total=$((size / 512))
[ "$total" -ge "$MIN_SECTORS" ] || fail 'the selected disk is smaller than 4 GiB; no disk was changed'
[ "$total" -le 4294967295 ] || fail 'the selected disk is larger than 2 TiB (MBR); no disk was changed'
log "disk_sectors=$total part_start=$PART_START part_sectors=$PART_SECTORS"

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
# Active, CHS 0/1/1 .. 254/246/55 (255 heads, 63 sectors), type 06 (FAT16 > 32 MiB).
{ printf '\200\001\001\000\006\366\067\376'; le32 "$PART_START"; le32 "$PART_SECTORS"; } | dd of="$mbr" bs=1 seek=446 count=16 conv=notrunc 2>/dev/null
printf '\125\252' | dd of="$mbr" bs=1 seek=510 count=2 conv=notrunc 2>/dev/null
dd if="$mbr" of="$TARGET_DEVICE" bs=512 count=1 conv=notrunc,fsync 2>/dev/null || fail 'cannot write the MBR'

part_loop=$(losetup -f) || fail 'no free loop device for the new partition'
losetup -o $((PART_START * 512)) "$part_loop" "$TARGET_DEVICE" || fail 'cannot attach the new partition'
mkfs.fat -F 16 -s 64 -R 1 -f 2 -r 512 -h "$PART_START" -g 255/63 -D 0x80 -M 0xF8 -n USOS-NT4 "$part_loop" $((PART_SECTORS / 2)) >/dev/null ||
    fail 'cannot format the FAT16 partition'
mount -t vfat -o shortname=winnt,utf8=0 "$part_loop" "$work/c" || fail 'cannot mount the new FAT16 partition'

ls_dir="$work/c/\$WIN_NT\$.~LS"
bt_dir="$work/c/\$WIN_NT\$.~BT"
nt4_copy_upper "$i386" "$ls_dir/I386" || fail 'cannot copy the I386 folder (local source)'
nt4_copy_upper "$i386" "$bt_dir" files || fail 'cannot copy the Setup boot files'
log "local source: $(find "$ls_dir/I386" -type f | wc -l | tr -d ' ') files"
cp "$work/WINNT.SIF" "$bt_dir/WINNT.SIF" || fail 'cannot copy WINNT.SIF'
cp "$work/WINNT.SIF" "$work/c/WINNT.SIF" || fail 'cannot copy WINNT.SIF'
cp "$setupldr" "$work/c/\$LDR\$" || fail 'cannot copy the Setup loader'
cp "$txtsetup" "$work/c/TXTSETUP.SIF" || fail 'cannot copy TXTSETUP.SIF'
# setupldr started from the hard disk runs \NTDETECT.COM of the boot
# partition (QEMU 2026-10-07: "NTDETECT failed" without it).
ntdetect=''
for name in NTDETECT.COM ntdetect.com; do [ -f "$i386/$name" ] && ntdetect="$i386/$name" && break; done
[ -n "$ntdetect" ] || fail 'the ISO has no I386\NTDETECT.COM'
cp "$ntdetect" "$work/c/NTDETECT.COM" || fail 'cannot copy NTDETECT.COM'

# $OEM$ (OemPreinstall = Yes): CMDLINES.TXT runs at the end of GUI-mode Setup
# and turns on one automatic Administrator logon with POST.CMD in RunOnce.
for oem in "$ls_dir/\$OEM\$" "$ls_dir/I386/\$OEM\$"; do
    mkdir -p "$oem"
    printf '[Commands]\r\n"C:\\WINNT\\REGEDIT.EXE /s C:\\USOS\\NT4\\SETUP.REG"\r\n' > "$oem/CMDLINES.TXT"
done

usos="$work/c/USOS/NT4"
mkdir -p "$usos"
cp "$LIB/nt4/AHCINT.SYS" "$usos/AHCINT.SYS" || fail 'cannot copy AHCINT.SYS'
cp "$LIB/nt4/USOSRST.SYS" "$usos/USOSRST.SYS" || fail 'cannot copy USOSRST.SYS'
cp "$LIB/nt4/USOSOFF.EXE" "$usos/USOSOFF.EXE" || fail 'cannot copy USOSOFF.EXE'
if [ -n "$SP_EXE" ]; then
    cp "$SP_EXE" "$usos/SP6I386.EXE" || fail 'cannot copy the service pack'
    log "service pack: $(basename "$SP_EXE") ($(wc -c < "$SP_EXE" | tr -d ' ') bytes)"
else
    log 'service pack: none (the X470 needs SP6a: the RTM kernel stops on Zen CPUs)'
fi
crlf() { awk -v BINMODE=3 '{ sub(/\r$/, ""); printf "%s\r\n", $0 }'; }
crlf > "$usos/SETUP.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"AutoAdminLogon"="1"
"DefaultUserName"="Administrator"
"DefaultPassword"=""

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce]
"USOSNT4"="C:\\USOS\\NT4\\POST.CMD"
EOF
# NT 4.0 is not PnP: a SCSI miniport needs only its file and Services key and
# scans PCI itself; usosrst (HPET legacy replacement off, CMOS century,
# restart through CF9/8042) loads before the HAL's timer is trusted.
crlf > "$usos/DRIVERS.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ahcint]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000001
"Group"="SCSI miniport"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosrst]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000000
"Group"="System Bus Extender"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosrst\Parameters]
"HpetLegacyOff"=dword:00000001
"RtcFix"=dword:00000001
EOF
# End of the VM part: no more automatic logon; atapi off (the real machine has no
# legacy IDE ports: it would only report "a service failed" at every start).
crlf > "$usos/DONE.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"AutoAdminLogon"="0"
"DefaultPassword"=""

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\atapi]
"Start"=dword:00000004
EOF
# The only logon in the VM (automatic, RunOnce from CMDLINES.TXT): drivers,
# SP6a (-u unattended, -z no restart), the version and usosrst keys for the
# check, no more automatic logon, DONE.TXT, then USOSOFF restarts the guest,
# which ends QEMU (-no-reboot). Files SP6a could not replace while in use
# are renamed by SMSS at the first start on the real machine (SP6a kernel).
crlf > "$usos/POST.CMD" <<'EOF'
@echo off
if exist C:\USOS\NT4\POST.OK goto end
echo USOS NT4 post > C:\USOS\NT4\POST.LOG
copy /y C:\USOS\NT4\AHCINT.SYS %SystemRoot%\system32\drivers\ahcint.sys >> C:\USOS\NT4\POST.LOG
copy /y C:\USOS\NT4\USOSRST.SYS %SystemRoot%\system32\drivers\usosrst.sys >> C:\USOS\NT4\POST.LOG
%SystemRoot%\regedit.exe /s C:\USOS\NT4\DRIVERS.REG
echo drivers registered >> C:\USOS\NT4\POST.LOG
if not exist C:\USOS\NT4\SP6I386.EXE goto nosp
echo sp start >> C:\USOS\NT4\POST.LOG
start /wait C:\USOS\NT4\SP6I386.EXE -u -z
echo sp end %errorlevel% >> C:\USOS\NT4\POST.LOG
:nosp
echo ok > C:\USOS\NT4\POST.OK
%SystemRoot%\regedit.exe /e C:\USOS\NT4\VERSION.REG "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
%SystemRoot%\regedit.exe /e C:\USOS\NT4\USOSRST.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosrst
%SystemRoot%\regedit.exe /s C:\USOS\NT4\DONE.REG
echo done > C:\USOS\NT4\DONE.TXT
C:\USOS\NT4\USOSOFF.EXE /r
:end
EOF
printf 'answer=%s\r\n' "$ANSWER_KIND" > "$usos/SOURCE.TXT"

for file in "$SYSLINUX_DIR/chain.c32" "$SYSLINUX_DIR/libcom32.c32" "$SYSLINUX_DIR/libutil.c32"; do
    cp "$file" "$work/c/$(basename "$file" | tr '[:lower:]' '[:upper:]')" || fail "cannot copy $(basename "$file")"
done
printf 'DEFAULT nt4\nPROMPT 0\nTIMEOUT 0\nLABEL nt4\n  COM32 /CHAIN.C32\n  APPEND boot ntldr=/$LDR$\n' > "$work/c/SYSLINUX.CFG"
sync
umount "$work/c" || fail 'cannot unmount the new partition'
syslinux --install "$part_loop" || fail 'syslinux could not make the partition bootable'
mdir -a -i "$part_loop" ::/LDLINUX.SYS >/dev/null 2>&1 || fail 'read-back: LDLINUX.SYS missing'
mdir -i "$part_loop" '::/$LDR$' >/dev/null 2>&1 || fail 'read-back: $LDR$ missing'
losetup -d "$part_loop"; part_loop=''
sync
blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true
dd if="$TARGET_DEVICE" of="$mbr" bs=512 count=1 2>/dev/null || fail 'cannot read back the MBR'
[ "$(od -An -tu1 -j450 -N1 "$mbr" | tr -d ' \n')" = 6 ] || fail 'read-back: the Windows partition type differs'
[ "$(od -An -tu1 -j446 -N1 "$mbr" | tr -d ' \n')" = 128 ] || fail 'read-back: the Windows partition is not active'
log "PASS target=$TARGET_DEVICE answer=$ANSWER_KIND; next: the NT 4.0 install in the VM"
