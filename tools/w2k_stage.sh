#!/bin/sh
# Windows 2000 SP4 (UEFI profile w2k-x86-sp4-uefi-csm, experimental): the
# pieces NT 5.0 needs on modern boards (docs/windows-2000-modern-2026-09-30.md).
# Applied on the target after the local source copy, before xhci98
# (nt52_usb_stage.sh):
#
# 1. AHCI: AHCINT 1.3.0.0 (https://github.com/ages2001/AHCINT, GPL-3.0,
#    tools/vendor/ahcint/1.3.0.0, unmodified), a ScsiPort miniport with
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
#        TXTSETUP.SIF [HiveInfs.Fresh]: text mode applies its [AddReg] to
#        the new system hive. It sets Services\ahcint\Parameters\
#        PnpInterface "5" = 1 (what ahcint.inf sets) from the first boot,
#        and the CriticalDeviceDatabase rows (pci#cc_010601 and the three
#        AMD IDs -> ahcint). Without PnpInterface the first boots run
#        AHCINT as a LEGACY miniport (its own PCI scan, a root-enumerated
#        instance); GUI-mode PnP then installs ahcint.inf on the PCI
#        devnode and ScsiPort starts a SECOND, PnP instance on the same
#        HBA, which resets it (GHC.HR) under the first: QEMU 2026-09-30,
#        both SeaBIOS and CSMWrap, GUI Setup hung halfway through
#        "Installing devices" with a zeroed NTFS boot sector or a corrupt
#        SYSTEM hive. HIVESYS.INF itself is UTF-16 on 2000 and stays as is.
#      - DOSNET.INF lists ahcint.sys, ahcint.inf and usosw2k.inf.
# 2. ACPI: the 2000 ACPI.SYS (5.0.2195, ACPI 1.0b) is expected to stop with
#    0xA5 on modern tables (as the stock 5.1/5.2 drivers do on the X470),
#    and no ACPI 2.0 driver exists for NT 5.0. With USOS_W2K_ACPI=off (the
#    default of this profile) TXTSETUP.SIF [ACPIOptions] ACPIEnable becomes
#    0: SETUPLDR then never selects an ACPI HAL, NTDETECT's MP table (the
#    firmware's, or CSMWrap's, which builds one from MADT and _PRT) gives
#    the "MPS Multiprocessor PC" HAL (halmps.dll, I/O APIC), and without MP
#    table "Standard PC". Costs: no ACPI power-off, power button or sleep.
#    USOS_W2K_ACPI=on keeps Microsoft's date rule (ACPIEnable = 2).
# No Microsoft file is added or changed except the TXTSETUP.SIF and
# DOSNET.INF copies on the target.
#   sh w2k_stage.sh apply     (XP_TARGET_ROOT, NT5_SOURCE_DIR=I386)
usos_w2k_apply() (
    set -eu
    : "${XP_TARGET_ROOT:?}" "${NT5_SOURCE_DIR:?}"
    [ "$NT5_SOURCE_DIR" = I386 ] || { echo '[W2K_STAGE] STOP: Windows 2000 needs the I386 source'; exit 1; }
    pkg=${USOS_W2K_DIR:-/usr/lib/usos/w2k-drivers}
    for name in ahcint.sys ahcint.inf; do
        [ -f "$pkg/$name" ] || { echo "[W2K_STAGE] STOP: $pkg/$name missing"; exit 1; }
    done
    acpi=${USOS_W2K_ACPI:-off}
    case "$acpi" in on|off) ;; *) echo "[W2K_STAGE] STOP: USOS_W2K_ACPI must be on or off"; exit 1 ;; esac
    bt="$XP_TARGET_ROOT/\$WIN_NT\$.~BT"
    ls="$XP_TARGET_ROOT/\$WIN_NT\$.~LS/I386"
    for folder in "$bt" "$ls"; do
        [ -f "$folder/TXTSETUP.SIF" ] || { echo "[W2K_STAGE] STOP: $folder/TXTSETUP.SIF missing"; exit 1; }
        find "$folder" -maxdepth 1 -type f \( -iname ahcint.sys -o -iname ahcint.sy_ -o -iname ahcint.inf -o -iname ahcint.in_ -o -iname usosw2k.inf \) -exec rm -f '{}' \;
        cp "$pkg/ahcint.sys" "$folder/ahcint.sys"
        cmp -s "$pkg/ahcint.sys" "$folder/ahcint.sys"
        usos_w2k_ahcint_inf < "$pkg/ahcint.inf" > "$folder/ahcint.inf" || { echo '[W2K_STAGE] STOP: cannot adapt ahcint.inf'; exit 1; }
        usos_w2k_hive_inf > "$folder/usosw2k.inf"
    done
    find "$ls" -maxdepth 1 -type d -iname ahcint -exec rm -rf '{}' +
    mkdir "$ls/AHCINT"
    cp "$pkg/ahcint.sys" "$ls/AHCINT/ahcint.sys"
    cmp -s "$pkg/ahcint.sys" "$ls/AHCINT/ahcint.sys"
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
    printf '[W2K_STAGE] APPLIED PASS ahcint 1.3.0.0 boot+local source, TXTSETUP.SIF PCI\\CC_010601, usosw2k.inf (PnpInterface, CriticalDeviceDatabase); ACPI %s\n' \
        "$([ "$acpi" = off ] && echo 'off (ACPIEnable = 0: MPS or Standard PC HAL)' || echo 'kept (ACPIEnable unchanged)')"
)

# Every output line ends in CRLF, as the NT5 setup files do (BusyBox awk
# keeps the input CR, other awks drop it; both give the same bytes here).

# The PCI IDs that get a [HardwareIdsDatabase] row (the class code first).
USOS_W2K_AHCI_IDS='CC_010601 VEN_1022&DEV_7901 VEN_1022&DEV_43C8 VEN_1022&DEV_43EB'

# stdin TXTSETUP.SIF -> stdout with the AHCINT rows (first block of each
# section; the same rows twice are refused).
usos_w2k_storage_sif() {
    awk -v ids="$USOS_W2K_AHCI_IDS" '
        BEGIN { bs = sprintf("%c", 92); n = split(ids, id, " ") }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*ahcint/ || index(low, "pci" bs "cc_010601") || index(low, "usosw2k.inf") { dup = 1 }
        { print line "\r" }
        low == "[sourcedisksfiles]" && !f { print "ahcint.sys = 1,,,,,,4_,4,1,,,1,4\r"; print "ahcint.inf = 1,,,,,,,20,0,0\r"; print "usosw2k.inf = 1,,,,,,_x,20,3,3\r"; f = 1 }
        low == "[hardwareidsdatabase]" && !h { for (i = 1; i <= n; i++) print "PCI" bs id[i] " = \"ahcint\"\r"; h = 1 }
        low == "[scsi.load]" && !l { print "ahcint = ahcint.sys,4\r"; l = 1 }
        low == "[scsi]" && !s { print "ahcint = \"AHCI SATA Controller (AHCINT 1.3.0.0, USOS)\"\r"; s = 1 }
        low == "[hiveinfs.fresh]" && !r { print "AddReg = usosw2k.inf,AddReg\r"; r = 1 }
        END { if (dup || !(f && h && l && s && r)) exit 3 }
    '
}

# stdout: usosw2k.inf, the text-mode registry rows (see the header):
# PnpInterface for AHCINT and the CriticalDeviceDatabase entries of
# USOS_W2K_AHCI_IDS. Loaded through TXTSETUP.SIF [HiveInfs.Fresh].
usos_w2k_hive_inf() {
    awk -v ids="$USOS_W2K_AHCI_IDS" '
        BEGIN {
            bs = sprintf("%c", 92); q = sprintf("%c", 34); n = split(ids, id, " ")
            base = "HKLM," q "SYSTEM" bs "CurrentControlSet" bs
            cddb = base "Control" bs "CriticalDeviceDatabase" bs "pci#"
            print "; USOS: Windows 2000 AHCINT registry rows (tools/w2k_stage.sh)\r"
            print "[Version]\r"; print "Signature = " q "$Windows NT$" q "\r"; print "\r"; print "[AddReg]\r"
            print base "Services" bs "ahcint" bs "Parameters" bs "PnpInterface" q "," q "5" q ",0x00010001,1\r"
            for (i = 1; i <= n; i++) {
                key = tolower(id[i])
                print cddb key q "," q "Service" q ",0x00000000," q "ahcint" q "\r"
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
    awk '
        BEGIN { bs = sprintf("%c", 92); dir = bs "i386" bs "ahcint" }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/[ \t]+$/, "", section) }
        (section == "[sourcedisksnames]" || section == "[sourcedisksnames.x86]") && line ~ /^[ \t]*1[ \t]*=/ {
            m = split(line, v, ",")
            if (m != 4) { bad = 1 } else { line = v[1] ",," v[3] "," dir; done[section] = 1 }
        }
        { print line "\r" }
        END { if (bad || !done["[sourcedisksnames]"] || !done["[sourcedisksnames.x86]"]) exit 3 }
    '
}

# stdin DOSNET.INF -> stdout with d1,ahcint.sys, d1,ahcint.inf and d1,usosw2k.inf in the
# first [Files] and [FloppyFiles.1] blocks.
usos_w2k_dosnet() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, "ahcint") { dup = 1 }
        { print line "\r" }
        low == "[files]" && !f { print "d1,ahcint.sys\r"; print "d1,ahcint.inf\r"; print "d1,usosw2k.inf\r"; f = 1 }
        low == "[floppyfiles.1]" && !b { print "d1,ahcint.sys\r"; print "d1,ahcint.inf\r"; print "d1,usosw2k.inf\r"; b = 1 }
        END { if (dup || !(f && b)) exit 3 }
    '
}

if [ "${1:-}" = apply ]; then usos_w2k_apply; fi
