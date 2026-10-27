"""USOSPID.DRV (src/platform/bios/win9x/usospid.c): the Windows 95 OEM
Product ID typed into Setup's own Product ID page (950: one field; OSR2:
the COA page's three fields) by a Win16 installable driver in Setup's
mini-Windows.

Always: the decisions of usospid_logic.h compiled for the host with zig cc
(key file format, the tick state machine), and source checks (what the
driver may call, the key file name the target script stages). With the
pinned OpenWatcom in tools/cache/openwatcom: the driver builds without the
C runtime, imports KERNEL/USER only. With the user's 95/98 media (read-only,
as test_w9x_setup_mini.py): every import resolves against the mini-Windows
KRNL386.EXE / USER.EXE of MINI.CAB, and the SUWIN.EXE dialog templates of
the 950 and OSR2.1 media carry the control IDs the driver looks for.
Made-up test IDs only (no real keys)."""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import depguard  # noqa: E402

SRC = ROOT / 'src/platform/bios/win9x'
LOGIC = SRC / 'usospid_logic.h'
DRIVER = SRC / 'usospid.c'
FAKE_ID = '12345-OEM-0000007-54321'
FAKE_CD = '111-1111111'

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usospid_logic.h"
/* k HEX...: pid_key_parse of each byte string; s FLAGS...: pid_step per
 * tick, FLAGS = 7 digits expired active box page edit_empty edit_full
 * next_ready, an 8th digit edit_ours (else 0), a leading F: pid_focus
 * instead (the field got the focus); prints the action numbers; p KEY:
 * the COA parts 0..3 of a parsed OEM ID, "len:text" each. */
int main(int argc, char **argv)
{
    int i;
    if (argv[1][0] == 'p') {
        char key[PID_KEY_LEN + 1], part[8];
        if (pid_key_parse((const unsigned char *)argv[2], (int)strlen(argv[2]), key) != PID_KEY_OEM) { printf("bad\n"); return 0; }
        for (i = 0; i < 4; i++) { int n = pid_key_part(key, i, part); printf("%d:%s\n", n, part); }
    } else if (argv[1][0] == 'k') {
        for (i = 2; i < argc; i++) {
            unsigned char buf[64];
            char out[PID_KEY_LEN + 1];
            int n = 0;
            const char *h = argv[i];
            while (h[0] && h[1] && n < 64) { char t[3] = { h[0], h[1], 0 }; buf[n++] = (unsigned char)strtoul(t, 0, 16); h += 2; }
            printf("%d %s\n", pid_key_parse(buf, n, out), out);
        }
    } else {
        PIDSTATE s;
        memset(&s, 0, sizeof(s));
        for (i = 2; i < argc; i++) {
            PIDVIEW v;
            const char *f = argv[i];
            int focus = f[0] == 'F';
            if (focus) f++;
            v.expired = f[0] == '1'; v.active = f[1] == '1'; v.box = f[2] == '1'; v.page = f[3] == '1';
            v.edit_empty = f[4] == '1'; v.edit_full = f[5] == '1'; v.next_ready = f[6] == '1';
            v.edit_ours = strlen(f) > 7 && f[7] == '1';
            printf("%d", focus ? pid_focus(&s, &v) : pid_step(&s, &v));
        }
        printf("\n");
    }
    return 0;
}
'''

NONE, TYPE, NEXT, DISMISS, STOP = '0', '1', '2', '3', '4'
# flags: expired active box page edit_empty edit_full next_ready
PAGE_EMPTY = '0101101'
PAGE_TYPED = '0101011'
PAGE_TYPED_NEXT_OFF = '0101010'
PAGE_USER = '0101001'      # someone typed something else
PAGE_OURS = '01010111'     # the field already holds the key (Setup, the focus fill)
FOCUS_EMPTY = 'F0001101'   # the page's empty field gets the focus
FOCUS_USER = 'F0001001'
BOX = '0110000'
OTHER = '0100000'          # another page / window active
BEHIND = '0001101'         # the page's frame, but not the active window
EXPIRED = '1101101'


class Logic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        depguard.require_zig()
        work = ROOT / 'zig-out/usospid-test'
        work.mkdir(parents=True, exist_ok=True)
        (work / 'harness.c').write_text(HARNESS)
        cls.exe = work / 'usospid.exe'
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-O1', '-Wall', '-Werror', '-I', str(SRC),
                        str(work / 'harness.c'), '-o', str(cls.exe)], check=True,
                       env={**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(ROOT / 'tools/cache/zig-global')})

    def run_exe(self, *args):
        return subprocess.run([str(self.exe), *args], capture_output=True, text=True, check=True).stdout.splitlines()

    def steps(self, *ticks):
        return self.run_exe('s', *ticks)[0]

    def test_key_file_format(self):
        hexs = lambda b: b.hex()
        cases = [(FAKE_ID.encode() + b'\r\n', '1 ' + FAKE_ID), (FAKE_ID.encode(), '1 ' + FAKE_ID),
                 (FAKE_ID.lower().encode() + b'\n\0\0', '1 ' + FAKE_ID), (FAKE_ID.encode() + b' \t', '1 ' + FAKE_ID),
                 (FAKE_ID[:-1].encode(), '0 '), (FAKE_ID.encode() + b'9', '0 '), (FAKE_ID.replace('OEM', 'OEX').encode(), '0 '),
                 (FAKE_ID.replace('-', '=', 1).encode(), '0 '), (b'', '0 '),
                 (FAKE_ID.encode() + b'\r\nmore', '0 '),
                 # a retail CD's CD key (2026-10-27): PID_KEY_CD
                 (FAKE_CD.encode() + b'\r\n', '2 ' + FAKE_CD), (FAKE_CD.encode(), '2 ' + FAKE_CD),
                 (FAKE_CD[:-1].encode(), '0 '), (FAKE_CD.encode() + b'9', '0 '), (b'1234567890\r\n', '0 '),
                 (b'12a-4567890', '0 '), (FAKE_CD.replace('-', '=').encode(), '0 ')]
        got = self.run_exe('k', *[hexs(b) or '00' for b, _ in cases])
        # an empty argument is not passed: 00 is one NUL byte (too short)
        self.assertEqual([g.rstrip() for g in got], [w.rstrip() for _, w in cases])

    def test_types_on_the_first_sight_of_the_page_then_next(self):
        # 2026-10-27: no second sighting any more (the RTM X470 run showed
        # Setup's batch Next on the empty field first).
        self.assertEqual(self.steps(PAGE_EMPTY, PAGE_TYPED, PAGE_TYPED), TYPE + NEXT + STOP)

    def test_focus_fills_the_empty_field_at_once(self):
        # The field gets the focus: typed then; the next tick presses Next.
        self.assertEqual(self.steps(FOCUS_EMPTY, PAGE_TYPED), TYPE + NEXT)
        # Setup moved on by itself with the key (its batch Next): done.
        self.assertEqual(self.steps(FOCUS_EMPTY, OTHER, PAGE_EMPTY), TYPE + STOP + STOP)
        # Once only; never into a field with text; not after the box.
        self.assertEqual(self.steps(FOCUS_EMPTY, FOCUS_EMPTY), TYPE + NONE)
        self.assertEqual(self.steps(FOCUS_USER, PAGE_USER), NONE + STOP)
        self.assertEqual(self.steps('F0011101', 'F1001101'), NONE + NONE)
        self.assertEqual(self.steps(PAGE_EMPTY, FOCUS_EMPTY, PAGE_TYPED), TYPE + NONE + NEXT)

    def test_a_field_that_already_holds_the_key_goes_to_next(self):
        self.assertEqual(self.steps(PAGE_OURS), NEXT)
        self.assertEqual(self.steps('01010101', PAGE_OURS), NONE + NEXT)

    def test_batch_invalid_box_first_is_answered_once(self):
        # Setup's batch mode pressed Next on the empty field: OK, then the page.
        self.assertEqual(self.steps(BOX, BOX, BEHIND, PAGE_EMPTY, PAGE_TYPED), DISMISS + NONE + NONE + TYPE + NEXT)

    def test_rejected_key_stops_at_the_box(self):
        self.assertEqual(self.steps(PAGE_EMPTY, BOX, BOX), TYPE + STOP + STOP)

    def test_user_typing_or_page_change_stops(self):
        self.assertEqual(self.steps(PAGE_USER, PAGE_EMPTY), STOP + STOP)
        self.assertEqual(self.steps(PAGE_EMPTY, PAGE_USER), TYPE + STOP)
        self.assertEqual(self.steps(PAGE_EMPTY, OTHER), TYPE + STOP)

    def test_inactive_windows_change_nothing(self):
        self.assertEqual(self.steps(OTHER, BEHIND, OTHER, PAGE_EMPTY), NONE + NONE + NONE + TYPE)

    def test_next_disabled_waits_then_gives_up(self):
        ticks = [PAGE_EMPTY] + [PAGE_TYPED_NEXT_OFF] * 10
        self.assertEqual(self.steps(*ticks), TYPE + NONE * 9 + STOP)
        self.assertEqual(self.steps(PAGE_EMPTY, PAGE_TYPED_NEXT_OFF, PAGE_TYPED), TYPE + NONE + NEXT)

    def test_coa_parts_are_the_digit_groups(self):
        # OSR2's COA page: 5 + 7 + 5 digits, without "OEM" and the dashes.
        self.assertEqual(self.run_exe('p', FAKE_ID), ['5:12345', '7:0000007', '5:54321', '0:'])
        self.assertEqual(self.run_exe('p', FAKE_ID.lower()), ['5:12345', '7:0000007', '5:54321', '0:'])
        self.assertEqual(self.run_exe('p', '123-4567890'), ['bad'])

    def test_never_appearing_page_times_out_quietly(self):
        self.assertEqual(self.steps(OTHER, OTHER, EXPIRED, PAGE_EMPTY), NONE + NONE + STOP + STOP)


class Source(unittest.TestCase):
    def test_driver_calls_and_key_handling(self):
        c = DRIVER.read_text(encoding='utf-8')
        self.assertIn('#define KEY_FILE   "C:\\\\USOS9X\\\\USOSPID.KEY"', c)
        # read, zeroed, deleted at DRV_LOAD; zeroed again when stopping
        load = c[c.index('static int read_key(void)'):c.index('static int class_is')]
        self.assertLess(load.index('OF_READ'), load.index('OF_WRITE'))
        self.assertLess(load.index('OF_WRITE'), load.index('OF_DELETE'))
        self.assertIn('zero((BYTE *)key, sizeof(key));', c[c.index('static void stop_all'):])
        self.assertIn('case DRV_LOAD:    return read_key() ? 1L : 0L;', c)
        for banned in ('OutputDebugString', 'wsprintf', 'MessageBox', 'WinExec', 'keybd_event'):
            self.assertNotIn(banned, c)
        # OSR2 COA page: the three Edits without 526, typed one part each,
        # the part buffer zeroed after use.
        self.assertIn('static const int coa_ids[3] = { PID_COA1_ID, PID_COA2_ID, PID_COA3_ID };', c)
        coa = c[c.index('static int coa_page(HWND c)'):c.index('static HWND oem_page(')]
        self.assertIn('if (GetDlgItem(c, PID_EDIT_ID)) return 0;', coa)
        typing = c[c.index('static void type_key(HWND page)'):c.index('void FAR PASCAL __export __loadds tick(')]
        self.assertIn('SetWindowText(GetDlgItem(page, coa_ids[i]), part);', typing)
        self.assertIn('zero((BYTE *)part, sizeof(part));', typing)
        # a CD key goes only into a retail page (526 with 1097), an OEM ID never
        page = c[c.index('static HWND oem_page(HWND frame)'):c.index('/* Field `w` holds')]
        self.assertIn('if (class_is(GetDlgItem(c, PID_EDIT_ID), "Edit") && GetDlgItem(c, PID_ADVANCED_ID)) return c;', page)
        self.assertLess(page.index('key_kind == PID_KEY_CD'), page.index('PID_LABEL_ID'))
        # the focus fill: in the CBT hook, only before typing, read-back buffer zeroed
        self.assertIn('if (code == HCBT_SETFOCUS && wp && !st.done && !st.typed) focus_fill((HWND)wp);', c)
        self.assertIn('zero((BYTE *)seen, sizeof(seen));', c)
        # nothing on the stack is handed to Windows or helpers by address (SS != DS)
        self.assertNotIn('&coa', c)
        target = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('"$work/c/USOS9X/USOSPID.KEY"', target)

    def test_staged_with_the_win9x_support(self):
        import build_win9x_support as b
        self.assertIn('USOSPID.DRV', b.STAGED)
        self.assertNotIn('USOSPID.DRV', b.FILES)          # not in the Legacy Core RAM disk list
        self.assertIn("'EFI/USOS/dos-native/win9x/USOSPID.DRV'",
                      (ROOT / 'tools/verify_release_consistency.ps1').read_text(encoding='utf-8'))


def _openwatcom():
    import build_win3_usb_keyboard as k
    home = k.OW_CACHE / ('ow-' + k.OW_SNAPSHOT['sha256'][:12])
    return (home / 'binnt64/wcc.exe').is_file()


@unittest.skipUnless(_openwatcom(), 'pinned OpenWatcom not unpacked in tools/cache/openwatcom')
class Build(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import build_win9x_support as b
        cls.tmp = Path(tempfile.mkdtemp(prefix='usos-usospid-'))
        (cls.tmp / 'out').mkdir()
        (cls.tmp / 'work').mkdir()
        cls.drv = b.build_usospid(cls.tmp / 'out', cls.tmp / 'work').read_bytes()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_ne_driver(self):
        import test_w9x_setup_mini as m
        from build_win3_usb_keyboard import ne_imported_modules
        self.assertEqual(self.drv[:2], b'MZ')
        self.assertTrue(set(ne_imported_modules(self.drv)) <= {'KERNEL', 'USER'})
        exports = m.ne_exports(self.drv)
        for name in ('DRIVERPROC', 'WEP', 'TICK', 'CBT_PROC'):
            self.assertIn(name, exports)
        self.assertNotIn(FAKE_ID.encode(), self.drv)

    def test_imports_resolve_in_mini_windows(self):
        import test_w9x_setup_mini as m
        imports = m.ne_imports(self.drv)
        self.assertTrue(imports)
        seen = 0
        for k, (iso, member) in m.ISOS.items():
            if not m._media(k):
                continue
            with self.subTest(media=k):
                d = self.tmp / 'media' / k
                d.mkdir(parents=True)
                subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(m.MEDIA / iso), member], capture_output=True)
                cab = next(d.glob('[Mm][Ii][Nn][Ii].[Cc][Aa][Bb]'), None)
                self.assertIsNotNone(cab)
                _, files, _ = m.read_cab(cab.read_bytes())
                exports = {'KERNEL': m.ne_exports(files['KRNL386.EXE'][0]), 'USER': m.ne_exports(files['USER.EXE'][0])}
                for mod, what in sorted(imports, key=str):
                    self.assertIn(what, exports[mod], f'{mod}.{what}')
                seen += 1
        if not seen:
            self.skipTest('no Windows 95/98 media')

    def test_950_mini_cab_gets_the_helper(self):
        import test_w9x_setup_mini as m
        if not m._tool() or not m.VBMOUSE_DRV.exists() or not m._media('95-rtm-pl'):
            self.skipTest('zig build win3x-display-tool and the 95 RTM PL media')
        iso, member = m.ISOS['95-rtm-pl']
        d, helpers = self.tmp / 'mini', self.tmp / 'helpers'
        d.mkdir()
        helpers.mkdir()
        subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(m.MEDIA / iso), member], capture_output=True)
        (helpers / 'USOSKEY.DRV').write_bytes(b'MZ USOSKEY test stand-in')
        shutil.copyfile(m.VBMOUSE_DRV, helpers / 'VBMOUSE.DRV')
        (helpers / 'USOSPID.DRV').write_bytes(self.drv)
        r = subprocess.run([str(m._tool()), 'w9x-mini', str(d), str(helpers)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        log = (helpers / 'USOSMINI.TXT').read_text().splitlines()
        self.assertEqual(log[-2:], ['pid=on', 'bridge=on'])
        _, files, _ = m.read_cab((d / 'MINI.CAB').read_bytes())
        self.assertEqual(files['USOSPID.DRV'][0], self.drv)
        self.assertIn('\r\ndrivers=usoskey.drv usospid.drv\r\n', files['SYSTEM.INI'][0].decode('latin1'))


# ---------------------------------------------------------------- SUWIN dialogs

def ne_dialogs(raw: bytes) -> dict:
    """{dialog id: [(control id, class)]} from an NE file's RT_DIALOG resources."""
    ne = struct.unpack_from('<I', raw, 0x3c)[0]
    rt = ne + struct.unpack_from('<H', raw, ne + 0x24)[0]
    shift = struct.unpack_from('<H', raw, rt)[0]
    p, out = rt + 2, {}
    while True:
        tid = struct.unpack_from('<H', raw, p)[0]
        if tid == 0:
            break
        cnt = struct.unpack_from('<H', raw, p + 2)[0]
        p += 8
        for _ in range(cnt):
            off, ln, _, rid = struct.unpack_from('<HHHH', raw, p)
            p += 12
            if tid != 0x8005 or not rid & 0x8000:
                continue
            b = raw[off << shift:(off << shift) + (ln << shift)]
            style, n = struct.unpack_from('<IB', b, 0)
            i = 13
            for _k in range(2):                                     # menu, class
                i = i + 3 if b[i] == 0xff else b.index(b'\0', i) + 1
            i = b.index(b'\0', i) + 1                               # caption
            if style & 0x40:
                i = b.index(b'\0', i + 2) + 1                       # font
            ctrls = []
            for _k in range(n):
                cid = struct.unpack_from('<H', b, i + 8)[0]
                i += 14
                if b[i] & 0x80:
                    cls = {0x80: 'Button', 0x81: 'Edit', 0x82: 'Static'}.get(b[i], hex(b[i]))
                    i += 1
                else:
                    e = b.index(b'\0', i)
                    cls, i = b[i:e].decode('latin1'), e + 1
                i = i + 3 if b[i] == 0xff else b.index(b'\0', i) + 1
                i += 1 + b[i]
                ctrls.append((cid, cls))
            out[rid & 0x7fff] = ctrls
    return out


SUWIN_OSR2 = {
    '95-osr21-pl': 'Windows 95/Windows 95 OSR2.1 PL.iso',
}
SUWIN_950 = {
    '95-rtm-pl': 'Windows 95/Windows 95 RTM PL OEM x86/Microsoft Windows 95 [Polish] (OEM) (ISO)/disk01.iso',
    '95-osr1-en': 'Windows 95/Windows 95 OSR1 EN OEM x86/win95_a_oem.iso',
}


def _suwin(m, iso, d):
    # SUWIN.EXE spans PRECOPY1.CAB and PRECOPY2.CAB: both next to each other.
    subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(m.MEDIA / iso), 'WIN95/PRECOPY1.CAB', 'WIN95/PRECOPY2.CAB'],
                   capture_output=True)
    cab = next(d.glob('[Pp][Rr][Ee][Cc][Oo][Pp][Yy]1.[Cc][Aa][Bb]'), None)
    if cab is None:
        return None
    subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(cab), 'suwin.exe'], capture_output=True)
    return next(d.glob('[Ss][Uu][Ww][Ii][Nn].[Ee][Xx][Ee]'), None)


class SuwinDialogs(unittest.TestCase):
    def test_osr2_coa_page_ids(self):
        # Also read (not here: 7-Zip archives) from the OSR2 EN 4.00.1111 and
        # OSR2.5 EN CDs: their SUWIN.EXE is one file (sha256 b8507541...),
        # 604 with the same three Edits, 156 with OK / 1118 / Exit.
        import test_w9x_setup_mini as m
        if not m.SEVEN.exists():
            self.skipTest('7-Zip not installed')
        logic = LOGIC.read_text()
        ids = {name: int(logic.split(f'#define {name}')[1].split()[0], 0)
               for name in ('PID_EDIT_ID', 'PID_COA1_ID', 'PID_COA2_ID', 'PID_COA3_ID', 'PID_IGNORE_ID')}
        coa = [ids['PID_COA1_ID'], ids['PID_COA2_ID'], ids['PID_COA3_ID']]
        seen = 0
        tmp = Path(tempfile.mkdtemp(prefix='usos-usospid-osr2-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        for k, iso in SUWIN_OSR2.items():
            if not (m.MEDIA / iso).exists():
                continue
            with self.subTest(media=k):
                d = tmp / k
                d.mkdir()
                suwin = _suwin(m, iso, d)
                self.assertIsNotNone(suwin)
                dialogs = ne_dialogs(suwin.read_bytes())
                page = dict(dialogs[604])
                self.assertEqual([page.get(i) for i in coa], ['Edit'] * 3)
                self.assertNotIn(ids['PID_EDIT_ID'], page)
                for rid, ctrls in dialogs.items():
                    if rid != 604:
                        self.assertFalse(set(coa) & set(dict(ctrls)), rid)
                box = dict(dialogs[156])
                self.assertEqual([box.get(1), box.get(ids['PID_IGNORE_ID']), box.get(2)], ['Button'] * 3)
                seen += 1
        # and no 950 SUWIN has any of them
        for k, iso in SUWIN_950.items():
            if not (m.MEDIA / iso).exists():
                continue
            with self.subTest(media=k):
                d = tmp / k
                d.mkdir()
                suwin = _suwin(m, iso, d)
                self.assertIsNotNone(suwin)
                for rid, ctrls in ne_dialogs(suwin.read_bytes()).items():
                    self.assertFalse(set(coa) & set(dict(ctrls)), rid)
        if not seen:
            self.skipTest('no Windows 95 OSR2 media')

    def test_950_page_ids(self):
        import test_w9x_setup_mini as m
        if not m.SEVEN.exists():
            self.skipTest('7-Zip not installed')
        seen = 0
        tmp = Path(tempfile.mkdtemp(prefix='usos-usospid-suwin-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        for k, iso in SUWIN_950.items():
            if not (m.MEDIA / iso).exists():
                continue
            with self.subTest(media=k):
                d = tmp / k
                d.mkdir()
                # SUWIN.EXE spans PRECOPY1.CAB and PRECOPY2.CAB: both next to each other.
                subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(m.MEDIA / iso), 'WIN95/PRECOPY1.CAB', 'WIN95/PRECOPY2.CAB'],
                               capture_output=True)
                cab = next(d.glob('[Pp][Rr][Ee][Cc][Oo][Pp][Yy]1.[Cc][Aa][Bb]'), None)
                self.assertIsNotNone(cab, 'no WIN95/PRECOPY1.CAB')
                subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(cab), 'suwin.exe'], capture_output=True)
                suwin = next(d.glob('[Ss][Uu][Ww][Ii][Nn].[Ee][Xx][Ee]'), None)
                self.assertIsNotNone(suwin)
                dialogs = ne_dialogs(suwin.read_bytes())
                logic = LOGIC.read_text()
                ids = {name: int(logic.split(f'#define {name}')[1].split()[0], 0)
                       for name in ('PID_EDIT_ID', 'PID_LABEL_ID', 'PID_ADVANCED_ID', 'PID_IGNORE_ID')}
                oem = dict(dialogs[604])
                self.assertEqual(oem.get(ids['PID_EDIT_ID']), 'Edit')
                self.assertIn(ids['PID_LABEL_ID'], oem)
                self.assertNotIn(ids['PID_ADVANCED_ID'], oem)
                # every other page with the edit has the Advanced button: no match
                for rid, ctrls in dialogs.items():
                    c = dict(ctrls)
                    if rid != 604 and c.get(ids['PID_EDIT_ID']) == 'Edit' and ids['PID_LABEL_ID'] in c:
                        self.assertIn(ids['PID_ADVANCED_ID'], c, rid)
                box = dict(dialogs[156])
                self.assertEqual([box.get(1), box.get(ids['PID_IGNORE_ID']), box.get(2)], ['Button'] * 3)
                seen += 1
        if not seen:
            self.skipTest('no Windows 95 RTM media')


if __name__ == '__main__':
    unittest.main()
