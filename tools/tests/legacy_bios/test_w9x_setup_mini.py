#!/usr/bin/env python3
"""Windows 95/98 Setup's own mini-Windows on the real PC (native phase 1,
CSMWrap): MINI.CAB gets the VGA.DRV latch fix and the Windows 3.1
standard-mode USB keyboard/mouse bridge (src/compat/win3x/w9x_mini.zig, run
as `usos-fb-ui --w9x-setup-mini` by tools/w9x_csmwrap_target.sh; INSTALL.BAT
loads USOSKEY.COM + VBMOUSE.EXE before SETUP when U9ENV.BAT has U9MINI=1).

Always: script wiring, the target-script step under Git sh with a fake
usos-fb-ui (VM phase 1 / flag / bridge=on decisions), an own cabinet reader
(MSZIP through zlib with the previous blocks as dictionary, CFDATA checksums).
With the user's media (read-only; Desktop/Universal_Service_OS/OS/Windows or
USOS_W9X_MEDIA) and the host tool (`zig build win3x-display-tool`): every
95/98 MINI.CAB is rewritten by the Zig code, read back by the own reader and
by Windows' expand.exe, VGA.DRV equals tools/win3x_vga_patch.py's result on
the original byte for byte (= 9685c4f8..., the driver X470-tested in Windows
3.1), SYSTEM.INI has the bridge lines, the header (set ID, cabinet chain) is
kept, a second run changes nothing. USOSKEY.DRV / VBMOUSE.DRV imports must
resolve against the mini-Windows KRNL386.EXE / USER.EXE exports.
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
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))

SEVEN = Path(r'C:\Program Files\7-Zip\7z.exe')
MEDIA = Path(os.environ.get('USOS_W9X_MEDIA', Path.home() / 'Desktop/Universal_Service_OS/OS/Windows'))
ISOS = {
    '95-osr21-pl': ('Windows 95/Windows 95 OSR2.1 PL.iso', 'WIN95/MINI.CAB'),
    '95-rtm-pl': ('Windows 95/Windows 95 RTM PL OEM x86/Microsoft Windows 95 [Polish] (OEM) (ISO)/disk01.iso',
                  'WIN95/MINI.CAB'),
    '98-pl': ('Windows 98/Windows 98 PL.iso', 'WIN98/MINI.CAB'),
    '98se-pl': ('Windows 98 SE/Windows 98 SE PL OEM.iso', 'WIN98/MINI.CAB'),
}
VGA31 = '53312ed013bda513c74e33659f4ee7d1b4f2b1cf1a06aed672432a8fbc4a820a'
VGA31_PATCHED = '9685c4f8021e67ddcd0942797ded66d2a80b1611f97f1fa03f8a41b762dc8467'
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'
INSTALL = ROOT / 'src/platform/bios/dos_startup.cmd'
VBMOUSE_DRV = ROOT / 'tools/vendor/vbados/0.67/VBMOUSE.DRV'


# ---------------------------------------------------------------- own cabinet reader

def csum(data: bytes, seed: int = 0) -> int:
    n = len(data) // 4 * 4
    c = seed
    for i in range(0, n, 4):
        c ^= struct.unpack_from('<I', data, i)[0]
    ul = 0
    rest = data[n:]
    for b in rest:
        ul = (ul << 8) | b
    return c ^ ul


def read_cab(d: bytes, check_sums: bool = True):
    """(header bytes, {name: (data, date, time, attr)} in order, block count)."""
    assert d[:4] == b'MSCF', 'not a cabinet'
    cb, coff = struct.unpack_from('<I', d, 8)[0], struct.unpack_from('<I', d, 16)[0]
    vmin, vmaj, nfold, nfile, flags = struct.unpack_from('<BBHHH', d, 24)
    assert cb == len(d) and (vmaj, vmin) == (1, 3) and nfold == 1
    o, rdata = 36, 0
    if flags & 4:
        hres, _, rdata = struct.unpack_from('<HBB', d, 36)
        o = 40 + hres
    for bit in (1, 2):
        if flags & bit:
            o = d.index(b'\0', d.index(b'\0', o) + 1) + 1
    header = d[:o]
    dataoff, nblk, ctype = struct.unpack_from('<IHH', d, o)
    body, q = bytearray(), dataoff
    for _ in range(nblk):
        s, cbd, cbu = struct.unpack_from('<IHH', d, q)
        blk = d[q + 8 + rdata:q + 8 + rdata + cbd]
        if check_sums:
            assert s == csum(d[q + 4:q + 8], csum(blk)), 'CFDATA checksum'
        if ctype == 0:
            body += blk
        else:
            assert blk[:2] == b'CK'
            z = zlib.decompressobj(-15, zdict=bytes(body[-32768:])) if body else zlib.decompressobj(-15)
            out = z.decompress(blk[2:]) + z.flush()
            assert len(out) == cbu
            body += out
        q += 8 + rdata + cbd
    files, q = {}, coff
    for _ in range(nfile):
        size, uoff, ifold, date, time, attr = struct.unpack_from('<IIHHHH', d, q)
        e = d.index(b'\0', q + 16)
        files[d[q + 16:e].decode('latin1')] = (bytes(body[uoff:uoff + size]), date, time, attr)
        q = e + 1
    return header, files, nblk


# ---------------------------------------------------------------- NE imports / exports

def ne_imports(raw: bytes) -> set:
    ne = struct.unpack_from('<I', raw, 0x3c)[0]
    h = lambda o: struct.unpack_from('<H', raw, ne + o)[0]
    modtab, imptab, nseg, segtab, shift = ne + h(0x28), ne + h(0x2a), h(0x1c), ne + h(0x22), h(0x32)
    mods = []
    for i in range(h(0x1e)):
        o = imptab + struct.unpack_from('<H', raw, modtab + 2 * i)[0]
        mods.append(raw[o + 1:o + 1 + raw[o]].decode())
    out = set()
    for s in range(nseg):
        so, sl, fl, _ = struct.unpack_from('<HHHH', raw, segtab + 8 * s)
        if not so or not fl & 0x100:
            continue
        fo, ln = so << shift, sl or 0x10000
        for k in range(struct.unpack_from('<H', raw, fo + ln)[0]):
            _, rt, _, a, b = struct.unpack_from('<BBHHH', raw, fo + ln + 2 + 8 * k)
            if rt & 3 == 1:
                out.add((mods[a - 1], b))
            elif rt & 3 == 2:
                o = imptab + b
                out.add((mods[a - 1], raw[o + 1:o + 1 + raw[o]].decode().upper()))
    return out


def ne_exports(raw: bytes) -> set:
    ne = struct.unpack_from('<I', raw, 0x3c)[0]
    h = lambda o: struct.unpack_from('<H', raw, ne + o)[0]
    out = set()
    for tab, end, skip_first in ((ne + h(0x26), None, True), (h(0x2c), h(0x2c) + h(0x20), False)):
        o, first = tab, True
        while (end is None or o < end) and raw[o]:
            n = raw[o]
            name = raw[o + 1:o + 1 + n].decode('latin1').upper()
            if not (first and skip_first):
                out.add(struct.unpack_from('<H', raw, o + 1 + n)[0])
                out.add(name)
            first = False
            o += 3 + n
    return out


def _tool():
    for name in ('usos-win3x-display.exe', 'usos-win3x-display'):
        p = ROOT / 'zig-out/bin' / name
        if p.exists():
            return p
    return None


def _usoskey_drv():
    env = os.environ.get('USOS_USOSKEY_DRV')
    cands = [Path(env)] if env else []
    cands += [ROOT / 'zig-out/dos-native/win9x/USOSKEY.DRV']
    cands += sorted(Path.home().glob('usos-work/*/zig-out/dos-native/win9x/USOSKEY.DRV'),
                    key=lambda p: p.stat().st_mtime, reverse=True)
    return next((p for p in cands if p.exists()), None)


def _media(key):
    iso, _ = ISOS[key]
    return SEVEN.exists() and (MEDIA / iso).exists()


def _sh():
    return shutil.which('sh')


def _posix(p: Path) -> str:
    """C:/x -> /c/x for Git sh (PATH entries must not contain a colon)."""
    s = p.as_posix()
    return '/' + s[0].lower() + s[2:] if len(s) > 1 and s[1] == ':' else s


# ---------------------------------------------------------------- tests

class ScriptTest(unittest.TestCase):
    def test_target_step_guarded_and_after_u9env(self):
        s = TARGET.read_text()
        call = 'usos-fb-ui --w9x-setup-mini "$work/c/$SETUP_FOLDER" "$work/c/USOS9X"'
        self.assertEqual(s.count(call), 1)
        i = s.index(call)
        # U9ENV.BAT is created first, the helpers (USOSKEY.DRV, VBMOUSE.DRV) are in C:\USOS9X
        self.assertLess(s.index('> "$work/c/USOS9X/U9ENV.BAT"'), i)
        self.assertLess(s.index('for file in "$HELPERS"/*; do'), i)
        block = s[s.index('SETUP_MINI_OFF_FLAG='):s.index("log 'setup mini-Windows: U9MINI=1")]
        self.assertIn('if [ "$VM_PHASE1" = 1 ]; then', block)
        self.assertIn("grep -qx 'bridge=on'", block)
        self.assertIn('USOSKEY.COM', block)
        self.assertIn('VBMOUSE.EXE', block)

    def test_install_bat_loads_bridge_before_setup_and_in_resume(self):
        s = INSTALL.read_text()
        a = s.index('IF NOT "%U9MINI%"=="1" GOTO MINIDONE')
        b = s.index(':MINIDONE')
        block = s[a:b]
        self.assertLess(block.index('C:\\USOS9X\\VBMOUSE.EXE'), block.index('C:\\USOS9X\\USOSKEY.COM'))
        self.assertIn('CTTY NUL', block)
        self.assertIn('CTTY CON', block)
        setup = s.index('C:\\%U9SRC%\\SETUP.EXE C:\\%U9SRC%\\MSBATCH.INF %U9SW%\n')
        self.assertLess(b, setup)
        # RESUME.BAT: created, then the bridge lines, then its SETUP line
        r0 = s.index('ECHO @ECHO OFF>C:\\USOS9X\\RESUME.BAT')
        r1 = s.index('ECHO C:\\USOS9X\\USOSKEY.COM>>C:\\USOS9X\\RESUME.BAT')
        r2 = s.index('ECHO C:\\%U9SRC%\\SETUP.EXE C:\\%U9SRC%\\MSBATCH.INF %U9SW%>>C:\\USOS9X\\RESUME.BAT')
        self.assertLess(r0, r1)
        self.assertLess(r1, r2)

    def test_tool_entry_points(self):
        fb = (ROOT / 'src/platform/linux/fb_ui_main.zig').read_text()
        self.assertIn('"--w9x-setup-mini"', fb)
        self.assertIn('usos.win3x.w9x_mini.run(', fb)
        self.assertIn('"w9x-mini"', (ROOT / 'src/tools/win3x_display_main.zig').read_text())


@unittest.skipUnless(_sh(), 'Git sh not found')
class TargetStepShellTest(unittest.TestCase):
    """The target-script block alone under sh with a fake usos-fb-ui."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9xmini-'))
        s = TARGET.read_text()
        a = s.index('SETUP_MINI_OFF_FLAG=')
        b = s.index('\n', s.index("log 'setup mini-Windows: U9MINI=1")) + 1
        b = s.index('fi\n', b) + 3
        self.block = s[a:b]
        (self.tmp / 'bin').mkdir()
        (self.tmp / 'c/WIN95').mkdir(parents=True)
        (self.tmp / 'c/USOS9X').mkdir(parents=True)
        (self.tmp / 'c/WIN95/MINI.CAB').write_bytes(b'MSCF')
        for n in ('USOSKEY.COM', 'VBMOUSE.EXE'):
            (self.tmp / 'c/USOS9X' / n).write_bytes(b'x')
        (self.tmp / 'c/USOS9X/U9ENV.BAT').write_bytes(b'SET U9SYS=95\r\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_block(self, vm='0', bridge='on', flag=False):
        fake = self.tmp / 'bin/usos-fb-ui'
        fake.write_text('#!/bin/sh\necho "called $*" >> "%s/calls"\nprintf \'x\\r\\nbridge=%s\\r\\n\' > "$3/USOSMINI.TXT"\n'
                        % (self.tmp.as_posix(), bridge), newline='\n')
        fake.chmod(0o755)
        if flag:
            (self.tmp / 'off.flag').write_bytes(b'')
        script = ('log() { printf "%%s\\n" "$*"; }\nwork=%s\nSETUP_FOLDER=WIN95\nVM_PHASE1=%s\nESP_DIR=/nonexistent\n'
                  'W9X_SETUP_MINI_OFF_FLAG=%s/off.flag\nPATH="%s/bin:$PATH"\n' %
                  (_posix(self.tmp), vm, _posix(self.tmp), _posix(self.tmp))) + self.block
        r = subprocess.run([_sh(), '-c', script], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = (self.tmp / 'calls').read_text() if (self.tmp / 'calls').exists() else ''
        return r.stdout, calls, (self.tmp / 'c/USOS9X/U9ENV.BAT').read_bytes()

    def test_native_bridge_on(self):
        out, calls, env = self.run_block()
        self.assertIn('--w9x-setup-mini', calls)
        self.assertTrue(env.endswith(b'SET U9MINI=1\r\n'))

    def test_bridge_off_keeps_u9env(self):
        out, calls, env = self.run_block(bridge='off')
        self.assertIn('--w9x-setup-mini', calls)
        self.assertNotIn(b'U9MINI', env)

    def test_vm_phase1_and_flag_skip(self):
        for kw in ({'vm': '1'}, {'flag': True}):
            with self.subTest(**kw):
                out, calls, env = self.run_block(**kw)
                self.assertEqual(calls, '')
                self.assertNotIn(b'U9MINI', env)
                self.assertIn('MINI.CAB unchanged', out)


class ReaderTest(unittest.TestCase):
    def test_checksum_matches_cabinet_sdk_remainder_order(self):
        # 3 trailing bytes are one word, first byte highest
        self.assertEqual(csum(b'\x01\x02\x03'), 0x010203)
        self.assertEqual(csum(b'\x10\x00\x00\x00\x01\x02'), 0x10 ^ 0x0102)


@unittest.skipUnless(_tool() and VBMOUSE_DRV.exists(), 'zig build win3x-display-tool first')
class MediaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix='usos-w9xmini-media-'))
        cls.helpers = cls.tmp / 'helpers'
        cls.helpers.mkdir()
        key = _usoskey_drv()
        cls.key = key.read_bytes() if key else b'MZ USOSKEY test stand-in'
        (cls.helpers / 'USOSKEY.DRV').write_bytes(cls.key)
        shutil.copyfile(VBMOUSE_DRV, cls.helpers / 'VBMOUSE.DRV')
        cls.orig = {}
        for k, (iso, member) in ISOS.items():
            if not _media(k):
                continue
            d = cls.tmp / 'orig' / k
            d.mkdir(parents=True)
            subprocess.run([str(SEVEN), 'e', '-y', f'-o{d}', str(MEDIA / iso), member], capture_output=True)
            p = next(d.glob('[Mm][Ii][Nn][Ii].[Cc][Aa][Bb]'), None)
            if p:
                cls.orig[k] = p.read_bytes()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_media_cabinets(self):
        if not self.orig:
            self.skipTest('no Windows 95/98 media')
        import win3x_vga_patch as vp
        for k, raw in self.orig.items():
            with self.subTest(media=k):
                hdr0, files0, _ = read_cab(raw)
                self.assertEqual(hashlib.sha256(files0['VGA.DRV'][0]).hexdigest(), VGA31)
                d = self.tmp / 'stage' / k
                d.mkdir(parents=True)
                (d / 'MINI.CAB').write_bytes(raw)
                r = subprocess.run([str(_tool()), 'w9x-mini', str(d), str(self.helpers)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                log = (self.helpers / 'USOSMINI.TXT').read_text()
                self.assertTrue(log.rstrip().endswith('bridge=on'), log)
                new = (d / 'MINI.CAB').read_bytes()
                hdr1, files1, nblk = read_cab(new)
                # header kept except cbCabinet / coffFiles / cFiles
                self.assertEqual(len(hdr0), len(hdr1))
                for lo, hi in ((0, 8), (12, 16), (20, 28), (30, len(hdr0))):
                    self.assertEqual(hdr0[lo:hi], hdr1[lo:hi], (lo, hi))
                self.assertEqual(list(files1)[:len(files0)], list(files0))
                self.assertEqual(list(files1)[len(files0):], ['USOSKEY.DRV', 'VBMOUSE.DRV'])
                for name, (data, date, time, attr) in files0.items():
                    if name in ('VGA.DRV', 'SYSTEM.INI'):
                        continue
                    self.assertEqual(files1[name], (data, date, time, attr), name)
                vga = files1['VGA.DRV'][0]
                self.assertEqual(vga, vp.patch(files0['VGA.DRV'][0])[0])
                self.assertEqual(hashlib.sha256(vga).hexdigest(), VGA31_PATCHED)
                ini0 = files0['SYSTEM.INI'][0].decode('latin1')
                ini1 = files1['SYSTEM.INI'][0].decode('latin1')
                self.assertIn('[boot]           \r\ndrivers=usoskey.drv\r\n', ini1)
                self.assertIn('\r\nmouse.drv=vbmouse.drv\r\n', ini1)
                self.assertNotIn('msmous31', ini1.split('[keyboard]')[0].replace('; setup.exe', ''))
                self.assertEqual(ini1.replace('drivers=usoskey.drv\r\n', '').replace('vbmouse.drv', 'msmous31.drv'), ini0)
                self.assertEqual(files1['USOSKEY.DRV'][0], self.key)
                self.assertEqual(files1['VBMOUSE.DRV'][0], VBMOUSE_DRV.read_bytes())
                # Windows' own cabinet decoder (FDI) reads it too
                expand = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/expand.exe'
                if expand.exists():
                    out = self.tmp / 'ms' / k
                    out.mkdir(parents=True)
                    subprocess.run([str(expand), '-F:*', str(d / 'MINI.CAB'), str(out)], capture_output=True)
                    for name, (data, *_rest) in files1.items():
                        self.assertEqual((out / name).read_bytes(), data, f'expand.exe: {name}')
                # idempotent
                r = subprocess.run([str(_tool()), 'w9x-mini', str(d), str(self.helpers)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual((d / 'MINI.CAB').read_bytes(), new)
                log = (self.helpers / 'USOSMINI.TXT').read_text()
                self.assertIn('already patched', log)
                self.assertIn('nothing to change', log)
                self.assertTrue(log.rstrip().endswith('bridge=on'))

    def test_no_helpers_only_vga(self):
        if not self.orig:
            self.skipTest('no Windows 95/98 media')
        k, raw = next(iter(self.orig.items()))
        d = self.tmp / 'nohelp'
        d.mkdir()
        (d / 'MINI.CAB').write_bytes(raw)
        r = subprocess.run([str(_tool()), 'w9x-mini', str(d), '-'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((d / 'USOSMINI.TXT').read_text().rstrip().endswith('bridge=off'))
        _, files0, _ = read_cab(raw)
        _, files1, _ = read_cab((d / 'MINI.CAB').read_bytes())
        self.assertEqual(list(files1), list(files0))
        self.assertEqual(files1['SYSTEM.INI'], files0['SYSTEM.INI'])
        self.assertEqual(hashlib.sha256(files1['VGA.DRV'][0]).hexdigest(), VGA31_PATCHED)

    def test_bridge_imports_resolve_in_mini_windows(self):
        if not self.orig:
            self.skipTest('no Windows 95/98 media')
        if not _usoskey_drv():
            self.skipTest('no built USOSKEY.DRV (USOS_USOSKEY_DRV)')
        for k, raw in self.orig.items():
            with self.subTest(media=k):
                _, files, _ = read_cab(raw)
                exports = {'KERNEL': ne_exports(files['KRNL386.EXE'][0]), 'USER': ne_exports(files['USER.EXE'][0])}
                for drv in (self.key, VBMOUSE_DRV.read_bytes()):
                    for mod, what in sorted(ne_imports(drv), key=str):
                        self.assertIn(mod, exports, f'import from {mod}')
                        self.assertIn(what, exports[mod], f'{mod}.{what}')


if __name__ == '__main__':
    unittest.main()
