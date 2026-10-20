"""Host test: CSMWrap 3.1.2-usos15 patch 0020 (USB mouse wheel in the Z word
without the knock, ring of the last INT 15h C2xxh calls in USOSMWHL).

    python tools/tests/csmwrap/test_csmwrap_wheel15.py [path-to-zig.exe]

1. Unit: seabios/src/hw/usb-hid.c and mouse.c from the pinned source archive
   with 0016 + 0018 + 0019 + 0020 applied; handle_mouse,
   process_mouse_packet and usb_mouse_diag_c2 built on the host (zig cc,
   UBSan, -Werror). Package size 3: the wheel in the handler's Z word with
   device ID 0 and 3; sizes 1/2 and 4-7 as in usos14 (the wheel byte only
   with ID 3); the C2RG ring layout (+312, the first 310 bytes as in 0018)
   and its wrap.
2. Wiring: handle_15c2 records every call after its switch with AX/BX
   taken before it; the ring is only written; usb-hid.h declares it.
3. Series: usos15 = usos14 byte for byte + 0020; manifest; the release
   pins are usos16 now (same 0001-0020 files, test_csmwrap_uds16.py).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csmwrap_acpi10 import ROOT, find_zig  # noqa: E402
from test_csmwrap_wheel import apply, file_hunks, grab  # noqa: E402
import test_csmwrap_wheel_diag as diag  # noqa: E402

V15 = ROOT / "tools/vendor/csmwrap/3.1.2-usos15"
V14 = ROOT / "tools/vendor/csmwrap/3.1.2-usos14"
P20 = V15 / "patches/0020-usb-mouse-wheel-z-always-c2-ring.patch"
HID, MOUSE, HIDH = "seabios/src/hw/usb-hid.c", "seabios/src/mouse.c", "seabios/src/hw/usb-hid.h"
sha = diag.sha


def patched_sources() -> tuple[dict[str, str], dict[str, str]]:
    _, s14 = diag.patched_sources()
    hunks = file_hunks(P20.read_text(encoding="utf-8"))
    assert set(hunks) == {HID, MOUSE, HIDH}, sorted(hunks)
    s15 = dict(s14)
    for n in (HID, MOUSE):
        s15[n] = apply(s14[n], hunks[n])
    return s14, s15


MAIN = r'''
static u8 desc[4096];
int main(int argc, char **argv)
{
    if (argv[1][0] == 'L') {
        printf("L %d %zu %zu %zu %zu %zu %d %zu %zu %zu\n", (int)sizeof(struct usb_mouse_diag),
               offsetof(struct usb_mouse_diag, desc_got), offsetof(struct usb_mouse_diag, desc),
               offsetof(struct usb_mouse_diag, c2_magic), offsetof(struct usb_mouse_diag, c2_count),
               offsetof(struct usb_mouse_diag, c2_head), (int)sizeof(struct usb_mouse_c2),
               offsetof(struct usb_mouse_diag, c2), offsetof(struct usb_mouse_c2, id),
               offsetof(struct usb_mouse_c2, res));
        return 0;
    }
    if (argv[1][0] == 'R') {               /* R <calls> */
        int n = atoi(argv[2]);
        for (int i = 0; i < n; i++) {
            usb_mouse_id = i & 1 ? 3 : 0;
            usb_mouse_diag_c2(0xC200 + (i & 7), 0x100 + i, 0x2230, 0xF000, 0x1000 + i, i == 2 ? 0x84 : 0);
        }
        printf("R %08x %u %u", usb_mouse_diag.c2_magic, usb_mouse_diag.c2_count, usb_mouse_diag.c2_head);
        for (int i = 0; i < USB_MOUSE_C2_RING; i++)
            printf(" %04x/%04x/%04x/%04x:%04x/%u/%02x", usb_mouse_diag.c2[i].ax, usb_mouse_diag.c2[i].bx,
                   usb_mouse_diag.c2[i].es, usb_mouse_diag.c2[i].cs, usb_mouse_diag.c2[i].ip,
                   usb_mouse_diag.c2[i].id, usb_mouse_diag.c2[i].res);
        printf("\n");
        return 0;
    }
    /* P <id> <package size> <maxpacket> desc... ; packets on stdin */
    int id = atoi(argv[2]), pkg = atoi(argv[3]), maxpacket = atoi(argv[4]), n = 0;
    for (int i = 5; i < argc; i++) desc[n++] = strtol(argv[i], 0, 16);
    struct mouse_node m;
    memset(&m, 0, sizeof(m));
    m.maxpacket = maxpacket;
    int r = hid_parse_mouse(desc, n, &m, maxpacket * 8);
    m.report = r == 0;
    m.diag = 0;
    usb_mouse_id = id;
    ebda.mouse_flag2 = 0x80 | pkg;
    char line[256];
    while (fgets(line, sizeof(line), stdin)) {
        u8 rep[16] = { 0 }; int k = 0; char *p = line, *e;
        while (k < 16) { long v = strtol(p, &e, 16); if (e == p) break; rep[k++] = v; p = e; }
        if (k) handle_mouse(&m, rep);
    }
    return 0;
}
'''

PRELUDE = diag.PRELUDE.replace("#define CONFIG_MOUSE 1\n", "#define CONFIG_MOUSE 1\n#define CONFIG_USB_MOUSE 1\n")
# a byte-stream handler (package size 1/2) prints one line per byte
PRELUDE = PRELUDE.replace('printf(" z=%d\\n", (ebda.mouse_flag2 & 7) >= 4 ? ebda.mouse_data[3] : mouse_extra_z);',
                          'printf(" z=%d\\n", (ebda.mouse_flag2 & 7) >= 4 ? ebda.mouse_data[3] : mouse_extra_z);'
                          '\n    fflush(stdout);')


def build(zig: str, srcs: dict[str, str], td: Path) -> Path:
    hid, mouse = srcs[HID], srcs[MOUSE]
    parts = [
        grab(hid, r"^struct hid_loc \{[^\n]*\};\n"),
        grab(hid, r"^struct mouse_node \{.*?\n\};\n#define USB_MOUSE_ZLP 0x80\n"),
        grab(hid, r"^#define USB_MOUSE_DIAG_DEVS.*?^struct usb_mouse_diag usb_mouse_diag VARLOW __aligned\(16\);\n"),
        grab(hid, r"^u8 usb_mouse_skip\[USB_MOUSE_DIAG_DEVS\] VARLOW;\n"),
        grab(hid, r"^// Why a mouse stays.*?^#define USB_MD_SETPROTO +-30[^\n]*\n"),
        "void process_mouse_packet(u8 flag, u8 x, u8 y, u8 z, int imps2);\n",
        grab(hid, r"^void\nusb_mouse_diag_c2\(.*?\n\}\n"),
        grab(hid, r"^static int\nhid_parse_mouse\(.*?\n\}\n"),
        grab(hid, r"^static s32\nhid_bits\(.*?\n\}\n"),
        grab(hid, r"^static int\nclamp127\(.*?\n\}\n"),
        grab(hid, r"^static void\nhandle_mouse\(.*?\n\}\n"),
        grab(mouse, r"^void\nprocess_mouse\(u8 data\).*?\n\}\n"),
        grab(mouse, r"^void\nprocess_mouse_packet\(.*?\n\}\n"),
    ]
    c = td / "wheel15.c"
    c.write_text(PRELUDE + "\n".join(parts) + MAIN, encoding="utf-8")
    exe = td / ("wheel15.exe" if os.name == "nt" else "wheel15")
    env = dict(os.environ)
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(td / "zig-cache"))
    r = subprocess.run([zig, "cc", "-std=gnu11", "-O1", "-Wall", "-Werror", "-Wno-unused-function",
                        "-Wno-pointer-arith", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-o", str(exe), str(c)], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    return exe


def events(exe: Path, mid: int, pkg: int, desc: bytes, maxpacket: int, packets) -> list[str]:
    out = subprocess.run([str(exe), "P", str(mid), str(pkg), str(maxpacket)] + ["%02x" % b for b in desc],
                         input="\n".join(packets) + "\n", capture_output=True, text=True, check=True).stdout
    return [line for line in out.strip().split("\n") if line]


def unit(exe: Path) -> None:
    g = diag.G502
    up = ["00 00 00 00 00 00 01 00"]         # wheel up one notch: IntelliMouse z = -1 (255)
    # package size 3: Z word with ID 3 (as usos14) and now also with ID 0
    assert events(exe, 3, 3, g, 8, up) == ["H 8 0 0 z=255"]
    assert events(exe, 0, 3, g, 8, up) == ["H 8 0 0 z=255"]
    # a mouse without a wheel: Z stays 0 with ID 0
    assert events(exe, 0, 3, diag.NOWHEEL, 4, ["01 05 fb"]) == ["H 9 5 5 z=0"]
    # package size 4: the 4th byte only with ID 3 (unchanged)
    assert events(exe, 3, 4, g, 8, up) == ["H 8 0 0 255 z=255"]
    assert events(exe, 0, 4, g, 8, up) == ["H 8 0 0 0 z=0"]
    # package sizes 5..7: rest zero, wheel byte only with ID 3
    assert events(exe, 3, 7, g, 8, up) == ["H 8 0 0 255 0 0 0 z=255"]
    assert events(exe, 0, 7, g, 8, up) == ["H 8 0 0 0 0 0 0 z=0"]
    # package size 1: a 3-byte stream without the knock, 4 bytes with it
    assert events(exe, 0, 1, g, 8, up) == ["H 8 z=0", "H 0 z=0", "H 0 z=0"]
    assert events(exe, 3, 1, g, 8, up) == ["H 8 z=0", "H 0 z=0", "H 0 z=0", "H 255 z=0"]
    # the Z word is per packet: a following packet without wheel has Z 0
    assert events(exe, 0, 3, g, 8, up + ["00 00 01 00 00 00 00 00"]) == ["H 8 0 0 z=255", "H 8 1 0 z=0"]


def layout(exe: Path) -> None:
    out = subprocess.run([str(exe), "L"], capture_output=True, text=True, check=True).stdout.split()
    # sizeof, desc_got and desc as in 0018 (USOSDBG's MDIAG), then the ring
    assert out[1:] == ["512", "148", "150", "312", "316", "318", "12", "320", "10", "11"], out
    out = subprocess.run([str(exe), "R", "3"], capture_output=True, text=True, check=True).stdout.split()
    assert out[1:4] == ["47523243", "3", "3"], out
    assert out[4:7] == ["c200/0100/2230/f000:1000/0/00", "c201/0101/2230/f000:1001/3/00",
                        "c202/0102/2230/f000:1002/0/84"], out
    assert out[7] == "0000/0000/0000/0000:0000/0/00", out
    out = subprocess.run([str(exe), "R", "20"], capture_output=True, text=True, check=True).stdout.split()
    assert out[1:4] == ["47523243", "20", "4"], out
    # slots 0..3 hold calls 16..19, slot 4 the oldest kept (call 4)
    assert out[4].startswith("c200/0110/") and out[7].startswith("c203/0113/"), out
    assert out[8].startswith("c204/0104/"), out


def wiring(s14: dict[str, str], s15: dict[str, str]) -> None:
    mouse = s15[MOUSE]
    h15 = grab(mouse, r"^void\nhandle_15c2\(.*?\n\}\n")
    assert "u16 ax = regs->ax, bx = regs->bx;\n    switch (regs->al) {" in h15
    assert h15.rstrip().endswith(
        "    usb_mouse_diag_c2(ax, bx, regs->es, regs->code.seg, regs->code.offset\n"
        "                      , (regs->flags & F_CF) ? 0x80 | (regs->ah & 0x7f) : 0);\n}")
    # every other INT 15h C2xxh function is unchanged
    for fn in (r"^mouse_15c207\(.*?\n\}\n", r"^mouse_15c205\(.*?\n\}\n", r"^mouse_15c201\(.*?\n\}\n",
               r"^invoke_mouse_handler\(.*?\n\}\n"):
        assert grab(mouse, fn) == grab(s14[MOUSE], fn), fn
    pk = grab(mouse, r"^void\nprocess_mouse_packet\(.*?\n\}\n")
    assert "    if (package_count == 3)\n        SET_LOW(mouse_extra_z, z);" in pk
    assert pk.count("imps2") == 3      # parameter, the byte stream and the 4th byte stay gated
    hid = s15[HID]
    c2 = grab(hid, r"^void\nusb_mouse_diag_c2\(.*?\n\}\n")
    assert "if (! CONFIG_USB_MOUSE)\n        return;" in c2
    # the ring is only written: its GET_LOWs are the slot, the counter and the device ID
    for line in hid.split("\n"):
        if "GET_LOW(usb_mouse_diag.c2" in line:
            assert "c2_head" in line or "c2_count" in line, line
    assert "SET_LOW(usb_mouse_diag.c2_magic, 0x47523243);" in c2
    assert "SET_LOW(usb_mouse_diag.version, 1);" in hid          # old USOSDBG still reads the record
    assert hid.replace(c2, "").count("usb_mouse_diag_c2") == 0     # called from mouse.c only
    # handle_mouse and the setup are as in usos14
    for fn in (r"^static void\nhandle_mouse\(.*?\n\}\n", r"^usb_mouse_setup\(.*?\n\}\n",
               r"^usb_mouse_command\(.*?\n\}\n"):
        assert grab(hid, fn) == grab(s14[HID], fn), fn
    assert "void usb_mouse_diag_c2(u16 ax, u16 bx, u16 es, u16 cs, u16 ip, u8 res);" in P20.read_text(encoding="utf-8")


def pins() -> None:
    names = sorted(p.name for p in (V15 / "patches").glob("*.patch"))
    base = sorted(p.name for p in (V14 / "patches").glob("*.patch"))
    assert names == sorted(base + [P20.name]), names
    for n in base:
        assert sha(V15 / "patches" / n) == sha(V14 / "patches" / n), n
    manifest = json.loads((V15 / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == "3.1.2-usos15"
    assert manifest["patches"] == {n: sha(V15 / "patches" / n) for n in names}
    for name, digest in manifest["files"].items():
        assert sha(V15 / name) == digest, name
    # the release pins moved to 3.1.2-usos16, then 3.1.2-usos17 (same 0001-0020 files, test_csmwrap_uds17.py)
    efi = (V15 / "csmwrapx64.efi").read_bytes()
    assert efi[:2] == b"MZ" and b"3.1.2-usos15" in efi and b"pci_irq_routing" in efi
    tp = json.loads((ROOT / "tools/release/third-party.json").read_text(encoding="utf-8"))
    cw = [c for c in tp["components"] if c.get("id") == "csmwrap"] if isinstance(tp, dict) and "components" in tp else []
    if cw:
        assert cw[0]["version"] in ("3.1.2-usos15", "3.1.2-usos16", "3.1.2-usos17")


def main() -> int:
    s14, s15 = patched_sources()
    wiring(s14, s15)
    pins()
    zig = sys.argv[1] if len(sys.argv) > 1 else find_zig()
    with tempfile.TemporaryDirectory() as td:
        exe = build(zig, s15, Path(td))
        unit(exe)
        layout(exe)
    print("CSMWRAP-WHEEL15-TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
