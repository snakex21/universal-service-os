#!/bin/sh
# Windows Server 2003 x86 and XP x64 (NT 5.2, UEFI profiles, experimental):
# GenAHCI 6.3.0.1 (tools/vendor/xp-modern/2026-09-21/GenAHCI_6.3.0.1.7z, the
# x86 or x64 build) on the system's OWN StorPort, integrated for text-mode
# AND GUI-mode Setup. Every import of both builds resolves against the 5.2
# SP2 kernel/HAL/StorPort (docs/nt52-2003-xp64-2026-09-27.md). No XP bundle,
# no ntoskrn8. Applied on the target after the local source copy:
#   - genahci.sys in $WIN_NT$.~BT (loaded by SETUPLDR) and the local source
#     (I386 or AMD64), genahci.inf next to both;
#   - TXTSETUP.SIF (the three copies): [SourceDisksFiles] genahci.sys
#     (system32\drivers) and genahci.inf (dirid 20, %windir%\inf),
#     [HardwareIdsDatabase] PCI\CC_010601, [SCSI.Load], [SCSI];
#   - genahci.inf: the package's copy, [SourceDisksNames] row 1 pointed at
#     <source dir>\GENAHCI (build_xp_uefi_csm_trial.genahci_inf), which holds
#     a second genahci.sys and genahci.cat. Text-mode Setup MOVES an
#     uncompressed local-source file to its destination, so GUI-mode PnP
#     would not find the copy next to TXTSETUP.SIF (as with xhci98). Without
#     the INF, GUI-mode PnP gives the AHCI controller a NULL driver, text
#     mode's CriticalDeviceDatabase entry goes with it, and every boot after
#     GUI Setup is a silent STOP 0x7B (X470, XP x64 SP2, 2026-09-29);
#   - HIVESYS.INF of the local source, first [AddReg] block: the
#     CriticalDeviceDatabase entries pci#cc_010601 (any AHCI controller) and
#     pci#ven_1022&dev_43c8 (AMD X470/B450 chipset SATA) -> Service genahci,
#     so the boot device keeps its driver even if the INF match fails.
#     NT 5.2 has no inbox AHCI driver (no msahci/storahci entry to clash);
#   - DOSNET.INF of the local source lists genahci.sys and genahci.inf.
# No Microsoft file is added or changed except the TXTSETUP.SIF, DOSNET.INF
# and HIVESYS.INF copies on the target.
#   sh nt5_storage_stage.sh apply     (XP_TARGET_ROOT, NT5_SOURCE_DIR)
usos_nt5_storage_apply() (
    set -eu
    : "${XP_TARGET_ROOT:?}" "${NT5_SOURCE_DIR:?}"
    case "$NT5_SOURCE_DIR" in
        I386) arch=x86 ;;
        AMD64) arch=amd64 ;;
        *) echo '[NT5_STORAGE] STOP: unsupported source directory'; exit 1 ;;
    esac
    pkg=${USOS_NT5_STORAGE_DIR:-/usr/lib/usos/nt5-storage}/$arch
    for name in genahci.sys genahci.inf genahci.cat; do
        [ -f "$pkg/$name" ] || { echo "[NT5_STORAGE] STOP: $pkg/$name missing"; exit 1; }
    done
    bt="$XP_TARGET_ROOT/\$WIN_NT\$.~BT"
    ls="$XP_TARGET_ROOT/\$WIN_NT\$.~LS/$NT5_SOURCE_DIR"
    [ -f "$ls/HIVESYS.INF" ] || { echo "[NT5_STORAGE] STOP: $ls/HIVESYS.INF missing"; exit 1; }
    for folder in "$bt" "$ls"; do
        [ -f "$folder/TXTSETUP.SIF" ] || { echo "[NT5_STORAGE] STOP: $folder/TXTSETUP.SIF missing"; exit 1; }
        find "$folder" -maxdepth 1 -type f \( -iname genahci.sys -o -iname genahci.sy_ -o -iname genahci.inf -o -iname genahci.in_ \) -exec rm -f '{}' \;
        for name in genahci.sys genahci.inf; do
            cp "$pkg/$name" "$folder/$name"
            cmp -s "$pkg/$name" "$folder/$name"
        done
    done
    find "$ls" -maxdepth 1 -type d -iname genahci -exec rm -rf '{}' +
    mkdir "$ls/GENAHCI"
    for name in genahci.sys genahci.cat; do
        cp "$pkg/$name" "$ls/GENAHCI/$name"
        cmp -s "$pkg/$name" "$ls/GENAHCI/$name"
    done
    for sif in "$bt/TXTSETUP.SIF" "$ls/TXTSETUP.SIF" "$XP_TARGET_ROOT/TXTSETUP.SIF"; do
        [ -f "$sif" ] || continue
        usos_nt5_storage_sif < "$sif" > "$sif.usos" || { rm -f "$sif.usos"; echo "[NT5_STORAGE] STOP: cannot patch $sif"; exit 1; }
        mv "$sif.usos" "$sif"
    done
    usos_nt5_storage_hivesys < "$ls/HIVESYS.INF" > "$ls/HIVESYS.INF.usos" || { rm -f "$ls/HIVESYS.INF.usos"; echo '[NT5_STORAGE] STOP: cannot patch HIVESYS.INF'; exit 1; }
    mv "$ls/HIVESYS.INF.usos" "$ls/HIVESYS.INF"
    if [ -f "$ls/DOSNET.INF" ]; then
        usos_nt5_storage_dosnet < "$ls/DOSNET.INF" > "$ls/DOSNET.INF.usos" || { rm -f "$ls/DOSNET.INF.usos"; echo '[NT5_STORAGE] STOP: cannot patch DOSNET.INF'; exit 1; }
        mv "$ls/DOSNET.INF.usos" "$ls/DOSNET.INF"
    fi
    sync
    printf '[NT5_STORAGE] APPLIED PASS genahci.sys+inf (%s) boot+local source, TXTSETUP.SIF PCI\\CC_010601, HIVESYS.INF CriticalDeviceDatabase\n' "$arch"
)

# Every output line ends in CRLF, as the NT5 setup files do (BusyBox awk
# keeps the input CR, other awks drop it; both give the same bytes here).
#
# stdin TXTSETUP.SIF -> stdout with the GenAHCI rows (first block of each
# section only; the same rows twice are refused).
usos_nt5_storage_sif() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^genahci/ || low ~ /pci\\cc_010601/ { dup = 1 }
        { print line "\r" }
        low == "[sourcedisksfiles]" && !f { print "genahci.sys = 1,,,,,,4_,4,1,,,1,4\r"; print "genahci.inf = 1,,,,,,,20,0,0\r"; f = 1 }
        # The backslash from its code: awks differ in string escape handling.
        low == "[hardwareidsdatabase]" && !h { print "PCI" sprintf("%c", 92) "CC_010601 = \"genahci\"\r"; h = 1 }
        low == "[scsi.load]" && !l { print "genahci = genahci.sys,4\r"; l = 1 }
        low == "[scsi]" && !s { print "genahci = \"Standard AHCI 1.0 SATA Controller (GenAHCI, USOS)\"\r"; s = 1 }
        END { if (dup || !(f && h && l && s)) exit 3 }
    '
}

# The CriticalDeviceDatabase keys (HIVESYS.INF spelling, "&" literal).
USOS_NT5_STORAGE_CDDB='pci#cc_010601 pci#ven_1022&dev_43c8'

# stdin HIVESYS.INF -> stdout with Service/ClassGUID rows for every key of
# USOS_NT5_STORAGE_CDDB at the top of the first [AddReg] block. Exit 3: no
# [AddReg], or one of the keys is already there.
usos_nt5_storage_hivesys() {
    awk -v keys="$USOS_NT5_STORAGE_CDDB" '
        BEGIN {
            bs = sprintf("%c", 92); n = split(keys, key, " ")
            base = "HKLM,\"SYSTEM" bs "CurrentControlSet" bs "Control" bs "CriticalDeviceDatabase" bs
        }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        { for (i = 1; i <= n; i++) if (index(low, "criticaldevicedatabase" bs key[i] "\"")) dup = 1 }
        { print line "\r" }
        low ~ /^[ \t]*\[addreg\][ \t]*$/ && !a {
            for (i = 1; i <= n; i++) {
                print base key[i] "\",Service,0x00000000,genahci\r"
                print base key[i] "\",ClassGUID,0x00000000,{4D36E97B-E325-11CE-BFC1-08002BE10318}\r"
            }
            a = 1
        }
        END { if (dup || !a) exit 3 }
    '
}

# stdin DOSNET.INF -> stdout with d1,genahci.sys and d1,genahci.inf in the
# first [Files] and [FloppyFiles.1] blocks.
usos_nt5_storage_dosnet() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, "genahci") { dup = 1 }
        { print line "\r" }
        low == "[files]" && !f { print "d1,genahci.sys\r"; print "d1,genahci.inf\r"; f = 1 }
        low == "[floppyfiles.1]" && !b { print "d1,genahci.sys\r"; print "d1,genahci.inf\r"; b = 1 }
        END { if (dup || !(f && b)) exit 3 }
    '
}

if [ "${1:-}" = apply ]; then usos_nt5_storage_apply; fi
