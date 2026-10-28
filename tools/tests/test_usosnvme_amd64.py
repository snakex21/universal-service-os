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

    def test_amd64_prps_above_4g_and_refusals(self):
        # The amd64 PRP builder against a mock ScsiPort S/G lookup: 64-bit
        # pages above 4 GiB go out unmodified; anything the PRP model cannot
        # carry is refused before the controller sees it.
        gcc = shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        source = (ROOT / 'tools/nt/usosnvme/src/usosnvme.c').read_text()
        start = source.index('static BOOLEAN NvmePaUsable(')
        function = source[start:source.index('\n#endif', start)]
        rw = source[source.index('static ULONG NvmeRw('):]
        rw = rw[:rw.index('\n}\n')]
        # the amd64 branch of NvmeRw uses the builder; the x86 inline code stays
        self.assertIn('#elif defined(_WIN64)\n    refused = NvmeBuildPrps(', rw)
        self.assertIn('NVME_LOG_DMA_HIGH', rw)
        parent = ROOT / 'zig-out/amd64-host-tests'; parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as tmp:
            c = Path(tmp) / 'prps.c'; exe = Path(tmp) / 'prps.exe'
            c.write_text(r'''#include <stdint.h>
#include <assert.h>
#include <string.h>
typedef uint32_t ULONG; typedef ULONG *PULONG; typedef unsigned char UCHAR, *PUCHAR, BOOLEAN, *PBOOLEAN;
#define TRUE 1
#define FALSE 0
#define NVME_PAGE 4096UL
#define NVME_MAX_TRANSFER (128UL * 1024UL)
typedef struct { uint32_t LowPart; int32_t HighPart; } SCSI_PHYSICAL_ADDRESS;
typedef struct { ULONG Cdw0,Nsid,R2,R3,MptrLo,MptrHi,Prp1Lo,Prp1Hi,Prp2Lo,Prp2Hi,Cdw10,Cdw11,Cdw12,Cdw13,Cdw14,Cdw15; } NVME_SQE, *PNVME_SQE;
typedef struct { PULONG PrpList; SCSI_PHYSICAL_ADDRESS PrpListPhys; } HW_DEVICE_EXTENSION, *PHW_DEVICE_EXTENSION;
typedef struct SRB *PSCSI_REQUEST_BLOCK;
static _Alignas(4096) UCHAR buffer[40 * 4096];
static uint64_t page_pa[40];        /* physical page per buffer page; ~0 = no address */
static ULONG zero_len_page = 99, merge = 0;
static SCSI_PHYSICAL_ADDRESS ScsiPortGetPhysicalAddress(PHW_DEVICE_EXTENSION e, PSCSI_REQUEST_BLOCK s, void *va, ULONG *len) {
 (void)e; (void)s; SCSI_PHYSICAL_ADDRESS r; size_t off = (UCHAR *)va - buffer; size_t pg = off / 4096;
 uint64_t pa = page_pa[pg] == ~0ull ? ~0ull : page_pa[pg] + off % 4096;
 *len = pg == zero_len_page ? 0 : (ULONG)(4096 - off % 4096);
 while (merge && pg + 1 < 40 && page_pa[pg + 1] == page_pa[pg] + 4096) { *len += 4096; pg++; }
 r.LowPart = (uint32_t)pa; r.HighPart = (int32_t)(pa >> 32); return r;
}
''' + function + r'''
static ULONG list[512];
static HW_DEVICE_EXTENSION ext = { list, { 0x7ff3e000u, 0 } };
static NVME_SQE c; static BOOLEAN hi;
static uint64_t P(ULONG lo, ULONG h) { return ((uint64_t)h << 32) | lo; }
static ULONG run(ULONG offset, ULONG bytes) { memset(&c, 0, sizeof c); return NvmeBuildPrps(&ext, 0, buffer + offset, bytes, &c, &hi); }
int main(void) {
 for (int i = 0; i < 40; i++) page_pa[i] = 0x5ull * 0x100000000ull + 0x10000000ull + (uint64_t)(39 - i) * 0x3000; /* scattered, above 4 GiB */
 /* one page, offset 0x200: PRP1 only, both dwords */
 assert(run(0x200, 0xE00) == 0 && hi); assert(P(c.Prp1Lo, c.Prp1Hi) == page_pa[0] + 0x200 && !c.Prp2Lo && !c.Prp2Hi);
 /* two pages: PRP2 = second page, high dword kept */
 assert(run(0x200, 0x1000) == 0); assert(P(c.Prp2Lo, c.Prp2Hi) == page_pa[1]);
 /* 128 KiB from offset 0x200: 33 pages -> PRP list of 32 entries */
 memset(list, 0xAB, sizeof list);
 assert(run(0x200, 128 * 1024) == 0); assert(c.Prp2Lo == 0x7ff3e000u && c.Prp2Hi == 0);
 for (int i = 0; i < 32; i++) assert(P(list[2 * i], list[2 * i + 1]) == page_pa[1 + i]);
 assert(list[64] == 0xABABABABu);
 /* below 4 GiB: no high flag, same layout */
 for (int i = 0; i < 40; i++) page_pa[i] = 0x100000ull + (uint64_t)i * 0x2000;
 assert(run(0, 0x3000) == 0 && !hi); assert(P(c.Prp1Lo, c.Prp1Hi) == page_pa[0]);
 /* physically contiguous run (one S/G element over several pages) */
 for (int i = 0; i < 40; i++) page_pa[i] = 0x2ull * 0x100000000ull + (uint64_t)i * 4096;
 merge = 1;
 assert(run(0x40, 0x5000) == 0 && hi); assert(P(list[0], list[1]) == page_pa[1] && P(list[8], list[9]) == page_pa[5]);
 merge = 0;
 /* refusals; the PRP list page is not touched by a refused request */
 memset(list, 0xCD, sizeof list);
 page_pa[3] = ~0ull; assert(run(0x200, 0x8000) == 4); assert(list[0] == 0xCDCDCDCDu);   /* SP_UNINITIALIZED_VALUE */
 page_pa[3] = 0x2ull * 0x100000000ull + 3 * 4096;
 zero_len_page = 0; assert(run(0x200, 0x400) == 1); zero_len_page = 99;                    /* outside the S/G list */
 page_pa[0] = 0x0010000000000000ull; assert(run(0, 0x200) == 1);                           /* beyond 2^52 */
 page_pa[0] = 0x2ull * 0x100000000ull;
 page_pa[2] = page_pa[2] + 0x800; assert(run(0, 0x3000) == 3);                             /* later entry not page aligned */
 page_pa[2] = 0x2ull * 0x100000000ull + 2 * 4096;
 assert(run(0x202, 0x200) == 1);                                                           /* PRP1 not dword aligned */
 assert(run(0, 0) == 1);
 return 0;
}
''')
            r = subprocess.run([gcc, '-std=c11', '-Werror', '-Wall', '-Wextra', str(c), '-o', str(exe)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            subprocess.run([str(exe)], check=True)

    def test_amd64_binary_has_the_checked_prp_builder(self):
        # x86 builds keep their hardware-tested inline PRP code (no _WIN64 path)
        source = (ROOT / 'tools/nt/usosnvme/src/usosnvme.c').read_text()
        self.assertIn('#if defined(_WIN64) && !defined(USOSNVME_W9X)\n/* amd64', source)
        header = (ROOT / 'tools/nt/usosnvme/src/usosnvme.h').read_text()
        self.assertIn('NVME_LOG_DMA_HIGH    0x4E560009UL', header)
        self.assertIn('NVME_LOG_BAD_PA      0x4E56000AUL', header)

if __name__ == '__main__': unittest.main()
