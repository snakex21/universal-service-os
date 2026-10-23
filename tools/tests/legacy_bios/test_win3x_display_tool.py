#!/usr/bin/env python3
"""The micro-Linux Windows 3.x display patch (src/compat/win3x, run as
`usos-fb-ui --win3x-display DIR` by tools/dos_csmwrap_target.sh) against the
Python patchers it was ported from.

With the user's media (read-only; Desktop/Universal_Service_OS/OS, or
USOS_WIN3X_MEDIA=<dir with the ISOs>) the display files of every Windows 3.x
ISO are extracted into a temporary WINSETUP copy, patched by the host build
of the same Zig code (zig-out/bin/usos-win3x-display, `zig build
win3x-display-tool`) and compared byte for byte with
tools/win3x_vga_patch.py / tools/win3x_logo_patch.py on the expanded
originals; the stored file must be in the media's own container (SZDD / KWAJ)
and a second run must change nothing. src/compat/win3x/display_table.zig
must be what tools/win3x_patch_table.py generates from the same drivers.
Without the media or the tool those tests are skipped; the decoder and
script checks always run.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
import win3x_logo_patch as lp  # noqa: E402
import win3x_vga_patch as vp  # noqa: E402
import win3x_patch_table as pt  # noqa: E402

SEVEN = Path(r'C:\Program Files\7-Zip\7z.exe')
MEDIA = Path(os.environ.get('USOS_WIN3X_MEDIA', Path.home() / 'Desktop/Universal_Service_OS/OS/Windows'))
ISOS = {
    '3.0a': 'Windows 3.0/Windows 3.0a EN.iso',
    '3.1': 'Windows 3.1/Windows 3.1 PL.iso',
    '3.11': 'Windows 3.11/Windows 3.11 OEM EN.iso',
    'wfw': 'Windows for Workgroups 3.11/Windows for Workgroups 3.11 PL.iso',
}
FILES = ('VGA.DRV', 'VGA.DR_', 'EGA.DRV', 'EGA.DR_', 'VGALOGO.LGO', 'VGALOGO.LG_')
TABLE_ORDER = (('3.0a', 'VGA.DRV', 'Windows 3.0a VGA.DRV'), ('3.0a', 'EGA.DRV', 'Windows 3.0a EGA.DRV'),
               ('3.1', 'VGA.DR_', 'Windows 3.1/3.11 VGA.DRV'), ('3.1', 'EGA.DR_', 'Windows 3.1/3.11 EGA.DRV'),
               ('wfw', 'VGA.DR_', 'Windows for Workgroups 3.11 VGA.DRV'))


# ---------------------------------------------------------------- reference decoders

def szdd_expand(b: bytes) -> bytes:
    n = struct.unpack_from('<I', b, 10)[0]
    win, pos, out, i = bytearray(b' ' * 4096), 4096 - 16, bytearray(), 14
    while len(out) < n:
        f = b[i]
        i += 1
        for k in range(8):
            if len(out) >= n:
                break
            if f >> k & 1:
                c = b[i]
                i += 1
                out.append(c)
                win[pos] = c
                pos = (pos + 1) & 4095
            else:
                lo, hi = b[i], b[i + 1]
                i += 2
                src, ln = lo | ((hi & 0xf0) << 4), (hi & 15) + 3
                for j in range(ln):
                    c = win[(src + j) & 4095]
                    out.append(c)
                    win[pos] = c
                    pos = (pos + 1) & 4095
    return bytes(out[:n])


class _Bits:
    def __init__(self, b, i):
        self.b, self.i, self.buf, self.n = b, i, 0, 0

    def read(self, k):
        v = 0
        for _ in range(k):
            if not self.n:
                self.buf = self.b[self.i] if self.i < len(self.b) else 0
                self.i, self.n = self.i + 1, 8
            self.n -= 1
            v = v << 1 | (self.buf >> self.n) & 1
        return v


def _lens(bs, typ, num):
    if typ == 0:
        return [{16: 4, 32: 5, 64: 6, 256: 8}[num]] * num
    if typ == 3:
        return [bs.read(4) for _ in range(num)]
    c = bs.read(4)
    lens = [c]
    for _ in range(1, num):
        if typ == 1:
            if bs.read(1):
                c = c + 1 if not bs.read(1) else bs.read(4)
        else:
            sel = bs.read(2)
            c = bs.read(4) if sel == 3 else (c + sel - 1) & 0xff
        lens.append(c)
    return lens


def _codes(lens):
    codes, code = {}, 0
    for ln in range(1, 17):
        for s, x in enumerate(lens):
            if x == ln:
                codes[(ln, code)] = s
                code += 1
        code <<= 1
    return codes


def _sym(bs, codes):
    code = 0
    for ln in range(1, 17):
        code = code << 1 | bs.read(1)
        if (ln, code) in codes:
            return codes[(ln, code)]
    raise ValueError('bad Huffman code')


def kwaj_expand(b: bytes) -> bytes:
    method, doff, flags = struct.unpack_from('<HHH', b, 8)
    assert method == 3 and flags & 1
    n = struct.unpack_from('<I', b, 14)[0]
    bs = _Bits(b, doff)
    types = [bs.read(4) for _ in range(6)]
    ml1, ml2, ll, off, lit = (_codes(_lens(bs, types[k], num)) for k, num in enumerate((16, 16, 32, 64, 256)))
    win, pos, out, lit_run = bytearray(b' ' * 4096), 0, bytearray(), False
    while len(out) < n:
        ln = _sym(bs, ml2 if lit_run else ml1)
        if ln:
            ln, lit_run = ln + 2, False
            o = _sym(bs, off) << 6 | bs.read(6)
            for _ in range(ln):
                c = win[(pos - o) & 4095]
                win[pos] = c
                out.append(c)
                pos = (pos + 1) & 4095
        else:
            ln = _sym(bs, ll) + 1
            lit_run = ln != 32
            for _ in range(ln):
                c = _sym(bs, lit)
                win[pos] = c
                out.append(c)
                pos = (pos + 1) & 4095
    return bytes(out[:n])


def expand(b: bytes) -> bytes:
    if b[:4] == b'SZDD':
        return szdd_expand(b)
    if b[:4] == b'KWAJ':
        return kwaj_expand(b)
    return b


def _tool():
    for name in ('usos-win3x-display.exe', 'usos-win3x-display'):
        p = ROOT / 'zig-out/bin' / name
        if p.exists():
            return p
    return None


def _media_ok():
    return SEVEN.exists() and all((MEDIA / p).exists() for p in ISOS.values())


class ScriptTest(unittest.TestCase):
    def test_target_script_patches_windows_3x_only(self):
        s = (ROOT / 'tools/dos_csmwrap_target.sh').read_text()
        call = 'usos-fb-ui --win3x-display "$U/WINSETUP"'
        self.assertEqual(s.count(call), 1)
        i = s.index(call)
        block = s[s.rindex('case "$WIN_EARLY" in', 0, i):i]
        self.assertIn("''|windows-3-0)", block)
        self.assertNotIn('windows-2', block)
        # after the copy of the Setup files, before the batch files are chosen
        self.assertLess(s.index("log 'Windows 3.x Setup files copied'"), i)
        self.assertLess(i, s.index('printf \'%s\\r\\n\' "$WIN_EARLY" > "$U/EARLY.TAG"'))

    def test_fb_ui_subcommand(self):
        s = (ROOT / 'src/platform/linux/fb_ui_main.zig').read_text()
        self.assertIn('"--win3x-display"', s)
        self.assertIn('usos.win3x.display_run.run(', s)


@unittest.skipUnless(_media_ok(), 'Windows 3.x media or 7-Zip not available')
class MediaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix='usos-w3disp-'))
        cls.orig = {}
        for key, iso in ISOS.items():
            d = cls.tmp / 'orig' / key
            d.mkdir(parents=True)
            subprocess.run([str(SEVEN), 'e', '-y', f'-o{d}', str(MEDIA / iso), *FILES],
                           check=True, capture_output=True)
            cls.orig[key] = {p.name: p.read_bytes() for p in d.iterdir()}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_table_is_generated_from_the_drivers(self):
        args = []
        for key, name, label in TABLE_ORDER:
            p = self.tmp / f'{key}-{name}.bin'
            p.write_bytes(expand(self.orig[key][name]))
            args.append(f'{label}={p}')
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            pt.main(args)
        self.assertEqual(buf.getvalue(), (ROOT / 'src/compat/win3x/display_table.zig').read_text())

    @unittest.skipUnless(_tool(), 'zig build win3x-display-tool first')
    def test_zig_tool_matches_python(self):
        tool = _tool()
        for key in ISOS:
            with self.subTest(media=key):
                d = self.tmp / 'stage' / key
                d.mkdir(parents=True)
                for name, data in self.orig[key].items():
                    (d / name).write_bytes(data)
                r = subprocess.run([str(tool), 'patch-dir', str(d)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                log = (d / 'USOSDISP.TXT').read_text()
                for name, data in self.orig[key].items():
                    new = (d / name).read_bytes()
                    self.assertEqual(new[:4], data[:4], f'{name}: container changed')
                    body = expand(data)
                    if name.startswith('VGALOGO'):
                        want = lp.patch(body)[0]
                    else:
                        want = vp.patch(body)[0]
                    self.assertEqual(hashlib.sha256(expand(new)).hexdigest(), hashlib.sha256(want).hexdigest(), name)
                    self.assertIn(f'{name}: ', log)
                self.assertNotIn('left as is', log)
                before = {p.name: p.read_bytes() for p in d.iterdir() if p.name != 'USOSDISP.TXT'}
                r = subprocess.run([str(tool), 'patch-dir', str(d)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(before, {p.name: p.read_bytes() for p in d.iterdir() if p.name != 'USOSDISP.TXT'})
                self.assertIn('already patched', (d / 'USOSDISP.TXT').read_text())

    @unittest.skipUnless(_tool(), 'zig build win3x-display-tool first')
    def test_unknown_driver_left_alone(self):
        d = self.tmp / 'unknown'
        d.mkdir()
        body = bytearray(expand(self.orig['3.1']['VGA.DR_']))
        body[0x40] ^= 1
        (d / 'VGA.DRV').write_bytes(bytes(body))
        r = subprocess.run([str(_tool()), 'patch-dir', str(d)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual((d / 'VGA.DRV').read_bytes(), bytes(body))
        self.assertIn('unknown driver', (d / 'USOSDISP.TXT').read_text())


if __name__ == '__main__':
    unittest.main()
