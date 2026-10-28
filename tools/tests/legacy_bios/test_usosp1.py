"""USOSP1.DRV (src/platform/bios/win9x/usosp1.c): the Windows Me native phase
1's end fixes, done by a Win16 installable driver in Setup's own
mini-Windows when it ends (before Setup's restart).

Always: the text edits of usosp1_logic.h compiled for the host with zig cc
and compared byte for byte with what the VM path's w9x_phase1_patch_c
(tools/w9x_phase1_qemu.sh, Git sh) makes of the same files; source checks
(the messages it acts on, no file work in WEP, what the target script keeps).
With the pinned OpenWatcom in tools/cache/openwatcom: the driver builds
without the C runtime and imports KERNEL only; with the user's Me medium
(read-only): every import resolves against the Me mini-Windows KRNL386.EXE of
MINI.CAB, and that MINI.CAB takes the driver (w9x_mini.zig) as USOSPID.DRV."""
from pathlib import Path
import os
import shutil
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
DRIVER = SRC / 'usosp1.c'
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'
ME_ISO = ('Windows ME/Windows ME PL OEM.iso', 'WIN9X/MINI.CAB')

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include "usosp1_logic.h"
/* m IN OUT: p1_drop_mouse; l IN OUT: p1_add_logo; s IN OUT: p1_set_mousedrv. Prints "status removed";
 * OUT is written only for P1_CHANGED. */
static char in[P1_MAX + 2], out[P1_MAX + P1_SLACK];
int main(int argc, char **argv)
{
    FILE *f = fopen(argv[2], "rb");
    unsigned n, len = 0, removed = 0;
    int r;
    if (!f) return 2;
    n = (unsigned)fread(in, 1, sizeof(in), f);
    fclose(f);
    r = argv[1][0] == 'm' ? p1_drop_mouse(in, n, out, &len, &removed)
      : argv[1][0] == 's' ? p1_set_mousedrv(in, n, out, &len) : p1_add_logo(in, n, out, &len);
    if (r == P1_CHANGED) {
        f = fopen(argv[3], "wb");
        fwrite(out, 1, len, f);
        fclose(f);
    }
    printf("%d %u\n", r, removed);
    return 0;
}
'''

INIS = [
    # the BIOSTAR/X470 98 SE disk after phase 1 (as test_w9x_phase1_qemu.py)
    b'[boot]\r\nmouse.drv=mouse.drv\r\n[386Enh]\r\nebios=*ebios\r\nmouse=*vmouse, msmouse.vxd\r\n'
    b'woafont=dosapp.fon\r\n[mci]\r\nmouse=keep\r\n',
    # Me after phase 1: [386Enh] before the device lines, case and blanks
    b'[boot]\r\ndrivers=mmsystem.dll usoskey.drv\r\n\r\n  [386ENH]  \r\nMaxPhysPage=40000\r\n'
    b'display=*vdd,*vflatd\r\nkeyboard=*vkd\r\n  MOUSE = *vmouse, msmouse.vxd\r\ndevice=*vmouse\r\n'
    b'mousesomething=1\r\n[drivers32]\r\nmouse=x\r\n',
    # two sections named 386Enh, a last line without CR LF
    b'[386Enh]\r\nmouse=a\r\n[x]\r\nmouse=b\r\n[386enh]\r\nmouse\t=c',
    # nothing to do
    b'[boot]\r\nmouse.drv=mouse.drv\r\n[386Enh]\r\ndevice=*vmouse\r\n',
    b'',
]
MSDOS = [
    b'[Paths]\r\nWinDir=C:\\WINDOWS\r\n\r\n[Options]\r\nBootMulti=1\r\nBootGUI=1\r\nWinVer=4.90.3000\r\n;\r\n;xxxxxxxxxxa\r\n',
    b'[options]\r\nBootGUI=1\r\n[OPTIONS]\r\n',
    b'[Options]\r\nlogo=1\r\n',           # a user's Logo= stays
    b'[Paths]\r\n  Logo = 1\r\n[Options]\r\n',
    b'[Paths]\r\nWinDir=C:\\WINDOWS\r\n',  # no [Options]
    b' [Options]\r\nBootGUI=1\r\n',        # not at the line start: no match
]


def _sh():
    import test_w9x_phase1_qemu as q
    return q


class Logic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        depguard.require_zig()
        work = ROOT / 'zig-out/usosp1-test'
        work.mkdir(parents=True, exist_ok=True)
        (work / 'harness.c').write_text(HARNESS)
        cls.exe = work / 'usosp1.exe'
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-O1', '-Wall', '-Werror', '-I', str(SRC),
                        str(work / 'harness.c'), '-o', str(cls.exe)], check=True,
                       env={**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(ROOT / 'tools/cache/zig-global')})

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-usosp1-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def edit(self, mode, data):
        src, dst = self.tmp / 'in', self.tmp / 'out'
        src.write_bytes(data)
        if dst.exists():
            dst.unlink()
        status, removed = subprocess.run([str(self.exe), mode, str(src), str(dst)], capture_output=True, text=True,
                                         check=True).stdout.split()
        return int(status), int(removed), dst.read_bytes() if dst.exists() else data

    def vm_patch(self, ini=None, msdos=None):
        """What w9x_phase1_patch_c (the VM path) makes of the same files."""
        q = _sh()
        c, run = self.tmp / 'c', self.tmp / 'run'
        shutil.rmtree(c, ignore_errors=True)
        (c / 'WINDOWS').mkdir(parents=True)
        run.mkdir(exist_ok=True)
        if ini is not None:
            (c / 'WINDOWS/SYSTEM.INI').write_bytes(ini)
        if msdos is not None:
            (c / 'MSDOS.SYS').write_bytes(msdos)
        rc, out, err = q.sh(f'. "{q.LIB}"\nw9x_phase1_patch_c "{c.as_posix()}"', {'W9X_VM_RUN': run.as_posix()})
        self.assertEqual(rc, 0, err)
        return ((c / 'WINDOWS/SYSTEM.INI').read_bytes() if ini is not None else None,
                (c / 'MSDOS.SYS').read_bytes() if msdos is not None else None)

    def test_system_ini_matches_the_vm_path(self):
        for ini in INIS:
            with self.subTest(ini=ini[:40]):
                status, removed, got = self.edit('m', ini)
                want, _ = self.vm_patch(ini=ini)
                self.assertEqual(got, want)
                self.assertEqual(status, 1 if got != ini else 0)
                self.assertEqual(removed, ini.count(b'\n') + (not ini.endswith(b'\n') and bool(ini)) -
                                 want.count(b'\n') - (not want.endswith(b'\n') and bool(want)))
        self.assertEqual(self.edit('m', INIS[1])[2],
                         b'[boot]\r\ndrivers=mmsystem.dll usoskey.drv\r\n\r\n  [386ENH]  \r\nMaxPhysPage=40000\r\n'
                         b'display=*vdd,*vflatd\r\nkeyboard=*vkd\r\ndevice=*vmouse\r\nmousesomething=1\r\n'
                         b'[drivers32]\r\nmouse=x\r\n')
        self.assertEqual(self.edit('m', INIS[2])[:2], (1, 2))

    def test_msdos_sys_matches_the_vm_path(self):
        for msdos in MSDOS:
            with self.subTest(msdos=msdos[:40]):
                status, _, got = self.edit('l', msdos)
                _, want = self.vm_patch(msdos=msdos)
                self.assertEqual(got, want)
        self.assertEqual([self.edit('l', m)[0] for m in MSDOS], [1, 1, 2, 2, 3, 3])
        self.assertEqual(self.edit('l', MSDOS[0])[2],
                         MSDOS[0].replace(b'[Options]\r\n', b'[Options]\r\nLogo=0\r\nBootLog=1\r\n'))
        # once: the result has a Logo= line
        once = self.edit('l', MSDOS[0])[2]
        self.assertEqual(self.edit('l', once)[0], 2)

    def test_me_mouse_drv(self):
        # X470 Me PL 2026-10-28: the first start after phase 1 had Setup's mouse.drv=mouse.drv (no USB mouse)
        cases = (
            (b'[boot]\r\nmouse.drv=mouse.drv\r\n[386Enh]\r\nmouse.drv=x\r\n', 1,
             b'[boot]\r\nmouse.drv=usosmous.drv\r\n[386Enh]\r\nmouse.drv=x\r\n'),
            (b'[boot]           \r\nshell=Explorer.exe\r\n  MOUSE.DRV = mouse.drv\r\nkeyboard.drv=keyboard.drv\r\n', 1,
             b'[boot]           \r\nshell=Explorer.exe\r\nmouse.drv=usosmous.drv\r\nkeyboard.drv=keyboard.drv\r\n'),
            (b'[boot]\r\nshell=Explorer.exe\r\n[386Enh]\r\n', 1,
             b'[boot]\r\nmouse.drv=usosmous.drv\r\nshell=Explorer.exe\r\n[386Enh]\r\n'),
            (b'[boot]', 1, b'[boot]\r\nmouse.drv=usosmous.drv\r\n'),
            (b'[boot]\r\nmouse.drv= USOSMOUS.DRV \r\n', 0, None),
            (b'[386Enh]\r\nmouse=x\r\n', 3, None),
            (b'[boot]\r\nmouse.drv=usosmous.drv2\r\n', 1, b'[boot]\r\nmouse.drv=usosmous.drv\r\n'),
        )
        for ini, status, want in cases:
            with self.subTest(ini=ini[:40]):
                got_status, _, got = self.edit('s', ini)
                self.assertEqual(got_status, status)
                self.assertEqual(got, want if want is not None else ini)
        # once: the result is left alone; after the [386Enh] mouse= drop (the driver's order)
        once = self.edit('s', cases[0][0])[2]
        self.assertEqual(self.edit('s', once)[0], 0)
        dropped = self.edit('m', INIS[1])[2]
        status, _, both = self.edit('s', dropped)
        self.assertEqual(status, 1)
        self.assertTrue(both.startswith(b'[boot]\r\nmouse.drv=usosmous.drv\r\ndrivers=mmsystem.dll usoskey.drv\r\n'))
        self.assertNotIn(b'MOUSE = *vmouse', both)
        self.assertEqual(self.edit('s', b'[boot]\r\n' + b';' * 16000)[0], 4)

    def test_too_big_is_left_alone(self):
        big = b'[386Enh]\r\nmouse=x\r\n' + b';' * 16000
        self.assertEqual(self.edit('m', big)[:2], (4, 0))
        self.assertEqual(self.edit('l', b'[Options]\r\n' + b';' * 16000)[0], 4)


class Source(unittest.TestCase):
    def test_driver_messages_and_files(self):
        c = DRIVER.read_text(encoding='utf-8')
        self.assertTrue(c.isascii())
        for name in ('INI_FILE  "C:\\\\WINDOWS\\\\SYSTEM.INI"', 'DOS_FILE  "C:\\\\MSDOS.SYS"', 'LOG_FILE  "C:\\\\USOS9X\\\\USOSP1.TXT"'):
            self.assertIn('#define ' + name, c)
        proc = c[c.index('DriverProc('):c.index('int FAR PASCAL __export __loadds WEP(')]
        for msg, event in (('DRV_EXITSESSION', 'exitsession'), ('DRV_DISABLE', 'disable'), ('DRV_FREE', 'free')):
            self.assertIn(f'case {msg}:', proc)
            self.assertIn(f'fix("{event}")', proc)
        self.assertNotIn('fix(', proc[:proc.index('case DRV_EXITSESSION')])   # not at load / open
        wep = c[c.index('int FAR PASCAL __export __loadds WEP('):]
        self.assertNotIn('fix(', wep)
        self.assertNotIn('OpenFile', wep)
        # read-only cleared only around the write, the attributes restored
        logo = c[c.index('static void fix_logo(void)'):c.index('static void log_line(void)')]
        self.assertLess(logo.index('dos_setattr(path, attr & ~1u)'), logo.index('r = store(olen);'))
        self.assertLess(logo.index('r = store(olen);'), logo.index('dos_setattr(path, attr);'))
        # in place with a zero-length write as the cut (keeps the entry)
        store = c[c.index('static int store(unsigned len)'):c.index('static void fix_ini(void)')]
        self.assertIn('OpenFile(path, &of, OF_WRITE)', store)
        self.assertIn('_lwrite(f, out, 0)', store)
        self.assertNotIn('OF_CREATE', store)
        # nothing on the stack handed out by address (SS != DS)
        self.assertNotIn('&len', c)
        self.assertNotIn('&removed', c)
        for banned in ('WritePrivateProfileString', 'GetPrivateProfileString', 'MessageBox', 'WinExec', 'lstrcmp'):
            self.assertNotIn(banned, c)

    def test_me_mouse_switch_and_diagnostics(self):
        c = DRIVER.read_text(encoding='utf-8')
        self.assertIn(r'#define MOUSE_DRV "C:\\WINDOWS\\SYSTEM\\USOSMOUS.DRV"', c)
        self.assertIn(r'#define MOUSE_INF "C:\\USOS9X\\USOSMOUS.INF"', c)
        ini = c[c.index('static void fix_ini(void)'):c.index('static char modname[80];')]
        # the [386Enh] drop first, then mouse.drv only with the Me mouse staged; one write
        self.assertLess(ini.index('p1_drop_mouse('), ini.index('p1_set_mousedrv('))
        self.assertIn('r = me_mouse_staged() ? p1_set_mousedrv(in, len, out, &olen) : P1_SAME;', ini)
        self.assertEqual(ini.count('store('), 1)
        self.assertLess(ini.index('copy_path(INI_FILE);'), ini.index('store(len)'))
        staged = c[c.index('static int me_mouse_staged(void)'):c.index('static void fix_ini(void)')]
        self.assertIn('copy_path(MOUSE_DRV);', staged)
        self.assertIn('copy_path(MOUSE_INF);', staged)
        self.assertEqual(staged.count('OF_EXIST'), 2)
        # diagnostics: read only; INT 33h only with VBMOUSE.DRV as module MOUSE, never a reset
        diag = c[c.index('static void mouse_diag(void)'):c.index('static void fix_logo(void)')]
        self.assertIn('GetModuleHandle("MOUSE")', diag)
        self.assertLess(diag.index('"VBMOUSE.DRV"'), diag.index('int 33h'))
        self.assertIn('mov ax, 0024h', diag)
        self.assertIn('mov ax, 0003h', diag)
        for banned in ('mov ax, 0000h', 'mov ax, 0021h', 'OpenFile', 'store('):
            self.assertNotIn(banned, diag)
        proc = c[c.index('DriverProc('):c.index('int FAR PASCAL __export __loadds WEP(')]
        self.assertIn('case DRV_ENABLE:      diag("enable"); return 1L;', proc)
        install = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='utf-8', errors='replace')
        self.assertIn(r'COPY /Y C:\USOS9X\USOSMOUS.DRV C:\WINDOWS\SYSTEM >NUL', install)
        self.assertIn(r'ECHO [Version]>C:\USOS9X\USOSMOUS.INF', install)

    def test_me_phase1_xms_manager(self):
        # Me's floppy has no HIMEM.SYS: HimemX (port 92h) instead of Setup's XMSMMGR.EXE, native phase 1 only
        text = TARGET.read_text(encoding='utf-8')
        block = text[text.index("if mdir -i \"$floppy\" ::/HIMEM.SYS"):text.index("printf 'FILES=40")]
        self.assertIn('elif [ "$SYSTEM_TAG" = ME ] && [ "$VM_PHASE1" != 1 ] && [ -f "$ESP_DIR/dos-native/msdos/HIMEMX.EXE" ]; then', block)
        self.assertIn(r"printf 'DEVICE=C:\\USOS9X\\HIMEMX.EXE /MAX=32768 /X2MAX32 /METHOD:PORT92\r\n'", block)
        self.assertIn('cp "$ESP_DIR/dos-native/msdos/HIMEMX.EXE" "$work/c/USOS9X/HIMEMX.EXE"', block)
        # CREGFIX first, then the XMS manager, as on 98 / 98 SE
        self.assertLess(text.index("printf 'DEVICE=C:\\\\USOS9X\\\\CREGFIX.SYS\\r\\n' >> \"$work/CONFIG.SYS\""),
                        text.index("if mdir -i \"$floppy\" ::/HIMEM.SYS"))
        self.assertIn('payload_zip\tEFI/USOS/dos-native/msdos/HIMEMX.EXE\n',
                      (ROOT / 'tools/tests/golden/staged_payloads.tsv').read_text(encoding='utf-8'))

    def test_staged_with_the_win9x_support(self):
        import build_win9x_support as b
        self.assertIn('USOSP1.DRV', b.STAGED)
        self.assertNotIn('USOSP1.DRV', b.FILES)
        self.assertEqual(b.USOSP1_IMPORTS, {'KERNEL'})
        self.assertIn("'EFI/USOS/dos-native/win9x/USOSP1.DRV'",
                      (ROOT / 'tools/verify_release_consistency.ps1').read_text(encoding='utf-8'))
        self.assertIn('{`zig-out/dos-native/win9x/USOSP1.DRV`, `EFI/USOS/dos-native/win9x/USOSP1.DRV`}',
                      (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8'))


class Target(unittest.TestCase):
    """The target script keeps USOSP1.DRV for Me with a native phase 1 only,
    and only when the mini-Windows step put it into MINI.CAB."""

    def block(self, start, end):
        text = TARGET.read_text(encoding='utf-8')
        a = text.index(start)
        return text[a:text.index(end, a)]

    def run_block(self, block, d, **env):
        q = _sh()
        script = 'set -eu\nlog() { printf "%s\\n" "$*"; }\n' + ''.join(f'{k}={v}\n' for k, v in env.items()) + \
                 f'work="{d.as_posix()}"\n' + block
        rc, out, err = q.sh(script)
        self.assertEqual(rc, 0, err)
        return out

    def test_kept_for_me_native_only(self):
        block = self.block('# Windows Me with a native phase 1: the VM path', '# Display: the answer')
        for tag, vm, kept in (('ME', '0', True), ('ME', '1', False), ('98SE', '0', False), ('95', '0', False)):
            with self.subTest(tag=tag, vm=vm):
                d = Path(tempfile.mkdtemp(prefix='usos-usosp1-target-'))
                self.addCleanup(shutil.rmtree, d, ignore_errors=True)
                (d / 'c/USOS9X').mkdir(parents=True)
                (d / 'c/USOS9X/USOSP1.DRV').write_bytes(b'MZ')
                out = self.run_block(block, d, SYSTEM_TAG=tag, VM_PHASE1=vm)
                self.assertEqual((d / 'c/USOS9X/USOSP1.DRV').exists(), kept)
                self.assertEqual('me phase 1 end: USOSP1.DRV for the mini-Windows' in out, kept)

    def test_removed_without_the_mini_windows_helper(self):
        block = self.block('# USOSP1.DRV (above) only inside this MINI.CAB', '\n# NVMe target')
        for bridge, mini, kept in (('1', 'p1=on\r\npid=off\r\nbridge=on\r\n', True), ('1', 'p1=off\r\npid=off\r\nbridge=on\r\n', False),
                                   ('0', 'p1=on\r\npid=off\r\nbridge=on\r\n', False), ('1', None, False)):
            with self.subTest(bridge=bridge, mini=mini):
                d = Path(tempfile.mkdtemp(prefix='usos-usosp1-mini-'))
                self.addCleanup(shutil.rmtree, d, ignore_errors=True)
                (d / 'c/USOS9X').mkdir(parents=True)
                (d / 'c/USOS9X/USOSP1.DRV').write_bytes(b'MZ')
                if mini is not None:
                    (d / 'c/USOS9X/USOSMINI.TXT').write_bytes(mini.encode())
                self.run_block(block, d, mini_bridge=bridge)
                self.assertEqual((d / 'c/USOS9X/USOSP1.DRV').exists(), kept)

    def test_order(self):
        text = TARGET.read_text(encoding='utf-8')
        # after the helpers are copied, before the mini-Windows step reads them
        self.assertLess(text.index('for file in "$HELPERS"/*; do'), text.index('# Windows Me with a native phase 1: the VM path'))
        self.assertLess(text.index('# Windows Me with a native phase 1: the VM path'), text.index('usos-fb-ui --w9x-setup-mini'))
        self.assertLess(text.index('usos-fb-ui --w9x-setup-mini'), text.index("grep -qx 'p1=on'"))


def _openwatcom():
    import build_win3_usb_keyboard as k
    home = k.OW_CACHE / ('ow-' + k.OW_SNAPSHOT['sha256'][:12])
    return (home / 'binnt64/wcc.exe').is_file()


@unittest.skipUnless(_openwatcom(), 'pinned OpenWatcom not unpacked in tools/cache/openwatcom')
class Build(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import build_win9x_support as b
        cls.tmp = Path(tempfile.mkdtemp(prefix='usos-usosp1-build-'))
        (cls.tmp / 'out').mkdir()
        (cls.tmp / 'work').mkdir()
        cls.drv = b.build_usosp1(cls.tmp / 'out', cls.tmp / 'work').read_bytes()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_ne_driver(self):
        import test_w9x_setup_mini as m
        from build_win3_usb_keyboard import ne_imported_modules
        self.assertEqual(self.drv[:2], b'MZ')
        self.assertEqual(set(ne_imported_modules(self.drv)), {'KERNEL'})
        exports = m.ne_exports(self.drv)
        for name in ('DRIVERPROC', 'WEP'):
            self.assertIn(name, exports)

    def me_mini(self):
        import test_w9x_setup_mini as m
        iso, member = ME_ISO
        if not m.SEVEN.exists() or not (m.MEDIA / iso).exists():
            self.skipTest('7-Zip or the Windows Me PL medium missing')
        d = self.tmp / 'me'
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir()
        subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(m.MEDIA / iso), member], capture_output=True)
        cab = next(d.glob('[Mm][Ii][Nn][Ii].[Cc][Aa][Bb]'), None)
        self.assertIsNotNone(cab)
        return m, d, cab

    def test_imports_resolve_in_the_me_mini_windows(self):
        m, _, cab = self.me_mini()
        _, files, _ = m.read_cab(cab.read_bytes())
        self.assertIn('shell=w9xsetup.bin', files['SYSTEM.INI'][0].decode('latin1'))
        kernel = m.ne_exports(files['KRNL386.EXE'][0])
        imports = m.ne_imports(self.drv)
        self.assertTrue(imports)
        for mod, what in sorted(imports, key=str):
            self.assertEqual(mod, 'KERNEL')
            self.assertIn(what, kernel, f'{mod}.{what}')

    def test_me_mini_cab_gets_the_helper(self):
        import test_w9x_setup_mini as m
        if not m._tool() or not m.VBMOUSE_DRV.exists():
            self.skipTest('zig build win3x-display-tool')
        m, d, cab = self.me_mini()
        if cab.name != 'MINI.CAB':
            cab.rename(d / 'MINI.CAB')
        helpers = self.tmp / 'helpers'
        shutil.rmtree(helpers, ignore_errors=True)
        helpers.mkdir()
        (helpers / 'USOSKEY.DRV').write_bytes(b'MZ USOSKEY test stand-in')
        shutil.copyfile(m.VBMOUSE_DRV, helpers / 'VBMOUSE.DRV')
        (helpers / 'USOSP1.DRV').write_bytes(self.drv)
        r = subprocess.run([str(m._tool()), 'w9x-mini', str(d), str(helpers)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        log = (helpers / 'USOSMINI.TXT').read_text().splitlines()
        self.assertEqual(log[-3:], ['p1=on', 'pid=off', 'bridge=on'])
        _, files, _ = m.read_cab((d / 'MINI.CAB').read_bytes())
        self.assertEqual(files['USOSP1.DRV'][0], self.drv)
        self.assertIn('\r\ndrivers=usoskey.drv usosp1.drv\r\n', files['SYSTEM.INI'][0].decode('latin1'))


if __name__ == '__main__':
    unittest.main()
