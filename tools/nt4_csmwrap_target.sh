#!/bin/sh
# Windows NT 4.0 and NT 3.51 Workstation / Server from the UEFI menu without
# firmware CSM (profiles nt4-x86-qemu-csmwrap, nt3-x86-qemu-csmwrap,
# experimental; docs/nt4-2026-10-07.md, docs/nt351-2026-10-08.md).
# NT 3.51 (TXTSETUP.SIF MajorVersion = 3) takes the same layout and differs
# in: no I386\SYSTEM32, no $OEM$ (NT 3.51 has no CMDLINES.TXT, no RunOnce and
# no REGEDIT4 import), \USOS\NT3 instead of \USOS\NT4 with USOSNT3.EXE (own
# GPL tool, tools/nt3/usosnt3: GUI Setup starts it as [GuiUnattended]
# !DetachedProgram; it registers itself as a service that does the
# post-install work at the first start of the installed system) and the NT
# 3.51 driver builds, and the "!"-prefixed GUI keys of the answer file.
# Called by tools/w9x_csmwrap_prepare.sh after the user picked and confirmed
# the disk. The whole NT4 install then runs in QEMU on this disk
# (tools/nt4_qemu_install.sh: -cpu pentium3, IDE); the RTM text-mode kernel
# cannot start on a Zen 3 CPUID and the SP6a kernel cannot run text mode, so
# the real machine only ever boots the finished SP6a system through CSMWrap.
#
# Writes ONLY $TARGET_DEVICE:
#   MBR     USOS MBR code (boots the active partition), new disk signature;
#           NT 3.51: nt3-e820-mbr-440.bin, which also hides E820 entries
#           above 4 GiB / non-RAM entries above 1 MiB from the 3.51 loaders
#           (their kernel otherwise sizes MmHighestPhysicalPage from a
#           firmware range at FFFC0000 and stops with 0x50 in MmInit)
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
#                        AHCINT.SYS + USOSRST.SYS + USOSUSB.SYS (NT4 builds),
#                        USOSVBE.SYS (own VESA miniport), USOSOFF.EXE,
#                        FRAMEBUF.DL_ (copied from the user's CD, if present),
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
# otherwise it is dropped (Setup shows the time zone page). $2 = yes: NT 3.51,
# whose GUI Setup reads "!TimeZone" and runs main.cpl /INSTALL=<string> with
# its own, older list (UNATTEND.TXT of the 3.51 CD; Warsaw is "Lisbon, Warsaw").
nt4_resolve_time_zone() {
    awk -v BINMODE=3 -v lang="$1" -v nt3="${2:-}" '
        function en351(k) {
            if (k == "Central European" || k == "Central Europe") return "(GMT+01:00) Lisbon, Warsaw"
            if (k == "W. Europe") return "(GMT+01:00) Berlin, Stockholm, Rome, Bern, Brussels, Vienna"
            if (k == "Romance") return "(GMT+01:00) Paris, Madrid"
            if (k == "GMT") return "(GMT) Greenwich Mean Time; Dublin, Edinburgh, London"
            if (k == "E. Europe") return "(GMT+02:00) Eastern Europe"
            if (k == "GTB" || k == "FLE") return "(GMT+02:00) Athens, Helsinki, Istanbul"
            if (k == "Russian") return "(GMT+03:00) Moscow, St. Petersburg"
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
            if (k == "New Zealand") return "(GMT+12:00) Wellington"
            if (k == "AUS Eastern") return "(GMT+10:00) Brisbane, Melbourne, Sydney"
            if (k == "China") return "(GMT+08:00) Beijing, Chongqing, Urumqi"
            return ""
        }
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
            k = substr(line, 10)
            if (nt3 == "yes") v = (lang == "0409") ? en351(k) : ""
            else v = (lang == "0415") ? pl(k) : (lang == "0409") ? en(k) : ""
            if (v != "") printf "%sTimeZone = \"%s\"\r\n", (nt3 == "yes" ? "!" : ""), v
            next
        }
        { printf "%s\r\n", line }'
}

# The Server pages of GUI-mode Setup (stdin -> stdout, CR LF) when the CD's
# TXTSETUP.SIF [SetupData] ProductType ($1) is not 0 (Workstation): NT 4.0
# Server and Enterprise Server Setup wait on "Server Type" (syssetup.dll,
# [GuiUnattended] AdvServerType = SERVERNT | LANSECNT | LANMANNT) and on
# "Choose Licensing Mode" (liccpa.cpl, [LicenseFilePrintData] AutoMode /
# AutoUsers) when the answer lacks them (X470 2026-10-07: the install VM sat
# on a page at 15 MB written). Stand-alone server (no network is installed,
# so no domain role), Per Server for 5 connections; keys already in the
# answer are kept. $2 = yes: NT 3.51 ("!"-prefixed keys, same values).
nt4_server_answer() {
    awk -v BINMODE=3 -v product="$1" -v bang="$([ "${2:-}" = yes ] && echo '!')" '
        { line = $0; sub(/\r$/, "", line); lines[++n] = line; low = tolower(line); gsub(/[ \t]/, "", low)
          if (low ~ /^!?advservertype=/) has_type = 1
          if (low ~ /^!?automode=/) has_lic = 1 }
        END {
            server = (product != "" && product != "0")
            for (i = 1; i <= n; i++) {
                printf "%s\r\n", lines[i]
                low = tolower(lines[i]); gsub(/[ \t]/, "", low)
                if (server && !has_type && low == "[guiunattended]") { printf "%sAdvServerType = SERVERNT\r\n", bang; has_type = 1 }
                # An empty [LicenseFilePrintData] (the NT 3.51 answer has one) gets the keys.
                if (server && !has_lic && low == "[licensefileprintdata]") { printf "%sAutoMode = PerServer\r\n%sAutoUsers = 5\r\n", bang, bang; has_lic = 1 }
            }
            if (server && !has_type) printf "\r\n[GuiUnattended]\r\n%sAdvServerType = SERVERNT\r\n", bang
            if (server && !has_lic) printf "\r\n[LicenseFilePrintData]\r\n%sAutoMode = PerServer\r\n%sAutoUsers = 5\r\n", bang, bang
        }'
}

# NT 3.51 (stdin -> stdout, CR LF): GUI Setup (INITIAL.INF) starts
# [GuiUnattended] !DetachedProgram with !Arguments early, next to its own
# work. USOSNT3.EXE /setup only registers the USOS service (usosnt3) that
# does the post-install work at the first start of the installed system
# (NT 3.51 has no RunOnce, no CMDLINES.TXT and no .REG import). An answer
# that names its own detached program keeps it, and the service is missing.
nt3_detached_answer() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); lines[++n] = line; low = tolower(line); gsub(/[ \t]/, "", low)
          if (low ~ /^!detachedprogram=/) has = 1 }
        END {
            for (i = 1; i <= n; i++) {
                printf "%s\r\n", lines[i]
                low = tolower(lines[i]); gsub(/[ \t]/, "", low)
                # INITIAL.INF tests $(!SetupNetWork) (capital W; INF variable
                # names are case-sensitive), UNATTEND.TXT documents
                # !SetupNetwork: write both (QEMU 2026-10-08, the network
                # adapter page stopped GUI Setup).
                if (low ~ /^!setupnetwork=/ && lines[i] !~ /^[ \t]*!SetupNetWork[ \t]*=/) {
                    v = lines[i]; sub(/^[^=]*=[ \t]*/, "", v); printf "!SetupNetWork = %s\r\n", v
                }
                if (!has && low == "[guiunattended]") {
                    printf "!DetachedProgram = \"C:\\USOS\\NT3\\USOSNT3.EXE\"\r\n!Arguments = \"/setup\"\r\n"; has = 1
                }
            }
            if (!has) printf "\r\n[GuiUnattended]\r\n!DetachedProgram = \"C:\\USOS\\NT3\\USOSNT3.EXE\"\r\n!Arguments = \"/setup\"\r\n"
        }'
}

# NT 3.51 TXTSETUP.SIF (stdin -> stdout, CR LF): the [hal] rows of the MPS
# machine types (mps_up = halapic.dll, mps_mp = halmps.dll) install the
# "Standard PC" hal.dll (8259 PIC) instead. The install VM has an APIC and an
# MP table, so Setup picks mps_up; on the X470 under CSMWrap the firmware
# leaves the HPET in LegacyReplacement mode, the I/O APIC pin 2 clock never
# ticks and the 3.51 kernel hung right after "1 System Processor [.. KB
# Memory]" (2026-10-08, before any boot driver ran, so usosrst cannot clear
# it). The PIT -> 8259 IRQ 0 path works there (DOS, 9x, Win2000 Standard PC).
# NT 3.51 text-mode Setup has no [Unattended] ComputerType, hence the table.
# [Hal.Load] (the text-mode HAL inside the VM) stays as it is.
nt3_standard_hal() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low)
          if (low ~ /^\[/) sec = low
          else if (sec == "[hal]" && low ~ /^mps[0-9]*_(up|mp)=/) {
              key = line; sub(/[ \t]*=.*/, "", key); rest = line; sub(/^[^,]*/, "", rest)
              line = key " = hal.dll    " rest
          }
          printf "%s\r\n", line }'
}

for tool in dd od mkfs.fat mdir syslinux mount umount losetup blockdev awk sync wc tr; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
for file in "$LIB/xp-geometry-fix-mbr-440.bin" "$SYSLINUX_DIR/chain.c32" "$SYSLINUX_DIR/libcom32.c32" "$SYSLINUX_DIR/libutil.c32" "$ANSWER_SIF" "$SOURCE_ISO"; do
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
[ -n "$txtsetup" ] && [ -n "$setupldr" ] || fail 'the ISO has no I386\TXTSETUP.SIF / SETUPLDR.BIN (not an NT 3.51 / 4.0 Setup CD)'
# [SetupData] MajorVersion: 4 = NT 4.0, 3 = NT 3.51 (2000/XP: 5). NT_MAJOR
# (the system chosen in the menu, when set) must match the CD.
setup_value() {
    awk -v key="$1" '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) == "[setupdata]") } s && tolower($1) == key { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }' "$txtsetup"
}
major=$(setup_value majorversion)
minor=$(setup_value minorversion)
case "$major" in
    4) nt3='' sub=NT4 ;;
    3) nt3=yes sub=NT3 ;;
    *) fail "the ISO is not Windows NT 3.51 / 4.0 Setup (MajorVersion=${major:-none})" ;;
esac
[ -z "${NT_MAJOR:-}" ] || [ "$NT_MAJOR" = "$major" ] || fail "the ISO is Windows NT $major.$minor Setup, not the chosen NT $NT_MAJOR system"
# NT 3.51 and NT 3.5 (MinorVersion 50: the same winnt /b layout; its GUI
# Setup refuses a CPU newer than a Pentium, so its install VM runs -cpu
# pentium, nt4_qemu_install.sh). NT 3.1 has no TXTSETUP.SIF (docs/nt35-2026-10-09.md).
case "$nt3:$minor" in
    yes:51|yes:50|:*) ;;
    *) fail "of the NT 3.x family only NT 3.51 and NT 3.5 are supported so far (MinorVersion=${minor:-none})" ;;
esac
[ -z "${NT_MINOR:-}" ] || [ "$NT_MINOR" = "$minor" ] || fail "the ISO is Windows NT $major.$minor Setup, not the chosen NT $major.$NT_MINOR system"
mbr_code=$LIB/xp-geometry-fix-mbr-440.bin
[ -z "$nt3" ] || mbr_code=$LIB/nt3-e820-mbr-440.bin
[ -r "$mbr_code" ] || fail "missing: $mbr_code"
[ "$(wc -c < "$mbr_code" | tr -d ' ')" = 440 ] || fail 'USOS MBR code must be 440 bytes'
drv=$LIB/$(printf %s "$sub" | tr '[:upper:]' '[:lower:]')
for file in AHCINT.SYS USOSRST.SYS USOSUSB.SYS; do [ -r "$drv/$file" ] || fail "missing: $drv/$file"; done
# usosrst for NT 3.5 (USOSRST35.SYS, build-nt35.cmd): the 3.5 kernel lacks
# KeSetTargetProcessorDpc / KeSetImportanceDpc.
rst=USOSRST.SYS
[ "$nt3:$minor" != yes:50 ] || rst=USOSRST35.SYS
if [ -n "$nt3" ]; then
    for file in USOSNT3.EXE USOSACHK.EXE $rst; do [ -r "$drv/$file" ] || fail "missing: $drv/$file"; done
else
    for file in USOSVBE.SYS USOSOFF.EXE; do [ -r "$drv/$file" ] || fail "missing: $drv/$file"; done
fi
lang=$(awk '{ sub(/\r$/, "") } tolower($1) == "unicodecasetable" { n = split($0, a, ","); v = a[n]; gsub(/[ \t]/, "", v); print v; exit }' "$txtsetup")
product=$(awk '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) == "[setupdata]") } s && tolower($1) == "producttype" { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }' "$txtsetup")
log "source: NT $major.$minor ProductType=${product:-?} language=${lang:-?}"
if [ -n "$nt3" ]; then
    nt4_resolve_time_zone "${lang:-}" yes < "$ANSWER_SIF" | nt4_server_answer "${product:-0}" yes | nt3_detached_answer > "$work/WINNT.SIF" ||
        fail 'cannot prepare WINNT.SIF'
else
    nt4_resolve_time_zone "${lang:-}" < "$ANSWER_SIF" | nt4_server_answer "${product:-0}" > "$work/WINNT.SIF" || fail 'cannot prepare WINNT.SIF'
fi
[ "${product:-0}" = 0 ] || log 'server CD: stand-alone server (AdvServerType = SERVERNT), licensing Per Server 5 (LicenseFilePrintData)'
if grep -qi '^!\{0,1\}TimeZone' "$work/WINNT.SIF"; then log 'time zone: set for this CD language'; else log 'time zone: none (Setup asks)'; fi
# Encryption strength of the CD: a US/Canada CD has 128-bit security files
# (SCHANNEL.DLL "US/Canada Only, Not for Export"). SP6a's update.exe then
# refuses the Standard Encryption (export) SP6a, silently with -u ("You have
# chosen to install a version of the Service Pack with Standard Encryption
# onto a system with High Encryption", QEMU 2026-10-07, English Enterprise
# Server CD). The finish step names the High Encryption SP6a for this case.
# The version string is UTF-16: match its bytes as hex. BusyBox tr cannot
# delete NUL bytes (tr -d '\000' kept all 105232 bytes of the Enterprise
# CD's SCHANNEL.DLL in micro-Linux, QEMU 2026-10-07), GNU tr can.
crypto=standard
not_for_export='4e006f007400200066006f00720020004500780070006f0072007400'
for name in SCHANNEL.DLL schannel.dll; do
    if [ -f "$i386/$name" ] && od -An -v -tx1 "$i386/$name" | tr -d ' \n' | grep -q "$not_for_export"; then crypto=high; fi
done
if [ "$crypto" = high ]; then
    log 'CD encryption: high (128-bit, US/Canada): a Standard Encryption SP6a switches it to standard (POST.CMD)'
else
    log 'CD encryption: standard'
fi

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
dd if="$mbr_code" of="$mbr" bs=440 count=1 conv=notrunc 2>/dev/null
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
# NT 4.0 Setup reads \$WIN_NT$.~LS\I386; NT 3.51 reads the files straight
# from \$WIN_NT$.~LS (its DOSNET.INF d1 = \; QEMU 2026-10-08: "Setup was
# unable to copy the file kbdclass.sys" with an I386 subfolder).
ls_src=$ls_dir/I386
[ -z "$nt3" ] || ls_src=$ls_dir
nt4_copy_upper "$i386" "$ls_src" || fail 'cannot copy the I386 folder (local source)'
nt4_copy_upper "$i386" "$bt_dir" files || fail 'cannot copy the Setup boot files'
# Text mode runs \SystemRoot\SYSTEM32\SMSS.EXE of the boot folder (QEMU
# 2026-10-07: STOP 0x6B, C000003A without I386\SYSTEM32 in ~BT).
for name in SYSTEM32 system32; do
    [ -d "$i386/$name" ] || continue
    nt4_copy_upper "$i386/$name" "$bt_dir/SYSTEM32" || fail 'cannot copy I386\SYSTEM32'
    break
done
# NT 3.51 has no I386\SYSTEM32: winnt.exe builds it from DOSNET.INF
# [FloppyFiles.1] (ntdll.dll -> system32\ntdll.dll, usetup.exe ->
# system32\smss.exe); without it text mode stops with 0x6B C000003A.
if [ -n "$nt3" ] && [ ! -d "$bt_dir/SYSTEM32" ]; then
    [ -f "$bt_dir/NTDLL.DLL" ] && [ -f "$bt_dir/USETUP.EXE" ] || fail 'the ISO has no I386\NTDLL.DLL or I386\USETUP.EXE (NT 3.51 text-mode Setup)'
    mkdir -p "$bt_dir/SYSTEM32" || fail 'cannot create the Setup SYSTEM32 folder'
    cp "$bt_dir/NTDLL.DLL" "$bt_dir/SYSTEM32/NTDLL.DLL" || fail 'cannot copy NTDLL.DLL'
    cp "$bt_dir/USETUP.EXE" "$bt_dir/SYSTEM32/SMSS.EXE" || fail 'cannot copy USETUP.EXE as SMSS.EXE'
fi
if [ -n "$nt3" ]; then
    # The other renamed [FloppyFiles.x] entries: the boot-disk tag files
    # (d1,disk1,disk101 .. disk103) Setup looks for in the boot folder.
    dosnet=''
    for name in DOSNET.INF dosnet.inf; do [ -f "$i386/$name" ] && dosnet="$i386/$name" && break; done
    [ -n "$dosnet" ] || fail 'the ISO has no I386\DOSNET.INF'
    awk '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) ~ /^\[floppyfiles\./) ; next }
        s && $0 !~ /^[ \t]*#/ { n = split($0, a, ","); if (n >= 3) { gsub(/[ \t]/, "", a[2]); gsub(/[ \t]/, "", a[3]); print toupper(a[2]) " " toupper(a[3]) } }' "$dosnet" |
    while read -r src dst; do
        dst=$(printf %s "$dst" | tr '\\' /)
        [ -f "$bt_dir/$dst" ] && continue
        [ -f "$bt_dir/$src" ] || fail "the ISO has no I386\\$src (DOSNET.INF [FloppyFiles])"
        mkdir -p "$(dirname "$bt_dir/$dst")" && cp "$bt_dir/$src" "$bt_dir/$dst" || fail "cannot copy $src as $dst"
    done || exit 1
    # winnt.exe writes \$WIN_NT$.~LS\SIZE.SIF ([Data] Size = bytes of the local source).
    printf '[Data]\r\nSize = %s\r\n' "$(du -sk "$ls_src" | awk '{ print $1 * 1024 }')" > "$ls_src/SIZE.SIF" || fail 'cannot write SIZE.SIF'
fi
[ -d "$bt_dir/SYSTEM32" ] || fail 'the ISO has no I386\SYSTEM32 (text-mode Setup)'
log "local source: $(find "$ls_src" -type f | wc -l | tr -d ' ') files"
cp "$work/WINNT.SIF" "$bt_dir/WINNT.SIF" || fail 'cannot copy WINNT.SIF'
cp "$work/WINNT.SIF" "$work/c/WINNT.SIF" || fail 'cannot copy WINNT.SIF'
cp "$setupldr" "$work/c/\$LDR\$" || fail 'cannot copy the Setup loader'
cp "$txtsetup" "$work/c/TXTSETUP.SIF" || fail 'cannot copy TXTSETUP.SIF'
if [ -n "$nt3" ]; then
    # Standard PC HAL on the finished system (nt3_standard_hal); every copy
    # Setup may read: \TXTSETUP.SIF, ~BT and the local source.
    for sif in "$work/c/TXTSETUP.SIF" "$bt_dir/TXTSETUP.SIF" "$ls_src/TXTSETUP.SIF"; do
        [ -f "$sif" ] || continue
        nt3_standard_hal < "$sif" > "$work/txtsetup.hal" && cat "$work/txtsetup.hal" > "$sif" || fail 'cannot write TXTSETUP.SIF'
    done
    grep -aiEq '^mps[0-9]*_(up|mp) *= *hal\.dll' "$work/c/TXTSETUP.SIF" || fail 'TXTSETUP.SIF has no [hal] MPS row (not an NT 3.5 / 3.51 CD?)'
    log 'HAL: Standard PC (hal.dll) for the MPS machine types'
fi
# setupldr started from the hard disk runs \NTDETECT.COM of the boot
# partition (QEMU 2026-10-07: "NTDETECT failed" without it).
ntdetect=''
for name in NTDETECT.COM ntdetect.com; do [ -f "$i386/$name" ] && ntdetect="$i386/$name" && break; done
[ -n "$ntdetect" ] || fail 'the ISO has no I386\NTDETECT.COM'
cp "$ntdetect" "$work/c/NTDETECT.COM" || fail 'cannot copy NTDETECT.COM'

crlf() { awk -v BINMODE=3 '{ sub(/\r$/, ""); printf "%s\r\n", $0 }'; }
# NT 3.51: \USOS\NT3 with the NT 3.51 driver builds and USOSNT3.EXE, which
# does what POST.CMD and the .REG files do for NT 4.0 (tools/nt3/usosnt3:
# copies the drivers, writes their Services keys, atdisk/atapi off, the
# version and driver keys as text, DONE.TXT, restart). No service pack yet:
# the NT 3.51 RTM kernel starts on Zen 3 (QEMU EPYC-Milan 2026-10-08).
if [ -n "$nt3" ]; then
usos="$work/c/USOS/NT3"
mkdir -p "$usos"
for file in AHCINT.SYS USOSUSB.SYS USOSNT3.EXE; do
    cp "$drv/$file" "$usos/$file" || fail "cannot copy $file"
done
cp "$drv/$rst" "$usos/USOSRST.SYS" || fail "cannot copy $rst"
# Text-mode Setup runs AUTOCHK.EXE from the local source on C: ("Checking
# drive C:"); in the QEMU install VM that run overflows a kernel stack and
# the VM triple-faults (2026-10-08: double fault -> STOP 0x7F 8 while the
# HAL resets the display in V86 mode). The local source gets USOSACHK.EXE
# (tools/nt3/usosachk, own native program that ends with success) under that
# name; Setup copies it as system32\autochk.exe and nt4_vm_finish puts the
# CD's AUTOCHK.EXE, kept as \USOS\NT3\AUTOCHK.EXE, back in place.
[ -f "$ls_src/AUTOCHK.EXE" ] || fail 'the ISO has no I386\AUTOCHK.EXE'
mv "$ls_src/AUTOCHK.EXE" "$usos/AUTOCHK.EXE" || fail 'cannot move AUTOCHK.EXE'
cp "$drv/USOSACHK.EXE" "$ls_src/AUTOCHK.EXE" || fail 'cannot copy USOSACHK.EXE'
rm -f "$bt_dir/AUTOCHK.EXE"
[ -z "$SP_EXE" ] || log "service pack: $(basename "$SP_EXE") ignored (NT 3.51 service packs are not installed yet)"
log 'display: VGA (640x480x16; no VESA for NT 3.51 yet)'
printf 'answer=%s\r\nversion=%s.%s\r\n' "$ANSWER_KIND" "$major" "$minor" > "$usos/SOURCE.TXT"
else
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
cp "$LIB/nt4/USOSUSB.SYS" "$usos/USOSUSB.SYS" || fail 'cannot copy USOSUSB.SYS'
cp "$LIB/nt4/USOSVBE.SYS" "$usos/USOSVBE.SYS" || fail 'cannot copy USOSVBE.SYS'
cp "$LIB/nt4/USOSOFF.EXE" "$usos/USOSOFF.EXE" || fail 'cannot copy USOSOFF.EXE'
# VESA display = our miniport (usosvbe.sys) + NT 4.0's own frame buffer
# display driver framebuf.dll. USOS never ships framebuf.dll: text-mode Setup
# installs it from the user's CD ([files.vga] of TXTSETUP.SIF, Workstation and
# Server CDs alike). The CD's compressed copy goes along as a second source
# for POST.CMD (expanded there with NT 4.0's own expand.exe). Without either,
# POST.CMD leaves the VGA driver alone (640x480x16).
framebuf=''
for name in FRAMEBUF.DL_ framebuf.dl_; do [ -f "$i386/$name" ] && framebuf="$i386/$name" && break; done
if [ -n "$framebuf" ]; then
    cp "$framebuf" "$usos/FRAMEBUF.DL_" || fail 'cannot copy FRAMEBUF.DL_'
    log 'display: VESA (usosvbe + framebuf.dll from the CD)'
else
    log 'display: the CD has no I386\FRAMEBUF.DL_ (VESA only if Setup installs framebuf.dll)'
fi
if [ -n "$SP_EXE" ]; then
    cp "$SP_EXE" "$usos/SP6I386.EXE" || fail 'cannot copy the service pack'
    log "service pack: $(basename "$SP_EXE") ($(wc -c < "$SP_EXE" | tr -d ' ') bytes)"
else
    log 'service pack: none (the X470 needs SP6a: the RTM kernel stops on Zen CPUs)'
fi
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
# usosusb (own GPL driver, tools/nt4/usosusb): keyboard and pointer port for
# USB keyboards and mice on xHCI (NT 4.0 has no USB stack). It loads after
# i8042prt and before the class drivers, which connect to every port
# (ConnectMultiplePorts), so PS/2 and USB work side by side. Its pointer
# port always exists, so mouclass no longer fails without a PS/2 mouse
# (Service Control Manager event 7026 "Mouclass" at every start).
# usosvbe is registered by VESA.REG, and only when framebuf.dll is there.
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

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosusb]
"Type"=dword:00000001
"Start"=dword:00000001
"ErrorControl"=dword:00000000
"Group"="Keyboard Port"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Kbdclass\Parameters]
"ConnectMultiplePorts"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Mouclass\Parameters]
"ConnectMultiplePorts"=dword:00000001
EOF
# usosvbe (own GPL miniport, tools/nt4/usosvbe) + framebuf.dll (NT 4.0's own,
# from the user's CD): 1024x768x16 by default; the Display applet lists every
# VBE mode. VgaStart (Video Init, ForceVga) would load first and win, so it is
# off; VgaSave stays for full-screen consoles and /basevideo ([VGA mode]).
# InstalledDisplayDrivers is REG_MULTI_SZ "framebuf": NT 4.0 regedit
# (REGEDIT4) takes hex(7) as ANSI bytes and widens each one.
crlf > "$usos/VESA.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosvbe]
"Type"=dword:00000001
"Start"=dword:00000001
"ErrorControl"=dword:00000000
"Group"="Video"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosvbe\Device0]
"InstalledDisplayDrivers"=hex(7):66,72,61,6d,65,62,75,66,00,00
"VgaCompatible"=dword:00000000
"DefaultSettings.BitsPerPel"=dword:00000010
"DefaultSettings.XResolution"=dword:00000400
"DefaultSettings.YResolution"=dword:00000300
"DefaultSettings.VRefresh"=dword:0000003c
"DefaultSettings.Flags"=dword:00000000
"DefaultSettings.XPanning"=dword:00000000
"DefaultSettings.YPanning"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\VgaStart]
"Start"=dword:00000004
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
# which ends QEMU (-no-reboot). NT 4.0 COPY has no /Y (it overwrites; with /Y
# it stops with a syntax error, QEMU e2e 2026-10-07). SP6a sets
# Control\Windows CSDVersion (0x600) at once; the CurrentVersion string
# follows after a restart. Files SP6a could not replace while in use
# are renamed by SMSS at the first start on the real machine (SP6a kernel).
# The Enterprise Server CD's GUI Setup (NHSETUP.CMD) puts "Windows NT Server,
# Enterprise Edition Installer.cmd" in the All Users Startup group: at every
# logon NHLOADER.EXE offers Service Pack 3 from the CD's \SP3 and the
# Enterprise components. Without the CD its "Install Service Pack 3" window
# hangs (QEMU 2026-10-07, 18 min), and SP3 must never go over SP6a: POST.CMD
# removes it (RunOnce runs before the Startup group).
# SP6a runs from its own extracted copy (sfxcab -x:dir -q: silent, exit 0;
# the package itself only runs update\update.exe). A US/Canada 128-bit CD
# (CRYPTOHI.TXT) with a Standard Encryption (export) SP6a: update.exe refuses
# silently ("Standard Encryption onto a system with High Encryption"; it reads
# the version strings of schannel.dll/rsaenh.dll), CSDVersion stays below
# 0x600. POST.CMD then renames the CD's 128-bit schannel.dll to schannel.128
# (it is loaded, so COPY over it fails: "0 file(s) copied", QEMU 2026-10-07;
# a copy stays in C:\USOS\NT4\SCHAN128.DLL), puts the SP6a's own export
# schannel.dll in its place, renames rsaenh.dll (if any)
# to rsaenh.128 and runs update.exe again: the system drops to standard
# encryption (SP6a installs that schannel.dll anyway). A real 128-bit SP6a
# installs at the first try and nothing is switched.
crlf > "$usos/POST.CMD" <<'EOF'
@echo off
if exist C:\USOS\NT4\POST.OK goto end
echo USOS NT4 post > C:\USOS\NT4\POST.LOG
set NHI=%SystemRoot%\Profiles\All Users\Start Menu\Programs\Startup\Windows NT Server, Enterprise Edition Installer.cmd
if not exist "%NHI%" goto nonhi
del "%NHI%"
if exist "%NHI%" echo Enterprise Edition Installer removal FAILED >> C:\USOS\NT4\POST.LOG
if not exist "%NHI%" echo Enterprise Edition Installer removed >> C:\USOS\NT4\POST.LOG
:nonhi
set NHI=
copy C:\USOS\NT4\AHCINT.SYS %SystemRoot%\system32\drivers\ahcint.sys >> C:\USOS\NT4\POST.LOG
copy C:\USOS\NT4\USOSRST.SYS %SystemRoot%\system32\drivers\usosrst.sys >> C:\USOS\NT4\POST.LOG
copy C:\USOS\NT4\USOSUSB.SYS %SystemRoot%\system32\drivers\usosusb.sys >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\drivers\ahcint.sys echo AHCINT.SYS copy FAILED >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\drivers\usosrst.sys echo USOSRST.SYS copy FAILED >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\drivers\usosusb.sys echo USOSUSB.SYS copy FAILED >> C:\USOS\NT4\POST.LOG
%SystemRoot%\regedit.exe /s C:\USOS\NT4\DRIVERS.REG
echo drivers registered >> C:\USOS\NT4\POST.LOG
if exist %SystemRoot%\system32\framebuf.dll goto vesa
if not exist C:\USOS\NT4\FRAMEBUF.DL_ goto novesa
%SystemRoot%\system32\expand.exe C:\USOS\NT4\FRAMEBUF.DL_ %SystemRoot%\system32\framebuf.dll >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\framebuf.dll goto novesa
:vesa
copy C:\USOS\NT4\USOSVBE.SYS %SystemRoot%\system32\drivers\usosvbe.sys >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\drivers\usosvbe.sys goto novesa
%SystemRoot%\regedit.exe /s C:\USOS\NT4\VESA.REG
echo vesa on >> C:\USOS\NT4\POST.LOG
goto vesadone
:novesa
echo vesa off: no framebuf.dll, VGA stays >> C:\USOS\NT4\POST.LOG
:vesadone
if not exist C:\USOS\NT4\SP6I386.EXE goto nosp
start /wait C:\USOS\NT4\SP6I386.EXE -x:C:\USOS\NT4\SP6X -q
if not exist C:\USOS\NT4\SP6X\update\update.exe goto spsfx
echo sp start >> C:\USOS\NT4\POST.LOG
start /wait C:\USOS\NT4\SP6X\update\update.exe -u -z
echo sp end %errorlevel% >> C:\USOS\NT4\POST.LOG
if not exist C:\USOS\NT4\CRYPTOHI.TXT goto nosp
%SystemRoot%\regedit.exe /e C:\USOS\NT4\CSD1.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Windows
findstr /i /c:"dword:00000600" C:\USOS\NT4\CSD1.REG > nul
if not errorlevel 1 goto nosp
if not exist C:\USOS\NT4\SP6X\schannel.dll goto nosp
echo crypto: high to standard for SP6a (Standard Encryption SP6a on a 128-bit CD) >> C:\USOS\NT4\POST.LOG
copy %SystemRoot%\system32\schannel.dll C:\USOS\NT4\SCHAN128.DLL >> C:\USOS\NT4\POST.LOG
if exist %SystemRoot%\system32\schannel.128 del %SystemRoot%\system32\schannel.128
ren %SystemRoot%\system32\schannel.dll schannel.128
copy C:\USOS\NT4\SP6X\schannel.dll %SystemRoot%\system32\schannel.dll >> C:\USOS\NT4\POST.LOG
if exist %SystemRoot%\system32\schannel.128 echo crypto: 128-bit schannel.dll renamed to schannel.128 >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\schannel.dll echo crypto: schannel.dll swap FAILED >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\schannel.dll copy C:\USOS\NT4\SCHAN128.DLL %SystemRoot%\system32\schannel.dll >> C:\USOS\NT4\POST.LOG
if exist %SystemRoot%\system32\rsaenh.dll ren %SystemRoot%\system32\rsaenh.dll rsaenh.128
if exist %SystemRoot%\system32\rsaenh.128 echo crypto: rsaenh.dll renamed to rsaenh.128 >> C:\USOS\NT4\POST.LOG
echo sp start (standard) >> C:\USOS\NT4\POST.LOG
start /wait C:\USOS\NT4\SP6X\update\update.exe -u -z
echo sp end %errorlevel% >> C:\USOS\NT4\POST.LOG
goto nosp
:spsfx
echo sp extract failed, running the package >> C:\USOS\NT4\POST.LOG
start /wait C:\USOS\NT4\SP6I386.EXE -u -z
echo sp end %errorlevel% >> C:\USOS\NT4\POST.LOG
:nosp
echo ok > C:\USOS\NT4\POST.OK
%SystemRoot%\regedit.exe /e C:\USOS\NT4\VERSION.REG "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
%SystemRoot%\regedit.exe /e C:\USOS\NT4\CSD.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Windows
%SystemRoot%\regedit.exe /e C:\USOS\NT4\USOSRST.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosrst
%SystemRoot%\regedit.exe /e C:\USOS\NT4\USOSVBE.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosvbe
%SystemRoot%\regedit.exe /s C:\USOS\NT4\DONE.REG
echo done > C:\USOS\NT4\DONE.TXT
C:\USOS\NT4\USOSOFF.EXE /r
:end
EOF
printf 'answer=%s\r\ncrypto=%s\r\n' "$ANSWER_KIND" "$crypto" > "$usos/SOURCE.TXT"
# POST.CMD reads the strength from this flag (cmd cannot parse SOURCE.TXT
# easily): a 128-bit CD with a Standard Encryption SP6a switches to the
# SP6a's own schannel.dll and runs update.exe again.
if [ "$crypto" = high ]; then printf 'high\r\n' > "$usos/CRYPTOHI.TXT"; fi
fi

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
