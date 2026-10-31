"""Native NT 3.5 round (2026-10-30): host checks of the NT 3.5 native path.

usosrst 1.7-nt35 (shutdown log, quiesce, CF9h, RAM marker, ACPI S5),
usosnet35n (NT 3.51 native NDIS code on NDIS 3.5), the native NT 3.5 LAN
wiring, the Standard PC HAL / UP kernel rows on the NT 3.5 TXTSETUP.SIF
shape, the RAM cap, and the boot-screen rows gated on /SOS.
"""
from pathlib import Path
import subprocess
import shutil
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_nt52_driver_imports import pe  # noqa: E402
from check_nt4_driver_imports import parse  # noqa: E402

TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
NL = chr(10)


def tables():
    t = parse((ROOT / 'tools/tests/data/nt35_exports.txt').read_text(encoding='utf-8'))
    t.update(parse((ROOT / 'tools/tests/data/nt35_ndis_exports.txt').read_text(encoding='utf-8')))
    return t


def missing(rel, view):
    _, imports = pe(ROOT / rel)
    return [f'{m}!{n}' for m, n in imports if n not in view.get(m.lower(), {})]


def bash():
    for name in ('sh', 'bash'):
        found = shutil.which(name)
        if found:
            return found
    return None


class Nt35NativeDrivers(unittest.TestCase):
    def test_usosrst_nt35_restart_and_power_off(self):
        src = (ROOT / 'tools/w2k/usosrst/src/usosrst.c').read_text(encoding='latin-1')
        block = src[src.index('#elif defined(USOSRST_NT35)'):src.index('#define USOSRST_VERSION "usosrst 1.8-nt351"')]
        for want in ('"usosrst 1.7-nt35"', '#define USOSRST_SHUTLOG 1', '#define USOSRST_RAMLOG 1',
                     '#define USOSRST_POWEROFF 1', '#define USOSRST_INLINE 1'):
            self.assertIn(want, block)
        binary = (ROOT / 'tools/w2k/usosrst/bin/nt35/i386/usosrst.sys').read_bytes()
        for want in (b'usosrst 1.7-nt35', b' s5', b' osd+', 'LoadLine'.encode('utf-16-le')):
            self.assertIn(want, binary)
        t = tables()
        for kernel, hal in (('ntoskrnl.exe', 'hal.dll'), ('ntkrnlmp.exe', 'halmps.dll')):
            view = {'ntoskrnl.exe': t[kernel], 'hal.dll': t[hal]}
            self.assertEqual(missing('tools/w2k/usosrst/bin/nt35/i386/usosrst.sys', view), [], kernel)

    def test_usosnet35n_resolves_on_ndis35(self):
        t = tables()
        view = {'ndis.sys': t['ndis.sys'], 'ntoskrnl.exe': t['ntoskrnl.exe'], 'hal.dll': t['hal.dll']}
        self.assertEqual(missing('tools/nt/usosnet/bin/i386/usosnet35n.sys', view), [])
        # usosnet351n needs NDIS 3.51 services NT 3.5 lacks: hence the own build.
        self.assertTrue(missing('tools/nt/usosnet/bin/i386/usosnet351n.sys', view))
        sources = (ROOT / 'tools/nt/usosnet/src35n/sources').read_text(encoding='utf-8')
        self.assertIn('-DUSOSNET_NT351=1 -DUSOSNET_NT35N=1', sources)
        src = (ROOT / 'tools/nt/usosnet/src/usosnet.c').read_text(encoding='latin-1')
        nt35n = src[src.index('#if USOSNET_NT35N' + NL + '    /* native NT 3.5'):]
        nt35n = nt35n[:nt35n.index('#elif USOSNET_NT35')]
        self.assertIn('if (!Cf8Find(A))', nt35n)
        self.assertNotIn('LegacyFind', nt35n)
        build = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn("'usr/lib/usos/nt3/USOSNET35N.SYS'", build)

    def test_usosnt3_resolves_on_nt35(self):
        t = tables()
        view = {'kernel32.dll': t['kernel32.dll'], 'advapi32.dll': t['advapi32.dll']}
        self.assertEqual(missing('tools/nt3/usosnt3/bin/i386/usosnt3.exe', view), [])

    def test_usosnt3_native_nt35(self):
        src = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='latin-1')
        self.assertIn('(minor == 50 && GetFileAttributesA(DIR "NET35.ON") != 0xFFFFFFFF)', src)
        self.assertIn('if (!net351_hal_pci()) {', src[src.index('static int nt35_network(void)'):])
        self.assertIn('"PowerdownAfterShutdown", "1", 0);', src)
        self.assertIn('if (net351_version() == 50)', src)


class Nt35NativeTarget(unittest.TestCase):
    def test_lan_wiring_and_source_patch(self):
        text = TARGET.read_text(encoding='utf-8')
        lan = text.index('if [ "$NATIVE" = 1 ] && [ "$major:$minor" = 3:50 ]; then')
        self.assertIn('usos_nt35_preflight "$work/WINNT.SIF" "$LIB" "${USOS_PCI_ROOT:-/sys/bus/pci/devices}" native',
                      text[lan:lan + 800])
        patch = text.index('usos_nt35_source_patch "$ls_src" "$work"')
        self.assertLess(patch, text.index('cp "$work/WINNT.SIF" "$bt_dir/WINNT.SIF"'))
        lib = (ROOT / 'tools/nt35_network_setup.sh').read_text(encoding='utf-8')
        self.assertIn('_u35_sys=$_u35_lib/nt3/USOSNET35N.SYS', lib)
        self.assertIn('37e16b22d26d7717a91c63cd1d26be4c7b4977d76214de63980831ae547c7cb0) echo '
                      'fff3c06dad680983a3389d906c8d81daa918f0cf191ad2cdbb3fa3894fd327cf', lib)

    def test_ram_cap_and_no_numproc(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn("yes:50) ram_cap=8 ram_oct='\\010' ;;", text)
        self.assertIn('[ "$minor" != 50 ] || NT_NATIVE_LOAD_OPTIONS=${NT35_NATIVE_LOAD_OPTIONS:-/MAXMEM=128}', text)

    @unittest.skipUnless(bash(), 'sh missing')
    def test_standard_hal_on_nt35_shape(self):
        # The NT 3.5 CD's rows (shape only): mps11_mp, Multiprocessor with a
        # rename to ntoskrnl.exe; the Uniprocessor row replaces it.
        text = TARGET.read_text(encoding='utf-8')
        fn = text[text.index('nt3_standard_hal() {'):]
        fn = fn[:fn.index(NL + '}' + NL) + 3]
        sif = NL.join(['[SpecialFiles]', 'Multiprocessor = ntkrnlmp.exe,2,ntoskrnl.exe', 'Uniprocessor   = ntoskrnl.exe,2',
                       '', '[hal]', 'e_isa_up    = hal.dll     ,2,hal.dll', 'mps11_mp    = halmps.dll  ,2,hal.dll', ''])
        r = subprocess.run([bash(), '-c', fn + NL + 'nt3_standard_hal'], input=sif.encode(), capture_output=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout.decode().replace(chr(13), '')
        self.assertIn('Multiprocessor = ntoskrnl.exe,2', out)
        self.assertIn('mps11_mp = hal.dll    ,2,hal.dll', out)
        self.assertNotIn('ntkrnlmp', out)
        self.assertNotIn('halmps', out)


class BootScreenRows(unittest.TestCase):
    def test_rows_only_with_sos(self):
        rst = (ROOT / 'tools/w2k/usosrst/src/usosrst.c').read_text(encoding='latin-1')
        self.assertIn('if (!g_Sos && Attr != 0x4F00) return;', rst)
        self.assertIn('g_Sos = BootHasSos();', rst)
        ahci = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcisatl.c').read_text(encoding='latin-1')
        self.assertIn('if (!g_UsosSos && attr != 0x4F00) return;', ahci)
        nvme = (ROOT / 'tools/nt/usosnvme/src/usosnvme.c').read_text(encoding='latin-1')
        self.assertIn('if (!Error && !g_NvmeSos) return;', nvme)
        for text in (rst, ahci, nvme):
            self.assertIn('SystemStartOptions', text)
            self.assertIn('Registry' + chr(92) * 2 + 'Machine', text)
        for rel in ('tools/vendor/ahcint/1.3.0.0-usos4/bin/NT351/i386/ahcint.sys',
                    'tools/vendor/ahcint/1.3.0.0-usos4/bin/NT4/i386/ahcint.sys',
                    'tools/vendor/ahcint/1.3.0.0-usos4/bin/NT31/i386/ahcint.sys',
                    'tools/nt/usosnvme/bin/NT351/i386/usosnvme.sys',
                    'tools/nt/usosnvme/bin/NT4/i386/usosnvme.sys',
                    'tools/nt/usosnvme/bin/NT31/i386/usosnvme.sys',
                    'tools/w2k/usosrst/bin/nt351/i386/usosrst.sys',
                    'tools/w2k/usosrst/bin/nt4n/i386/usosrst.sys'):
            self.assertIn('SystemStartOptions'.encode('utf-16-le'), (ROOT / rel).read_bytes(), rel)


if __name__ == '__main__':
    unittest.main()


class Nt35Kbdclass(unittest.TestCase):
    """X470 2026-10-30 (B261030-125748): Kbdclass failed (7026; Kbdclass 8
    C000000E, 7) on native NT 3.5: its kbdclass keeps the appended port
    number after a failed connect (KeyboardPort0 = i8042prt without a PS/2
    keyboard), so usosusb must load first and own KeyboardPort0."""

    def test_usosusb_group_base_on_native_nt35(self):
        src = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='latin-1')
        fn = src[src.index('static const char *usb_group(void)' + NL + '{'):]
        fn = fn[:fn.index(NL + '}' + NL)]
        self.assertIn('native_install() && net351_version() == 50', fn)
        self.assertIn('"Base" : "Keyboard Port"', fn)
        self.assertEqual(src.count('set_sz("usosusb", "Group", REG_SZ, usb_group());'), 2)
        self.assertNotIn('set_sz("usosusb", "Group", REG_SZ, "Keyboard Port");', src)
        self.assertIn(b'Base', (ROOT / 'tools/nt3/usosnt3/bin/i386/usosnt3.exe').read_bytes())
