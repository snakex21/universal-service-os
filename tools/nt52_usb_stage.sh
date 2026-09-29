#!/bin/sh
# Windows Server 2003 x86 and XP x64 (NT 5.2, UEFI profiles, experimental):
# USB 2.0 input and storage on xHCI-only boards through xhci98 1.1.1.0-usos1
# (https://github.com/yeokm1/xhci98, GPL-2.0-only; a USBPORT miniport, no
# KMDF, no kernel extender; tools/vendor/xhci98/1.1.1.0-usos1, MODIFIED). The x86 build
# (.NTx86 sections) for Server 2003 x86, the amd64 build for XP x64. Every
# import resolves on the 5.2 SP2 kernel/HAL/usbport, and 5.2's usbport
# reports the XP lineage (USBPORT_GetHciMn = 0x10000001) that xhci98
# accepts (docs/nt52-xhci98-2026-09-29.md). XP x86 never runs this: it keeps
# its own USB3 backport bundle.
#
# Integrated like a text-mode driver, applied to the target after the local
# source copy and the storage step:
#   - xhci98.sys in $WIN_NT$.~BT (loaded by SETUPLDR) and the local source;
#     xhci98.inf in the local source only, its [SourceDisksNames] row 1
#     pointed at a second copy of xhci98.sys in <source dir>\XHCI98 (\i386
#     or \amd64 plus \xhci98), without a tag file. Text-mode Setup MOVES an
#     uncompressed local-source file to its destination, so the copy next to
#     TXTSETUP.SIF is gone by GUI mode (QEMU 2026-09-29: "Files Needed:
#     xhci98.sys ... C:\$WIN_NT$.~LS\amd64"); nothing lists the subfolder
#     copy, so it stays until Setup deletes the local source;
#   - TXTSETUP.SIF: [SourceDisksFiles] xhci98.sys (system32\drivers) and
#     xhci98.inf (dirid 20, %windir%\inf: GUI-mode PnP installs the
#     controller from it and the installed system keeps it),
#     [HardwareIdsDatabase] PCI\CC_0C0330, [InputDevicesSupport(.Load)],
#     [files.xhci98];
#   - the USB/HID stack is FORCE-COPIED: Microsoft's rows give usbport,
#     usbd, usbhub, hidclass, hidparse, hidusb and kbdhid the text-mode
#     disposition "do not copy" (,1,3), so an xHCI-only machine ends up
#     without them (Code 39, xhci98 readme section 3). They become ",0,0"
#     (copy on a new installation). mouhid.sys is not on the media outside
#     DRIVER.CAB; GUI-mode PnP installs it from the driver cache (input.inf).
#   - DOSNET.INF of the local source lists both files ([Files], and
#     [FloppyFiles.1] for the .sys), so the local source stays consistent.
# No Microsoft file is added or changed except the TXTSETUP.SIF and
# DOSNET.INF copies on the target.
#   sh nt52_usb_stage.sh apply     (XP_TARGET_ROOT, NT5_SOURCE_DIR)

# The Microsoft USB/HID files whose text-mode rows are forced to copy.
USOS_NT52_USB_STACK='usbport.sys usbd.sys usbhub.sys hidclass.sys hidparse.sys hidusb.sys kbdhid.sys'

usos_nt52_usb_apply() (
    set -eu
    : "${XP_TARGET_ROOT:?}" "${NT5_SOURCE_DIR:?}"
    case "$NT5_SOURCE_DIR" in
        I386) arch=x86; subdir=i386 ;;
        AMD64) arch=amd64; subdir=amd64 ;;
        *) echo '[NT52_USB] STOP: unsupported source directory'; exit 1 ;;
    esac
    pkg=${USOS_NT52_USB_DIR:-/usr/lib/usos/nt52-usb}/$arch
    for name in xhci98.sys xhci98.inf; do
        [ -f "$pkg/$name" ] || { echo "[NT52_USB] STOP: $pkg/$name missing"; exit 1; }
    done
    bt="$XP_TARGET_ROOT/\$WIN_NT\$.~BT"
    ls="$XP_TARGET_ROOT/\$WIN_NT\$.~LS/$NT5_SOURCE_DIR"
    for folder in "$bt" "$ls"; do
        [ -f "$folder/TXTSETUP.SIF" ] || { echo "[NT52_USB] STOP: $folder/TXTSETUP.SIF missing"; exit 1; }
        find "$folder" -maxdepth 1 -type f \( -iname xhci98.sys -o -iname xhci98.sy_ -o -iname xhci98.inf -o -iname xhci98.in_ \) -exec rm -f '{}' \;
        cp "$pkg/xhci98.sys" "$folder/xhci98.sys"
        cmp -s "$pkg/xhci98.sys" "$folder/xhci98.sys"
    done
    find "$ls" -maxdepth 1 -type d -iname xhci98 -exec rm -rf '{}' +
    mkdir "$ls/XHCI98"
    cp "$pkg/xhci98.sys" "$ls/XHCI98/xhci98.sys"
    cmp -s "$pkg/xhci98.sys" "$ls/XHCI98/xhci98.sys"
    usos_nt52_usb_inf "$subdir" < "$pkg/xhci98.inf" > "$ls/xhci98.inf" || { echo '[NT52_USB] STOP: cannot adapt xhci98.inf'; exit 1; }
    for sif in "$bt/TXTSETUP.SIF" "$ls/TXTSETUP.SIF" "$XP_TARGET_ROOT/TXTSETUP.SIF"; do
        [ -f "$sif" ] || continue
        usos_nt52_usb_sif < "$sif" > "$sif.usos" || { rm -f "$sif.usos"; echo "[NT52_USB] STOP: cannot patch $sif"; exit 1; }
        mv "$sif.usos" "$sif"
    done
    if [ -f "$ls/DOSNET.INF" ]; then
        usos_nt52_usb_dosnet < "$ls/DOSNET.INF" > "$ls/DOSNET.INF.usos" || { rm -f "$ls/DOSNET.INF.usos"; echo '[NT52_USB] STOP: cannot patch DOSNET.INF'; exit 1; }
        mv "$ls/DOSNET.INF.usos" "$ls/DOSNET.INF"
    fi
    sync
    printf '[NT52_USB] APPLIED PASS xhci98 1.1.1.0-usos1 (%s) boot+local source, TXTSETUP.SIF PCI\\CC_0C0330, USB/HID stack forced\n' "$arch"
)

# Every output line ends in CRLF, as the NT5 setup files do (BusyBox awk
# keeps the input CR, other awks drop it; both give the same bytes here).
#
# stdin TXTSETUP.SIF -> stdout with the xhci98 rows (first block of each
# section) and the USB/HID stack rows forced to copy (every
# [SourceDisksFiles*] block). Exit 3: already integrated, a section is
# missing, or a stack row is missing or not in the expected form.
usos_nt52_usb_sif() {
    awk -v stack="$USOS_NT52_USB_STACK" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        BEGIN { bs = sprintf("%c", 92); n = split(stack, want, " "); for (i = 1; i <= n; i++) need[want[i]] = 1 }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = trim(low) }
        low ~ /^[ \t]*xhci98/ || index(low, "pci" bs "cc_0c0330") || section == "[files.xhci98]" { dup = 1 }
        section ~ /^\[sourcedisksfiles/ && index(line, "=") {
            key = tolower(trim(substr(line, 1, index(line, "=") - 1)))
            if (key in need) {
                m = split(substr(line, index(line, "=") + 1), v, ",")
                # disk,subdir,size,checksum,,,bootmedia,dirid,upgrade,newinstall,...
                if (m < 10 || trim(v[8]) != "4") { bad = 1 }
                else {
                    v[9] = "0"; v[10] = "0"; row = v[1]
                    for (i = 2; i <= m; i++) row = row "," v[i]
                    line = substr(line, 1, index(line, "=")) " " trim(row)
                    forced[key] = 1
                }
                print line "\r"; next
            }
        }
        { print line "\r" }
        low == "[sourcedisksfiles]" && !f {
            print "xhci98.sys = 1,,,,,,4_,4,1,,,1,4\r"
            print "xhci98.inf = 1,,,,,,,20,0,0\r"; f = 1
        }
        low == "[hardwareidsdatabase]" && !h { print "PCI" bs "CC_0C0330 = \"xhci98\"\r"; h = 1 }
        low == "[inputdevicessupport.load]" && !l { print "xhci98 = xhci98.sys\r"; l = 1 }
        low == "[inputdevicessupport]" && !s { print "xhci98 = \"USB 2.0 xHCI Host Controller (xhci98)\",files.xhci98,xhci98\r"; s = 1 }
        END {
            for (k in need) if (!(k in forced)) bad = 1
            if (dup || bad || !(f && h && l && s)) exit 3
            print "\r"
            print "[files.xhci98]\r"
            print "xhci98.sys,4\r"
            print "usbport.sys,4\r"
            print "usbd.sys,4\r"
            print "hidclass.sys,4\r"
            print "hidparse.sys,4\r"
        }
    '
}

# stdin xhci98.inf -> stdout with [SourceDisksNames] row 1 given the path
# \<$1>\xhci98 ($1: i386 or amd64) and no tag file. GUI-mode Setup installs
# the INF from %windir%\inf; its source root is the local source, and the
# file is in the XHCI98 folder of the I386 or AMD64 directory (see above).
# Exit 3 unless exactly one row changed.
usos_nt52_usb_inf() {
    awk -v dir="$1" '
        BEGIN { dir = dir sprintf("%c", 92) "xhci98" }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/[ \t]+$/, "", section) }
        section == "[sourcedisksnames]" && line ~ /^[ \t]*1[ \t]*=/ {
            m = split(line, v, ",")
            if (m != 4 || v[4] != "") { bad = 1 }
            else { line = v[1] ",," v[3] "," sprintf("%c", 92) dir; done++ }
        }
        { print line "\r" }
        END { if (bad || done != 1) exit 3 }
    '
}

# stdin DOSNET.INF -> stdout with d1,xhci98.sys and d1,xhci98.inf in the
# first [Files] block and d1,xhci98.sys in the first [FloppyFiles.1] block.
usos_nt52_usb_dosnet() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, "xhci98") { dup = 1 }
        { print line "\r" }
        low == "[files]" && !f { print "d1,xhci98.sys\r"; print "d1,xhci98.inf\r"; f = 1 }
        low == "[floppyfiles.1]" && !b { print "d1,xhci98.sys\r"; b = 1 }
        END { if (dup || !(f && b)) exit 3 }
    '
}

if [ "${1:-}" = apply ]; then usos_nt52_usb_apply; fi
