#!/bin/sh
# Windows Server 2003 x86 and XP x64 (NT 5.2, UEFI profiles, experimental):
# GenAHCI 6.3.0.1 (tools/vendor/xp-modern/2026-09-21/GenAHCI_6.3.0.1.7z, the
# x86 or x64 build) on the system's OWN StorPort, integrated for text-mode
# Setup like a F6 driver: the file in $WIN_NT$.~BT (loaded by SETUPLDR) and
# in the local source, plus four TXTSETUP.SIF rows (SourceDisksFiles,
# HardwareIdsDatabase PCI\CC_010601, SCSI.Load, SCSI). Every import of both
# builds resolves against the 5.2 SP2 kernel/HAL/StorPort
# (docs/nt52-2003-xp64-2026-09-27.md). No XP bundle, no ntoskrn8, no
# Microsoft file is changed except the three TXTSETUP.SIF copies.
#   sh nt5_storage_stage.sh apply     (XP_TARGET_ROOT, NT5_SOURCE_DIR)
usos_nt5_storage_apply() (
    set -eu
    : "${XP_TARGET_ROOT:?}" "${NT5_SOURCE_DIR:?}"
    case "$NT5_SOURCE_DIR" in
        I386) arch=x86 ;;
        AMD64) arch=amd64 ;;
        *) echo '[NT5_STORAGE] STOP: unsupported source directory'; exit 1 ;;
    esac
    src=${USOS_NT5_STORAGE_DIR:-/usr/lib/usos/nt5-storage}/$arch/genahci.sys
    [ -f "$src" ] || { echo "[NT5_STORAGE] STOP: $src missing"; exit 1; }
    bt="$XP_TARGET_ROOT/\$WIN_NT\$.~BT"
    ls="$XP_TARGET_ROOT/\$WIN_NT\$.~LS/$NT5_SOURCE_DIR"
    for folder in "$bt" "$ls"; do
        [ -f "$folder/TXTSETUP.SIF" ] || { echo "[NT5_STORAGE] STOP: $folder/TXTSETUP.SIF missing"; exit 1; }
        find "$folder" -maxdepth 1 -type f \( -iname genahci.sys -o -iname genahci.sy_ \) -exec rm -f '{}' \;
        cp "$src" "$folder/genahci.sys"
        cmp -s "$src" "$folder/genahci.sys"
    done
    for sif in "$bt/TXTSETUP.SIF" "$ls/TXTSETUP.SIF" "$XP_TARGET_ROOT/TXTSETUP.SIF"; do
        [ -f "$sif" ] || continue
        usos_nt5_storage_sif < "$sif" > "$sif.usos" || { echo "[NT5_STORAGE] STOP: cannot patch $sif"; exit 1; }
        mv "$sif.usos" "$sif"
    done
    sync
    printf '[NT5_STORAGE] APPLIED PASS genahci.sys (%s) boot+local source, TXTSETUP.SIF PCI\\CC_010601\n' "$arch"
)

# stdin TXTSETUP.SIF -> stdout with the GenAHCI rows (first block of each
# section only; the same rows twice are refused).
usos_nt5_storage_sif() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        tolower(line) ~ /^genahci/ || low ~ /pci\\cc_010601/ { dup = 1 }
        { print }
        low == "[sourcedisksfiles]" && !f { print "genahci.sys = 1,,,,,,4_,4,1,,,1,4\r"; f = 1 }
        # The backslash from its code: awks differ in string escape handling.
        low == "[hardwareidsdatabase]" && !h { print "PCI" sprintf("%c", 92) "CC_010601 = \"genahci\"\r"; h = 1 }
        low == "[scsi.load]" && !l { print "genahci = genahci.sys,4\r"; l = 1 }
        low == "[scsi]" && !s { print "genahci = \"Standard AHCI 1.0 SATA Controller (GenAHCI, USOS)\"\r"; s = 1 }
        END { if (dup || !(f && h && l && s)) exit 3 }
    '
}

if [ "${1:-}" = apply ]; then usos_nt5_storage_apply; fi
