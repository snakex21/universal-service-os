"""Host test: CSMWrap 3.1.2-usos14 patches 0018 (USB mouse wheel diagnostics
record) and 0019 (long reports of other IDs, more report IDs, a boot mouse
behind a boot keyboard interface).

    python tools/tests/csmwrap/test_csmwrap_wheel_diag.py [path-to-zig.exe]

1. Unit: seabios/src/hw/usb-hid.c, usb.c and mouse.c from the pinned source
   archive with 0016 + 0018 + 0019 applied (no other patch touches them);
   hid_parse_mouse, handle_mouse, process_mouse_packet and
   usb_hid_next_mouse are built on the host (zig cc, UBSan, -Werror).
   Real-world mouse shapes (see SHAPES: where each descriptor comes from),
   the reason codes of refused ones, long vendor reports skipped by packet
   count, the zero-length-packet replay, the USOSMWHL record layout that
   USOSDBG.EXE reads, and the interface walk for composite devices.
2. Wiring: keyboard setup/handling untouched; boot protocol for every
   refusal; the record only written; usb.c adds only boot mice after a
   boot keyboard interface.
3. Series: usos14 = usos13 byte for byte + 0018 + 0019; manifest; the
   release pins are usos15 now (same 0001-0019 files, test_csmwrap_wheel15.py).
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csmwrap_acpi10 import ROOT, find_zig  # noqa: E402
from test_csmwrap_wheel import apply, file_hunks, grab, h  # noqa: E402

V14 = ROOT / "tools/vendor/csmwrap/3.1.2-usos14"
V13 = ROOT / "tools/vendor/csmwrap/3.1.2-usos13"
P16 = V14 / "patches/0016-usb-mouse-wheel.patch"
P18 = V14 / "patches/0018-usb-mouse-wheel-diag.patch"
P19 = V14 / "patches/0019-usb-mouse-long-reports-and-composite.patch"
ARCHIVE = ROOT / "tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz"
NAMES = ("seabios/src/hw/usb-hid.c", "seabios/src/hw/usb.c", "seabios/src/mouse.c")


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def patched_sources() -> tuple[dict[str, str], dict[str, str]]:
    with tarfile.open(ARCHIVE) as t:
        orig = {n: t.extractfile("csmwrap-3.1.2/" + n).read().decode() for n in NAMES}
    src = dict(orig)
    for patch, files in ((P16, {"seabios/src/hw/usb-hid.c", "seabios/src/mouse.c", "seabios/src/util.h"}),
                         (P18, {"seabios/src/hw/usb-hid.c"}),
                         (P19, {"seabios/src/hw/usb-hid.c", "seabios/src/hw/usb.c"})):
        hunks = file_hunks(patch.read_text(encoding="utf-8"))
        assert set(hunks) == files, (patch.name, sorted(hunks))
        for n in files & set(NAMES):
            src[n] = apply(src[n], hunks[n])
    return orig, src


PRELUDE = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
typedef uint8_t u8; typedef int8_t s8; typedef uint16_t u16; typedef int16_t s16;
typedef uint32_t u32; typedef int32_t s32;
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define GET_GLOBALFLAT(x) (x)
#define GET_LOW(x) (x)
#define SET_LOW(x, v) ((x) = (v))
#define VARLOW
#define __aligned(n) __attribute__((aligned(n)))
#define CONFIG_MOUSE 1
#define dprintf(...) do { } while (0)
#define MAX_MOUSE_EVENT 16
struct usb_pipe;
static u8 usb_mouse_id;
static u8 mouse_extra_z;
static struct { u8 mouse_flag1, mouse_flag2, mouse_data[8]; } ebda;
static u16 get_ebda_seg(void) { return 0; }
#define GET_EBDA(seg, f) ((void)(seg), ebda.f)
#define SET_EBDA(seg, f, v) ((void)(seg), ebda.f = (v))
static void invoke_mouse_handler(void)
{
    int n = ebda.mouse_flag2 & 7;
    printf("H");
    for (int i = 0; i < n; i++) printf(" %d", ebda.mouse_data[i]);
    printf(" z=%d\n", (ebda.mouse_flag2 & 7) >= 4 ? ebda.mouse_data[3] : mouse_extra_z);
    mouse_extra_z = 0;
}
/* usb.c's interface walk */
#define USB_DT_INTERFACE 0x04
#define USB_CLASS_HID 3
#define USB_INTERFACE_SUBCLASS_BOOT 1
#define USB_INTERFACE_PROTOCOL_KEYBOARD 1
#define USB_INTERFACE_PROTOCOL_MOUSE 2
struct usb_interface_descriptor {
    u8 bLength, bDescriptorType, bInterfaceNumber, bAlternateSetting, bNumEndpoints;
    u8 bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol, iInterface;
} __attribute__((packed));
struct usbdevice_s { void *hub, *defpipe; u32 port; void *config;
                     struct usb_interface_descriptor *iface; int imax; u8 speed, devaddr; };
static int usb_hid_setup(struct usbdevice_s *usbdev)
{
    printf("setup if %d imax %d\n", usbdev->iface->bInterfaceNumber, usbdev->imax);
    return 0;
}
'''

MAIN = r'''
static u8 desc[4096];
static void layout(void)
{
    printf("L %d %zu %zu %zu %zu %zu %zu %zu %zu %zu\n", (int)sizeof(struct usb_mouse_diag),
           offsetof(struct usb_mouse_diag, version), offsetof(struct usb_mouse_diag, packets),
           offsetof(struct usb_mouse_diag, skipped), offsetof(struct usb_mouse_diag, last_raw),
           offsetof(struct usb_mouse_diag, dev), sizeof(struct usb_mouse_diag_dev),
           offsetof(struct usb_mouse_diag_dev, desclen), offsetof(struct usb_mouse_diag, desc_got),
           offsetof(struct usb_mouse_diag, desc));
}
int main(int argc, char **argv)
{
    if (argv[1][0] == 'L') { layout(); return 0; }
    if (argv[1][0] == 'C') {               /* C <num_iface> config bytes after the config header */
        int n = 0, num = atoi(argv[2]);
        for (int i = 3; i < argc; i++) desc[n++] = strtol(argv[i], 0, 16);
        struct usbdevice_s dev = { 0 };
        dev.iface = (void *)desc;          /* the first interface (the keyboard) */
        dev.imax = n;
        /* num_iface as configure_usb_device leaves it: the interfaces after the first */
        printf("ret %d\n", usb_hid_next_mouse(&dev, desc + n, num - 1));
        return 0;
    }
    int maxpacket = atoi(argv[1]);
    int n = 0;
    for (int i = 2; i < argc; i++) desc[n++] = strtol(argv[i], 0, 16);
    struct mouse_node m;
    memset(&m, 0, sizeof(m));
    m.maxpacket = maxpacket;
    int r = hid_parse_mouse(desc, n, &m, maxpacket * 8);
    struct hid_loc *l = m.loc;
    printf("%d %d %d %d %d %d %d %d %d %d", r, m.report_id, l[0].off, l[0].size, l[1].off, l[1].size,
           l[2].off, l[2].size, l[0].sgn | l[1].sgn << 1 | l[2].sgn << 2,
           (l[3].size != 0) | (l[4].size != 0) << 1 | (l[5].size != 0) << 2);
    for (int i = 0; i < m.nlong; i++) printf(" long %d:%d%s", m.long_id[i], m.long_pk[i] & 0x7f,
                                             m.long_pk[i] & USB_MOUSE_ZLP ? "z" : "");
    printf("\n");
    char line[256];
    m.report = r == 0;
    m.diag = 0;
    usb_mouse_id = 3;
    ebda.mouse_flag2 = 0x80 | 4;
    while (fgets(line, sizeof(line), stdin)) {
        u8 rep[16] = { 0 }; int k = 0; char *p = line, *e;
        while (k < 16) { long v = strtol(p, &e, 16); if (e == p) break; rep[k++] = v; p = e; }
        if (k) handle_mouse(&m, rep);
    }
    printf("D %u %u %u %d\n", usb_mouse_diag.packets, usb_mouse_diag.zpackets, usb_mouse_diag.skipped,
           usb_mouse_diag.last_z);
    return 0;
}
'''


def build(zig: str, srcs: dict[str, str], td: Path) -> Path:
    hid, usb, mouse = (srcs[n] for n in NAMES)
    parts = [
        grab(hid, r"^struct hid_loc \{[^\n]*\};\n"),
        grab(hid, r"^struct mouse_node \{.*?\n\};\n#define USB_MOUSE_ZLP 0x80\n"),
        grab(hid, r"^#define USB_MOUSE_DIAG_DEVS.*?^struct usb_mouse_diag usb_mouse_diag VARLOW __aligned\(16\);\n"),
        grab(hid, r"^u8 usb_mouse_skip\[USB_MOUSE_DIAG_DEVS\] VARLOW;\n"),
        grab(hid, r"^// Why a mouse stays.*?^#define USB_MD_SETPROTO +-30[^\n]*\n"),
        "void process_mouse_packet(u8 flag, u8 x, u8 y, u8 z, int imps2);\n",
        grab(hid, r"^static int\nhid_parse_mouse\(.*?\n\}\n"),
        grab(hid, r"^static s32\nhid_bits\(.*?\n\}\n"),
        grab(hid, r"^static int\nclamp127\(.*?\n\}\n"),
        grab(hid, r"^static void\nhandle_mouse\(.*?\n\}\n"),
        grab(mouse, r"^void\nprocess_mouse\(u8 data\).*?\n\}\n"),
        grab(mouse, r"^void\nprocess_mouse_packet\(.*?\n\}\n"),
        grab(usb, r"^static int\nusb_hid_next_mouse\(.*?\n\}\n"),
    ]
    c = td / "wheel.c"
    c.write_text(PRELUDE + "\n".join(parts) + MAIN, encoding="utf-8")
    exe = td / ("wheel.exe" if os.name == "nt" else "wheel")
    env = dict(os.environ)
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(td / "zig-cache"))
    r = subprocess.run([zig, "cc", "-std=gnu11", "-O1", "-Wall", "-Werror", "-Wno-unused-function",
                        "-Wno-pointer-arith", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-o", str(exe), str(c)], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    return exe


def run(exe: Path, maxpacket: int, desc: bytes, packets=()) -> tuple[list[str], list[str], list[int]]:
    out = subprocess.run([str(exe), str(maxpacket)] + ["%02x" % b for b in desc], input="\n".join(packets) + "\n",
                         capture_output=True, text=True, check=True).stdout.strip().split("\n")
    return out[0].split(), out[1:-1], [int(x) for x in out[-1].split()[1:]]


# Report descriptors. Provenance, honestly: only QEMU's is a byte-exact copy
# of a published descriptor (hw/usb/dev-hid.c qemu_mouse_hid_report_descriptor).
# No byte dump of the other devices was found in public sources during this
# work; they are written here from the HID 1.11 item format to the field
# layouts these mouse families are generally reported to use (button count,
# axis width, report IDs, extra reports). They test the SHAPES; the real
# X470 mouse (Logitech G502 HERO, 046D:C08B) descriptor comes back through
# the USOSMWHL record (first 160 bytes) and is checked against the parser
# then. No device is special-cased: the parser has no VID/PID logic.
QEMU = h("05010902a1010901a1000509190129051500250195057501810295017503810105010930093109381581257f750895038106c0c0")
# Logitech wired HERO-generation gaming mouse layout (G502 HERO, G203, G Pro):
# no report ID, 16 buttons, 16-bit X/Y (-32767..32767), 8-bit wheel, 8-bit
# AC Pan, 8 bytes, wMaxPacketSize 8, boot mouse on interface 0.
G502 = h("05010902a1010901a100 0509 1901 2910 1500 2501 9510 7501 8102"
         " 0501 160180 26ff7f 7510 9502 0930 0931 8106"
         " 1581 257f 7508 9501 0938 8106 050c 0a3802 9501 8106 c0c0")
# Logitech receiver (Unifying / Lightspeed) mouse interface, behind the boot
# keyboard on interface 0: ID 2 mouse 16 buttons, 12-bit X/Y, wheel, AC Pan
# (8 bytes with the ID); ID 3 consumer (5 bytes), ID 4 system control.
RX_MOUSE12 = h("05010902a1018502 0901a100 0509 1901 2910 1500 2501 9510 7501 8102"
               " 0501 1601f8 26ff07 750c 9502 0930 0931 8106 1581 257f 7508 9501 0938 8106"
               " 050c 0a3802 9501 8106 c0c0")
RX_CONSUMER = h("050c0901a1018503 7510 9502 1501 26ff02 1901 2aff02 8100 c0")
RX_SYSTEM = h("05010980a1018504 7502 9501 1501 2503 0982 0981 0983 8160 7506 8103 c0")
RECEIVER = RX_MOUSE12 + RX_CONSUMER + RX_SYSTEM
# The same with 16-bit X/Y: 9 bytes with the ID.
RX_MOUSE16 = RX_MOUSE12.replace(h("1601f8 26ff07 750c"), h("160180 26ff7f 7510"))
# Razer-style: no report ID, 5 buttons + 3 padding bits, 16-bit X/Y
# (-32768..32767), 8-bit wheel, 6 bytes.
RAZER = h("05010902a1010901a100 0509 1901 2905 1500 2501 7501 9505 8102 7503 9501 8101"
          " 0501 0930 0931 160080 26ff7f 7510 9502 8106 0938 1581 257f 7508 9501 8106 c0c0")
# SteelSeries-style: report ID 1, 8 buttons, 16-bit X/Y as a usage range,
# wheel, and vendor feature reports on the same interface (features ignored).
STEEL = h("05010902a1018501 0901a100 0509 1901 2908 1500 2501 9508 7501 8102"
          " 0501 1930 2931 160180 26ff7f 7510 9502 8106 0938 1581 257f 7508 9501 8106 c0c0"
          " 0600ff 0901 a101 85b1 0902 1500 26ff00 7508 951f b102 c0")
# Microsoft basic wheel mouse style: buttons outside the physical collection,
# 8-bit X/Y/wheel, 4 bytes on a 4-byte endpoint.
MSBASIC = h("05010902a101 0509 1901 2903 1500 2501 9503 7501 8102 9501 7505 8103"
            " 0501 0901 a100 0930 0931 1581 257f 7508 9502 8106 0938 9501 8106 c0c0")
# Microsoft newer style: Resolution Multiplier feature collections with
# Push/Pop, wheel and AC Pan in logical collections.
MSMULT = h("05010902a1010901a100 0509 1901 2903 1500 2501 9503 7501 8102 9501 7505 8101"
           " 0501 0930 0931 1581 257f 7508 9502 8106"
           " a102 0948 1500 2501 3501 4504 7502 9501 a4 b102"
           " 0938 1581 257f 3500 4500 7508 8106 c0"
           " a102 0948 b4 b102 3500 4500 7504 b103"
           " 050c 0a3802 1581 257f 7508 8106 c0 c0c0")
# Generic low-cost 3-button wheel mouse: X, Y, wheel as one 3-field item.
CHEAP = h("05010902a1010901a100 0509 1901 2903 1500 2501 7501 9503 8102 7505 9501 8101"
          " 0501 0930 0931 0938 1581 257f 7508 9503 8106 c0c0")
# Gaming mouse with keyboard/consumer reports on the mouse interface and a
# 32-byte vendor input report (ID 0x0b): 33 bytes = 5 packets of 8.
G_MOUSE = h("05010902a1018501 0901a100 0509 1901 2905 1500 2501 9505 7501 8102 9503 8101"
            " 0501 160180 26ff7f 7510 9502 0930 0931 8106 1581 257f 7508 9501 0938 8106 c0c0")
G_CONSUMER = h("050c0901a1018502 1900 2a3c02 1500 263c02 95017510 8100 c0")
G_KEYBOARD = h("05010906a1018503 0507 19e0 29e7 1500 2501 75019508 8102 95067508 1500 2565 1900 2965 8100 c0")
VENDOR32 = h("0600ff 0901 a101 850b 0901 1500 26ff00 7508 9520 8102 c0")
# 63 bytes + ID = 64 bytes = exactly 4 packets of 16 (a ZLP may follow).
VENDOR63 = h("0600ff 0901 a101 8505 0901 1500 26ff00 7508 953f 8102 c0")
GAMING = G_MOUSE + G_CONSUMER + G_KEYBOARD
# Refused shapes
NOID_LONG = G502 + h("0600ff 0901 a101 0901 1500 26ff00 7508 9514 8102 c0")   # 20-byte report, no IDs
SPLIT = h("05010902a1018501 0901a100 0509190129031500250195037501 8102 95017505 8101"
          " 0501 1581257f 75089502 09300931 8106 c0c0"
          " 05010902a1018502 0938 1581257f 75089501 8106 c0")
TABLET = h("05010902a1010901a100 0509 1901 2903 1500 2501 9503 7501 8102 9501 7505 8101"
           " 0501 0930 0931 1500 26ff7f 7510 9502 8102 0938 1581 257f 7508 9501 8106 c0c0")
NOWHEEL = h("05010902a1010901a100 0509 1901 2903 1500 2501 9503 7501 8102 9501 7505 8101"
            " 0501 0930 0931 1581 257f 7508 9502 8106 c0c0")

# name: (maxpacket, descriptor, expected head (r, id, X off/size, Y off/size, W off/size, signs, buttons) + long)
SHAPES = {
    "QEMU usb-mouse": (4, QEMU, "0 0 8 8 16 8 24 8 7 7"),
    "Logitech HERO wired (G502 HERO layout)": (8, G502, "0 0 16 16 32 16 48 8 7 7"),
    "Logitech receiver mouse, 12-bit X/Y, IDs 2/3/4": (8, RECEIVER, "0 2 16 12 28 12 40 8 7 7"),
    "Logitech receiver mouse, 16-bit X/Y, 16-byte endpoint": (16, RX_MOUSE16 + RX_CONSUMER + RX_SYSTEM,
                                                              "0 2 16 16 32 16 48 8 7 7"),
    "Razer-style 5 buttons, 16-bit X/Y": (8, RAZER, "0 0 8 16 24 16 40 8 7 7"),
    "SteelSeries-style ID 1, usage range, vendor feature": (8, STEEL, "0 1 8 16 24 16 40 8 7 7"),
    "Microsoft basic wheel mouse": (4, MSBASIC, "0 0 8 8 16 8 24 8 7 7"),
    "Microsoft Resolution Multiplier + AC Pan": (8, MSMULT, "0 0 8 8 16 8 24 8 7 7"),
    "generic 3-button wheel": (4, CHEAP, "0 0 8 8 16 8 24 8 7 7"),
    "gaming composite + 32-byte vendor (8)": (8, GAMING + VENDOR32, "0 1 8 16 24 16 40 8 7 7 long 11:5"),
    "gaming composite + 64-byte vendor (16)": (16, GAMING + VENDOR63, "0 1 8 16 24 16 40 8 7 7 long 5:4z"),
    # refused (boot protocol, no wheel): reason codes of 0018
    "receiver 16-bit X/Y on an 8-byte endpoint": (8, RX_MOUSE16, "-7"),
    "long report without report IDs": (8, NOID_LONG, "-7"),
    "wheel in another report than X": (8, SPLIT, "-10"),
    "absolute X/Y": (8, TABLET, "-8"),
    "no wheel": (4, NOWHEEL, "-10"),
    "truncated": (4, QEMU[:-9], "-1"),
    "nested Push": (4, QEMU[:20] + b"\xa4\xa4" + QEMU[20:], "-3"),
    "Pop without Push": (4, b"\xb4" + QEMU, "-4"),
    "17 input report IDs": (8, G_MOUSE + b"".join(h("0600ff0901a10185%02x 0901 1500 26ff00 7508 9501 8102 c0" % i)
                                                  for i in range(2, 19)), "-5"),
}


def unit(exe: Path) -> list[str]:
    report = []
    for name, (mp, desc, want) in SHAPES.items():
        head, _, _ = run(exe, mp, desc)
        got = " ".join(head) if head[0] == "0" else head[0]
        assert got == want, (name, got, want)
        report.append(f"{'ACCEPT' if head[0] == '0' else 'REFUSE ' + head[0]:10} {name}")
    # G502 layout: buttons 1, X +10, Y -3 (HID down positive), wheel up, pan 0
    _, ev, d = run(exe, 8, G502, ["01 00 0a 00 fd ff 01 00", "00 00 00 00 00 00 ff 00"])
    assert ev == ["H 9 10 3 255 z=255", "H 8 0 0 1 z=1"], ev
    assert d == [2, 2, 0, 1], d
    # receiver: ID 2 decoded, ID 3/4 skipped
    _, ev, d = run(exe, 8, RECEIVER, ["02 00 00 0a f0 ff 01 00", "03 e9 00 00 00", "04 01"])
    assert ev == ["H 8 10 1 255 z=255"], ev
    assert d == [3, 1, 2, -1], d
    # 32-byte vendor report on 8-byte packets: ID 0x0b + 4 continuation packets skipped,
    # even when a continuation packet starts with the mouse report ID
    long_rep = ["0b 01 02 03 04 05 06 07", "01 7f 00 7f 00 7f 00 00", "08 09 0a 0b 0c 0d 0e 0f",
                "10 11 12 13 14 15 16 17", "18 19 1a 1b 1c 1d 1e 1f"]
    _, ev, d = run(exe, 8, GAMING + VENDOR32, ["01 01 05 00 fb ff 01"] + long_rep + ["01 00 02 00 00 00 ff"])
    assert ev == ["H 9 5 5 255 z=255", "H 8 2 0 1 z=1"], ev
    assert d == [7, 2, 1, 1], d
    # 64-byte vendor report on 16-byte packets, then the ZLP replay of the last
    # continuation packet: skipped; a different packet after it is decoded
    cont = "40 41 42 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f"
    vend = ["05 " + " ".join(["aa"] * 15), "01 " + " ".join(["bb"] * 15), "cc " * 16, cont]
    _, ev, d = run(exe, 16, GAMING + VENDOR63, vend + [cont, "01 00 03 00 00 00 00"])
    assert ev == ["H 8 3 0 0 z=0"], ev
    # without the ZLP: the next real packet right after the report is decoded
    _, ev, _ = run(exe, 16, GAMING + VENDOR63, vend + ["01 00 03 00 00 00 00"])
    assert ev == ["H 8 3 0 0 z=0"], ev
    # boot protocol stays 3 bytes, wheel 0
    _, ev, _ = run(exe, 4, NOWHEEL, ["01 05 fb"])
    assert ev == ["H 9 5 5 0 z=0"], ev
    return report


def record_layout(exe: Path) -> None:
    out = subprocess.run([str(exe), "L"], capture_output=True, text=True, check=True).stdout.split()
    # sizeof (with the u32 tail padding), version, packets, skipped, last_raw, dev, dev size,
    # dev.desclen, desc_got, desc: the offsets USOSDBG.EXE's MDIAG uses (usosdbg.c)
    assert out[1:] == ["312", "8", "16", "24", "28", "44", "26", "6", "148", "150"], out


def usosdbg_layout(zig: str, td: Path) -> None:
    """USOSDBG.EXE's MDIAG (usosdbg.c) has the record's offsets with 1-, 2-
    (OpenWatcom wcc 16-bit) and 4-byte packing."""
    import re
    src = (ROOT / "src/platform/bios/win9x/usosdbg.c").read_text(encoding="utf-8").replace("\r\n", "\n")
    defs = grab(src, r"^typedef struct \{\n    BYTE iface, maxpacket.*?\} MDIAG;\n")
    probe = ('int main(void) { printf("%zu %zu %zu %zu %zu %zu %zu %zu %zu", offsetof(MDIAG, version),'
             ' offsetof(MDIAG, packets), offsetof(MDIAG, skipped), offsetof(MDIAG, last_raw),'
             ' offsetof(MDIAG, dev), sizeof(MDIAGDEV), offsetof(MDIAGDEV, desclen),'
             ' offsetof(MDIAG, desc_got), offsetof(MDIAG, desc)); return 0; }\n')
    env = dict(os.environ)
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(td / "zig-cache"))
    for pack in ("1", "2", "4"):
        c = td / f"dbg{pack}.c"
        c.write_text("#include <stdio.h>\n#include <stddef.h>\n#include <stdint.h>\n"
                     "typedef uint8_t BYTE; typedef uint16_t WORD; typedef uint32_t DWORD;\n"
                     f"#pragma pack({pack})\n" + defs + probe, encoding="utf-8")
        exe = td / f"dbg{pack}.exe"
        subprocess.run([zig, "cc", "-o", str(exe), str(c)], check=True, env=env, capture_output=True)
        out = subprocess.run([str(exe)], capture_output=True, text=True, check=True).stdout.split()
        assert out == ["8", "16", "24", "28", "44", "26", "6", "148", "150"], (pack, out)
    # the reason texts cover every USB_MD_* code
    hid = patched_sources()[1]["seabios/src/hw/usb-hid.c"]
    codes = [int(x) for x in re.findall(r"^#define USB_MD_\w+ +(-\d+)", hid, re.M)]
    reasons = grab(src, r"^static const char \*md_reason\(int r\).*?\n\}\n")
    assert sorted(int(x) for x in re.findall(r"case (-?\d+):", reasons)) == sorted(codes + [0]), codes


def composite(exe: Path) -> None:
    def iface(num, alt, cls, sub, proto):
        return bytes([9, 4, num, alt, 1, cls, sub, proto, 0])
    hid = h("09 21 1101 00 01 22 4000")
    ep = lambda a: bytes([7, 5, a, 3, 8, 0, 1])                       # noqa: E731
    kbd = iface(0, 0, 3, 1, 1) + hid + ep(0x81)
    mouse = iface(1, 0, 3, 1, 2) + hid + ep(0x82)
    vend = iface(2, 0, 3, 0, 0) + hid + ep(0x83)

    def call(cfg: bytes, num: int) -> list[str]:
        return subprocess.run([str(exe), "C", str(num)] + ["%02x" % b for b in cfg], capture_output=True,
                              text=True, check=True).stdout.strip().split("\n")
    # receiver: keyboard, mouse, HID++ -> the mouse (interface 1), imax to the end
    assert call(kbd + mouse + vend, 3) == ["setup if 1 imax %d" % len(mouse + vend), "ret 0"]
    # vendor interface before the mouse: still found
    assert call(kbd + vend + mouse.replace(b"\x09\x04\x01", b"\x09\x04\x02"), 3)[0].startswith("setup if 2")
    # only a keyboard (or a second keyboard): nothing added
    assert call(kbd + vend, 2) == ["ret -1"]
    assert call(kbd + iface(1, 0, 3, 1, 1) + hid + ep(0x82), 2) == ["ret -1"]
    # non-boot mouse interface (subclass 0) and alternate settings are not used
    assert call(kbd + iface(1, 0, 3, 0, 2) + hid + ep(0x82), 2) == ["ret -1"]
    assert call(kbd + iface(1, 1, 3, 1, 2) + hid + ep(0x82), 2) == ["ret -1"]
    # bNumInterfaces bounds the walk; a truncated descriptor ends it
    assert call(kbd + vend + mouse, 2) == ["ret -1"]
    assert call(kbd + mouse[:5], 2) == ["ret -1"]


def wiring(orig: dict[str, str], srcs: dict[str, str]) -> None:
    hid, usb = srcs["seabios/src/hw/usb-hid.c"], srcs["seabios/src/hw/usb.c"]
    ohid = orig["seabios/src/hw/usb-hid.c"]
    for fn in (r"^usb_kbd_setup\(.*?\n\}\n", r"^usb_check_key\(.*?\n\}\n", r"^handle_key\(.*?\n\}\n",
               r"^usb_kbd_command\(.*?\n\}\n", r"^usb_hid_setup\(.*?\n\}\n"):
        assert grab(hid, fn) == grab(ohid, fn), fn
    setup = grab(hid, r"^usb_mouse_setup\(.*?\n\}\n")
    assert "int lret = usb_mouse_layout(usbdev, m, epdesc->wMaxPacketSize, slot);" in setup
    assert "if (!lret && m->nlong && m->diag == 0xff)\n        lret = USB_MD_LONGREPORT;" in setup
    assert "if (!lret && set_protocol(usbdev->defpipe, 1, ifnum))\n        lret = USB_MD_SETPROTO;" in setup
    assert "if (!lret) {\n        m->report = 1;" in setup and "if (set_protocol(usbdev->defpipe, 0, ifnum))" in setup
    # the record is only written by the BIOS: every GET_LOW of it is in handle_mouse's
    # ZLP compare (last_raw/last_dev) or a counter increment
    for line in hid.split("\n"):
        if "GET_LOW(usb_mouse_diag." in line:
            assert any(k in line for k in ("usb_mouse_diag.packets", "usb_mouse_diag.zpackets",
                                           "usb_mouse_diag.skipped", "usb_mouse_diag.count",
                                           "usb_mouse_diag.last_dev", "usb_mouse_diag.last_raw")), line
    assert "SET_LOW(usb_mouse_diag.sig[0], 0x534f5355);" in setup and "SET_LOW(usb_mouse_diag.sig[1], 0x4c48574d);" in setup
    # usb.c: only the HID branch of configure_usb_device changes
    ousb = orig["seabios/src/hw/usb.c"]
    cfg, ocfg = grab(usb, r"^configure_usb_device\(.*?\n\}\n"), grab(ousb, r"^configure_usb_device\(.*?\n\}\n")
    old = "    } else\n        ret = usb_hid_setup(usbdev);\n"
    new = ("    } else {\n        ret = usb_hid_setup(usbdev);\n"
           "        if (iface->bInterfaceProtocol == USB_INTERFACE_PROTOCOL_KEYBOARD\n"
           "            && !usb_hid_next_mouse(usbdev, config_end, num_iface))\n            ret = 0;\n    }\n")
    assert ocfg.count(old) == 1 and cfg == ocfg.replace(old, new)
    assert usb.replace(grab(usb, r"^// USOS \(usb-mouse-wheel\): the first boot mouse.*?\n\}\n\n"), "").replace(cfg, ocfg) == ousb
    for p in (P18, P19):
        assert "ps2port.c" not in p.read_text(encoding="utf-8")


def pins() -> None:
    names = sorted(p.name for p in (V14 / "patches").glob("*.patch"))
    base = sorted(p.name for p in (V13 / "patches").glob("*.patch"))
    assert names == sorted(base + [P18.name, P19.name]), names
    for n in base:
        assert sha(V14 / "patches" / n) == sha(V13 / "patches" / n), n
    manifest = json.loads((V14 / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == "3.1.2-usos14"
    assert manifest["patches"] == {n: sha(V14 / "patches" / n) for n in names}
    for name, digest in manifest["files"].items():
        assert sha(V14 / name) == digest, name
    # the release pins moved to 3.1.2-usos15 (same 0018/0019 files, test_csmwrap_wheel15.py)
    for n in (P18.name, P19.name):
        assert sha(ROOT / "tools/vendor/csmwrap/3.1.2-usos15/patches" / n) == sha(V14 / "patches" / n), n
    efi = (V14 / "csmwrapx64.efi").read_bytes()
    assert efi[:2] == b"MZ" and b"3.1.2-usos14" in efi and b"pci_irq_routing" in efi


def main() -> int:
    orig, srcs = patched_sources()
    wiring(orig, srcs)
    pins()
    zig = find_zig()
    with tempfile.TemporaryDirectory() as td:
        exe = build(zig, srcs, Path(td))
        report = unit(exe)
        record_layout(exe)
        usosdbg_layout(zig, Path(td))
        composite(exe)
    print("\n".join(report))
    print("CSMWRAP-WHEEL-DIAG-TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
