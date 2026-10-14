#!/bin/sh
# Every NT 5 system USOS installs (Windows 2000, XP, XP x64, Server 2003
# x86/x64, from BIOS or UEFI): every partition of a USB stick gets a drive
# letter. Windows before 10 1703 mounts only the first partition of a disk
# that reports removable media (most sticks; the USOS stick shows only its
# first partition). usosmpart.sys (own GPL-3.0-or-later disk class lower
# filter, tools/nt/usosmpart) attaches only to USBSTOR disks and lets a USB
# stick whose media holds more than one partition start like a USB hard
# disk; hot plug, "Safely Remove Hardware" and the quick-removal write
# policy are unchanged (tools/nt/usosmpart/README.md).
#
# Integrated like a text-mode file, applied to the target after the local
# source copy (and after the storage / USB steps):
#   - usosmpart.sys (i386 or amd64 build) uncompressed in the local source
#     (I386 or AMD64); text mode copies it to system32\drivers;
#   - usosmpt.inf (ASCII, written here) in ~BT and the local source, read
#     by text mode through TXTSETUP.SIF [HiveInfs.Fresh] (as w2k_stage.sh's
#     usosw2k.inf; HIVESYS.INF is UTF-16 on localized CDs and stays as is):
#     the boot-start service (Type 1, Start 0, ErrorControl 1, Group
#     "Filter") and the disk class {4D36E967-...} LowerFilters = usosmpart
#     (REG_MULTI_SZ; NT 5 has no disk class lower filter of its own, text
#     mode cannot append);
#   - TXTSETUP.SIF (the copies in ~BT, ~LS and the volume root):
#     [SourceDisksFiles] usosmpart.sys (system32\drivers) and usosmpt.inf
#     (not copied), [HiveInfs.Fresh] AddReg = usosmpt.inf,AddReg;
#   - DOSNET.INF of the local source lists both files ([Files]).
# A class filter of the boot disk must be loadable at boot (the loader
# loads Start 0 drivers); the file and the registry entries come from the
# same Setup pass. Nothing is written when the package lacks the file
# (logged SKIP, the system installs as before).
#   sh nt5_usosmpart_stage.sh apply     (XP_TARGET_ROOT, NT5_SOURCE_DIR)
usos_nt5_usosmpart_apply() (
    set -eu
    : "${XP_TARGET_ROOT:?}" "${NT5_SOURCE_DIR:?}"
    case "$NT5_SOURCE_DIR" in
        I386) arch=i386 ;;
        AMD64) arch=amd64 ;;
        *) echo '[NT5_MPART] SKIP: unsupported source directory'; exit 0 ;;
    esac
    sys=${USOS_NT5_MPART_DIR:-/usr/lib/usos/nt5-usosmpart}/$arch/usosmpart.sys
    [ -f "$sys" ] || { echo "[NT5_MPART] SKIP: $sys missing from this build; USB sticks keep one volume"; exit 0; }
    bt="$XP_TARGET_ROOT/\$WIN_NT\$.~BT"
    ls="$XP_TARGET_ROOT/\$WIN_NT\$.~LS/$NT5_SOURCE_DIR"
    # TXTSETUP.SIF is plain on every NT 5 CD; a source without it installs
    # as before.
    [ -f "$ls/TXTSETUP.SIF" ] || { echo "[NT5_MPART] SKIP: no plain TXTSETUP.SIF in $ls"; exit 0; }
    find "$ls" -maxdepth 1 -type f \( -iname usosmpart.sys -o -iname usosmpart.sy_ \) -exec rm -f '{}' \;
    cp "$sys" "$ls/usosmpart.sys"
    cmp -s "$sys" "$ls/usosmpart.sys"
    for folder in "$bt" "$ls"; do
        [ -d "$folder" ] || continue
        find "$folder" -maxdepth 1 -type f \( -iname usosmpt.inf -o -iname usosmpt.in_ \) -exec rm -f '{}' \;
        usos_nt5_usosmpart_hive_inf > "$folder/usosmpt.inf"
    done
    for sif in "$bt/TXTSETUP.SIF" "$ls/TXTSETUP.SIF" "$XP_TARGET_ROOT/TXTSETUP.SIF"; do
        [ -f "$sif" ] || continue
        usos_nt5_usosmpart_sif < "$sif" > "$sif.usos" || { rm -f "$sif.usos"; echo "[NT5_MPART] STOP: cannot patch $sif"; exit 1; }
        mv "$sif.usos" "$sif"
    done
    if [ -f "$ls/DOSNET.INF" ]; then
        usos_nt5_usosmpart_dosnet < "$ls/DOSNET.INF" > "$ls/DOSNET.INF.usos" || { rm -f "$ls/DOSNET.INF.usos"; echo '[NT5_MPART] STOP: cannot patch DOSNET.INF'; exit 1; }
        mv "$ls/DOSNET.INF.usos" "$ls/DOSNET.INF"
    fi
    sync
    printf '[NT5_MPART] APPLIED PASS usosmpart.sys (%s) sha256=%s, TXTSETUP.SIF, usosmpt.inf (disk class LowerFilters)\n' \
        "$arch" "$(sha256sum "$sys" | awk '{print $1}')"
)

# Output lines end in CRLF, as the NT5 setup files do.
#
# stdin TXTSETUP.SIF -> stdout with the usosmpart.sys and usosmpt.inf rows
# at the top of the first [SourceDisksFiles] block and the hive INF in
# [HiveInfs.Fresh] (exit 3: a section is missing or the rows are there).
usos_nt5_usosmpart_sif() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, "usosmpart.sys") || index(low, "usosmpt.inf") { dup = 1 }
        { print line "\r" }
        low == "[sourcedisksfiles]" && !f { print "usosmpart.sys = 1,,,,,,,4,0,0\r"; print "usosmpt.inf = 1,,,,,,_x,20,3,3\r"; f = 1 }
        low == "[hiveinfs.fresh]" && !r { print "AddReg = usosmpt.inf,AddReg\r"; r = 1 }
        END { if (dup || !(f && r)) exit 3 }
    '
}

# stdout: usosmpt.inf, the text-mode registry rows (see the header).
usos_nt5_usosmpart_hive_inf() {
    awk '
        BEGIN {
            bs = sprintf("%c", 92); q = sprintf("%c", 34)
            svc = "HKLM," q "SYSTEM" bs "CurrentControlSet" bs "Services" bs "usosmpart" q
            cls = "HKLM," q "SYSTEM" bs "CurrentControlSet" bs "Control" bs "Class" bs "{4D36E967-E325-11CE-BFC1-08002BE10318}" q
            print "; USOS: USB multi-partition disk filter (tools/nt5_usosmpart_stage.sh)\r"
            print "[Version]\r"; print "Signature = " q "$Windows NT$" q "\r"; print "\r"; print "[AddReg]\r"
            print svc ",Type,0x00010001,1\r"
            print svc ",Start,0x00010001,0\r"
            print svc ",ErrorControl,0x00010001,1\r"
            print svc ",Group,0x00000000," q "Filter" q "\r"
            print svc ",ImagePath,0x00020000," q "system32" bs "DRIVERS" bs "usosmpart.sys" q "\r"
            print svc ",DisplayName,0x00000000," q "USOS USB multi-partition disk filter" q "\r"
            print cls ",LowerFilters,0x00010000," q "usosmpart" q "\r"
        }
    '
}

# stdin DOSNET.INF -> stdout with d1,usosmpart.sys and d1,usosmpt.inf in the
# first [Files] block.
usos_nt5_usosmpart_dosnet() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, "usosmpart") || index(low, "usosmpt") { dup = 1 }
        { print line "\r" }
        low == "[files]" && !f { print "d1,usosmpart.sys\r"; print "d1,usosmpt.inf\r"; f = 1 }
        END { if (dup || !f) exit 3 }
    '
}

if [ "${1:-}" = apply ]; then usos_nt5_usosmpart_apply; fi
