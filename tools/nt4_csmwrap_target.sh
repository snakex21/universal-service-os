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
# tse: the menu entry is Windows NT 4.0 Terminal Server Edition (the CD must
# be the TSE CD and the other entries must not take it).
EDITION=${NT4_EDITION:-}
# 1 (default): usosusb also drives USB sticks (NT 4.0 only; DATA
# usb-storage-off.txt -> 0, read by w9x_csmwrap_prepare.sh).
USB_STORAGE=${NT4_USB_STORAGE:-1}
# 1: text mode, GUI mode and the first start run natively on this PC after
# the restart (no install VM; docs/nt-native-plan.md). NT 3.51 / 3.5
# (nt3-native.flag) and NT 4.0 / Server / TSE (nt4-native.flag).
NATIVE=${NT_NATIVE:-0}
# BOOT.INI options of the VM flow's finish step (nt4_qemu_install.sh
# NT4_BOOT_OPTIONS), here through TXTSETUP.SIF OsLoadOptions (NT 4.0 also
# OsLoadOptionsVar, the BOOT.INI value of its text mode).
NT_NATIVE_LOAD_OPTIONS=${NT_NATIVE_LOAD_OPTIONS:-/NUMPROC=2 /MAXMEM=1024}
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
            if (k == "Greenwich") return "(GMT) Monrovia, Casablanca"
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

# NT 4.0 product key gate (2026-10-28, the key is optional in the menu and
# profile like Windows 95's). $1 = the answer SIF, $2 = the CD's I386 folder.
# rc 0: the answer has a ProductId, or the CD's I386\SETUPP.INI [Pid] Pid
# names the Select (site 270) or MSDN (335) channel, whose Setup is expected
# not to ask for a CD key (unverified on NT 4.0 hardware; the channel codes
# are the ones NT Setup keeps in SETUPP.INI). rc 1: no key and a retail/OEM
# CD - GUI Setup would wait on its key page inside the install VM, where
# nobody can type. One status word on stdout: key | select | msdn | needed.
nt4_key_gate() {
    if awk '{ sub(/\r$/, "") } /^[ \t]*\[/ { s = (tolower($0) ~ /^[ \t]*\[userdata\][ \t]*$/); next }
            s && tolower($0) ~ /^[ \t]*productid[ \t]*=[ \t]*"?[0-9a-z]/ { f = 1 } END { exit !f }' "$1"; then
        echo key; return 0
    fi
    setupp=''
    for name in SETUPP.INI setupp.ini; do [ -f "$2/$name" ] && setupp="$2/$name" && break; done
    pid=''
    [ -z "$setupp" ] || pid=$(awk '{ sub(/\r$/, "") } /^[ \t]*\[/ { s = (tolower($0) ~ /^[ \t]*\[pid\][ \t]*$/); next }
            s && tolower($0) ~ /^[ \t]*pid[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/[ \t"]/, "", v); print toupper(v); exit }' "$setupp")
    case "$pid" in
        ?????270*) echo select; return 0 ;;
        ?????335*) echo msdn; return 0 ;;
    esac
    echo needed; return 1
}

# Terminal Server Edition (stdin -> stdout, CR LF): GUI Setup waits on its
# "Terminal Server Desktops" page (number of client licenses) unless the
# answer has [TerminalServerDesktops] Quantity (the CD's I386\UNATTEND.TXT);
# QEMU 2026-10-10: the install VM sat on that page with a "licenses set to
# zero" warning box. 5, like the Per Server licensing. [InternetExplorer]
# InstallIE4 = No: the CD's IE 4.0 setup at the end of GUI Setup is left
# out (its own pages; it can be run from the CD later). Keys already in the
# answer are kept.
nt4_tse_answer() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); lines[++n] = line; low = tolower(line); gsub(/[ \t]/, "", low)
          if (low ~ /^\[/) sec = low
          if (sec == "[terminalserverdesktops]" && low ~ /^quantity=/) has_qty = 1
          if (sec == "[internetexplorer]" && low ~ /^installie4=/) has_ie = 1
          if (low == "[terminalserverdesktops]") has_qsec = 1
          if (low == "[internetexplorer]") has_isec = 1 }
        END {
            for (i = 1; i <= n; i++) {
                printf "%s\r\n", lines[i]
                low = tolower(lines[i]); gsub(/[ \t]/, "", low)
                if (!has_qty && low == "[terminalserverdesktops]") { printf "Quantity = 5\r\n"; has_qty = 1 }
                if (!has_ie && low == "[internetexplorer]") { printf "InstallIE4 = No\r\n"; has_ie = 1 }
            }
            if (!has_qty) printf "\r\n[TerminalServerDesktops]\r\nQuantity = 5\r\n"
            if (!has_ie) printf "\r\n[InternetExplorer]\r\nInstallIE4 = No\r\n"
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

# NT 3.x answer-profile values (docs/nt3-polish-2026-10-14.md): the
# ;USOS-USER= / ;USOS-PASSWORD= / ;USOS-AUTOLOGON= / ;USOS-LOCALE= /
# ;USOS-KEYBOARD= lines of the answer $1 (src/flow/answer/nt3.zig; the menu
# language's locale from w9x_csmwrap_prepare.sh w9x_nt3_ui_locale) become
# $2/ACCOUNT.TXT and $2/INTL.TXT (key=value, CR LF) for usosnt3.exe, which
# applies them at the first start (NT 3.1: POST.CMD at the end of GUI Setup)
# and deletes ACCOUNT.TXT. The account lines then leave $1, so the password
# is not in the copies of WINNT.SIF on C:.
nt3_profile_files() {
    awk -v BINMODE=3 -v dir="$2" '
        { line = $0; sub(/\r$/, "", line) }
        line ~ /^;USOS-USER=/ { v = line; sub(/^[^=]*=/, "", v); user = v; acct = 1; next }
        line ~ /^;USOS-PASSWORD=/ { v = line; sub(/^[^=]*=/, "", v); pw = v; acct = 1; next }
        line ~ /^;USOS-AUTOLOGON=/ { v = line; sub(/^[^=]*=/, "", v); auto = (v == "1") ? 1 : 0; acct = 1; next }
        line ~ /^;USOS-LOCALE=[0-9A-Fa-f]+$/ { v = line; sub(/^[^=]*=/, "", v); loc = toupper(v); intl = 1 }
        line ~ /^;USOS-KEYBOARD=[0-9A-Fa-f]+$/ { v = line; sub(/^[^=]*=/, "", v); kbd = toupper(v); intl = 1 }
        { printf "%s\r\n", line > (dir "/WINNT.NEW") }
        END {
            if (acct) printf "user=%s\r\npassword=%s\r\nautologon=%d\r\n", user, pw, auto > (dir "/ACCOUNT.TXT")
            if (intl) printf "locale=%s\r\nkeyboard=%s\r\n", loc, kbd > (dir "/INTL.TXT")
            printf "account=%s user=%s password=%s autologon=%s locale=%s keyboard=%s\n", acct ? "yes" : "no", user == "" ? "Administrator" : user, pw == "" ? "blank" : "set", auto ? "yes" : "no", loc == "" ? "CD" : loc, kbd == "" ? "CD" : kbd
        }' "$1" && mv "$2/WINNT.NEW" "$1"
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
# [SpecialFiles] Multiprocessor takes the Uniprocessor row as well: text mode
# installs the MP kernel (ntkrnlmp.exe as ntoskrnl.exe) for every machine
# type whose id ends in "_mp" (SpInstallingMp), and natively on the X470 (MP
# table, 16 threads) it detects mps_mp. The Standard PC hal.dll starts one
# processor only, so the MP kernel brings nothing and is a pairing Setup never
# makes on its own (X470 2026-10-29: ntkrnlmp + hal.dll, STOP 0x0A).
nt3_standard_hal() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); lines[++n] = line; low = tolower(line); gsub(/[ \t]/, "", low)
          if (low ~ /^\[/) sec = low
          else if (sec == "[specialfiles]" && low ~ /^uniprocessor=/) { up = line; sub(/^[^=]*=[ \t]*/, "", up) } }
        END {
            for (i = 1; i <= n; i++) {
                line = lines[i]; low = tolower(line); gsub(/[ \t]/, "", low)
                if (low ~ /^\[/) sec = low
                else if (sec == "[hal]" && low ~ /^mps[0-9]*_(up|mp)=/) {
                    key = line; sub(/[ \t]*=.*/, "", key); rest = line; sub(/^[^,]*/, "", rest)
                    line = key " = hal.dll    " rest
                } else if (sec == "[specialfiles]" && up != "" && low ~ /^multiprocessor=/)
                    line = "Multiprocessor = " up
                printf "%s\r\n", line
            }
        }'
}

# Native NT 3.51 / 3.5 / 4.0 text mode on this PC (NT_NATIVE=1,
# docs/nt-native-plan.md, no install VM): TXTSETUP.SIF (stdin -> stdout, CR LF) with
#   [SCSI.Load]  only the USOS miniports ($1: "ahcint" or "ahcint usosnvme"):
#                SETUPLDR loads every row, and the ISA/EISA probes of the
#                CD's 30+ miniports have no business on a modern board;
#   [SCSI]       their names (text mode installs the miniport that found the
#                boot disk as a boot driver of the new system);
#   [Files]      a row per miniport, the CD's amsint.sys row fields (same
#                media, directory 4 = system32\drivers, boot driver flag);
#                NT 4.0 names the section [SourceDisksFiles] (twice on its
#                CDs: the row goes into the first one);
#   [SetupData]  OsLoadOptions = $2: SETUPLDR passes it to the text-mode
#                kernel and text mode writes it into BOOT.INI (the NT 4.0
#                Enterprise CD's "/maxmem=256" reached BOOT.INI that way,
#                2026-10-07), so text mode, GUI mode and the installed system
#                run with the /MAXMEM the VM flow's finish step adds.
#                $3 (NT 4.0): OsLoadOptionsVar = $3 as well, the value text
#                mode takes for BOOT.INI when the SIF has it (the Enterprise
#                CD carries both; NT 4.0 has two [SetupData] sections, each
#                gets the rows).
# The NT 3.5 CD has no amsint.sys: its ncrc810.sys row (the same kind of PCI
# boot miniport, boot driver flag 1) is taken then.
# rc 1 (nothing written) when the SIF has neither [Files] row.
nt3_native_txtsetup() {
    awk -v BINMODE=3 -v ports="$1" -v opts="$2" -v var="${3:-}" '
        { line = $0; sub(/\r$/, "", line); lines[++n] = line }
        END {
            np = split(ports, port, " ")
            for (i = 1; i <= n; i++) {
                low = tolower(lines[i]); gsub(/[ \t]/, "", low)
                if (low ~ /^\[/) sec = low
                else if ((sec == "[files]" || sec == "[sourcedisksfiles]") && low ~ /^(amsint|ncrc810)\.sys=/) {
                    f = lines[i]; sub(/^[^=]*=[ \t]*/, "", f)
                    if (low ~ /^amsint/) ams = f; else ncr = f
                }
            }
            fields = (ams != "") ? ams : ncr
            if (fields == "") exit 1
            for (i = 1; i <= n; i++) {
                line = lines[i]; low = tolower(line); gsub(/[ \t]/, "", low)
                if (low ~ /^\[/) {
                    sec = low
                    printf "%s\r\n", line
                    if (sec == "[scsi.load]") for (p = 1; p <= np; p++) printf "%s = %s.sys,4\r\n", port[p], port[p]
                    if (sec == "[scsi]") for (p = 1; p <= np; p++) printf "%s = \"%s\"\r\n", port[p], (port[p] == "usosnvme" ? "USOS NVMe" : "USOS AHCI (SATA)")
                    if ((sec == "[files]" || sec == "[sourcedisksfiles]") && !files_done) {
                        for (p = 1; p <= np; p++) printf "%s.sys = %s\r\n", port[p], fields
                        files_done = 1
                    }
                    if (sec == "[setupdata]") {
                        printf "OsLoadOptions = \"%s\"\r\n", opts
                        if (var != "") printf "OsLoadOptionsVar = \"%s\"\r\n", var
                    }
                    continue
                }
                if (sec == "[scsi.load]" && low != "" && low !~ /^;/) continue
                if (sec == "[setupdata]" && low ~ /^osloadoptions=/) continue
                if (sec == "[setupdata]" && var != "" && low ~ /^osloadoptionsvar=/) continue
                printf "%s\r\n", line
            }
        }'
}

# Native NT 4.0: USB mouse from the first GUI Setup boot (X470 2026-10-29: no
# mouse in GUI Setup; USOSNT4 /early registers usosusb only at its end).
# Text mode creates the service of the chosen [Mouse] row (third field,
# Start 1, group "Pointer Port", spconfig.c SpConfigureMouseKeyboardDrivers)
# and copies its [files.*] list, so every [Mouse] row (PS/2, serial, bus,
# "no mouse": ntdetect finds none on a board without a PS/2 mouse) names
# usosusb with [files.usosusb]; the [SourceDisksFiles] row copies the CD's
# sermouse.sys fields (media 1, system32\drivers). "Pointer Port" loads
# before "Keyboard Port": usosusb's ports become PointerPort0 and
# KeyboardPort0, the ones the class drivers take before USOSNT4 /early sets
# ConnectMultiplePorts, so the USB keyboard (which usosusb takes over from
# the BIOS emulation) and mouse both work in GUI Setup. i8042prt stays the
# keyboard row's driver (a PS/2 keyboard or mouse works again once
# ConnectMultiplePorts is set). stdin -> stdout, CR LF; rc 1 when the SIF
# has no [Mouse] section or no sermouse.sys row.
nt4_native_mouse() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); lines[++n] = line }
        END {
            for (i = 1; i <= n; i++) {
                low = tolower(lines[i]); gsub(/[ \t]/, "", low)
                if (low ~ /^\[/) sec = low
                else if (sec == "[sourcedisksfiles]" && low ~ /^sermouse\.sys=/ && ser == "") { ser = lines[i]; sub(/^[^=]*=[ \t]*/, "", ser) }
                else if (sec == "[mouse]" && low != "" && low !~ /^;/) rows++
            }
            if (ser == "" || rows == 0) exit 1
            for (i = 1; i <= n; i++) {
                line = lines[i]; low = tolower(line); gsub(/[ \t]/, "", low)
                if (low ~ /^\[/) {
                    sec = low
                    printf "%s\r\n", line
                    if (sec == "[sourcedisksfiles]" && !files_done) { printf "usosusb.sys = %s\r\n", ser; files_done = 1 }
                    continue
                }
                if (sec == "[mouse]" && low != "" && low !~ /^;/ && match(line, /,[^,]*,[^,]*$/)) {
                    printf "%s,files.usosusb,usosusb\r\n", substr(line, 1, RSTART - 1)
                    continue
                }
                printf "%s\r\n", line
            }
            printf "\r\n[files.usosusb]\r\nusosusb.sys,4\r\n"
        }'
}

# Native NT 4.0: the CD's [Computer] description of a machine type ($1, e.g.
# mps_mp -> "MPS Multiprocessor PC"; stdin = TXTSETUP.SIF), for WINNT.SIF
# [Unattended] ComputerType, which must name it exactly.
nt4_computer_desc() {
    awk -v key="$1" '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) ~ /^\[computer\][ \t]*$/); next }
        s { k = $0; sub(/[ \t]*=.*/, "", k); gsub(/[ \t]/, "", k)
            if (tolower(k) == key && match($0, /"[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit } }'
}

# Native NT 4.0 (stdin -> stdout, CR LF): [Unattended] ComputerType = "$1",
# Retail unless the answer names one (the USOS answer pins MPS Multiprocessor
# PC; text mode would otherwise take what NTDETECT reports, and the VM flow's
# pentium3 VM is no longer there to make that MPS).
nt4_native_answer() {
    awk -v BINMODE=3 -v desc="$1" '
        { line = $0; sub(/\r$/, "", line); lines[++n] = line; low = tolower(line); gsub(/[ \t]/, "", low)
          if (low ~ /^\[/) sec = low
          else if (sec == "[unattended]" && low ~ /^computertype=/) has = 1 }
        END {
            for (i = 1; i <= n; i++) {
                printf "%s\r\n", lines[i]
                low = tolower(lines[i]); gsub(/[ \t]/, "", low)
                if (!has && low == "[unattended]") { printf "ComputerType = \"%s\", Retail\r\n", desc; has = 1 }
            }
            if (!has) printf "\r\n[Unattended]\r\nComputerType = \"%s\", Retail\r\n", desc
        }'
}

# Native NT 4.0: the CD's RTM kernels with the CPUID leaf limit raised
# (src/compat/win3x/nt4_kernel.zig, usos-fb-ui --nt4-kernel; the RTM
# KiSetProcessorType takes a CPU with more than 3 CPUID leaves for one
# without CPUID, and the boot ends in a triple fault on Zen 3). Run on the
# user's own CD files before the disk is written: $work/kernel/NTOSKRNL.EXE
# and NTKRNLMP.EXE (plain PE, checksum recomputed); a kernel without exactly
# one match (an SP CD, an unknown build) stops here.
nt4_native_kernels() {
    mkdir -p "$work/kernel" || fail 'cannot create the kernel work folder'
    for base in NTOSKRNL NTKRNLMP; do
        src=''
        low=$(printf %s "$base" | tr '[:upper:]' '[:lower:]')
        for name in "$base.EXE" "$base.EX_" "$low.exe" "$low.ex_"; do [ -f "$i386/$name" ] && src="$i386/$name" && break; done
        [ -n "$src" ] || fail "the ISO has no I386\\$base.EXE. No disk was changed"
        if "${USOS_FB_UI:-usos-fb-ui}" --nt4-kernel "$src" "$work/kernel/$base.EXE" > "$work/kernel.log" 2>&1; then rc=0; else rc=$?; fi
        while IFS= read -r line; do log "$line"; done < "$work/kernel.log"
        [ "$rc" = 0 ] && [ -s "$work/kernel/$base.EXE" ] ||
            fail "cannot raise the CPUID leaf limit of $base (not an NT 4.0 RTM kernel?). No disk was changed"
    done
}

crlf() { awk -v BINMODE=3 '{ sub(/\r$/, ""); printf "%s\r\n", $0 }'; }

# NT 3.1 (docs/nt31-2026-10-09.md). winnt.exe of NT 3.1 copies the I386
# folder flat to \$WIN_NT$.~LS (DOSNET.INF d1 = \) and writes a Setup boot
# floppy: the DOSNET.INF [FloppyFiles] (SETUPLDR, NTDETECT.COM, TXTSETUP.INF,
# the DISK1 tag file and the ISA/EISA SCSI miniports) with a [MsDosInitiated]
# section appended to TXTSETUP.INF; SETUPAPP.EXE (text mode) then takes every
# file from the local source. USOS puts the floppy files on the root of C:
# instead and starts SETUPLDR there (syslinux chain.c32 ntldr=, as $LDR$).
nt31_layout() {
    nt4_copy_upper "$i386" "$ls_dir" files || fail 'cannot copy the I386 folder (local source)'
    dosnet=''
    for name in DOSNET.INF dosnet.inf; do [ -f "$i386/$name" ] && dosnet="$i386/$name" && break; done
    [ -n "$dosnet" ] || fail 'the ISO has no I386\DOSNET.INF'
    awk '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) == "[floppyfiles]"); next }
        s && $0 !~ /^[ \t]*#/ { n = split($0, a, ","); if (n >= 2) { gsub(/[ \t]/, "", a[2]); if (a[2] != "") print toupper(a[2]) } }' "$dosnet" |
    while read -r file; do
        [ -f "$ls_dir/$file" ] || fail "the ISO has no I386\\$file (DOSNET.INF [FloppyFiles])"
        cp "$ls_dir/$file" "$work/c/$file" || fail "cannot copy $file"
    done || exit 1
    rm -f "$work/c/SETUPLDR"
    # Removed again after the install (nt4_vm_finish); NTDETECT.COM stays.
    mkdir -p "$work/c/USOS/NT3"
    ls "$work/c" | grep -v -x -e NTDETECT.COM -e USOS -e '$WIN_NT$.~LS' -e TXTSETUP.INF > "$work/c/USOS/NT3/ROOTLIST.TXT"
    cp "$setupldr" "$work/c/\$LDR\$" || fail 'cannot copy the Setup loader'
    { crlf < "$txtsetup"; printf '\r\n[MsDosInitiated]\r\n'; } > "$work/c/TXTSETUP.INF" || fail 'cannot write TXTSETUP.INF'
    [ -f "$work/c/NTDETECT.COM" ] || fail 'the ISO has no I386\NTDETECT.COM'
    log "local source: $(find "$ls_dir" -type f | wc -l | tr -d ' ') files (NT 3.1 layout)"
}

# NVMe target: usosnvme (own GPL miniport, tools/nt/usosnvme; the NT 3.x
# builds scan every PCI bus through CF8h/CFCh, so the PCI BIOS the NT 3.x MBR
# hides does not matter) as \USOS\NT3\USOSNVME.SYS. NT 3.5x: USOSNT3.EXE
# copies and registers it when present; NT 3.1: POST.CMD copies it and
# INITIAL.INF [UsosNt31Post] (nt31_initial_inf, nt4_qemu_install.sh) writes
# its key. The install VM runs on IDE / am53c974 and never starts it. A SATA
# target never gets the file.
nt3_nvme_stage() {
    [ -n "$nvme" ] || return 0
    cp "$drv/$nvme_sys" "$usos/USOSNVME.SYS" || fail "cannot copy $nvme_sys"
    log "storage: NVMe target $TARGET_DEVICE, usosnvme ($nvme_sys) staged next to AHCINT"
}

# The answer-profile files of nt3_profile_files into \USOS\NT3.
nt3_stage_profile() {
    for file in ACCOUNT.TXT INTL.TXT; do
        [ ! -f "$work/$file" ] || mv "$work/$file" "$usos/$file" || fail "cannot copy $file"
    done
    [ ! -f "$usos/INTL.TXT" ] || nt3_stage_intl
    if [ -n "${nt3:-}" ] && [ -z "${nt31:-}" ] && grep -q '^;USOS-DISPLAY=' "$ANSWER_SIF"; then
        . "$LIB/display_profile.sh"
        nt3_display_request=$(usos_display_from_answer "$ANSWER_SIF") || fail 'duplicate display request'
        if usos_display_keep "$nt3_display_request"; then
            log 'DISPLAY keep (profile display=keep or display-keep.txt): USOSRES not staged'
            return 0
        fi
        usos_display_stage "$usos" "$LIB/USOSRES.EXE" "$nt3_display_request" || fail 'cannot stage NT3 hardware display request'
        log "DISPLAY request=$nt3_display_request apply=hardware-service vm=deferred"
    fi
}

# The CD files GUI Setup would copy for the chosen locale and keyboard
# (LANGUAGE.INF / LAYOUT.INF; text-mode Setup copies only its own default
# layout and code pages): the layout DLL of TXTSETUP [Files.KeyboardLayout]
# (NT 3.1: TXTSETUP.INF) and, for the locale's code pages (the LANGUAGE.INF
# [Options] values), the code page tables and the bitmap fonts, each as the
# CD has it (NAME or the LZ-compressed NAM_, stored under NAME) in
# \USOS\NT3\INTL; usosnt3.exe expands them (docs/nt3-polish-2026-10-14.md). Files the CD lacks (the 3.5
# and 3.1 CDs have no CE fonts) are skipped; usosnt3.exe then keeps the
# code pages.
nt3_stage_intl() {
    intl_locale=$(awk -F= '{ sub(/\r$/, "") } $1 == "locale" { print toupper($2) }' "$usos/INTL.TXT")
    intl_kbd=$(awk -F= '{ sub(/\r$/, "") } $1 == "keyboard" { print toupper($2) }' "$usos/INTL.TXT")
    mkdir -p "$usos/INTL" || fail 'cannot create \USOS\NT3\INTL'
    kbd_dll=''
    if [ -n "$intl_kbd" ]; then
        kbd_dll=$(awk -v id="$intl_kbd" '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) ~ /keyboardlayout/); next }
            s { k = $1; gsub(/[ \t]/, "", k); if (toupper(k) == id && match(toupper($0), /[A-Z0-9_]+\.DLL/)) { print substr(toupper($0), RSTART, RLENGTH); exit } }' "$txtsetup")
    fi
    case "$intl_locale" in
        00000405|0000040E|00000415|0000041B|00000424|0000041A|00000418) cps='1250 852 10029' sfx=E ;;
        00000419|00000402) cps='1251 866 10007' sfx=R ;;
        00000408) cps='1253 737 10006' sfx=G ;;
        0000041F) cps='1254 857 10081' sfx=T ;;
        *) cps='' sfx='' ;;
    esac
    names=$kbd_dll
    if [ -n "$cps" ]; then
        set -- $cps
        names="$names C_$1.NLS C_$2.NLS C_$3.NLS VGA$2.FON APP$2.FON CGA40$2.FON CGA80$2.FON EGA40$2.FON EGA80$2.FON"
        for base in VGASYS VGAFIX SSERIFE COURE SERIFE SMALLE; do names="$names $base$sfx.FON"; done
    fi
    staged=0
    for name in $names; do
        packed=$(printf %s "$name" | sed 's/.$/_/')
        lower=$(printf '%s %s' "$name" "$packed" | tr '[:upper:]' '[:lower:]')
        for cand in "$name" "$packed" $lower; do
            [ -f "$i386/$cand" ] || continue
            cp "$i386/$cand" "$usos/INTL/$name" || fail "cannot copy $cand"
            staged=$((staged + 1))
            break
        done
    done
    [ -z "$kbd_dll" ] || printf 'keyboard_dll=%s\r\n' "$(printf %s "$kbd_dll" | tr '[:upper:]' '[:lower:]')" >> "$usos/INTL.TXT"
    log "locale ${intl_locale:-none}, keyboard ${intl_kbd:-none} (${kbd_dll:-no layout DLL}): $staged CD files for \\USOS\\NT3\\INTL"
}

# NT 3.1: \USOS\NT3 with the NT 3.1 driver builds; GUI Setup (the patched
# INITIAL.INF, nt31_initial_inf) copies and registers them itself.
nt31_usos() {
    usos="$work/c/USOS/NT3"
    mkdir -p "$usos"
    cp "$drv/$ahci" "$usos/AHCINT.SYS" || fail "cannot copy $ahci"
    cp "$drv/$rst" "$usos/USOSRST.SYS" || fail "cannot copy $rst"
    cp "$drv/$usb" "$usos/USOSUSB.SYS" || fail "cannot copy $usb"
    cp "$drv/USOSNT3.EXE" "$usos/USOSNT3.EXE" || fail 'cannot copy USOSNT3.EXE'
    nt3_nvme_stage
    nt3_stage_profile
    log 'display: VGA (640x480x16)'
    printf 'answer=%s\r\nversion=%s.%s\r\n' "$ANSWER_KIND" "$major" "$minor" > "$usos/SOURCE.TXT"
    # The names GUI Setup would ask for (WINNT.SIF [UserData]; NT 3.1 has no
    # answer file: nt31_vm_patch_initial writes them into INITIAL.INF).
    awk -v BINMODE=3 '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) == "[userdata]"); next }
        s && /=/ { k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*!?/, "", k); k = tolower(k)
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/"/, "", v); sub(/[ \t]+$/, "", v)
            if (k == "fullname") f = v; else if (k == "orgname") o = v; else if (k == "computername") c = v }
        END { if (f == "") f = "USOS"; if (c == "" || c == "USOS-NT351") c = "USOS-NT31"
            printf "fullname=%s\r\norg=%s\r\ncomputer=%s\r\n", f, o, c }' "$work/WINNT.SIF" > "$usos/NAMES.TXT" || fail 'cannot write NAMES.TXT'
    # Run by GUI Setup at its end (INITIAL.INF [UsosNt31Post], after the
    # Services keys): the drivers into place, then DONE.TXT for the VM loop.
    crlf <<'EOF' > "$usos/POST.CMD"
@echo off
echo USOS NT 3.1 post > C:\USOS\NT3\POST.LOG
copy C:\USOS\NT3\AHCINT.SYS C:\WINNT\SYSTEM32\DRIVERS\AHCINT.SYS >> C:\USOS\NT3\POST.LOG
copy C:\USOS\NT3\USOSRST.SYS C:\WINNT\SYSTEM32\DRIVERS\USOSRST.SYS >> C:\USOS\NT3\POST.LOG
copy C:\USOS\NT3\USOSUSB.SYS C:\WINNT\SYSTEM32\DRIVERS\USOSUSB.SYS >> C:\USOS\NT3\POST.LOG
if exist C:\USOS\NT3\USOSNVME.SYS copy C:\USOS\NT3\USOSNVME.SYS C:\WINNT\SYSTEM32\DRIVERS\USOSNVME.SYS >> C:\USOS\NT3\POST.LOG
if not exist C:\WINNT\SYSTEM32\DRIVERS\AHCINT.SYS echo AHCINT.SYS copy FAILED >> C:\USOS\NT3\POST.LOG
if exist C:\USOS\NT3\USOSNVME.SYS if not exist C:\WINNT\SYSTEM32\DRIVERS\USOSNVME.SYS echo USOSNVME.SYS copy FAILED >> C:\USOS\NT3\POST.LOG
C:\USOS\NT3\USOSNT3.EXE /polish
echo done > C:\USOS\NT3\DONE.TXT
EOF
}

# Native NT 3.1 (NT_NATIVE=1, docs/nt-native-plan.md section 8): TXTSETUP.INF
# (stdin -> stdout, CR LF) with
#   [SCSI.ISA.Load] / [SCSI.EISA.Load] / [SCSI.MCA.Load]  empty: SETUPLDR
#       loads and runs every listed ISA/EISA/MCA miniport, whose port probes
#       have no business on a modern board; text mode reaches C: through
#       BIOS INT 13h (SETUPAPP inside the loader, CSMWrap/SeaBIOS);
#   [WinntFiles]  the USOS drivers ($1 = "nvme": also usosnvme) to
#       system32\drivers (directory 4) from the local source, so the first
#       GUI-mode boot has them; their Services keys come from the patched
#       SYSTEM._ template (usos-fb-ui --nt31-hive);
#   [Keyboard] / [Mouse]  rows naming the service i8042prt name "beep"
#       instead: SETUPAPP sets the picked keyboard (and PS/2 mouse) service
#       to Start 1 over the template's 4, and NT 3.1's i8042prt never
#       returns from its initialisation on the X470 (2026-10-30: the
#       usosnvme request ring of the hung first GUI-mode boot ends with
#       I8042PRT.SYS; with i8042prt Start 4 GUI Setup ran to the desktop).
#       Beep is Start 1 in the template already, so that write changes
#       nothing; USB keyboard and mouse are usosusb's. The file is still
#       copied (files.i8042).
# rc 1 when a section or the keyboard row is missing.
nt31_native_txtsetup() {
    awk -v BINMODE=3 -v nvme="${1:-}" '
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low) }
        low ~ /^\[/ {
            sec = low; printf "%s\r\n", line
            if (sec ~ /^\[scsi\.(isa|eisa|mca)\.load\]$/) hit++
            if (sec == "[winntfiles]" && !files++) {
                printf "d2,AHCINT.SYS,4\r\nd2,USOSRST.SYS,4\r\nd2,USOSUSB.SYS,4\r\nd2,USOSDISK.SYS,4\r\n"
                if (nvme == "nvme") printf "d2,USOSNVME.SYS,4\r\n"
            }
            next
        }
        sec ~ /^\[scsi\.(isa|eisa|mca)\.load\]$/ && low != "" && low !~ /^#/ { next }
        (sec == "[keyboard]" || sec == "[mouse]") && low ~ /,i8042prt$/ {
            sub(/i8042prt[ \t]*$/, "beep", line)
            if (sec == "[keyboard]") kbd++
        }
        { printf "%s\r\n", line }
        END { if (files != 1 || hit != 3 || kbd < 1) { print "TXTSETUP.INF: no [WinntFiles] / [SCSI.*.Load] sections or no i8042prt [Keyboard] row" > "/dev/stderr"; exit 1 } }'
}

# Native NT 3.1 INITIAL.INF additions (after nt31_initial_inf; stdin ->
# stdout, CR LF): GUI Setup refuses a Zen 3 CPU (GetProcessor; the VM ran
# -cpu pentium), so STF_PROCESSOR = I586 right after "detect ProcessorVar"
# (as nt35_initial.zig does for 3.5), and the GUI page answerer USOSANS31
# (tools/nt3/native31: Date/Time OK, AS "Controller in New Domain") starts
# right after LoadSetupLibrary. [UsosNt31Post]: after its Scsidisk Start 0
# the first-boot class driver service usosdisk (nt31_hive.zig) goes to
# Start 4. rc 1 when an anchor is not there once.
nt31_native_initial() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low); printf "%s\r\n", line }
        low == "detectprocessorvar" { printf "    set STF_PROCESSOR = $(ProcessorID_I586) ;USOS-NT31-CPU\r\n"; cpu++ }
        low == "installloadsetuplibrary" { printf "    StartDetachedProcess STATUS \"\" \"\" \"C:\\USOS\\NT3\\USOSANS31.EXE\"\r\n"; ans++ }
        index(low, "createkey$(usossvc){{scsidisk,0,33554432}}") { pend = 1 }
        pend && low == "endif" {
            pend = 0; disk++
            printf "    shell \"registry.inf\" CreateKey $(UsosSvc) {{usosdisk,0,33554432}} {{Start,0,$(!REG_VT_DWORD),4}}\r\n"
            printf "    ifstr(i) $($R0) == STATUS_SUCCESSFUL\r\n        CloseRegKey $($R1)\r\n    endif\r\n"
        }
        END { if (cpu != 1 || ans != 1 || disk != 1) { print "INITIAL.INF: detect ProcessorVar " cpu "/1, LoadSetupLibrary " ans "/1, Scsidisk " disk "/1" > "/dev/stderr"; exit 1 } }'
}

# One SZDD file $1 of the local source through the filter "$2 ..." (the
# remaining arguments), written back in the same container (literal SZDD,
# read back by usos-fb-ui --szdd-put). A plain file is filtered as is.
nt31_native_szdd() {
    nf=$1
    shift
    [ -f "$nf" ] || fail "the NT 3.1 local source has no $(basename "$nf")"
    rm -f "$work/sz.in" "$work/sz.out" "$work/sz.new"
    "${USOS_FB_UI:-usos-fb-ui}" --szdd-get "$nf" "$work/sz.in" || fail "cannot expand $(basename "$nf")"
    "$@" < "$work/sz.in" > "$work/sz.out" || fail "cannot patch $(basename "$nf") (anchors differ: another CD?)"
    "${USOS_FB_UI:-usos-fb-ui}" --szdd-put "$nf" "$work/sz.out" "$work/sz.new" || fail "cannot pack $(basename "$nf")"
    cat "$work/sz.new" > "$nf" || fail "cannot write $(basename "$nf")"
    rm -f "$work/sz.in" "$work/sz.out" "$work/sz.new"
}

# Native NT 3.1 GUI INF filters (nt4_qemu_install.sh holds the VM flow's
# versions; sourced in a subshell, it only defines variables and functions).
nt31_initial_both() {
    ( . "$LIB/nt4_qemu_install.sh"; nt31_initial_inf "$q_full" "$q_org" "$q_comp" "$q_net" "$q_nvme" ) | nt31_native_initial
}
nt31_hardware() { ( . "$LIB/nt4_qemu_install.sh"; nt31_hardware_inf ); }
nt31_ntlanman() { ( . "$LIB/nt4_qemu_install.sh"; nt31_ntlanman_inf ); }
nt31_oemnadlb() { ( . "$LIB/nt4_qemu_install.sh"; nt31_oemnadlb_inf ); }

# Native NT 3.1: the local source and \USOS\NT3 for text mode, GUI mode and
# POST.CMD on this PC (no install VM; docs/nt-native-plan.md section 8).
nt31_native() {
    q_nvme=''
    [ -z "$nvme" ] || q_nvme=nvme
    for inf in "$work/c/TXTSETUP.INF" "$ls_dir/TXTSETUP.INF"; do
        [ -f "$inf" ] || continue
        nt31_native_txtsetup "$q_nvme" < "$inf" > "$work/txtsetup.nat" && cat "$work/txtsetup.nat" > "$inf" ||
            fail 'cannot prepare TXTSETUP.INF for the native NT 3.1 Setup'
    done
    log "native: TXTSETUP.INF [SCSI.*.Load] empty (text mode on BIOS INT 13h), [WinntFiles] + AHCINT USOSRST USOSUSB USOSDISK${nvme:+ USOSNVME}"
    cp "$drv/$ahci" "$ls_dir/AHCINT.SYS" && cp "$drv/$rst" "$ls_dir/USOSRST.SYS" && cp "$drv/$usb" "$ls_dir/USOSUSB.SYS" ||
        fail 'cannot copy the USOS drivers to the local source'
    [ -z "$nvme" ] || cp "$drv/$nvme_sys" "$ls_dir/USOSNVME.SYS" || fail 'cannot copy USOSNVME.SYS to the local source'
    # The disk class driver of the first GUI-mode boot (service usosdisk,
    # nt31_hive.zig): SETUPAPP sets Scsidisk Start 1 when SETUPLDR loaded
    # no SCSI miniport (always here) -> STOP 0x7B (X470 2026-10-30). The
    # CD's own SCSIDISK.SY_ under a second name (SZDD keeps only the last
    # character of the name, S in both).
    disk_src=''
    for name in SCSIDISK.SY_ SCSIDISK.SYS; do [ -f "$ls_dir/$name" ] && disk_src=$name && break; done
    [ -n "$disk_src" ] || fail 'the NT 3.1 local source has no SCSIDISK.SY_'
    cp "$ls_dir/$disk_src" "$ls_dir/USOSDISK.${disk_src##*.}" || fail 'cannot copy SCSIDISK as USOSDISK to the local source'
    # The SYSTEM hive template: the USOS boot drivers registered before text
    # mode copies it (src/compat/win3x/nt31_hive.zig).
    hive=''
    for name in SYSTEM._ SYSTEM; do [ -f "$ls_dir/$name" ] && hive="$ls_dir/$name" && break; done
    [ -n "$hive" ] || fail 'the NT 3.1 local source has no SYSTEM._ (hive template)'
    rm -f "$work/SYSTEM.NEW"
    if "${USOS_FB_UI:-usos-fb-ui}" --nt31-hive "$hive" "$work/SYSTEM.NEW" $q_nvme > "$work/hive.log" 2>&1; then rc=0; else rc=$?; fi
    while IFS= read -r line; do log "$line"; done < "$work/hive.log"
    [ "$rc" = 0 ] && [ -s "$work/SYSTEM.NEW" ] || fail 'cannot add the USOS boot drivers to the SYSTEM._ template (not the NT 3.1 CD template?)'
    cat "$work/SYSTEM.NEW" > "$hive" && cmp -s "$work/SYSTEM.NEW" "$hive" || fail 'read-back: SYSTEM._ differs'
    rm -f "$work/SYSTEM.NEW"
    # GUI Setup's INF files, patched here instead of between VM starts
    # (nt31_vm_patch_initial): names, no network / printer / apps / ERD,
    # [UsosNt31Post] (drivers, keys, POST.CMD) + the native additions.
    q_full=$(tr -d '\r' < "$usos/NAMES.TXT" | awk -F= '$1 == "fullname" { sub(/^[^=]*=/, ""); print; exit }')
    q_org=$(tr -d '\r' < "$usos/NAMES.TXT" | awk -F= '$1 == "org" { sub(/^[^=]*=/, ""); print; exit }')
    q_comp=$(tr -d '\r' < "$usos/NAMES.TXT" | awk -F= '$1 == "computer" { sub(/^[^=]*=/, ""); print; exit }')
    q_net=''
    [ "${product:-0}" = 0 ] || q_net=net
    nt31_native_szdd "$ls_dir/INITIAL.IN_" nt31_initial_both
    nt31_native_szdd "$ls_dir/HARDWARE.IN_" nt31_hardware
    if [ -n "$q_net" ]; then
        nt31_native_szdd "$ls_dir/NTLANMAN.IN_" nt31_ntlanman
        nt31_native_szdd "$ls_dir/OEMNADLB.IN_" nt31_oemnadlb
        log 'native: Advanced Server: MS Loopback Adapter + new domain USOSDOMAIN (USOSANS31 answers Domain Settings)'
    fi
    log 'native: INITIAL.IN_ (names, I586, no network/printer/apps/ERD, [UsosNt31Post], USOSANS31) + HARDWARE.IN_ patched in the local source'
    [ -r "$LIB/nt3/USOSANS31.EXE" ] || fail "missing: $LIB/nt3/USOSANS31.EXE (GUI Setup page answerer)"
    cp "$LIB/nt3/USOSANS31.EXE" "$usos/USOSANS31.EXE" || fail 'cannot copy USOSANS31.EXE'
    printf '[native]\r\ndomain=USOSDOMAIN\r\n' > "$usos/NATIVE31.INI" || fail 'cannot write NATIVE31.INI'
    printf 'boot_options=%s\r\n' "$NT_NATIVE_LOAD_OPTIONS" > "$usos/NATIVE.TXT" || fail 'cannot write NATIVE.TXT'
    # POST.CMD (end of GUI Setup): BOOT.INI as the VM finish step writes it
    # and the Setup leftovers removed (usosnt3 /finish31), before DONE.TXT.
    awk -v BINMODE=3 '{ sub(/\r$/, "") } /^echo done > / { printf "C:\\USOS\\NT3\\USOSNT3.EXE /finish31\r\n" } { printf "%s\r\n", $0 }' "$usos/POST.CMD" > "$work/post.cmd" &&
        cat "$work/post.cmd" > "$usos/POST.CMD" && grep -q 'finish31' "$usos/POST.CMD" || fail 'cannot write POST.CMD'
    log "native: NATIVE.TXT boot_options=$NT_NATIVE_LOAD_OPTIONS, POST.CMD runs USOSNT3.EXE /finish31 (BOOT.INI, leftovers)"
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
    rm -f "$work/WINNT.SIF" "$work/ACCOUNT.TXT" "$work/WINNT.NEW"
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
# NT 3.1 (docs/nt31-2026-10-09.md): the older Setup generation, I386\TXTSETUP.INF
# and I386\SETUPLDR (no .BIN), no MajorVersion. Its text-mode Setup is
# SETUPAPP.EXE inside the loader (BIOS disk calls, no CD driver needed when
# the files come from the local source on C:).
nt31=''
if [ -z "$txtsetup" ] && [ -z "$setupldr" ]; then
    for name in TXTSETUP.INF txtsetup.inf; do [ -f "$i386/$name" ] && txtsetup="$i386/$name" && break; done
    for name in SETUPLDR setupldr; do [ -f "$i386/$name" ] && setupldr="$i386/$name" && break; done
    [ -n "$txtsetup" ] && [ -n "$setupldr" ] && nt31=yes
fi
[ -n "$txtsetup" ] && [ -n "$setupldr" ] || fail 'the ISO has no I386\TXTSETUP.SIF / SETUPLDR.BIN (not an NT 3.x / 4.0 Setup CD)'
# [SetupData] MajorVersion: 4 = NT 4.0, 3 = NT 3.51 (2000/XP: 5). NT_MAJOR
# (the system chosen in the menu, when set) must match the CD.
setup_value() {
    awk -v key="$1" '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) == "[setupdata]") } s && tolower($1) == key { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }' "$txtsetup"
}
major=$(setup_value majorversion)
minor=$(setup_value minorversion)
[ -z "$nt31" ] || { major=3; minor=10; }
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
    yes:51|yes:50|yes:10|:*) ;;
    *) fail "of the NT 3.x family only NT 3.51, 3.5 and 3.1 are supported so far (MinorVersion=${minor:-none})" ;;
esac
# NVMe target gate, before any write (docs/nvme-nt6-2026-10-12.md): NT 4.0
# and NT 3.x get usosnvme below (NT 3.5x: NT351 build, NT 3.1: NT31 build;
# docs/nvme-nt-2026-10-11.md section 9).
nvme=''
case "$TARGET_DEVICE" in /dev/nvme*)
    nvme=yes
    nvme_lbs=$(cat "/sys/class/block/${TARGET_DEVICE##*/}/queue/logical_block_size" 2>/dev/null || echo unknown)
    [ "$nvme_lbs" = 512 ] || fail "the NVMe target uses $nvme_lbs-byte sectors; Windows NT needs 512-byte sectors. No disk was changed" ;;
esac
[ -z "${NT_MINOR:-}" ] || [ "$NT_MINOR" = "$minor" ] || fail "the ISO is Windows NT $major.$minor Setup, not the chosen NT $major.$NT_MINOR system"
# Native NT 4.0 (no VM): the NT 3.x MBR too. Text mode then runs on the PC,
# and its pre-ACPI HAL needs the HPET LegacyReplacement off before it starts
# (usosrst comes only with POST.CMD) and the E820 filter for the RTM
# SETUPLDR; the PCI BIOS stays visible (options byte, below).
nt4_native_mbr=''
[ -n "$nt3" ] || [ "$NATIVE" != 1 ] || nt4_native_mbr=yes
mbr_code=$LIB/xp-geometry-fix-mbr-440.bin
[ -z "$nt3$nt4_native_mbr" ] || mbr_code=$LIB/nt3-e820-mbr-440.bin
[ -r "$mbr_code" ] || fail "missing: $mbr_code"
[ "$(wc -c < "$mbr_code" | tr -d ' ')" = 440 ] || fail 'USOS MBR code must be 440 bytes'
# NT 3.x: the MBR's resident INT 15h / INT 1Ah hooks are sector 1
# (nt3_e820_mbr.S; it boots without hooks when the sector is missing).
mbr_hook=''
[ -z "$nt3$nt4_native_mbr" ] || mbr_hook=$LIB/nt3-e820-hook-512.bin
[ -z "$mbr_hook" ] || [ "$(wc -c < "$mbr_hook" 2>/dev/null | tr -d ' ')" = 512 ] || fail "missing or not 512 bytes: $mbr_hook"
# Its bus-master quiesce, sector 3 ("Q3"), run by the MBR only with bit 1 of
# the hook options byte (native NT 3.x, below).
mbr_quiesce=''
[ -z "$mbr_hook" ] || mbr_quiesce=$LIB/nt3-e820-quiesce-512.bin
[ -z "$mbr_quiesce" ] || [ "$(wc -c < "$mbr_quiesce" 2>/dev/null | tr -d ' ')" = 512 ] || fail "missing or not 512 bytes: $mbr_quiesce"
# Native NT 3.1: its text-mode key answerer, sector 5 ("K3"), loaded by the
# quiesce code with bit 2 of the hook options byte (below).
mbr_keys=''
[ "$NATIVE:$nt31" != 1:yes ] || [ -z "$mbr_hook" ] || mbr_keys=$LIB/nt3-e820-keys-512.bin
[ -z "$mbr_keys" ] || [ "$(wc -c < "$mbr_keys" 2>/dev/null | tr -d ' ')" = 512 ] || fail "missing or not 512 bytes: $mbr_keys. No disk was changed"
drv=$LIB/$(printf %s "$sub" | tr '[:upper:]' '[:lower:]')
for file in AHCINT.SYS USOSRST.SYS USOSUSB.SYS; do [ -r "$drv/$file" ] || fail "missing: $drv/$file"; done
# usosrst for NT 3.5 (USOSRST35.SYS, build-nt35.cmd): the 3.5 kernel lacks
# KeSetTargetProcessorDpc / KeSetImportanceDpc.
rst=USOSRST.SYS
[ "$nt3:$minor" != yes:50 ] || rst=USOSRST35.SYS
# NT 3.1 builds (no KeRegisterBugCheckCallback, memset, IofCompleteRequest,
# Kf*Irql in the 3.1 kernel / HAL): AHCINT31.SYS, USOSRST31.SYS, USOSUSB31.SYS.
ahci=AHCINT.SYS usb=USOSUSB.SYS
[ -z "$nt31" ] || { rst=USOSRST31.SYS ahci=AHCINT31.SYS usb=USOSUSB31.SYS; }
# usosnvme for an NVMe target: NT 3.1 build USOSNVME31.SYS, NT 3.5x build
# USOSNVME.SYS (both in $LIB/nt3); NT 4.0 takes $LIB/nt4/USOSNVME.SYS below.
nvme_sys=USOSNVME.SYS
[ -z "$nt31" ] || nvme_sys=USOSNVME31.SYS
[ -z "$nvme" ] || [ -r "$drv/$nvme_sys" ] || fail "missing: $drv/$nvme_sys (NVMe driver). No disk was changed"
if [ -n "$nt31" ]; then
    for file in $ahci $rst $usb USOSNT3.EXE; do [ -r "$drv/$file" ] || fail "missing: $drv/$file"; done
elif [ -n "$nt3" ]; then
    for file in USOSNT3.EXE USOSACHK.EXE $rst; do [ -r "$drv/$file" ] || fail "missing: $drv/$file"; done
else
    for file in USOSVBE.SYS USOSOFF.EXE; do [ -r "$drv/$file" ] || fail "missing: $drv/$file"; done
fi
lang=$(awk '{ sub(/\r$/, "") } tolower($1) == "unicodecasetable" { n = split($0, a, ","); v = a[n]; gsub(/[ \t]/, "", v); print v; exit }' "$txtsetup")
product=$(awk '{ sub(/\r$/, "") } /^\[/ { s = (tolower($0) == "[setupdata]") } s && tolower($1) == "producttype" { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }' "$txtsetup")
log "source: NT $major.$minor ProductType=${product:-?} language=${lang:-?}"
# Windows NT 4.0 Terminal Server Edition: tag file CDROM_TS.40 on the CD root
# (the Workstation / Server CDs have CDROM_W.40 / CDROM_S.40), kernel 1381
# multi-user (QFE number 32772). Same Setup, same layout and answers (it is a
# Server CD: ProductType 1); only its own service pack applies.
tse=''
for name in CDROM_TS.40 cdrom_ts.40; do [ -f "$work/iso/$name" ] && tse=yes; done
# This preparation round qualifies WS/Server only; TSE keeps its old path.
NT4_NATIVE_PREP=0
[ "${NATIVE:-0}:${major:-0}:${tse:-}" != 1:4: ] || NT4_NATIVE_PREP=1
if [ "$EDITION" = tse ] && [ -z "$tse" ]; then
    fail 'the ISO is not the Windows NT 4.0 Terminal Server Edition CD (no CDROM_TS.40): choose Windows NT 4.0 or Windows NT 4.0 Server for it'
fi
if [ -n "$tse" ] && [ "$EDITION" != tse ] && [ "${NT_MAJOR:-}" = 4 ]; then
    fail 'the ISO is the Windows NT 4.0 Terminal Server Edition CD: choose Windows NT 4.0 Terminal Server Edition for it (it needs its own service pack)'
fi
[ -z "$tse" ] || log 'edition: Terminal Server Edition (CDROM_TS.40)'
# Manual Setup (profile win9x_setup=manual, src/flow/answer/nt4.zig): GUI
# Setup shows its pages, so somebody must be at the screen: native only.
NT4_MANUAL=0
grep -aq '^;USOS-SETUP=manual' "$ANSWER_SIF" && NT4_MANUAL=1
if [ "$NT4_MANUAL" = 1 ] && [ "$NT4_NATIVE_PREP" != 1 ]; then
    fail 'manual Windows NT 4.0 Setup needs the native install (nt4-native.flag): in the install VM nobody can answer its pages. Choose the automatic Setup in the profile. No disk was changed'
fi
[ "$NT4_MANUAL" != 1 ] || log 'Setup: manual (GUI Setup shows Welcome, name, key without a profile key, computer name, date/time; text mode, network, display and the USOS steps stay automatic)'
if [ -z "$nt3" ] && [ "$NT4_MANUAL" = 1 ]; then
    log 'product key: setup-page (manual Setup asks for it when the profile has none)'
elif [ -z "$nt3" ]; then
    key_state=$(nt4_key_gate "$ANSWER_SIF" "$i386") ||
        fail 'this Windows NT 4.0 CD asks for its product key, and the install runs in a VM where nobody can type it: add the key to the answer profile (or type it when the menu asks). No disk was changed'
    log "product key: $key_state"
fi
if [ "$NATIVE" = 1 ]; then
    { [ "$nt3:$minor" = yes:51 ] || [ "$nt3:$minor" = yes:50 ] || [ "$nt3:$minor" = yes:10 ] || [ "$nt3:$major" = :4 ]; } ||
        fail "the native install (no VM) covers Windows NT 4.0, 3.51, 3.5 and 3.1 only so far, not NT $major.$minor. No disk was changed"
    # NT 3.1: no /NUMPROC in its loader; /NODEBUG (else its kernel debugger
    # takes COM1) and 64 MiB, the size every NT 3.1 X470 PASS ran with
    # (2026-10-10, winmsd 65,088 KB); the MBR hook caps text mode too.
    [ -z "$nt31" ] || NT_NATIVE_LOAD_OPTIONS=${NT31_NATIVE_LOAD_OPTIONS:-/NODEBUG /MAXMEM=64}
    # NT 3.5x: the Standard PC HAL and the uniprocessor kernel
    # (nt3_standard_hal) run one processor, so no /NUMPROC. NT 3.5: more
    # than 128 MiB loses the boot disk (NT35_BOOT_OPTIONS in
    # nt4_qemu_install.sh).
    [ "$nt3:$minor" != yes:51 ] || NT_NATIVE_LOAD_OPTIONS=${NT351_NATIVE_LOAD_OPTIONS:-/MAXMEM=1024}
    [ "$minor" != 50 ] || NT_NATIVE_LOAD_OPTIONS=${NT35_NATIVE_LOAD_OPTIONS:-/MAXMEM=128}
    # The GUI Setup page recorder (one build for NT 3.5x and 4.0, $LIB/nt3;
    # NT 3.1: its answerer USOSANS31.EXE, staged by nt31_native).
    ans3=$LIB/nt3/USOSANS3.EXE
    [ -z "$nt31" ] || ans3=$LIB/nt3/USOSANS31.EXE
    [ -r "$ans3" ] || fail "missing: $ans3 (GUI Setup page recorder). No disk was changed"
    if [ -z "$nt3" ]; then
        # Native NT 4.0 (nt4-native.flag): the RTM kernels with the CPUID
        # leaf limit raised, before any disk write; the MPS machine type for
        # ComputerType.
        command -v cmp >/dev/null 2>&1 || fail 'cmp is required. No disk was changed'
        if [ "$NT4_NATIVE_PREP" = 1 ]; then
            [ -r "$LIB/nt4/USOSNT4.EXE" ] || fail 'missing NT4 native finish helper. No disk was changed'
            [ -r "$LIB/nt4/USOSANS4.EXE" ] || fail 'missing NT4 native page answerer. No disk was changed'
            [ -r "$LIB/nt4/USOSRSTN.SYS" ] || fail 'missing native NT4 usosrst (USOSRSTN.SYS). No disk was changed'
            ans3=$LIB/nt4/USOSANS4.EXE
        fi
        nt4_native_kernels
        nt4_mps_desc=$(nt4_computer_desc mps_mp < "$txtsetup")
        [ -n "$nt4_mps_desc" ] || fail 'TXTSETUP.SIF has no [Computer] mps_mp row (not an NT 4.0 CD?). No disk was changed'
        [ -z "$nvme" ] || [ -r "$LIB/nt4/USOSNVME.SYS" ] || fail "missing: $LIB/nt4/USOSNVME.SYS (NVMe driver). No disk was changed"
    fi
    log 'native: text mode on this PC after the restart (no install VM)'
fi
if [ -n "$nt3" ]; then
    nt4_resolve_time_zone "${lang:-}" yes < "$ANSWER_SIF" | nt4_server_answer "${product:-0}" yes | nt3_detached_answer > "$work/WINNT.SIF" ||
        fail 'cannot prepare WINNT.SIF'
    profile_values=$(nt3_profile_files "$work/WINNT.SIF" "$work") || fail 'cannot read the answer profile values'
    log "answer profile: $profile_values"
    if [ "$NATIVE" = 1 ] && [ "$major:$minor" = 3:50 ]; then
        # Native NT 3.5 (2026-10-30): the USOSNET35N build (NT 3.51 native
        # code on NDIS 3.5, CF8h/CFCh) and the OEMNADLB patch in the local
        # source (usos_nt35_source_patch below), as on native NT 3.51. A
        # refused preflight installs without network.
        _u351_enabled=off
        . "$LIB/nt35_network_setup.sh"
        if ! usos_nt35_preflight "$work/WINNT.SIF" "$LIB" "${USOS_PCI_ROOT:-/sys/bus/pci/devices}" native; then
            log 'NT35 LAN skipped: preflight refused (DHCP, one supported card and verified own driver required); installing without network'
            _u35_enabled=off
        fi
        if [ "${_u35_enabled:-off}" = on ]; then
            cp "$work/WINNT.SIF" "$work/WINNT.NONET" || fail 'cannot keep the answer without network'
            usos_nt35_answer "$work/WINNT.SIF" > "$work/WINNT.NET35" &&
              mv "$work/WINNT.NET35" "$work/WINNT.SIF" || fail 'cannot render original NT35 LAN answer'
            log 'native NT 3.5 LAN: usosnet35n (CF8h/CFCh, polling), TCP/IP DHCP'
        fi
    elif [ "$NATIVE" = 1 ] && [ "$major:$minor" != 3:51 ]; then
        _u351_enabled=off
    elif [ "$major:$minor" = 3:51 ]; then
        . "$LIB/nt351_network_setup.sh"
        # LAN is optional, as on NT4 (network_setup.sh): a refused preflight
        # (no / two supported cards, static IP or DNS, driver check) installs
        # without network instead of stopping the whole install.
        # Native (docs/nt351-native-net-2026-10-28.md): the USOSNET351N build
        # (no HAL PCI bus on the X470) and the OEMNADLB patch in the local
        # source (usos_nt351_source_patch below) instead of between VM starts.
        _u351_variant=''
        [ "$NATIVE" != 1 ] || _u351_variant=native
        if ! usos_nt351_preflight "$work/WINNT.SIF" "$LIB" "${USOS_PCI_ROOT:-/sys/bus/pci/devices}" $_u351_variant; then
            log 'NT351 LAN skipped: preflight refused (DHCP, one supported card and verified own driver required); installing without network'
            _u351_enabled=off
        fi
        if [ "$_u351_enabled" = on ]; then
            cp "$work/WINNT.SIF" "$work/WINNT.NONET" || fail 'cannot keep the answer without network'
            usos_nt351_answer "$work/WINNT.SIF" > "$work/WINNT.NET351" &&
              mv "$work/WINNT.NET351" "$work/WINNT.SIF" || fail 'cannot render original NT351 LAN answer'
        fi
    fi
    if [ "$major:$minor" = 3:50 ] && [ "$NATIVE" != 1 ]; then
        . "$LIB/nt35_network_setup.sh"
        if ! usos_nt35_preflight "$work/WINNT.SIF" "$LIB" "${USOS_PCI_ROOT:-/sys/bus/pci/devices}"; then
            log 'NT35 LAN skipped: preflight refused (DHCP, exact PCI bus/slot and verified own driver required); installing without network'
            _u35_enabled=off
        fi
        if [ "$_u35_enabled" = on ]; then
            usos_nt35_answer "$work/WINNT.SIF" > "$work/WINNT.NET35" &&
              mv "$work/WINNT.NET35" "$work/WINNT.SIF" || fail 'cannot render original NT35 LAN answer'
        fi
    fi
else
    # Manual Setup: the Server Type and Licensing Mode pages are the user's
    # (no AdvServerType / LicenseFilePrintData), as are the TSE desktops.
    server_product=${product:-0}
    [ "$NT4_MANUAL" != 1 ] || server_product=0
    nt4_resolve_time_zone "${lang:-}" < "$ANSWER_SIF" | nt4_server_answer "$server_product" > "$work/WINNT.SIF" || fail 'cannot prepare WINNT.SIF'
    if [ -n "$tse" ] && [ "$NT4_MANUAL" != 1 ]; then
        nt4_tse_answer < "$work/WINNT.SIF" > "$work/WINNT.TSE" && mv "$work/WINNT.TSE" "$work/WINNT.SIF" || fail 'cannot prepare WINNT.SIF'
        log 'Terminal Server: 5 client licenses (TerminalServerDesktops), no IE 4.0 during Setup'
    fi
    if [ "$NATIVE" = 1 ]; then
        nt4_native_answer "$nt4_mps_desc" < "$work/WINNT.SIF" > "$work/WINNT.NAT" && mv "$work/WINNT.NAT" "$work/WINNT.SIF" || fail 'cannot prepare WINNT.SIF'
        log "native: ComputerType $(awk '{ sub(/\r$/, "") } tolower($0) ~ /^[ \t]*computertype[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); print; exit }' "$work/WINNT.SIF")"
    fi
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
CLUSTER_SECTORS=64
if [ -n "$nt31" ]; then
    PART_SECTORS=${NT31_PART_SECTORS:-1024000}
    CLUSTER_SECTORS=${NT31_CLUSTER_SECTORS:-16}
    MKFS_NOALIGN=-a
fi
log "disk_sectors=$total part_start=$PART_START part_sectors=$PART_SECTORS"
if [ -n "$nt4_native_mbr" ]; then
    # Hook sector options byte (offset 509, nt3_e820_mbr.S HOOK_OPTIONS):
    # bit 0 keeps the PCI BIOS visible for the NT 4.0 HAL.
    cp "$mbr_hook" "$work/hook.bin" && printf '\001' | dd of="$work/hook.bin" bs=1 seek=509 count=1 conv=notrunc 2>/dev/null ||
        fail 'cannot prepare the MBR hook sector. No disk was changed'
    [ "$(od -An -tu1 -j509 -N1 "$work/hook.bin" | tr -d ' \n')" = 1 ] || fail 'the MBR hook options byte did not take. No disk was changed'
    mbr_hook=$work/hook.bin
    log 'MBR: NT 3.x MBR + hook (E820 filter, HPET LegacyReplacement off), PCI BIOS kept (options byte 509 = 1)'
fi
# Native NT 3.5x: RAM cap in the hook sector (byte 508, 16 MiB units,
# nt3_e820_mbr.S HOOK_RAM_CAP), from the first text-mode start on, whatever
# BOOT.INI says. NT 3.5: 128 MiB (8); its kernel loses the boot disk above
# 128 MiB (docs/nt35-2026-10-09.md) and its text-mode SETUPLDR ignores
# /MAXMEM. NT 3.51: 1024 MiB (64); text mode writes Setup's BOOT.INI entry
# without /MAXMEM, so GUI Setup's starts ran on 3 GB and stopped with 0x0A
# in the working-set list growth (X470 B261029-161430). The hook clips E820
# and AH=88h / AX=E801h. Native NT 4.0 WS / Server (NT4_NATIVE_PREP):
# 1024 MiB (64) too, so text mode stays capped where /MAXMEM is ignored.
# Native TSE and the VM path keep 0.
ram_cap=''
if [ "$NATIVE" = 1 ] && [ -n "$mbr_hook" ]; then
    case "$nt3:$minor" in
        yes:50) ram_cap=8 ram_oct='\010' ;;
        yes:51) ram_cap=64 ram_oct='\100' ;;
        # NT 3.1: 64 MiB (4), through AH=88h / AX=E801h (its loaders know no E820).
        yes:10) ram_cap=4 ram_oct='\004' ;;
    esac
    [ "$NT4_NATIVE_PREP" != 1 ] || { ram_cap=64 ram_oct='\100'; }
fi
if [ -n "$ram_cap" ]; then
    cp "$mbr_hook" "$work/hookcap.bin" && printf "$ram_oct" | dd of="$work/hookcap.bin" bs=1 seek=508 count=1 conv=notrunc 2>/dev/null ||
        fail 'cannot prepare the MBR hook sector. No disk was changed'
    [ "$(od -An -tu1 -j508 -N1 "$work/hookcap.bin" | tr -d ' \n')" = "$ram_cap" ] || fail 'the MBR hook RAM cap did not take. No disk was changed'
    mbr_hook=$work/hookcap.bin
    log "MBR: NT 3.x MBR + hook, RAM cap $((ram_cap * 16)) MiB (hook byte 508 = $ram_cap; E820 + AH=88h/E801h)"
fi
# Native NT 3.x and NT 4.0: bus-master quiesce (hook options byte 509 bit 1,
# nt3_e820_mbr.S OPT_QUIESCE): before the boot sector the MBR clears PCI Bus
# Master Enable on every network controller, so a NIC the last NT boot left
# receiving (warm reset after a bugcheck / restart; the X470 I211) cannot
# write into the memory of the next boot before usosnet351n / usosnet4
# resets it. The quiesce code is sector 3 (written with the hook below).
if [ "$NATIVE" = 1 ] && [ -n "$mbr_hook" ]; then
    opt=$(od -An -tu1 -j509 -N1 "$mbr_hook" | tr -d ' \n')
    opt=$((opt | 2))
    # NT 3.1 text mode reads its keys through BIOS INT 16h and has no answer
    # file: bit 2 (OPT_KEYS31) makes the MBR load the key answerer
    # (sector 5) that types ENTER on the express-path pages (the install VM
    # runner's rules) and resets on the final page.
    [ -z "$mbr_keys" ] || opt=$((opt | 4))
    cp "$mbr_hook" "$work/hookq.bin" && printf "\\$(printf %03o "$opt")" | dd of="$work/hookq.bin" bs=1 seek=509 count=1 conv=notrunc 2>/dev/null ||
        fail 'cannot prepare the MBR hook sector. No disk was changed'
    [ "$(od -An -tu1 -j509 -N1 "$work/hookq.bin" | tr -d ' \n')" = "$opt" ] || fail 'the MBR hook quiesce bit did not take. No disk was changed'
    mbr_hook=$work/hookq.bin
    log "MBR: NT 3.x MBR + hook, NIC bus-master quiesce (hook byte 509 = $opt, sector 3)"
fi

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
[ -z "$mbr_hook" ] || dd if="$mbr_hook" of="$TARGET_DEVICE" bs=512 seek=1 count=1 conv=notrunc,fsync 2>/dev/null ||
    fail 'cannot write the MBR hook sector'
[ -z "$mbr_quiesce" ] || dd if="$mbr_quiesce" of="$TARGET_DEVICE" bs=512 seek=3 count=1 conv=notrunc,fsync 2>/dev/null ||
    fail 'cannot write the MBR quiesce sector'
[ -z "$mbr_keys" ] || dd if="$mbr_keys" of="$TARGET_DEVICE" bs=512 seek=5 count=1 conv=notrunc,fsync 2>/dev/null ||
    fail 'cannot write the MBR key answerer sector'
[ -z "$mbr_keys" ] || log 'MBR: NT 3.1 text-mode key answerer (sector 5, hook byte 509 bit 2): ENTER on Welcome / Express / partition C: / file system / \WINNT, reset on the final page'

part_loop=$(losetup -f) || fail 'no free loop device for the new partition'
losetup -o $((PART_START * 512)) "$part_loop" "$TARGET_DEVICE" || fail 'cannot attach the new partition'
mkfs.fat -F 16 -s "$CLUSTER_SECTORS" ${MKFS_NOALIGN:-} -R 1 -f 2 -r 512 -h "$PART_START" -g 255/63 -D 0x80 -M 0xF8 -n USOS-NT4 "$part_loop" $((PART_SECTORS / 2)) >/dev/null ||
    fail 'cannot format the FAT16 partition'
mount -t vfat -o shortname=winnt,utf8=0 "$part_loop" "$work/c" || fail 'cannot mount the new FAT16 partition'

ls_dir="$work/c/\$WIN_NT\$.~LS"
bt_dir="$work/c/\$WIN_NT\$.~BT"
# NT 4.0 Setup reads \$WIN_NT$.~LS\I386; NT 3.51 reads the files straight
# from \$WIN_NT$.~LS (its DOSNET.INF d1 = \; QEMU 2026-10-08: "Setup was
# unable to copy the file kbdclass.sys" with an I386 subfolder).
if [ -n "$nt31" ]; then
    nt31_layout
else
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
if [ "$NATIVE" = 1 ] && [ -n "$nt3" ] && [ "$minor" = 51 ] && [ "${_u351_enabled:-off}" = on ]; then
    # Native NT 3.51 LAN: OEMNADLB.IN_ of the local source patched before
    # text mode copies it (the VM path patched system32 between its starts).
    # A failed patch puts the answer without network back (GUI Setup would
    # otherwise stop on the loopback's options page) instead of stopping.
    if net351_log=$(usos_nt351_source_patch "$ls_src" "$work"); then
        log "$net351_log"
    else
        log 'NT351 LAN off: the local source OEMNADLB.IN_ is not the pinned original (or the cabinet rebuild failed); installing without network'
        mv "$work/WINNT.NONET" "$work/WINNT.SIF" || fail 'cannot restore the answer without network'
        _u351_enabled=off
    fi
fi
if [ "$NATIVE" = 1 ] && [ -n "$nt3" ] && [ "$minor" = 50 ] && [ "${_u35_enabled:-off}" = on ]; then
    # Native NT 3.5 LAN: the same local-source OEMNADLB.IN_ patch (pinned
    # NT 3.5 CD hash); a failed patch installs without network.
    if net35_log=$(usos_nt35_source_patch "$ls_src" "$work"); then
        log "$net35_log"
    else
        log 'NT35 LAN off: the local source OEMNADLB.IN_ is not the pinned original (or the cabinet rebuild failed); installing without network'
        mv "$work/WINNT.NONET" "$work/WINNT.SIF" || fail 'cannot restore the answer without network'
        _u35_enabled=off
    fi
fi
rm -f "$work/WINNT.NONET"
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
    grep -aiEq '^multiprocessor *= *ntoskrnl\.exe' "$work/c/TXTSETUP.SIF" || fail 'TXTSETUP.SIF has no [SpecialFiles] Uniprocessor kernel row (not an NT 3.5 / 3.51 CD?)'
    log 'HAL: Standard PC (hal.dll) for the MPS machine types, uniprocessor kernel (ntoskrnl.exe) for the _mp ones'
    if [ "$NATIVE" = 1 ]; then
        # Text mode reaches C: through our miniport (the PCI BIOS is hidden
        # by the NT 3.x MBR; AHCINT / usosnvme find their controller through
        # CF8h/CFCh). SETUPLDR loads it from ~BT, text mode copies it from
        # the local source.
        ports=ahcint
        [ -z "$nvme" ] || ports='ahcint usosnvme'
        for sif in "$work/c/TXTSETUP.SIF" "$bt_dir/TXTSETUP.SIF" "$ls_src/TXTSETUP.SIF"; do
            [ -f "$sif" ] || continue
            nt3_native_txtsetup "$ports" "/nodebug $NT_NATIVE_LOAD_OPTIONS" < "$sif" > "$work/txtsetup.nat" && cat "$work/txtsetup.nat" > "$sif" ||
                fail 'cannot add the USOS miniports to TXTSETUP.SIF (no amsint.sys [Files] row?)'
        done
        for dir in "$bt_dir" "$ls_src"; do
            cp "$drv/$ahci" "$dir/AHCINT.SYS" || fail 'cannot copy AHCINT.SYS to the Setup source'
            [ -z "$nvme" ] || cp "$drv/$nvme_sys" "$dir/USOSNVME.SYS" || fail 'cannot copy USOSNVME.SYS to the Setup source'
        done
        log "native: TXTSETUP.SIF [SCSI.Load] = $ports, OsLoadOptions = /nodebug $NT_NATIVE_LOAD_OPTIONS"
    fi
elif [ "$NATIVE" = 1 ]; then
    # Native NT 4.0: text mode reaches C: through the NT 4.0 AHCINT /
    # usosnvme builds (PCI through the HAL bus handler; the MBR keeps the
    # PCI BIOS), the same TXTSETUP.SIF routing as NT 3.5x; OsLoadOptions for
    # the text-mode kernel, OsLoadOptionsVar for BOOT.INI.
    ports=ahcint
    [ -z "$nvme" ] || ports='ahcint usosnvme'
    for sif in "$work/c/TXTSETUP.SIF" "$bt_dir/TXTSETUP.SIF" "$ls_src/TXTSETUP.SIF"; do
        [ -f "$sif" ] || continue
        nt3_native_txtsetup "$ports" "/nodebug $NT_NATIVE_LOAD_OPTIONS" "$NT_NATIVE_LOAD_OPTIONS" < "$sif" > "$work/txtsetup.nat" && cat "$work/txtsetup.nat" > "$sif" ||
            fail 'cannot add the USOS miniports to TXTSETUP.SIF (no amsint.sys [SourceDisksFiles] row?)'
        nt4_native_mouse < "$sif" > "$work/txtsetup.mou" && cat "$work/txtsetup.mou" > "$sif" ||
            fail 'cannot point the TXTSETUP.SIF [Mouse] rows at usosusb (no [Mouse] section or sermouse.sys row?)'
    done
    cp "$LIB/nt4/USOSUSB.SYS" "$ls_src/USOSUSB.SYS" || fail 'cannot copy USOSUSB.SYS to the Setup source'
    log 'native: TXTSETUP.SIF [Mouse] rows -> usosusb (USB keyboard and mouse from the first GUI Setup boot)'
    # The patched kernels (nt4_native_kernels) where SETUPLDR (~BT) and text
    # mode (local source) take them, as plain files: the CD's compressed
    # twin goes, so nothing can pick the unpatched copy.
    for dir in "$bt_dir" "$ls_src"; do
        cp "$drv/$ahci" "$dir/AHCINT.SYS" || fail 'cannot copy AHCINT.SYS to the Setup source'
        [ -z "$nvme" ] || cp "$drv/$nvme_sys" "$dir/USOSNVME.SYS" || fail 'cannot copy USOSNVME.SYS to the Setup source'
        for base in NTOSKRNL NTKRNLMP; do
            rm -f "$dir/$base.EX_" "$dir/$base.EXE"
            cp "$work/kernel/$base.EXE" "$dir/$base.EXE" || fail "cannot copy the patched $base.EXE to the Setup source"
            cmp -s "$work/kernel/$base.EXE" "$dir/$base.EXE" || fail "read-back: $base.EXE differs in the Setup source"
        done
    done
    log "native: TXTSETUP.SIF [SCSI.Load] = $ports, OsLoadOptions = /nodebug $NT_NATIVE_LOAD_OPTIONS, OsLoadOptionsVar = $NT_NATIVE_LOAD_OPTIONS"
    log 'native: NTOSKRNL.EXE + NTKRNLMP.EXE with the raised CPUID leaf limit in ~BT and the local source'
fi
# setupldr started from the hard disk runs \NTDETECT.COM of the boot
# partition (QEMU 2026-10-07: "NTDETECT failed" without it).
ntdetect=''
for name in NTDETECT.COM ntdetect.com; do [ -f "$i386/$name" ] && ntdetect="$i386/$name" && break; done
[ -n "$ntdetect" ] || fail 'the ISO has no I386\NTDETECT.COM'
cp "$ntdetect" "$work/c/NTDETECT.COM" || fail 'cannot copy NTDETECT.COM'
fi

# NT 3.51: \USOS\NT3 with the NT 3.51 driver builds and USOSNT3.EXE, which
# does what POST.CMD and the .REG files do for NT 4.0 (tools/nt3/usosnt3:
# copies the drivers, writes their Services keys, atdisk/atapi off, the
# version and driver keys as text, DONE.TXT, restart). No service pack yet:
# the NT 3.51 RTM kernel starts on Zen 3 (QEMU EPYC-Milan 2026-10-08).
if [ -n "$nt31" ]; then
nt31_usos
[ "$NATIVE" != 1 ] || nt31_native
elif [ -n "$nt3" ]; then
usos="$work/c/USOS/NT3"
mkdir -p "$usos"
for file in AHCINT.SYS USOSUSB.SYS USOSNT3.EXE; do
    cp "$drv/$file" "$usos/$file" || fail "cannot copy $file"
done
cp "$drv/$rst" "$usos/USOSRST.SYS" || fail "cannot copy $rst"
nt3_nvme_stage
nt3_stage_profile
# The NT 3.5 LAN library is sourced only on the install VM path (the native
# path skips NT 3.5 LAN above), so its stage functions exist only there
# (X470 2026-10-28, B261028-165856: "usos_nt351_stage: not found"). NT 3.51
# sources its library on both paths.
[ "$minor" != 51 ] || usos_nt351_stage "$work/c" || fail 'cannot stage verified NT351 LAN driver'
[ "$minor" != 51 ] || usos_nt351_client_request "$work/c" "${product:-}" "$ANSWER_KIND" || fail 'cannot stage NT351 Workstation client policy request'
# NT 3.5: its library is sourced on the VM path and, since 2026-10-30, on
# the native path too (usosnet35n staged under the USOSNET35.SYS name).
[ "$minor" != 50 ] || usos_nt35_stage "$work/c" || fail 'cannot stage verified NT35 LAN driver'
[ "$minor" != 50 ] || usos_nt35_client_request "$work/c" "${product:-}" "$ANSWER_KIND" || fail 'cannot stage NT35 Workstation client policy request'
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
if [ "$NATIVE" = 1 ]; then
    # GUI-mode Setup page recorder (tools/nt3/usosans3): USOSNT3.EXE /setup
    # starts it; it logs every page to \USOS\NT3\USOSANS.TXT.
    cp "$drv/USOSANS3.EXE" "$usos/USOSANS3.EXE" || fail 'cannot copy USOSANS3.EXE'
    # NATIVE.TXT: the native-path marker for usosnt3. /setup (GUI Setup)
    # installs usosusb at once, so the first start has the USB keyboard and
    # mouse; the service does the VM finish step's BOOT.INI part (timeout=5,
    # no C:\ entry, these options, [USOS /SOS]) and removes the leftovers.
    printf 'boot_options=%s\r\n' "$NT_NATIVE_LOAD_OPTIONS" > "$usos/NATIVE.TXT" || fail 'cannot write NATIVE.TXT'
    log "native: NATIVE.TXT boot_options=$NT_NATIVE_LOAD_OPTIONS (usosnt3: USB from the first start, BOOT.INI finish)"
fi
if [ "$NATIVE" = 1 ] && [ "$minor" = 50 ]; then
    # NT 3.5 text mode runs AUTOCHK.EXE from ~BT (TXTSETUP.SIF autochk.exe on
    # boot floppy _3); without it: "Setup was unable to verify your C:
    # drive ... Press ENTER" (the VM typed ENTER; text mode has no USB
    # keyboard). The stand-in goes there too, so the page never comes.
    cp "$drv/USOSACHK.EXE" "$bt_dir/AUTOCHK.EXE" || fail 'cannot copy USOSACHK.EXE to ~BT'
    # GUI Setup refuses a CPU newer than a Pentium (INITIAL.INF GetProcessor):
    # the local source's INITIAL.IN_ gets the I586 line
    # (src/compat/win3x/nt35_initial.zig, usos-fb-ui --nt35-initial).
    initial=''
    for name in INITIAL.IN_ INITIAL.INF; do [ -f "$ls_src/$name" ] && initial="$ls_src/$name" && break; done
    [ -n "$initial" ] || fail 'the NT 3.5 local source has no INITIAL.IN_'
    rm -f "$work/INITIAL.NEW"
    if "${USOS_FB_UI:-usos-fb-ui}" --nt35-initial "$initial" "$work/INITIAL.NEW" > "$work/initial.log" 2>&1; then rc=0; else rc=$?; fi
    while IFS= read -r line; do log "$line"; done < "$work/initial.log"
    [ "$rc" = 0 ] && [ -s "$work/INITIAL.NEW" ] || fail 'cannot patch the NT 3.5 INITIAL.INF processor check'
    cat "$work/INITIAL.NEW" > "$initial" && rm -f "$work/INITIAL.NEW" || fail 'cannot write INITIAL.IN_'
    log 'native NT 3.5: usosachk in ~BT, INITIAL.INF processor = I586'
fi
[ -z "$SP_EXE" ] || log "service pack: $(basename "$SP_EXE") ignored (NT 3.51 service packs are not installed yet)"
# VESA display (docs/nt3-vesa-2026-10-14.md): our miniport (USOSVBE.SYS, NT 3.x
# build of tools/nt4/usosvbe) + the CD's own framebuf.dll, which text-mode
# Setup installs from the user's CD ([files.video]); the CD's compressed copy
# goes along for usosnt3 (expanded with NT's own expand.exe if Setup did not
# install it). USOS never ships framebuf.dll. usosnt3 registers usosvbe
# (1024x768x16); without either file the system stays on VGA (640x480x16).
# The [VGA mode] boot entry (/basevideo) keeps VGA: usosvbe does not start.
if [ -r "$drv/USOSVBE.SYS" ]; then
    cp "$drv/USOSVBE.SYS" "$usos/USOSVBE.SYS" || fail 'cannot copy USOSVBE.SYS'
    framebuf=''
    for name in FRAMEBUF.DL_ framebuf.dl_; do [ -f "$i386/$name" ] && framebuf="$i386/$name" && break; done
    if [ -n "$framebuf" ]; then
        cp "$framebuf" "$usos/FRAMEBUF.DL_" || fail 'cannot copy FRAMEBUF.DL_'
    fi
    log 'display: VESA (usosvbe + framebuf.dll from the CD), [VGA mode] = 640x480x16'
else
    log 'display: VGA (640x480x16; no USOSVBE.SYS in this build)'
fi
printf 'answer=%s\r\nversion=%s.%s\r\n' "$ANSWER_KIND" "$major" "$minor" > "$usos/SOURCE.TXT"
else
# $OEM$ (OemPreinstall = Yes): CMDLINES.TXT runs at the end of GUI-mode Setup
# and turns on one automatic Administrator logon with POST.CMD in RunOnce.
# Native: first the GUI Setup page recorder (NT 4.0 has no DetachedProgram;
# /detach returns at once, the recorder keeps running, one instance only).
for oem in "$ls_dir/\$OEM\$" "$ls_dir/I386/\$OEM\$"; do
    mkdir -p "$oem"
    {
        printf '[Commands]\r\n'
        [ "$NATIVE" != 1 ] || printf '"C:\\USOS\\NT4\\USOSANS3.EXE /detach"\r\n'
        printf '"C:\\WINNT\\REGEDIT.EXE /s C:\\USOS\\NT4\\SETUP.REG"\r\n'
        [ "$NT4_NATIVE_PREP" != 1 ] || printf '"C:\\USOS\\NT4\\USOSNT4.EXE /early"\r\n'
    } > "$oem/CMDLINES.TXT"
done

usos="$work/c/USOS/NT4"
mkdir -p "$usos"
if [ "$NATIVE" = 1 ]; then
    cp "$ans3" "$usos/USOSANS3.EXE" || fail 'cannot copy USOSANS3.EXE'
    if [ "$NT4_NATIVE_PREP" = 1 ]; then
        cp "$LIB/nt4/USOSNT4.EXE" "$usos/USOSNT4.EXE" || fail 'cannot copy native NT4 helper'
        printf 'boot_options=%s\r\n' "$NT_NATIVE_LOAD_OPTIONS" > "$usos/NATIVE.TXT" || fail 'cannot write native NT4 marker'
        # Manual Setup: USOSNT4 /early checks whether the user set an
        # Administrator password (then no automatic logon, PWLOGON.TXT).
        if [ "$NT4_MANUAL" = 1 ]; then
            printf 'setup=manual\r\n' > "$usos/MANUAL.TXT" || fail 'cannot write the manual Setup marker'
            crlf > "$usos/NOAUTO.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"AutoAdminLogon"="0"
EOF
        fi
        # The finishing screen's language (USOSNT4.EXE /notice reads
        # locale= like usosnt3): the CD language, 0415 = Polish text.
        printf 'locale=0000%s\r\n' "${lang:-0409}" > "$usos/INTL.TXT" || fail 'cannot write the native NT4 notice language'
        log "native: finishing screen during POST.CMD (USOSNT4.EXE /notice, locale 0000${lang:-0409})"
    fi
    log 'native: GUI Setup page recorder USOSANS3.EXE (CMDLINES.TXT, log C:\USOS\NT4\USOSANS.TXT)'
fi
. "$LIB/network_setup.sh"
usos_net_answer_config "$ANSWER_SIF" NT4 > "$work/network.ini" || fail 'invalid LAN metadata'
USOS_NT4_NATIVE_DIAG=$NT4_NATIVE_PREP usos_net_stage "$work/network.ini" "$work/c" "$LIB" "${USOS_PCI_ROOT:-/sys/bus/pci/devices}" || fail 'cannot stage LAN defaults'
rm -f "$work/network.ini"
# Keep the requested $OEM$/$1 layout. NT4 is explicitly copied from it by
# CMDLINES: unlike NT5, do not assume that NT4 maps $1 to the system drive.
. "$LIB/legacy_addons.sh"
usos_addons_config "$ANSWER_SIF" > "$work/addons.ini" || fail 'invalid addon selection'
addon_lang=XX;case "$lang" in 0415) addon_lang=PL ;; *09) addon_lang=EN ;; esac
addon_root="$ls_dir/I386/\$OEM\$/\$1"
if [ -z "$tse" ]; then
    usos_addons_stage "$work/addons.ini" "$addon_root" "$LIB" "${USOS_ADDONS_DIR:-/mnt/data/Addons}" NT4 "$addon_lang" "${SP_EXE:+6a}" || fail 'cannot stage NT4 legacy pack'
fi
rm -f "$work/addons.ini"
if [ -f "$addon_root/USOS/ADDONS/USOSADD.EXE" ]; then
    # Both OEM search locations can run this command; COPY.OK makes it once-only.
    for oem in "$ls_dir/\$OEM\$" "$ls_dir/I386/\$OEM\$"; do
        printf '".\\ADDONS.CMD"\r\n' >> "$oem/CMDLINES.TXT"
        crlf > "$oem/ADDONS.CMD" <<'ADDONSCMD'
@echo off
rem NT4 CMDLINES copy only; packages start after POST.CMD on hardware.
if exist C:\USOS\ADDONS\COPY.OK goto addonscopied
if not exist C:\$WIN_NT$.~LS\I386\$OEM$\$1\USOS\ADDONS\USOSADD.EXE goto addoncopyfailed
if exist C:\$WIN_NT$.~LS\I386\$OEM$\$1\USOS\NT4\ADDONS.LOG type C:\$WIN_NT$.~LS\I386\$OEM$\$1\USOS\NT4\ADDONS.LOG >> C:\USOS\NT4\ADDONS.LOG
%SystemRoot%\system32\xcopy.exe C:\$WIN_NT$.~LS\I386\$OEM$\$1\USOS\ADDONS C:\USOS\ADDONS /E /I >> C:\USOS\NT4\ADDONS.LOG 2>&1
if errorlevel 1 goto addoncopyfailed
if not exist C:\USOS\ADDONS\USOSADD.EXE goto addoncopyfailed
if not exist C:\USOS\ADDONS\LEGACY.INI goto addoncopyfailed
if not exist C:\USOS\ADDONS\SELECT.INI goto addoncopyfailed
echo ok > C:\USOS\ADDONS\COPY.OK
goto addonscopied
:addoncopyfailed
echo addon OEM copy incomplete; OS Setup continues >> C:\USOS\NT4\ADDONS.LOG
:addonscopied
ADDONSCMD
    done
fi
cp "$LIB/nt4/AHCINT.SYS" "$usos/AHCINT.SYS" || fail 'cannot copy AHCINT.SYS'
if [ "$NT4_NATIVE_PREP" = 1 ]; then
    # Native: usosrst 1.11-nt4n (shutdown log, NVMe/xHCI/NIC quiesce, CF9h
    # full reset); USOSNT4.EXE /early registers it before the first boot.
    cp "$LIB/nt4/USOSRSTN.SYS" "$usos/USOSRST.SYS" || fail 'cannot copy USOSRST.SYS'
    log 'native: usosrst 1.11-nt4n (restart: quiesce + CF9h full reset; power-off: ACPI S5) from the first installed boot'
else
    cp "$LIB/nt4/USOSRST.SYS" "$usos/USOSRST.SYS" || fail 'cannot copy USOSRST.SYS'
fi
cp "$LIB/nt4/USOSUSB.SYS" "$usos/USOSUSB.SYS" || fail 'cannot copy USOSUSB.SYS'
cp "$LIB/nt4/USOSVBE.SYS" "$usos/USOSVBE.SYS" || fail 'cannot copy USOSVBE.SYS'
cp "$LIB/nt4/USOSOFF.EXE" "$usos/USOSOFF.EXE" || fail 'cannot copy USOSOFF.EXE'
# Typed answer-profile options (src/flow/answer/nt4.zig: ";USOS-REG=" lines
# of the rendered WINNT.SIF): the registry set for usos-reg.exe
# (tools/windows_usos_reg.c), applied by POST.CMD.
if grep -q '^;USOS-REG=' "$ANSWER_SIF"; then
    { printf '; USOS answer profile: registry set for usos-reg.exe\r\n'; sed -n 's/^;USOS-REG=//p' "$ANSWER_SIF" | tr -d '\r' | sed 's/$/\r/'; } > "$usos/USOS-REG.TXT" || fail 'cannot write USOS-REG.TXT'
    cp "$LIB/usos-reg.exe" "$usos/USOS-REG.EXE" || fail 'cannot copy usos-reg.exe'
    log "profile registry set: $(grep -vc '^;' "$usos/USOS-REG.TXT") entries (usos-reg.exe in POST.CMD)"
fi
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
    # Only the newer sfxcab stub (English SP6a re-release, 2000) knows -x:dir
    # and -q: its stub (the bytes before the MSCF cabinet, about 6 KiB) has
    # the " -X:" switch text. The older stub (Polish SP6a, 1999-12-15) knows
    # no switch and hands every argument to update.exe, which then shows its
    # modal usage box "UPDATE [-u] [-f] [-n] [-o] [-z] [-q]" and the install
    # waits forever (X470 NVMe run 2026-10-12, B261012-104904). For it
    # POST.CMD runs the package with -u -z directly (SPPKG.TXT).
    if head -c 16384 "$SP_EXE" | od -An -v -tx1 | tr -d ' \n' | grep -q '202d583a'; then
        log 'service pack: self-extractor with -x (extracted first)'
    else
        printf 'package\r\n' > "$usos/SPPKG.TXT"
        log 'service pack: older self-extractor without -x (package run with -u -z)'
    fi
elif [ "$NATIVE" = 1 ]; then
    log 'service pack: none (native: the RTM kernel with the raised CPUID leaf limit stays)'
elif [ -n "$tse" ]; then
    log 'service pack: none (the X470 needs the Terminal Server Edition SP6: the RTM TSE kernel stops on CPUs with more than 3 CPUID leaves)'
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
# USB sticks (usosusb 1.1-nt4, tools/nt4/usosusb/README.md "USB mass storage
# on NT 4.0"): the same driver and worker thread that own the xHCI for the
# keyboard and mouse, so there is no second xHCI owner (SeaBIOS's USB disk
# service, the 9x path, is not used: usosusb resets the controller).
# Storage=0 (DATA usb-storage-off.txt) keeps keyboard and mouse only. The
# log file gets one line per stick arrival / removal and the Diag changes.
if [ "$USB_STORAGE" = 0 ]; then
    usb_storage_dword=00000000
    log 'USB sticks: off (usb-storage-off.txt); usosusb drives keyboard and mouse only'
else
    usb_storage_dword=00000001
    log 'USB sticks: usosusb mass storage on (FAT12/FAT16/NTFS on MBR or superfloppy sticks; log C:\USOS\NT4\USOSUSB.LOG)'
fi
crlf >> "$usos/DRIVERS.REG" <<EOF

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosusb\Parameters]
"Storage"=dword:$usb_storage_dword
"LogFile"="\\\\DosDevices\\\\C:\\\\USOS\\\\NT4\\\\USOSUSB.LOG"
EOF
# NVMe target (docs/nvme-nt-2026-10-11.md): USOS's own usosnvme miniport
# (tools/nt/usosnvme, NT4 build: non-PnP, scans PCI for class 01-08-02,
# polled) next to AHCINT. Only for an NVMe target, so a SATA install never
# loads it (on a board without NVMe it would fail to start at every boot).
case "$TARGET_DEVICE" in /dev/nvme*)
    cp "$LIB/nt4/USOSNVME.SYS" "$usos/USOSNVME.SYS" || fail 'cannot copy USOSNVME.SYS'
    crlf >> "$usos/DRIVERS.REG" <<'EOF'

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosnvme]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000001
"Group"="SCSI miniport"
EOF
    log "storage: NVMe target $TARGET_DEVICE, usosnvme staged next to AHCINT" ;;
esac
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
# Native NT 4.0: automatic logon only while the installation restarts by
# itself (user decision 2026-10-29): POST.CMD, then the add-on chain
# (USOSADD from Run). NT 4.0 msgina takes the empty DefaultPassword (NT 4.0
# profiles always use a blank Administrator password: OEMBlankAdminPassword)
# as a one-shot logon and writes AutoAdminLogon=0 at that logon, so
# USOSNT4.EXE /logon (Run, Windows subsystem: no console window) re-arms it
# while the chain is pending and, once the chain has ended, removes
# AutoAdminLogon, DefaultPassword and its own Run value: the installed
# system shows the normal Ctrl+Alt+Del logon.
# PowerdownAfterShutdown: Shut down powers the machine off; usosrst
# 1.11-nt4n takes the HAL's HalReturnToFirmware(HalPowerDownRoutine) to ACPI
# S5 (_S5 of the DSDT, PM1a/PM1b_CNT). The VM path keeps the old DONE.REG.
if [ "$NT4_NATIVE_PREP" = 1 ]; then
    crlf > "$usos/DONE.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"AutoAdminLogon"="1"
"DefaultPassword"=""
"PowerdownAfterShutdown"="1"

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run]
"USOSAutoLogon"="C:\\USOS\\NT4\\USOSNT4.EXE /logon"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\atapi]
"Start"=dword:00000004
EOF
fi
# The NT 4.0 Welcome window ("Witamy", Tips\Show of the user; Setup leaves
# it on) at the first desktop covered the finishing work on the X470 and
# waited for a click. POST.CMD runs as the logged-on Administrator, so
# HKEY_CURRENT_USER is that profile.
crlf > "$usos/WELCOME.REG" <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Tips]
"Show"=hex:00,00,00,00
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
# Native: the restart goes to USOSNT4.EXE /restart, started detached so POST.CMD
# ends first. Explorer runs the HKLM RunOnce values after POST.CMD one by one
# (SP6a / Setup registrations, regsvr32), and a restart from inside POST.CMD
# interrupted them (X470 2026-10-30, "regsvr32.exe - DLL initialization
# failed"); the helper restarts once that queue has run.
crlf > "$usos/POST.CMD" <<'EOF'
@echo off
if exist C:\USOS\NT4\NATIVE.TXT start "USOS" C:\USOS\NT4\USOSNT4.EXE /notice
if exist C:\USOS\NT4\POST.OK if exist C:\USOS\NT4\NATIVE.TXT goto nativeresume
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
if exist C:\USOS\NT4\USOSNVME.SYS copy C:\USOS\NT4\USOSNVME.SYS %SystemRoot%\system32\drivers\usosnvme.sys >> C:\USOS\NT4\POST.LOG
if exist C:\USOS\NT4\USOSNVME.SYS if not exist %SystemRoot%\system32\drivers\usosnvme.sys echo USOSNVME.SYS copy FAILED >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\drivers\usosrst.sys echo USOSRST.SYS copy FAILED >> C:\USOS\NT4\POST.LOG
if not exist %SystemRoot%\system32\drivers\usosusb.sys echo USOSUSB.SYS copy FAILED >> C:\USOS\NT4\POST.LOG
%SystemRoot%\regedit.exe /s C:\USOS\NT4\DRIVERS.REG
echo drivers registered >> C:\USOS\NT4\POST.LOG
if exist C:\USOS\NT4\WELCOME.REG %SystemRoot%\regedit.exe /s C:\USOS\NT4\WELCOME.REG
echo welcome window off >> C:\USOS\NT4\POST.LOG
if not exist C:\USOS\Drivers\USOSNET\USOSNET4.SYS goto nonet4
if not exist C:\USOS\NT4\USOSNET.REG goto nonet4
%SystemRoot%\regedit.exe /e C:\USOS\NT4\LOOPCHK.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NDISLoop1
if not exist C:\USOS\NT4\LOOPCHK.REG goto noloop4
copy C:\USOS\Drivers\USOSNET\USOSNET4.SYS %SystemRoot%\system32\drivers\usosnet4.sys >> C:\USOS\NT4\NETSETUP.TXT
if not exist %SystemRoot%\system32\drivers\usosnet4.sys goto net4fail
%SystemRoot%\regedit.exe /s C:\USOS\NT4\USOSNET.REG
%SystemRoot%\regedit.exe /e C:\USOS\NT4\NET4CHK.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NDISLoop
findstr /i /c:"usosnet4.sys" C:\USOS\NT4\NET4CHK.REG > nul
if errorlevel 1 goto net4fail
echo usosnet4: NDISLoop service now loads usosnet4.sys, NDISLoop1 BusType 5 + TCP/IP from USOSNET.REG >> C:\USOS\NT4\NETSETUP.TXT
goto nonet4
:noloop4
echo usosnet4: no NDISLoop1 adapter (loopback not installed by Setup); driver not registered >> C:\USOS\NT4\NETSETUP.TXT
goto nonet4
:net4fail
echo usosnet4: copy or registry readback FAILED (NET4CHK.REG) >> C:\USOS\NT4\NETSETUP.TXT
:nonet4
if not exist C:\USOS\NT4\USOS-REG.TXT goto noregset
C:\USOS\NT4\USOS-REG.EXE --log C:\USOS\NT4\USOS-REG.LOG C:\USOS\NT4\USOS-REG.TXT
echo profile registry set applied %errorlevel% >> C:\USOS\NT4\POST.LOG
del C:\USOS\NT4\USOS-REG.TXT
:noregset
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
if exist C:\USOS\NT4\SPPKG.TXT goto sppkg
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
goto sprun
:sppkg
echo sp package without -x, running it with -u -z >> C:\USOS\NT4\POST.LOG
:sprun
start /wait C:\USOS\NT4\SP6I386.EXE -u -z
echo sp end %errorlevel% >> C:\USOS\NT4\POST.LOG
:nosp
if exist C:\USOS\NT4\USOSLAN.EXE if exist C:\USOS\NT4\LAN.REG %SystemRoot%\regedit.exe /s C:\USOS\NT4\LAN.REG
echo LAN first-desktop registration processed >> C:\USOS\NT4\POST.LOG
if exist C:\USOS\ADDONS\USOSADD.EXE if exist C:\USOS\ADDONS\ADDONS.REG %SystemRoot%\regedit.exe /s C:\USOS\ADDONS\ADDONS.REG
echo addons hardware-desktop Run registration processed >> C:\USOS\NT4\POST.LOG
echo ok > C:\USOS\NT4\POST.OK
%SystemRoot%\regedit.exe /e C:\USOS\NT4\VERSION.REG "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
%SystemRoot%\regedit.exe /e C:\USOS\NT4\CSD.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Windows
%SystemRoot%\regedit.exe /e C:\USOS\NT4\USOSRST.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosrst
%SystemRoot%\regedit.exe /e C:\USOS\NT4\USOSVBE.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosvbe
%SystemRoot%\regedit.exe /s C:\USOS\NT4\DONE.REG
if exist C:\USOS\NT4\PWLOGON.TXT %SystemRoot%\regedit.exe /s C:\USOS\NT4\NOAUTO.REG
:nativeresume
if not exist C:\USOS\NT4\NATIVE.TXT goto nativefinished
C:\USOS\NT4\USOSNT4.EXE /finish
if errorlevel 1 goto nativefailed
:nativefinished
echo done > C:\USOS\NT4\DONE.TXT
if not exist C:\USOS\NT4\NATIVE.TXT goto vmoff
start "USOS" C:\USOS\NT4\USOSNT4.EXE /restart
goto end
:vmoff
C:\USOS\NT4\USOSOFF.EXE /r
goto end
:nativefailed
echo native finish FAILED; no restart, inspect NATIVE.LOG >> C:\USOS\NT4\POST.LOG
C:\USOS\NT4\USOSNT4.EXE /nonotice
:end
EOF
printf 'answer=%s\r\ncrypto=%s\r\nedition=%s\r\n' "$ANSWER_KIND" "$crypto" "${tse:+tse}" > "$usos/SOURCE.TXT"
# POST.CMD reads the strength from this flag (cmd cannot parse SOURCE.TXT
# easily): a 128-bit CD with a Standard Encryption SP6a switches to the
# SP6a's own schannel.dll and runs update.exe again.
if [ "$crypto" = high ]; then printf 'high\r\n' > "$usos/CRYPTOHI.TXT"; fi
fi

# Preserve the installation VM's basic mode. The persistent hardware helper
# defers in QEMU and removes its Run value only after hardware processing.
# No request in a USOS-made answer (user decision 2026-10-20): auto, the
# native (EDID) or else highest tested mode (docs/display-policy.md), only with the VESA miniport. The first
# start keeps VESA.REG's 1024x768x16; USOSRES applies at the first hardware
# logon (CDS_TEST, rollback). A user's own answer file gets no request.
nt4_display_request=
if [ -z "$nt3" ] && [ -z "$nt31" ] && grep -q '^;USOS-DISPLAY=' "$ANSWER_SIF"; then
    . "$LIB/display_profile.sh"
    nt4_display_request=$(usos_display_from_answer "$ANSWER_SIF") || fail 'duplicate display request'
    [ -f "$usos/VESA.REG" ] || usos_display_keep "$nt4_display_request" || fail 'display request needs the VESA miniport'
elif [ -z "$nt3" ] && [ -z "$nt31" ] && [ "$ANSWER_KIND" != USER ] && [ -f "$usos/VESA.REG" ] && [ -f "$LIB/USOSRES.EXE" ]; then
    . "$LIB/display_profile.sh"
    nt4_display_request=autoxauto
    log 'DISPLAY no request in the answer, default auto (native EDID mode, else highest)'
fi
# Keep (profile display=keep or DATA's display-keep.txt): VESA.REG's first
# mode (1024x768x16) stays, no USOSRES and no Run value.
if [ -n "$nt4_display_request" ] && usos_display_keep "$nt4_display_request"; then
    log 'DISPLAY keep (profile display=keep or display-keep.txt): USOSRES not staged'
    nt4_display_request=
fi
if [ -n "$nt4_display_request" ]; then
    usos_display_stage "$usos" "$LIB/USOSRES.EXE" "$nt4_display_request" || fail 'cannot stage hardware display request'
    usos_display_run_reg NT4 | sed '1d' >> "$usos/VESA.REG" || fail 'cannot register hardware display helper'
    log "DISPLAY request=$nt4_display_request apply=hardware-logon vm=deferred"
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
if [ "$NATIVE" = 1 ]; then
    log "PASS target=$TARGET_DEVICE answer=$ANSWER_KIND; next: Setup on this PC after the restart (native)"
else
    log "PASS target=$TARGET_DEVICE answer=$ANSWER_KIND; next: the NT 4.0 install in the VM"
fi
