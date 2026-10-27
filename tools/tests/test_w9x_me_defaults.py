"""Windows 9x CSMWrap flow defaults since the X470 Windows Me pass (2026-10-19):
USOSVMD.VXD (mouse in MS-DOS boxes; 95 / 98 / 98 SE / Me) and USOSLOG.EXE (silent
logger from the machine Run key), each with a DATA opt-out file (vmd-off.txt,
logging-off.txt; usb-storage-off.txt is in test_w9x_usb_storage_flag.py).

Host only (Git sh): the VMD and logging blocks of tools/w9x_csmwrap_target.sh run as
they are against a temp C:\\USOS9X; the prepare.sh opt-out files; the payload lists.
INSTALL.BAT's [USOS.CsmReg] lines are checked in legacy_bios/test_usosmous.py.
No VM, no disk."""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TARGET = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
PREPARE = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
U9ENV = b'SET U9SYS=ME\r\nSET U9DISK=1\r\n'
VMD_INF = (b'; USOS: the USB mouse in MS-DOS boxes (USOSVMD.VXD, a VMOUSE minidriver).\r\n'
           b'; Machine RunOnce runs it once after Setup; effective from the next start.\r\n'
           b'; Off: delete both device= lines in SYSTEM.INI [386Enh].\r\n'
           b'[Version]\r\nSignature="$CHICAGO$"\r\n[DefaultInstall]\r\nUpdateInis=USOS.Vmd.Ini\r\n'
           b'[USOS.Vmd.Ini]\r\nsystem.ini,386Enh,,"device=*vmouse"\r\n'
           b'system.ini,386Enh,,"device=C:\\USOS9X\\USOSVMD.VXD"\r\n')


def cut(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a) + len(end)]


BLOCK = cut(TARGET, '# The mouse in MS-DOS boxes (VMD=1)',
            "[ \"$log_ok\" = 1 ] || log 'logging: USOSLOG.EXE stays in C:\\USOS9X (not started)'\n")


class TargetBlocks(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-medef-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.c = self.tmp / 'work/c/USOS9X'
        self.c.mkdir(parents=True)
        (self.c / 'U9ENV.BAT').write_bytes(U9ENV)
        for name in ('USOSVMD.VXD', 'USOSMOUS.DRV', 'USOSLOG.EXE'):
            (self.c / name).write_bytes(b'stand-in ' + name.encode())

    def run_block(self, vmd=1, log=1, tag='ME', answer='USOS'):
        script = ('set -eu\nlog() { printf "%s\\n" "$*" >&2; }\n'
                  'fail() { printf "STOP %s\\n" "$1" >&2; exit 1; }\n'
                  f'work="{(self.tmp / "work").as_posix()}"\nVMD={vmd}\nLOGGING={log}\n'
                  f'SYSTEM_TAG={tag}\nANSWER_KIND={answer}\n' + BLOCK)
        path = self.tmp / 'block.sh'
        path.write_bytes(script.encode('utf-8'))
        rc, out, err = sh(f'. "{path.as_posix()}"')
        self.assertEqual(rc, 0, err)
        return err

    def names(self):
        return sorted(p.name for p in self.c.iterdir())

    def env(self):
        return (self.c / 'U9ENV.BAT').read_bytes()

    def test_defaults_on_98_98se_me(self):
        for tag in ('ME', '98SE', '98'):
            for answer in ('USOS', 'PROFILE'):
                with self.subTest(tag=tag, answer=answer):
                    self.setUp()
                    err = self.run_block(tag=tag, answer=answer)
                    self.assertEqual(self.names(), ['U9ENV.BAT', 'USOSLOG.EXE', 'USOSMOUS.DRV', 'USOSVMD.INF',
                                                    'USOSVMD.ON', 'USOSVMD.VXD'])
                    self.assertEqual(self.env(), U9ENV + b'SET U9VMD=1\r\nSET U9LOG=1\r\n')
                    self.assertEqual((self.c / 'USOSVMD.INF').read_bytes(), VMD_INF)
                    on = (self.c / 'USOSVMD.ON').read_bytes()
                    self.assertTrue(on.startswith(b'USOSVMD.VXD (VMOUSE mode) on.') and on.endswith(b'.\r\n'))
                    self.assertEqual((self.c / 'USOSVMD.VXD').read_bytes(), b'stand-in USOSVMD.VXD')
                    self.assertIn('vmd-off.txt turns it off', err)
                    self.assertIn('logging-off.txt turns it off', err)

    def test_on_95_too(self):
        # 95 (2026-10-20): same files; the RunOnce value and the PS/2 devnode
        # flags come from REG95.REG (test_w9x_reg95.py), not [USOS.CsmReg].
        for answer in ('USOS', 'PROFILE'):
            with self.subTest(answer=answer):
                self.setUp()
                err = self.run_block(tag='95', answer=answer)
                self.assertEqual(self.names(), ['U9ENV.BAT', 'USOSLOG.EXE', 'USOSMOUS.DRV', 'USOSVMD.INF',
                                                'USOSVMD.ON', 'USOSVMD.VXD'])
                self.assertEqual(self.env(), U9ENV + b'SET U9VMD=1\r\nSET U9LOG=1\r\n')
                self.assertEqual((self.c / 'USOSVMD.INF').read_bytes(), VMD_INF)
                self.assertIn('RunOnce USOSVMD.INF from REG95.REG, PS/2 mouse devnode off', err)
                self.assertNotIn('not tested there', err)
        self.setUp()
        err = self.run_block(tag='95', answer='USER')
        self.assertEqual(self.names(), ['U9ENV.BAT', 'USOSLOG.EXE', 'USOSMOUS.DRV'])
        self.assertIn("user's own answer file", err)

    def test_user_answer(self):
        err = self.run_block(tag='98SE', answer='USER')
        self.assertEqual(self.names(), ['U9ENV.BAT', 'USOSLOG.EXE', 'USOSMOUS.DRV'])
        self.assertEqual(self.env(), U9ENV)
        self.assertIn("user's own answer file", err)
        self.assertIn('USOSLOG.EXE stays in C:\\USOS9X (not started)', err)

    def test_opt_outs(self):
        err = self.run_block(vmd=0, log=0)
        self.assertEqual(self.names(), ['U9ENV.BAT', 'USOSLOG.EXE', 'USOSMOUS.DRV'])
        self.assertEqual(self.env(), U9ENV)
        self.assertNotIn('vmd-off.txt turns it off', err)
        self.setUp()
        self.run_block(vmd=1, log=0)
        self.assertEqual(self.env(), U9ENV + b'SET U9VMD=1\r\n')
        self.setUp()
        self.run_block(vmd=0, log=1)
        self.assertEqual(self.env(), U9ENV + b'SET U9LOG=1\r\n')
        self.assertNotIn('USOSVMD.VXD', self.names())

    def test_missing_payload(self):
        (self.c / 'USOSMOUS.DRV').unlink()
        (self.c / 'USOSLOG.EXE').unlink()
        err = self.run_block()
        self.assertEqual(self.names(), ['U9ENV.BAT'])
        self.assertEqual(self.env(), U9ENV)
        self.assertIn('USOSVMD.VXD or USOSMOUS.DRV is not in this payload', err)
        self.assertIn('USOSLOG.EXE is not in this payload', err)

    def test_wiring(self):
        self.assertIn('VMD=${W9X_VMD:-0}', TARGET)
        self.assertIn('LOGGING=${W9X_LOGGING:-0}', TARGET)
        # after the helpers and U9ENV.BAT, after the USOSUSB block, before the int13 decision
        self.assertLess(TARGET.index('for file in "$HELPERS"/*; do'), TARGET.index('vmd_ok=0'))
        self.assertLess(TARGET.index('uds_ok=0'), TARGET.index('vmd_ok=0'))
        self.assertLess(TARGET.index('log_ok=0'), TARGET.index('int13_only=off'))


class Prepare(unittest.TestCase):
    def test_opt_out_files(self):
        gate = PREPARE[PREPARE.index('    usb9x=0\n'):PREPARE.index("    usos_ui_stage 4 5 'Preparing the disk'")]
        self.assertIn('[ -f "$unattended/vmd-off.txt" ]', gate)
        self.assertIn('[ -f "$unattended/logging-off.txt" ]', gate)
        self.assertIn('else\n            vmd9x=1', gate)
        self.assertIn('else\n            log9x=1', gate)
        self.assertIn('W9X_USB_STORAGE="$usb9x" W9X_VMD="$vmd9x" W9X_LOGGING="$log9x"', PREPARE)
        self.assertEqual(PREPARE.count('W9X_VMD='), 1)
        self.assertEqual(PREPARE.count('W9X_LOGGING='), 1)


class Payload(unittest.TestCase):
    def test_lists(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_win9x_support as b
        for name in ('USOSVMD.VXD', 'USOSLOG.EXE'):
            self.assertIn(name, b.STAGED)
            self.assertNotIn(name, b.FILES)      # not on the Legacy Core RAM disk
        self.assertIn('USOSVMD.VXD', b.BRIDGE)   # copied from the MS-DOS support build
        go = (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8')
        ps1 = (ROOT / 'tools/verify_release_consistency.ps1').read_text(encoding='utf-8-sig')
        for name in ('USOSVMD.VXD', 'USOSLOG.EXE'):
            self.assertIn(f'{{`zig-out/dos-native/win9x/{name}`, `EFI/USOS/dos-native/win9x/{name}`}}', go)
            self.assertIn(f"'EFI/USOS/dos-native/win9x/{name}'", ps1)
        build = (ROOT / 'tools/build_win9x_support.py').read_text(encoding='utf-8')
        # build() makes USOSDBG.EXE and USOSLOG.EXE; the Setup mini-Windows
        # drivers (USOSPID.DRV, USOSP1.DRV) are built between them
        self.assertIn('    build_usosdbg(out, work)\n    build_usospid(out, work)\n'
                      '    build_usosp1(out, work)\n    build_usoslog(out, work)\n', build)
        # reproducible: the link time is not kept
        self.assertIn("raw[pe + 8:pe + 12] = (0).to_bytes(4, 'little')", build)


if __name__ == '__main__':
    unittest.main()
