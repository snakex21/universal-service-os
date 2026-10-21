"""amd64 NT6 ABI and address carry; no Microsoft binaries required."""
from pathlib import Path
import importlib.util, os, re, shutil, struct, subprocess, sys, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_nt52_driver_imports import pe

class Amd64(unittest.TestCase):
    def test_setup_compatibility_preparation_fails_closed(self):
        gcc = shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        out = ROOT / 'zig-out/amd64-host-tests'; out.mkdir(parents=True, exist_ok=True)
        exe = out / 'vista-nvme-setup-mocks.exe'
        subprocess.run([gcc, '-std=c99', '-Wall', str(ROOT / 'tools/tests/vista_nvme_setup_harness.c'), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)

    def test_trust_and_package_staging_failures(self):
        source=(ROOT/'tools/windows_vista_oobe_gate.c').read_text()
        start=source.index('static BOOL nvme_stage(void)')
        function=source[start:source.index('\n#endif',start)]
        parent=ROOT/'zig-out/amd64-host-tests';parent.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as tmp:
            folder=Path(tmp);(folder/'nvme_stage_under_test.h').write_text(function)
            exe=folder/'stage.exe'
            subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-O2','-I'+str(folder),str(ROOT/'tools/tests/vista_nvme_stage_harness.c'),'-lkernel32','-ladvapi32','-lcrypt32','-o',str(exe)],check=True,capture_output=True)
            subprocess.run([str(exe)],check=True,capture_output=True)

    def test_gate_requires_profile_and_packaged_driver(self):
        # No DATA flag: the x64 profile opens NVMe when vista-support.cpio
        # carries the test-signed amd64 package (usosnvme-amd64.ready).
        sh = shutil.which('sh') or r'C:\Program Files\Git\bin\sh.exe'
        sys.path.insert(0, str(ROOT / 'tools'))
        from build_windows_native_cache import NewcWriter
        parent = ROOT / 'zig-out/amd64-host-tests'; parent.mkdir(parents=True, exist_ok=True)
        source = (ROOT / 'tools/vista_csmwrap_prepare.sh').read_text()
        function = source[source.index('vista_nvme64_enabled() {'):]
        function = function[:function.index('\n}')+2]
        self.assertNotIn('nvme-experimental', function)
        with tempfile.TemporaryDirectory(dir=parent) as tmp:
            root = Path(tmp); script = root / 'gate.sh'; script.write_text(function+'\nvista_nvme64_enabled "$1" "$2"\n',newline='\n')
            def archive(name, entries):
                w = NewcWriter(root / name)
                try:
                    for e in entries: w.add_bytes(e, b'1\r\n')
                finally:
                    w.close()
                return (root / name).as_posix()
            # micro-Linux has cpio; the host may not: a newc lister stands in for `cpio -it`.
            fake = root / 'bin'; fake.mkdir()
            (fake / 'lister.py').write_text('''import sys
d = sys.stdin.buffer.read(); i = 0
while i + 110 <= len(d):
    n = int(d[i+94:i+102], 16); size = int(d[i+54:i+62], 16)
    name = d[i+110:i+110+n-1].decode(); i = (i + 110 + n + 3) & ~3
    if name == 'TRAILER!!!': break
    print(name); i = (i + size + 3) & ~3
''')
            (fake / 'cpio').write_text('#!/bin/sh\n[ "$1" = -it ] || exit 9\nexec "%s" "%s"\n' % (Path(sys.executable).as_posix(), (fake / 'lister.py').as_posix()), newline='\n')
            env = dict(os.environ, PATH=fake.as_posix() + os.pathsep + os.environ.get('PATH', ''))
            def call(profile, cpio):
                return subprocess.run([sh, '-c', 'PATH="%s:$PATH"; . "%s"' % (fake.as_posix(), script.as_posix()), 'gate', profile, cpio], capture_output=True, env=env).returncode
            profile = 'vista-x64-sp2-uefi-csmwrap'
            ready = archive('ready.cpio', ['usos-vista-install.exe', 'usosnvme-amd64.ready', 'usosnvme-nt6.sys'])
            sata = archive('sata.cpio', ['usos-vista-install.exe', 'usosnvme-amd64.ready.bak'])
            self.assertEqual(call(profile, ready), 0)
            self.assertNotEqual(call(profile, sata), 0)
            self.assertNotEqual(call(profile, (root / 'missing.cpio').as_posix()), 0)
            self.assertNotEqual(call('win-nt6-x86-uefi-csmwrap', ready), 0)
            self.assertNotEqual(call('win-x86-uefi-csmwrap', ready), 0)

    def test_target_testsigning_and_preflight_order(self):
        target = (ROOT / 'tools/vista_csmwrap_target.sh').read_text(encoding='utf-8')
        first_write = target.index('dd if=/dev/zero of="$TARGET_DEVICE"')
        pre = target.index('if [ "$X86_SELF" != 1 ] && [ "${USOS_PE_NVME:-}" = usosnvme ]; then')
        self.assertLess(pre, first_write)
        block = target[pre:first_write]
        for want in ('command -v usos-fb-ui', 'usosnvme-amd64.ready', 'usosnvme-nt6.sys', 'usosnvme.cat', 'usosnvme.cer', 'nvme64=1'):
            self.assertIn(want, block)
        edit = 'usos-fb-ui --bcd-testsigning "$work/bcd"'
        self.assertIn(edit, target)
        self.assertLess(target.index('cp "$bcd" "$work/bcd"'), target.index(edit))
        self.assertLess(target.index(edit), target.index('cp "$work/bcd" "$work/staging/boot/bcd"'))
        self.assertIn('case "$rc" in 0|10) ;; *) fail', target)
        # the PE copy of stornvme.sys becomes usosnvme for the x64 path too
        self.assertIn('if [ "$target_bus" = nvme ] && [ "${USOS_PE_NVME:-}" = usosnvme ]; then', target)

    def test_release_build_packages_amd64(self):
        native = (ROOT / 'tools/build_windows_native_support.py').read_text(encoding='utf-8')
        self.assertIn("build_usosnvme_nt6_signed(root, nvme64, arch='amd64')", native)
        self.assertIn('build_vista_support(root, nvme_package=nvme64)', native)
        vista = (ROOT / 'tools/build_windows_vista_support.py').read_text(encoding='utf-8')
        self.assertIn("writer.add_bytes('usosnvme-amd64.ready', b'1\\r\\n')", vista)
        self.assertIn("gate_flags = ['-DUSOS_GATE_NVME_X64', '-lcrypt32'] if nvme_files else []", vista)

    def test_offline_service_and_restore_on_mock_disk(self):
        gcc = shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        out = ROOT / 'zig-out/amd64-host-tests'; out.mkdir(parents=True, exist_ok=True)
        exe = out / 'vista-nvme64-mocks.exe'
        subprocess.run([gcc, '-std=c99', '-Wall', str(ROOT / 'tools/tests/vista_nvme64_harness.c'), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)

    def test_native_amd64_and_import_abi(self):
        path = ROOT / 'tools/nt/usosnvme/bin/NT6/amd64/usosnvme.sys'
        raw = path.read_bytes(); nt = struct.unpack_from('<I', raw, 0x3c)[0]
        self.assertEqual(struct.unpack_from('<H', raw, nt+4)[0], 0x8664)
        self.assertEqual(struct.unpack_from('<H', raw, nt+24)[0], 0x20b)
        self.assertEqual(struct.unpack_from('<H', raw, nt+24+68)[0], 1) # native
        self.assertEqual(struct.unpack_from('<HH', raw, nt+24+48), (6, 0))
        self.assertGreater(len(raw), 4096)
        self.assertLess(len(raw), 65536)
        exports, imports = pe(path)
        self.assertLessEqual({m for m,n in imports}, {'ntoskrnl.exe', 'scsiport.sys'})
        names = {n for m,n in imports}
        self.assertTrue({'ScsiPortInitialize', 'ScsiPortGetPhysicalAddress', 'MmMapIoSpace'} <= names)
        self.assertFalse(names & {'memcpy', 'memset', 'memmove', '_allmul', '_aulldiv', '__security_check_cookie'})
        self.assertTrue(all(not n.startswith('#') for m,n in imports))

    def test_amd64_inf_and_default_x86_unchanged(self):
        spec = importlib.util.spec_from_file_location('sign', ROOT / 'tools/build_usosnvme_nt6_signed.py')
        sign = importlib.util.module_from_spec(spec); spec.loader.exec_module(sign)
        default = sign.nt6_inf(ROOT)
        self.assertEqual(default, sign.nt6_inf(ROOT, arch='x86'))
        amd64 = sign.nt6_inf(ROOT, arch='amd64')
        self.assertIn(b'%USOS% = Nvme_Models, NTamd64\r\n', amd64)
        self.assertIn(b'[Nvme_Models.NTamd64]\r\n', amd64)
        self.assertNotIn(b'\n', amd64.replace(b'\r\n', b''))
        self.assertNotIn(b'[Nvme_Models]\r\n', amd64)
        self.assertIn(b'CatalogFile=usosnvme.cat', amd64)
        with self.assertRaises(ValueError): sign.nt6_inf(ROOT, arch='arm64')
        with self.assertRaises(ValueError): sign.nt6_inf(ROOT, True, 'amd64')
        # Argument refusals precede deletion/creation of any output folder.
        with self.assertRaises(ValueError):
            sign.build(ROOT, ROOT / 'should-never-be-created', modern=True, arch='amd64')
        with self.assertRaisesRegex(ValueError, 'unsafe signing output'):
            sign.build(ROOT, ROOT, arch='amd64')
        self.assertFalse((ROOT / 'should-never-be-created').exists())

    def test_physical_address_add_carry(self):
        gcc = shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        source = (ROOT / 'tools/nt/usosnvme/src/usosnvme.c').read_text()
        function = re.search(r'static SCSI_PHYSICAL_ADDRESS NvmePhysAdd\([^\n]+\)\n\{.*?\n\}', source, re.S).group()
        parent = ROOT / 'zig-out/amd64-host-tests'; parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as tmp:
            c = Path(tmp) / 'carry.c'; exe = Path(tmp) / 'carry.exe'
            c.write_text('''#include <stdint.h>
#include <assert.h>
typedef uint32_t ULONG;
typedef struct { uint32_t LowPart; int32_t HighPart; } SCSI_PHYSICAL_ADDRESS;
''' + function + '''
int main(void) {
 SCSI_PHYSICAL_ADDRESS a,b;
 a.LowPart=0xfffff000u; a.HighPart=0; b=NvmePhysAdd(a,0x1000u); assert(b.LowPart==0&&b.HighPart==1);
 a.LowPart=0xfffffff0u; a.HighPart=0x123; b=NvmePhysAdd(a,0x20u); assert(b.LowPart==0x10&&b.HighPart==0x124);
 a.LowPart=0x1000; a.HighPart=7; b=NvmePhysAdd(a,0x5000); assert(b.LowPart==0x6000&&b.HighPart==7);
 b=NvmePhysAdd(a,0); assert(b.LowPart==a.LowPart&&b.HighPart==a.HighPart);
 return 0;
}
''')
            subprocess.run([gcc, '-std=c99', '-Werror', '-Wall', '-Wextra', str(c), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

if __name__ == '__main__': unittest.main()
