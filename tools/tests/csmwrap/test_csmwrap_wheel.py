"""Host test: CSMWrap 3.1.2-usos13 patch 0016 (USB mouse wheel) and 0017
(SeaBIOS romfile-only options off).

    python tools/tests/csmwrap/test_csmwrap_wheel.py [path-to-zig.exe]

1. Unit: seabios/src/hw/usb-hid.c and seabios/src/mouse.c from the pinned
   source archive with the 0016 hunks applied (no other patch touches them);
   hid_parse_mouse, hid_bits, handle_mouse, process_mouse and
   process_mouse_packet are built on the host (zig cc, UBSan, -Werror)
   against real-world report descriptors: the QEMU usb-mouse, a Logitech-
   style report-ID mouse, a composite gaming mouse (mouse, consumer and
   keyboard reports on one interface), no wheel, absolute pointer, Push/Pop,
   a vendor report longer than one packet, the wheel in another report;
   the decoded packet (ID filter, signs, wheel direction), the boot-protocol
   path, and the INT 15h C205h package sizes 1..7 with and without the
   IntelliMouse knock.
2. Wiring: the keyboard path is untouched; the knock answers ID 3 only with
   a wheel mouse; C201h resets it; C204h returns it; the handler's Z word.
3. Series: usos13 = usos12 byte for byte + 0016 + 0017; manifest; the
   release pins are usos14 now (same 0016/0017 files, test_csmwrap_wheel_diag.py).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csmwrap_acpi10 import ROOT, find_zig  # noqa: E402

V13 = ROOT / "tools/vendor/csmwrap/3.1.2-usos13"
V12 = ROOT / "tools/vendor/csmwrap/3.1.2-usos12"
PATCH = V13 / "patches/0016-usb-mouse-wheel.patch"
CONFIG = V13 / "patches/0017-seabios-config-no-romfile-features.patch"
ARCHIVE = ROOT / "tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz"


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def file_hunks(patch: str) -> dict[str, list[tuple[int, list[str]]]]:
    out: dict[str, list[tuple[int, list[str]]]] = {}
    for sect in re.split(r"^diff -ruN ", patch, flags=re.M)[1:]:
        name = re.search(r"^--- a/(\S+)$", sect, re.M).group(1)
        hunks = []
        for m in re.finditer(r"^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@.*\n((?:[ +\-].*\n?)*)", sect, re.M):
            hunks.append((int(m.group(1)), m.group(2).rstrip("\n").split("\n")))
        out[name] = hunks
    return out


def apply(orig: str, hunks: list[tuple[int, list[str]]]) -> str:
    lines = orig.split("\n")
    shift = 0
    for start, body in hunks:
        old = [l[1:] for l in body if l[:1] in (" ", "-")]
        new = [l[1:] for l in body if l[:1] in (" ", "+")]
        at = start - 1 + shift
        assert lines[at:at + len(old)] == old, f"hunk at {start} does not apply"
        lines[at:at + len(old)] = new
        shift += len(new) - len(old)
    return "\n".join(lines)


def patched_sources(patch: str) -> dict[str, str]:
    hunks = file_hunks(patch)
    assert set(hunks) == {"seabios/src/hw/usb-hid.c", "seabios/src/mouse.c", "seabios/src/util.h"}, sorted(hunks)
    # util.h is also touched by earlier patches; the unit needs only these two
    names = ("seabios/src/hw/usb-hid.c", "seabios/src/mouse.c")
    with tarfile.open(ARCHIVE) as t:
        src = {n: t.extractfile("csmwrap-3.1.2/" + n).read().decode() for n in names}
    return {n: apply(src[n], hunks[n]) for n in names}


def grab(text: str, pattern: str) -> str:
    m = re.search(pattern, text, re.S | re.M)
    assert m, pattern
    return m.group(0)


PRELUDE = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef uint8_t u8; typedef int8_t s8; typedef uint16_t u16; typedef int16_t s16;
typedef uint32_t u32; typedef int32_t s32;
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define GET_GLOBALFLAT(x) (x)
#define GET_LOW(x) (x)
#define SET_LOW(x, v) ((x) = (v))
#define CONFIG_MOUSE 1
#define dprintf(...) do { } while (0)
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
'''

MAIN = r'''
static u8 desc[1024];
int main(int argc, char **argv)
{
    if (argv[1][0] == 'P') {               /* P <pkgsize> <imps2> flag x y z */
        ebda.mouse_flag2 = 0x80 | atoi(argv[2]);
        process_mouse_packet(strtol(argv[4], 0, 16), strtol(argv[5], 0, 16), strtol(argv[6], 0, 16),
                             strtol(argv[7], 0, 16), atoi(argv[3]));
        return 0;
    }
    int maxpacket = atoi(argv[1]);
    int n = 0;
    for (int i = 2; i < argc; i++) desc[n++] = strtol(argv[i], 0, 16);
    struct mouse_node m;
    memset(&m, 0, sizeof(m));
    int r = hid_parse_mouse(desc, n, &m, maxpacket * 8);
    struct hid_loc *l = m.loc;
    printf("%d %d %d %d %d %d %d %d %d %d\n", r, m.report_id, l[0].off, l[0].size, l[1].off, l[1].size,
           l[2].off, l[2].size, l[0].sgn | l[1].sgn << 1 | l[2].sgn << 2,
           (l[3].size != 0) | (l[4].size != 0) << 1 | (l[5].size != 0) << 2);
    /* packets on stdin, one per line: decoded through handle_mouse */
    char line[256];
    m.report = r == 0;
    usb_mouse_id = 3;
    ebda.mouse_flag2 = 0x80 | 4;
    while (fgets(line, sizeof(line), stdin)) {
        u8 rep[16] = { 0 }; int k = 0; char *p = line, *e;
        while (k < 16) { long v = strtol(p, &e, 16); if (e == p) break; rep[k++] = v; p = e; }
        if (k) handle_mouse(&m, rep);
    }
    return 0;
}
'''


def build(zig: str, srcs: dict[str, str], td: Path) -> Path:
    hid, mouse = srcs["seabios/src/hw/usb-hid.c"], srcs["seabios/src/mouse.c"]
    parts = [
        grab(hid, r"^struct hid_loc \{[^\n]*\};\n"),
        grab(hid, r"^struct mouse_node \{.*?\n\};\n"),
        "void process_mouse_packet(u8 flag, u8 x, u8 y, u8 z, int imps2);\n",
        grab(hid, r"^static int\nhid_parse_mouse\(.*?\n\}\n"),
        grab(hid, r"^static s32\nhid_bits\(.*?\n\}\n"),
        grab(hid, r"^static int\nclamp127\(.*?\n\}\n"),
        grab(hid, r"^static void\nhandle_mouse\(.*?\n\}\n"),
        grab(mouse, r"^void\nprocess_mouse\(u8 data\).*?\n\}\n"),
        grab(mouse, r"^void\nprocess_mouse_packet\(.*?\n\}\n"),
    ]
    c = td / "wheel.c"
    c.write_text(PRELUDE + "\n".join(parts) + MAIN, encoding="utf-8")
    exe = td / ("wheel.exe" if os.name == "nt" else "wheel")
    env = dict(os.environ)
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(td / "zig-cache"))
    r = subprocess.run([zig, "cc", "-std=gnu11", "-O1", "-Wall", "-Werror", "-Wno-unused-function",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all", "-o", str(exe), str(c)],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    return exe


def h(s: str) -> bytes:
    return bytes.fromhex(s.replace(" ", ""))


# QEMU hw/usb/dev-hid.c usb-mouse: 5 buttons, X, Y, wheel, 8 bit each, no IDs.
QEMU = h("05010902a1010901a1000509190129051500250195057501810295017503810105010930093109381581257f750895038106c0c0")
# Logitech-style, report ID 2: 16 buttons, 12-bit X/Y, wheel, AC Pan (8 bytes).
LOGI = h("05010902a1018502 0901a100 0509190129101500250195107501 8102 0501 1601f826ff07 750c 9502 0930 0931 8106"
         " 1581257f 7508 9501 0938 8106 050c 0a3802 9501 8106 c0c0")
# Boot-style mouse without a wheel.
NOWHEEL = h("05010902a1010901a10005091901290315002501950375018102950175058101050109300931 1581257f75089502 8106c0c0")
# Absolute pointer with a wheel: X/Y absolute -> refused.
TABLET = h("05010902a1010901a1000509190129031500250195037501810295017505810105010930093115002 6ff7f 751095028102"
           " 0938 1581257f 750895018106 c0c0")
# Composite gaming mouse, one interface: ID 1 mouse (5 buttons, 16-bit X/Y,
# wheel; 8 bytes with the ID), ID 2 consumer (3 bytes), ID 3 keyboard (8 bytes).
G_MOUSE = h("05010902a1018501 0901a100 0509190129051500250195057501 8102 95017503 8101"
            " 0501 16018026ff7f 75109502 09300931 8106 1581257f 75089501 0938 8106 c0c0")
G_CONSUMER = h("050c0901a1018502 1900 2a3c02 1500 263c02 95017510 8100 c0")
G_KEYBOARD = h("05010906a1018503 0507 19e0 29e7 1500 2501 75019508 8102 95067508 1500 2565 1900 2965 8100 c0")
GAMING = G_MOUSE + G_CONSUMER + G_KEYBOARD
# A vendor input report of 19 bytes on the same interface (ID 4).
VENDOR = h("0600ff0901a1018504 1500 26ff00 75089513 0901 8102 c0")
# X/Y in report 1, the wheel only in report 2 -> no wheel layout.
SPLIT = h("05010902a1018501 0901a100 0509190129031500250195037501 8102 95017505 8101"
          " 0501 1581257f 75089502 09300931 8106 c0c0"
          " 05010902a1018502 0938 1581257f 75089501 8106 c0")


def run(exe: Path, maxpacket: int, desc: bytes, packets: list[str] = ()) -> tuple[list[int], list[str]]:
    out = subprocess.run([str(exe), str(maxpacket)] + ["%02x" % b for b in desc], input="\n".join(packets) + "\n",
                         capture_output=True, text=True, check=True).stdout.strip().split("\n")
    return [int(x) for x in out[0].split()], out[1:]


def pkt(exe: Path, size: int, imps2: int, flag: int, x: int, y: int, z: int) -> list[str]:
    out = subprocess.run([str(exe), "P", str(size), str(imps2)] + ["%02x" % (v & 0xff) for v in (flag, x, y, z)],
                         capture_output=True, text=True, check=True).stdout.strip()
    return out.split("\n") if out else []


def unit(exe: Path) -> None:
    # QEMU mouse: left button, X +5, Y -5 (HID down positive), wheel up 1.
    head, ev = run(exe, 4, QEMU, ["01 05 fb 01"])
    assert head == [0, 0, 8, 8, 16, 8, 24, 8, 7, 7], head
    # flag 0x09 = left + bit 3; Y up = +5 -> PS/2 positive; HID wheel up -> -1 (0xff)
    assert ev == ["H 9 5 5 255 z=255"], ev
    # Logitech, report ID 2: X=+10, Y=-1, wheel +1; another report ID ignored.
    head, ev = run(exe, 8, LOGI, ["02 00 00 0a f0 ff 01 00", "03 01 02 03 04 05 06 07"])
    assert head == [0, 2, 16, 12, 28, 12, 40, 8, 7, 7], head
    assert ev == ["H 8 10 1 255 z=255"], ev
    assert run(exe, 4, LOGI)[0][0] == -1, "report longer than the packet"
    assert run(exe, 4, NOWHEEL)[0][0] == -1, "no wheel: boot protocol"
    assert run(exe, 8, TABLET)[0][0] == -1, "absolute X/Y: boot protocol"
    assert run(exe, 4, QEMU[:-9])[0][0] == -1, "truncated"
    # composite gaming mouse: ID 1, 16-bit X/Y clamped to +-127; consumer and keyboard reports ignored
    head, ev = run(exe, 8, GAMING, ["01 02 2c 01 00 80 ff", "02 e9 00", "03 00 00 04 00 00 00 00", "01 00 03 00 fd ff 00"])
    assert head == [0, 1, 8, 16, 24, 16, 40, 8, 7, 7], head
    # right button, X +300 -> 127, Y -32768 -> -127 -> PS/2 +127, wheel -1 (down) -> +1
    assert ev == ["H 10 127 127 1 z=1", "H 8 3 3 0 z=0"], ev
    assert run(exe, 7, GAMING)[0][0] == -1, "8-byte mouse report on a 7-byte endpoint"
    assert run(exe, 16, GAMING + VENDOR)[0][0] == -1, "a 20-byte vendor report does not fit one packet"
    assert run(exe, 8, SPLIT)[0][0] == -1, "wheel in another report"
    # Push/Pop: one level kept, nested or unbalanced refused
    i = QEMU.index(h("05010930"))
    pushed = QEMU[:i] + b"\xa4" + QEMU[i:-2] + b"\xb4" + QEMU[-2:]
    assert run(exe, 4, pushed)[0] == [0, 0, 8, 8, 16, 8, 24, 8, 7, 7]
    assert run(exe, 4, QEMU[:i] + b"\xa4\xa4" + QEMU[i:])[0][0] == -1, "nested push"
    assert run(exe, 4, b"\xb4" + QEMU)[0][0] == -1, "pop without push"
    # Push keeps the report size: a field after Pop uses the restored size
    j = QEMU.index(h("8106c0c0"))
    p2 = QEMU[:j] + h("a4 7510 b4") + QEMU[j:]
    assert run(exe, 4, p2)[0] == [0, 0, 8, 8, 16, 8, 24, 8, 7, 7]
    # boot protocol (report = 0): 3 bytes as before, wheel 0
    head, ev = run(exe, 4, NOWHEEL, ["01 05 fb"])
    assert ev == ["H 9 5 5 0 z=0"], ev

    # INT 15h C205h package sizes (flag 09, x 05, y 05, wheel ff)
    assert pkt(exe, 3, 0, 9, 5, 5, -1) == ["H 9 5 5 z=0"]          # no knock: as before
    assert pkt(exe, 3, 1, 9, 5, 5, -1) == ["H 9 5 5 z=255"]        # knock: wheel in the Z word
    assert pkt(exe, 4, 1, 9, 5, 5, -1) == ["H 9 5 5 255 z=255"]
    assert pkt(exe, 4, 0, 9, 5, 5, -1) == ["H 9 5 5 0 z=0"]
    assert pkt(exe, 6, 1, 9, 5, 5, -1) == ["H 9 5 5 255 0 0 z=255"]
    assert pkt(exe, 1, 1, 9, 5, 5, -1) == ["H 9 z=0", "H 5 z=0", "H 5 z=0", "H 255 z=0"]
    assert pkt(exe, 1, 0, 9, 5, 5, -1) == ["H 9 z=0", "H 5 z=0", "H 5 z=0"]


def wiring(text: str, srcs: dict[str, str]) -> None:
    hid, mouse = srcs["seabios/src/hw/usb-hid.c"], srcs["seabios/src/mouse.c"]
    kbd = grab(hid, r"^usb_kbd_setup\(.*?\n\}\n")
    with tarfile.open(ARCHIVE) as t:
        orig = t.extractfile("csmwrap-3.1.2/seabios/src/hw/usb-hid.c").read().decode()
    assert kbd == grab(orig, r"^usb_kbd_setup\(.*?\n\}\n"), "keyboard setup unchanged"
    for fn in (r"^usb_check_key\(.*?\n\}\n", r"^handle_key\(.*?\n\}\n", r"^usb_kbd_command\(.*?\n\}\n"):
        assert grab(hid, fn) == grab(orig, fn), fn
    # report protocol only with a parsed wheel layout; boot otherwise
    setup = grab(hid, r"^usb_mouse_setup\(.*?\n\}\n")
    assert "if (!usb_mouse_layout(usbdev, m, epdesc->wMaxPacketSize)\n        && !set_protocol(usbdev->defpipe, 1, ifnum))" in setup
    assert "if (set_protocol(usbdev->defpipe, 0, ifnum))" in setup
    assert "memset(desc, 0, rlen);" in hid
    cmd = grab(hid, r"^usb_mouse_command\(.*?\n\}\n")
    assert "GET_GLOBAL(usb_mouse_wheel) && GET_LOW(usb_mouse_rate1) == 200" in cmd
    assert "GET_LOW(usb_mouse_rate2) == 100 && param[0] == 80" in cmd
    reset = cmd[cmd.index("case PSMOUSE_CMD_RESET_BAT:"):cmd.index("case PSMOUSE_CMD_GETID:")]
    assert "SET_LOW(usb_mouse_id, 0);" in reset and "param[0] = 0xaa;" in reset
    assert "param[0] = GET_LOW(usb_mouse_id);" in cmd[cmd.index("case PSMOUSE_CMD_GETID:"):]
    inv = grab(mouse, r"^invoke_mouse_handler\(void\).*?\n\}\n")
    assert '"pushw %w4\\n"  // Z' in inv and '"+S"(Z)' in inv and ': "edi", "cc", "memory"' in inv
    assert "if (regs->bh < 1 || regs->bh > 7)" in mouse
    # the PS/2 (i8042) path is untouched: ps2port.c not in the patch
    assert "ps2port.c" not in text
    # 0017: only the three romfile-only options, nothing else in the config
    cfg = CONFIG.read_text(encoding="utf-8")
    assert cfg.count("diff -ruN ") == 1 and "--- a/seabios-config\n" in cfg
    cfg = cfg[cfg.index("diff -ruN "):]
    added = [l[1:] for l in cfg.split("\n") if l.startswith("+") and not l.startswith("+++")]
    assert added == ["# CONFIG_BOOTSPLASH is not set", "# CONFIG_SERCON is not set",
                     "# CONFIG_HOST_BIOS_GEOMETRY is not set"], added
    assert not [l for l in cfg.split("\n") if l.startswith("-") and not l.startswith("---")]


def pins() -> None:
    names = sorted(p.name for p in (V13 / "patches").glob("*.patch"))
    base = sorted(p.name for p in (V12 / "patches").glob("*.patch"))
    assert names == sorted(base + [PATCH.name, CONFIG.name]), names
    for n in base:
        assert sha(V13 / "patches" / n) == sha(V12 / "patches" / n), n
    manifest = json.loads((V13 / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == "3.1.2-usos13"
    assert manifest["patches"] == {n: sha(V13 / "patches" / n) for n in names}
    for name, digest in manifest["files"].items():
        assert sha(V13 / name) == digest, name
    # the release pins moved to 3.1.2-usos14 (same 0016/0017 files, test_csmwrap_wheel_diag.py)
    for n in (PATCH.name, CONFIG.name):
        assert sha(ROOT / "tools/vendor/csmwrap/3.1.2-usos14/patches" / n) == sha(V13 / "patches" / n), n
    efi = (V13 / "csmwrapx64.efi").read_bytes()
    assert efi[:2] == b"MZ" and b"3.1.2-usos13" in efi and b"pci_irq_routing" in efi


def main() -> int:
    text = PATCH.read_text(encoding="utf-8")
    srcs = patched_sources(text)
    wiring(text, srcs)
    pins()
    zig = find_zig()
    with tempfile.TemporaryDirectory() as td:
        unit(build(zig, srcs, Path(td)))
    print("CSMWRAP-WHEEL-TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
