#!/bin/sh
# Windows 2000 SP4 (UEFI profile w2k-x86-sp4-uefi-csm, experimental): the
# pieces NT 5.0 needs on modern boards (docs/windows-2000-modern-2026-09-30.md).
# Applied on the target after the local source copy, before xhci98
# (nt52_usb_stage.sh):
#
# 1. AHCI: AHCINT 1.3.0.0-usos3 (https://github.com/ages2001/AHCINT, GPL-3.0,
#    MODIFIED by USOS: real FLUSH CACHE, FUA, caching mode page;
#    tools/vendor/ahcint/1.3.0.0-usos3), a ScsiPort miniport with
#    polling I/O (no interrupt needed, so it also runs without ACPI). Every
#    import (ntoskrnl, scsiport) resolves on the 2000 SP4 kernel. The
#    GenAHCI/StorPort route of NT 5.2 does not exist on 2000 (no StorPort).
#    Integrated for text-mode AND GUI-mode Setup, as GenAHCI on NT 5.2:
#      - ahcint.sys in $WIN_NT$.~BT (loaded by SETUPLDR) and I386, and a
#        second copy in I386\AHCINT: text-mode Setup MOVES an uncompressed
#        local-source file, and GUI-mode PnP must find one (the NT 5.2
#        lesson: no INF -> NULL driver -> silent STOP 0x7B after Setup);
#      - ahcint.inf (package copy, [SourceDisksNames] and
#        [SourceDisksNames.x86] row 1 = \i386\ahcint) next to TXTSETUP.SIF;
#        TXTSETUP puts it in %windir%\inf (dirid 20);
#      - TXTSETUP.SIF (the three copies): [SourceDisksFiles] ahcint.sys and
#        ahcint.inf, [HardwareIdsDatabase] PCI\CC_010601 plus the AMD SATA
#        IDs AHCINT also claims in RAID class (1022:7901, 43C8, 43EB) ->
#        text mode writes the CriticalDeviceDatabase entries for the boot
#        controller; [SCSI.Load], [SCSI].
#      - usosw2k.inf (ASCII, written here) in ~BT and I386, added to
#        TXTSETUP.SIF [HiveInfs.Fresh] and [SourceDisksFiles] (text mode
#        refuses a hive INF without a row): the CriticalDeviceDatabase rows
#        (pci#cc_010601 and the three AMD IDs -> ahcint) in the new system.
#      - AHCINT mode (USOS_W2K_AHCINT_MODE): "legacy" (default) comments out
#        ahcint.inf's PnpInterface row, so AHCINT stays the legacy
#        (non-PnP) ScsiPort miniport it is in text mode and GUI-mode PnP
#        only records the INF; "pnp" also writes PnpInterface "5" = 1
#        through usosw2k.inf. QEMU 2026-09-30..10-03: the PnP variants ran
#        "Installing devices" into ERROR_NO_SYSTEM_RESOURCES and an ESENT
#        log flood or hung; legacy mode with the ACPI HAL completes Setup.
#        HIVESYS.INF itself is UTF-16 on 2000 and stays as is.
#      - DOSNET.INF lists ahcint.sys, ahcint.inf and usosw2k.inf.
# 2. ACPI: the 2000 ACPI.SYS (5.0.2195, ACPI 1.0b) may stop with 0xA5 on
#    modern tables (as the stock 5.1/5.2 drivers do on the X470), and no
#    ACPI 2.0 driver exists for NT 5.0. Default USOS_W2K_ACPI=on keeps
#    Microsoft's rule (ACPIEnable = 2, the ACPI HAL): in QEMU it is the only
#    setting that completes GUI Setup on AHCI (2026-10-03). USOS_W2K_ACPI=off
#    (legacy_xp_staging.sh sets it when DATA has
#    Systems\Windows\Windows 2000\Unattended\acpi-off.txt) writes
#    ACPIEnable = 0: SETUPLDR never selects an ACPI HAL and NTDETECT's MP
#    table (the firmware's, or CSMWrap's, built from MADT and _PRT) gives
#    the MPS HAL. In QEMU that GUI Setup failed in "Installing devices"
#    (ERROR_NO_SYSTEM_RESOURCES, ESENT log flood) with AHCINT and hung with
#    IDE, so it is the X470 fallback for a STOP 0xA5, not the default.
#    Costs: no ACPI power-off, power button or sleep.
# 3. usosrst.sys (USOS's own GPL driver, tools/w2k/usosrst; diagnostic
#    build): loaded from [BootBusExtenders.Load] in text mode and as a boot
#    driver (group Boot Bus Extender) afterwards. A bugcheck callback writes
#    the STOP code, its parameters and the modules they point into to the
#    VGA text buffer (the X470 without CSM shows only a black "_" for a
#    STOP); while Setup runs (SystemSetupInProgress = 1) a last-chance
#    shutdown handler restarts through the FADT reset register, CF9h and
#    the 8042 (the 2000 HALs know only the 8042, which those boards lack).
#    USOS_W2K_USOSRST=off leaves it out.
# No Microsoft file is added or changed except the TXTSETUP.SIF and
# DOSNET.INF copies on the target.
#   sh w2k_stage.sh apply     (XP_TARGET_ROOT, NT5_SOURCE_DIR=I386)
usos_w2k_apply() (
    set -eu
    : "${XP_TARGET_ROOT:?}" "${NT5_SOURCE_DIR:?}"
    [ "$NT5_SOURCE_DIR" = I386 ] || { echo '[W2K_STAGE] STOP: Windows 2000 needs the I386 source'; exit 1; }
    pkg=${USOS_W2K_DIR:-/usr/lib/usos/w2k-drivers}
    # USOS_W2K_STORAGE: ahcint (default) or uniata (legacy_xp_staging.sh sets
    # it from DATA's Windows 2000\Unattended\storage-uniata.txt).
    drv=${USOS_W2K_STORAGE:-ahcint}
    case "$drv" in
        ahcint) need='ahcint.sys ahcint.inf' ;;
        uniata) need='uniata/uniata.sys'; pkg="$pkg" ;;
        *) echo '[W2K_STAGE] STOP: USOS_W2K_STORAGE must be ahcint or uniata'; exit 1 ;;
    esac
    helper=${USOS_W2K_USOSRST:-on}
    case "$helper" in on|off) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_USOSRST must be on or off'; exit 1 ;; esac
    USOS_W2K_USOSRST=$helper; export USOS_W2K_USOSRST
    [ "$helper" = off ] || need="$need usosrst.sys"
    for name in $need; do
        [ -f "$pkg/$name" ] || { echo "[W2K_STAGE] STOP: $pkg/$name missing"; exit 1; }
    done
    [ "$drv" = ahcint ] && sys="$pkg/ahcint.sys" || sys="$pkg/uniata/uniata.sys"
    USOS_W2K_DRV=$drv; export USOS_W2K_DRV
    acpi=${USOS_W2K_ACPI:-on}
    mode=${USOS_W2K_AHCINT_MODE:-legacy}
    case "$mode" in legacy|pnp) ;; *) echo "[W2K_STAGE] STOP: USOS_W2K_AHCINT_MODE must be legacy or pnp"; exit 1 ;; esac
    case "$acpi" in on|off) ;; *) echo "[W2K_STAGE] STOP: USOS_W2K_ACPI must be on or off"; exit 1 ;; esac
    bt="$XP_TARGET_ROOT/\$WIN_NT\$.~BT"
    ls="$XP_TARGET_ROOT/\$WIN_NT\$.~LS/I386"
    for folder in "$bt" "$ls"; do
        [ -f "$folder/TXTSETUP.SIF" ] || { echo "[W2K_STAGE] STOP: $folder/TXTSETUP.SIF missing"; exit 1; }
        find "$folder" -maxdepth 1 -type f \( -iname "$drv.sys" -o -iname "$drv.sy_" -o -iname "$drv.inf" -o -iname "$drv.in_" -o -iname usosw2k.inf -o -iname usosrst.sys -o -iname usosrst.sy_ \) -exec rm -f '{}' \;
        cp "$sys" "$folder/$drv.sys"
        cmp -s "$sys" "$folder/$drv.sys"
        if [ "$helper" = on ]; then
            cp "$pkg/usosrst.sys" "$folder/usosrst.sys"
            cmp -s "$pkg/usosrst.sys" "$folder/usosrst.sys"
        fi
        if [ "$drv" = ahcint ]; then
            usos_w2k_ahcint_inf "$mode" < "$pkg/ahcint.inf" > "$folder/ahcint.inf" || { echo '[W2K_STAGE] STOP: cannot adapt ahcint.inf'; exit 1; }
        else
            usos_w2k_uniata_inf > "$folder/uniata.inf"
        fi
        usos_w2k_hive_inf "$mode" > "$folder/usosw2k.inf"
    done
    upper=$(printf '%s' "$drv" | tr '[:lower:]' '[:upper:]')
    find "$ls" -maxdepth 1 -type d -iname "$drv" -exec rm -rf '{}' +
    mkdir "$ls/$upper"
    cp "$sys" "$ls/$upper/$drv.sys"
    cmp -s "$sys" "$ls/$upper/$drv.sys"
    for sif in "$bt/TXTSETUP.SIF" "$ls/TXTSETUP.SIF" "$XP_TARGET_ROOT/TXTSETUP.SIF"; do
        [ -f "$sif" ] || continue
        usos_w2k_storage_sif < "$sif" > "$sif.usos" || { rm -f "$sif.usos"; echo "[W2K_STAGE] STOP: cannot patch $sif"; exit 1; }
        if [ "$acpi" = off ]; then
            usos_w2k_acpi_off_sif < "$sif.usos" > "$sif.acpi" || { rm -f "$sif.usos" "$sif.acpi"; echo "[W2K_STAGE] STOP: no [ACPIOptions] ACPIEnable row in $sif"; exit 1; }
            mv "$sif.acpi" "$sif.usos"
        fi
        mv "$sif.usos" "$sif"
    done
    if [ -f "$ls/DOSNET.INF" ]; then
        usos_w2k_dosnet < "$ls/DOSNET.INF" > "$ls/DOSNET.INF.usos" || { rm -f "$ls/DOSNET.INF.usos"; echo '[W2K_STAGE] STOP: cannot patch DOSNET.INF'; exit 1; }
        mv "$ls/DOSNET.INF.usos" "$ls/DOSNET.INF"
    fi
    sync
    printf '[W2K_STAGE] APPLIED PASS %s boot+local source, TXTSETUP.SIF PCI\\CC_010601, usosw2k.inf (CriticalDeviceDatabase), %s mode; ACPI %s; usosrst %s\n' \
        "$(usos_w2k_driver_title)" "$mode" "$([ "$acpi" = off ] && echo 'off (ACPIEnable = 0: MPS or Standard PC HAL)' || echo 'kept (ACPIEnable unchanged)')" \
        "$([ "$helper" = on ] && echo 'on (STOP screen, Setup restart via FADT/CF9/8042)' || echo off)"
)

# Every output line ends in CRLF, as the NT5 setup files do (BusyBox awk
# keeps the input CR, other awks drop it; both give the same bytes here).

# The PCI IDs that get a [HardwareIdsDatabase] row (the class code first).
USOS_W2K_AHCI_IDS='CC_010601 VEN_1022&DEV_7901 VEN_1022&DEV_43C8 VEN_1022&DEV_43EB'

# The text-mode title of the selected driver (USOS_W2K_DRV, default ahcint).
usos_w2k_driver_title() {
    case "${USOS_W2K_DRV:-ahcint}" in
        uniata) echo 'UniATA 0.47b' ;;
        *) echo 'AHCINT 1.3.0.0-usos3 diagnostic' ;;
    esac
}

# stdin TXTSETUP.SIF -> stdout with the AHCINT rows (first block of each
# section; the same rows twice are refused) and, unless USOS_W2K_USOSRST=off,
# usosrst.sys: [SourceDisksFiles] (System32\drivers), [BootBusExtenders.Load]
# (SETUPLDR loads it from ~BT, the kernel starts it before the storage
# drivers), [BootBusExtenders] and its own [files.usosrst] section.
usos_w2k_storage_sif() {
    awk -v ids="$USOS_W2K_AHCI_IDS" -v drv="${USOS_W2K_DRV:-ahcint}" -v title="$(usos_w2k_driver_title)" -v helper="${USOS_W2K_USOSRST:-on}" '
        BEGIN { bs = sprintf("%c", 92); q = sprintf("%c", 34); n = split(ids, id, " ") }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, drv) == 1 || low ~ "^[ \t]+" drv || index(low, "pci" bs "cc_010601") || index(low, "usosw2k.inf") || index(low, "usosrst") { dup = 1 }
        { print line "\r" }
        low == "[sourcedisksfiles]" && !f {
            print drv ".sys = 1,,,,,,4_,4,1,,,1,4\r"; print drv ".inf = 1,,,,,,,20,0,0\r"; print "usosw2k.inf = 1,,,,,,_x,20,3,3\r"
            if (helper == "on") print "usosrst.sys = 1,,,,,,4_,4,1,,,1,4\r"
            f = 1
        }
        low == "[hardwareidsdatabase]" && !h { for (i = 1; i <= n; i++) print "PCI" bs id[i] " = " q drv q "\r"; h = 1 }
        low == "[scsi.load]" && !l { print drv " = " drv ".sys,4\r"; l = 1 }
        low == "[scsi]" && !s { print drv " = " q "AHCI SATA Controller (" title ", USOS)" q "\r"; s = 1 }
        low == "[hiveinfs.fresh]" && !r { print "AddReg = usosw2k.inf,AddReg\r"; r = 1 }
        helper == "on" && low == "[bootbusextenders.load]" && !bl { print "usosrst  = usosrst.sys\r"; bl = 1 }
        helper == "on" && low == "[bootbusextenders]" && !bb { print "usosrst  = " q "USOS STOP screen and restart helper" q ",files.usosrst,usosrst\r"; bb = 1 }
        END {
            if (dup || !(f && h && l && s && r)) exit 3
            if (helper == "on") {
                if (!(bl && bb)) exit 3
                print "\r"; print "[files.usosrst]\r"; print "usosrst.sys,4\r"
            }
        }
    '
}

# stdout: usosw2k.inf, the text-mode registry rows (see the header):
# PnpInterface for AHCINT and the CriticalDeviceDatabase entries of
# USOS_W2K_AHCI_IDS. Loaded through TXTSETUP.SIF [HiveInfs.Fresh].
usos_w2k_hive_inf() {
    awk -v ids="$USOS_W2K_AHCI_IDS" -v mode="${1:-legacy}" -v drv="${USOS_W2K_DRV:-ahcint}" -v helper="${USOS_W2K_USOSRST:-on}" '
        BEGIN {
            bs = sprintf("%c", 92); q = sprintf("%c", 34); n = split(ids, id, " ")
            base = "HKLM," q "SYSTEM" bs "CurrentControlSet" bs
            cddb = base "Control" bs "CriticalDeviceDatabase" bs "pci#"
            print "; USOS: Windows 2000 " toupper(drv) " registry rows (tools/w2k_stage.sh)\r"
            print "[Version]\r"; print "Signature = " q "$Windows NT$" q "\r"; print "\r"; print "[AddReg]\r"
            # UniATA drives PCI IDE controllers too (its own uniata_w2k.reg):
            # SkipRaids as shipped, and pciide/atapi off so the two never
            # claim the same channel (modern boards have no IDE mode anyway).
            if (drv == "uniata") {
                print base "Services" bs "uniata" bs "Parameters" q "," q "SkipRaids" q ",0x00010001,1\r"
                print base "Services" bs "PciIde" q "," q "Start" q ",0x00010001,4\r"
                print base "Services" bs "atapi" q "," q "Start" q ",0x00010001,4\r"
            }
            if (mode == "pnp") print base "Services" bs drv bs "Parameters" bs "PnpInterface" q "," q "5" q ",0x00010001,1\r"
            # usosrst: a boot driver of the first group, ErrorControl 0 (a
            # failed start never stops the boot).
            if (helper == "on") {
                svc = base "Services" bs "usosrst" q ","
                print svc q "Type" q ",0x00010001,1\r"
                print svc q "Start" q ",0x00010001,0\r"
                print svc q "ErrorControl" q ",0x00010001,0\r"
                print svc q "Group" q ",0x00000000," q "Boot Bus Extender" q "\r"
                print svc q "ImagePath" q ",0x00020000," q "System32" bs "DRIVERS" bs "usosrst.sys" q "\r"
            }
            for (i = 1; i <= n; i++) {
                key = tolower(id[i])
                print cddb key q "," q "Service" q ",0x00000000," q drv q "\r"
                print cddb key q "," q "ClassGUID" q ",0x00000000," q "{4D36E97B-E325-11CE-BFC1-08002BE10318}" q "\r"
            }
        }
    '
}

# stdin TXTSETUP.SIF -> stdout with [ACPIOptions] ACPIEnable = 0. Exit 3
# unless exactly one ACPIEnable row was found in that section.
usos_w2k_acpi_off_sif() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/[ \t]+$/, "", section) }
        section == "[acpioptions]" && low ~ /^[ \t]*acpienable[ \t]*=/ { line = "ACPIEnable = 0"; done++ }
        { print line "\r" }
        END { if (done != 1) exit 3 }
    '
}

# stdin ahcint.inf -> stdout with [SourceDisksNames] and
# [SourceDisksNames.x86] row 1 given the path \i386\ahcint (the folder of
# the local source that holds the GUI-mode copy). Exit 3 unless both rows
# changed.
usos_w2k_ahcint_inf() {
    awk -v mode="${1:-legacy}" '
        BEGIN { bs = sprintf("%c", 92); dir = bs "i386" bs "ahcint" }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/[ \t]+$/, "", section) }
        # legacy mode: the PnpInterface row is commented out (see the header).
        mode == "legacy" && index(low, "pnpinterface") && low !~ /^[ \t]*;/ { line = "; USOS legacy mode: " line; pnp++ }
        (section == "[sourcedisksnames]" || section == "[sourcedisksnames.x86]") && line ~ /^[ \t]*1[ \t]*=/ {
            m = split(line, v, ",")
            if (m != 4) { bad = 1 } else { line = v[1] ",," v[3] "," dir; done[section] = 1 }
        }
        { print line "\r" }
        END { if (bad || !done["[sourcedisksnames]"] || !done["[sourcedisksnames.x86]"] || (mode == "legacy" && pnp != 1)) exit 3 }
    '
}

# stdin DOSNET.INF -> stdout with d1,ahcint.sys, d1,ahcint.inf, d1,usosw2k.inf
# (and d1,usosrst.sys unless USOS_W2K_USOSRST=off) in the first [Files] and
# [FloppyFiles.1] blocks.
usos_w2k_dosnet() {
    awk -v drv="${USOS_W2K_DRV:-ahcint}" -v helper="${USOS_W2K_USOSRST:-on}" '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, drv) || index(low, "usosw2k") || index(low, "usosrst") { dup = 1 }
        { print line "\r" }
        low == "[files]" && !f { rowsfor(); f = 1 }
        low == "[floppyfiles.1]" && !b { rowsfor(); b = 1 }
        function rowsfor() { print "d1," drv ".sys\r"; print "d1," drv ".inf\r"; print "d1,usosw2k.inf\r"; if (helper == "on") print "d1,usosrst.sys\r" }
        END { if (dup || !(f && b)) exit 3 }
    '
}

# stdout: uniata.inf, written by USOS for UniATA 0.47b (the package's own
# uata_2k.inf targets IDE controllers of 2006 and lists no AHCI class code).
# A legacy ScsiPort miniport like AHCINT in legacy mode: PCI\CC_010601 and
# the AMD SATA IDs, service uniata, boot start, GUI-mode copy in
# \i386\uniata. No PnpInterface row.
usos_w2k_uniata_inf() {
    awk -v ids="$USOS_W2K_AHCI_IDS" '
        BEGIN {
            bs = sprintf("%c", 92); q = sprintf("%c", 34); n = split(ids, id, " ")
            print "; uniata.inf - UniATA 0.47b for Windows 2000, written by USOS (tools/w2k_stage.sh)\r"
            print "[Version]\r"; print "Signature=" q "$Windows NT$" q "\r"; print "Class=SCSIAdapter\r"
            print "ClassGUID={4D36E97B-E325-11CE-BFC1-08002BE10318}\r"; print "Provider=%Provider%\r"
            print "DriverVer=10/16/2021,0.47.2.0\r"; print "\r"
            print "[DestinationDirs]\r"; print "DefaultDestDir = 12\r"; print "\r"
            print "[SourceDisksNames]\r"; print "1 = %DiskName%,,," bs "i386" bs "uniata\r"; print "\r"
            print "[SourceDisksNames.x86]\r"; print "1 = %DiskName%,,," bs "i386" bs "uniata\r"; print "\r"
            print "[SourceDisksFiles]\r"; print "uniata.sys=1\r"; print "\r"
            print "[Manufacturer]\r"; print "%Mfg%=UniATA_Models\r"; print "\r"
            print "[UniATA_Models]\r"
            for (i = 1; i <= n; i++) print "%Desc% = UniATA_Inst, PCI" bs id[i] "\r"
            print "\r"
            print "[UniATA_Inst]\r"; print "CopyFiles = UniATA_Files\r"; print "\r"
            print "[UniATA_Files]\r"; print "uniata.sys\r"; print "\r"
            print "[UniATA_Inst.Services]\r"; print "AddService = uniata, 0x00000002, UniATA_Service\r"; print "\r"
            print "[UniATA_Service]\r"; print "ServiceType    = 1\r"; print "StartType      = 0\r"
            print "ErrorControl   = 1\r"; print "ServiceBinary  = %12%" bs "uniata.sys\r"
            print "LoadOrderGroup = SCSI Miniport\r"; print "\r"
            print "[Strings]\r"; print "Provider = " q "Alexander A. Telyatnikov (UniATA), packaged by USOS" q "\r"
            print "Mfg = " q "UniATA" q "\r"; print "Desc = " q "AHCI SATA Controller (UniATA 0.47b)" q "\r"
            print "DiskName = " q "UniATA 0.47b" q "\r"
        }
    '
}

# stdout: the 512-byte marker sector USOS writes at LBA 2046 of the prepared
# disk ("USOSW2KTRACE", boot counter 0 at offset 16, the MBR disk signature
# $1 as hex at offset 32). AHCINT usos2+ only touches a disk with this marker
# (write/read-back test at 2045, trace ring at 2040-2043; ahcint.h).
usos_w2k_gap_marker() {
    printf 'USOSW2KTRACE'
    printf '\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
    printf '%-8s' "${1:-00000000}" | cut -c1-8 | tr -d '\n'
    head -c 472 /dev/zero
}

if [ "${1:-}" = apply ]; then usos_w2k_apply; fi
