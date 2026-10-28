"""usosmpart on Vista / Server 2008 SP2 x64 (CSMWrap path, test mode),
host-only, no Microsoft files (docs/vista-x64-usb-multipartition-2026-10-21.md):

- tools/nt/usosmpart/bin/NT6/amd64: native AMD64 driver, NT 6.0 subsystem
  version, the same import set as the x86 / WNET builds, no CRT or /GS;
- tools/build_usosnvme_nt6_signed.py signs it with the amd64 package's
  per-build certificate in the same session;
- tools/build_windows_vista_support.py packs it (embedded signature
  required) as usosmpart-amd64.sys;
- tools/windows_vista_mpart.h (mock registry / files): service rows,
  disk class LowerFilters append, both control sets, restore on failure;
- tools/windows_vista_install.c: called after testsigning was set and only on
  the CSMWrap path.
"""
from pathlib import Path
import importlib.util, shutil, struct, subprocess, sys, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_usosmpart as mp

NT6 = ROOT / 'tools/nt/usosmpart/bin/NT6/amd64/usosmpart.sys'


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VistaX64Mpart(unittest.TestCase):
    def test_nt6_amd64_binary(self):
        raw = NT6.read_bytes()
        nt = struct.unpack_from('<I', raw, 0x3c)[0]
        opt = nt + 24
        self.assertEqual(struct.unpack_from('<H', raw, nt + 4)[0], 0x8664)
        self.assertEqual(struct.unpack_from('<H', raw, opt)[0], 0x20b)
        self.assertEqual(struct.unpack_from('<H', raw, opt + 68)[0], 1)  # native
        self.assertEqual(struct.unpack_from('<HH', raw, opt + 48), (6, 0))  # WLH target
        # Unsigned in git: the release build signs a copy.
        self.assertEqual(struct.unpack_from('<II', raw, opt + 112 + 4 * 8), (0, 0))
        machine, imports = mp.imports(raw)
        self.assertEqual(set(imports), {'ntoskrnl.exe'})
        names = set(imports['ntoskrnl.exe'])
        self.assertLessEqual(names, mp.IMPORTS)
        self.assertFalse(names & {'__security_check_cookie', '__C_specific_handler', '_allmul'})
        self.assertIn(b'U\0S\0O\0S\0', raw)  # version resource

    def test_build_cmd_target(self):
        cmd = (ROOT / 'tools/nt/usosmpart/build.cmd').read_text()
        self.assertIn('if /i "%ARCH%"=="nt6x64" set "ENVARGS=fre x64 WLH no_oacr" & set "OBJ=amd64" & set "OUT=NT6\\amd64"', cmd)
        self.assertIn('call "%~f0" nt6x64 "%~2"', cmd)

    def test_signing_includes_filter(self):
        sign = (ROOT / 'tools/build_usosnvme_nt6_signed.py').read_text(encoding='utf-8')
        self.assertIn("MPART_AMD64 = 'tools/nt/usosmpart/bin/NT6/amd64/usosmpart.sys'", sign)
        self.assertIn("shutil.copyfile(root / MPART_AMD64, out / 'usosmpart.sys')", sign)
        self.assertIn("USOS_SIGN_EXTRA=';'.join(extras)", sign)
        # Signed and verified in the session that deletes the key afterwards.
        ps = load('sign', 'tools/build_usosnvme_nt6_signed.py').PS_SIGN
        self.assertLess(ps.index('foreach ($extra in $extras)'), ps.index('} finally {'))
        self.assertIn("foreach ($f in (@('usosnvme.sys', 'usosnvme.cat') + $extras))", ps)
        self.assertIn("'usosnvme.cer', *extras)", sign)
        # x86 package: no filter (32-bit Windows needs no signature).
        self.assertIn("if arch == 'amd64':\n        # Same certificate", sign)

    def test_vista_support_requires_signed_filter(self):
        vista = load('vista_support', 'tools/build_windows_vista_support.py')
        src = (ROOT / 'tools/build_windows_vista_support.py').read_text(encoding='utf-8')
        self.assertIn("writer.add_file('usosmpart-amd64.sys', mpart_file)", src)
        raw = bytearray(NT6.read_bytes())
        self.assertFalse(vista.signed_amd64_image(bytes(raw)))
        nt = struct.unpack_from('<I', raw, 0x3c)[0]
        struct.pack_into('<II', raw, nt + 24 + 112 + 4 * 8, len(raw), 8)
        self.assertTrue(vista.signed_amd64_image(bytes(raw)))
        x86 = (ROOT / 'tools/nt/usosmpart/bin/i386/usosmpart.sys').read_bytes()
        self.assertFalse(vista.signed_amd64_image(x86))
        self.assertFalse(vista.signed_amd64_image(b''))

    def test_installer_wiring(self):
        c = (ROOT / 'tools/windows_vista_install.c').read_text(encoding='utf-8')
        self.assertIn('#include "windows_vista_mpart.h"', c)
        main = c[c.index('void entry(void){'):]
        boot = main.index('configure_boot_bios(target,&system_is_staging)')
        nvme = main.index('if(!install_nvme64(target))')
        call = main.index('if(!install_mpart64(target))logcode(')
        self.assertLess(boot, call)
        self.assertLess(nvme, call)
        h = (ROOT / 'tools/windows_vista_mpart.h').read_text(encoding='utf-8')
        self.assertIn('if(!csmwrap)return TRUE;', h)
        x86 = (ROOT / 'tools/windows_x86_csmwrap.cmd').read_text(encoding='utf-8')
        # Same service rows as the x86 :mpart_reg.
        for name, value in (('Type', '1'), ('Start', '0'), ('ErrorControl', '1')):
            self.assertIn('reg add "%%USOS_SVC%%" /v %s /t REG_DWORD /d %s /f' % (name, value), x86)
            self.assertIn('mp64_dword(hive,key,L"%s",%s)' % (name, value), h)
        self.assertIn('L"Group",REG_SZ,L"Filter"', h)

    def test_offline_registry_mock(self):
        gcc = shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        out = ROOT / 'zig-out/amd64-host-tests'
        out.mkdir(parents=True, exist_ok=True)
        exe = out / 'vista-mpart64-mocks.exe'
        subprocess.run([gcc, '-std=c99', '-Wall', '-Werror', str(ROOT / 'tools/tests/vista_mpart64_harness.c'), '-ladvapi32', '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == '__main__':
    unittest.main()
