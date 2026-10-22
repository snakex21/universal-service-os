"""tools/nt4/usosusb 1.4-nt4: USB sticks on Windows NT 4.0 (and NT 3.5x, the
same binary) through the driver that already owns the xHCI for the keyboard
and mouse. Host-only, no Microsoft files: binary markers and imports (NT 4.0
RTM / SP6a / TSE and NT 3.51 export-name fixtures), the real volume
publishing code of msc_attach run on the host against stick images (zig cc,
UBSan; NT4 and NT6 builds), and the NT4 flow (DRIVERS.REG Parameters, the
usb-storage-off.txt switch in the prepare step).
"""
from __future__ import annotations
from pathlib import Path
import shutil, struct, subprocess, sys, tempfile, unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import check_nt4_driver_imports as nt4  # noqa: E402

DRV = ROOT / 'tools/nt4/usosusb'
SYS = DRV / 'bin/i386/usosusb.sys'
SRC = DRV / 'src/usosusb.c'
README = DRV / 'README.md'
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
PREPARE = ROOT / 'tools/w9x_csmwrap_prepare.sh'
FIXTURES = ['nt4rtm_exports.txt', 'nt4sp6a_exports.txt', 'nt4tse_exports.txt', 'nt351_exports.txt']


class Binary(unittest.TestCase):
    def test_imports_resolve_on_nt4_and_nt351(self):
        for name in FIXTURES:
            r = nt4.check(nt4.parse((HERE / 'data' / name).read_text()), [SYS])['usosusb.sys']
            self.assertEqual(r['missing'], [], name)
            self.assertEqual(r['modules'], ['hal.dll', 'ntoskrnl.exe'], name)
            self.assertEqual(r['subsystem'], '4.00')

    def test_storage_path_markers(self):
        data = SYS.read_bytes()
        for text in ('usosusb 1.4-nt4', '\\Device\\UsosUsbDisk', '\\DosDevices\\X:', 'LogFile', 'Storage'):
            self.assertIn(text.encode('utf-16-le'), data, text)
        # Windows 2000+ only: mount manager, ...SpecifyCache, thread hard error mode
        for name in (b'MmMapLockedPagesSpecifyCache', b'IoSetThreadHardErrorMode', b'MmGetSystemRoutineAddress',
                     b'IoBuildDeviceIoControlRequest'):
            self.assertNotIn(name, data)
        self.assertNotIn('MountPointManager'.encode('utf-16-le'), data)

    def test_nt31_build_has_no_storage(self):
        self.assertNotIn('UsosUsbDisk'.encode('utf-16-le'), (DRV / 'bin/nt31/i386/usosusb.sys').read_bytes())


class Source(unittest.TestCase):
    def test_structure(self):
        text = SRC.read_text(encoding='utf-8')
        nt4blk = text[text.index('#define USOSUSB_VERSION L"usosusb 1.4-nt4"'):]
        nt4blk = nt4blk[:nt4blk.index('#endif')]
        self.assertIn('#define USOSUSB_MSC 1', nt4blk)
        self.assertIn('#define USOSUSB_NT4MSC 1', nt4blk)
        nt31 = text[text.index('#ifdef USOSUSB_NT31\n/* NT 3.1'):text.index('#elif defined(USOSUSB_NT6)')]
        self.assertNotIn('USOSUSB_MSC', nt31)
        # NT 4.0 rejects OBJ_KERNEL_HANDLE (Windows 2000 attribute)
        nt4mm = text[text.index('#else /* USOSUSB_NT4MSC'):text.index('#endif /* USOSUSB_NT6 */')]
        self.assertNotIn('OBJ_KERNEL_HANDLE', nt4mm)
        self.assertIn('IoCreateSymbolicLink(&ul, &ud)', nt4mm)
        self.assertIn('IoDeleteSymbolicLink(&ul)', nt4mm)
        self.assertIn("letter_used(L'C')", nt4mm)          # no stick letter before the boot letters
        self.assertIn('g_storage && b[off + 3] == 0 && b[off + 5] == 8', text)
        self.assertIn('q[0].Name = L"Storage";', text)
        self.assertIn('q[1].Name = L"LogFile";', text)

    def test_hub_paths(self):
        # sticks behind hubs (usosusb hubs, 2026-10-21): the attach sits in
        # dev_enum (root and hub ports), the volume removal hangs off
        # dev_drop (root port unplug, hub port disconnect, hub subtree drop)
        text = SRC.read_text(encoding='utf-8')
        def body(sig):
            s = text[text.index(sig):]
            return s[:s.index('\n}\n')]
        enum = body('static DEV *dev_enum(HC *hc, DEV *hub, ULONG p, ULONG speed)\n{')
        self.assertIn('!kind && g_storage && b[off + 3] == 0 && b[off + 5] == 8', enum)
        self.assertIn('msc_attach(d);', enum)
        drop = body('static void dev_drop(DEV *d)\n{')
        self.assertIn('msc_detach(d);', drop)
        self.assertLess(drop.index('dev_drop(c);'), drop.index('msc_detach(d);'))   # children first
        self.assertEqual(text.count('msc_detach(d);'), 1)
        self.assertEqual(text.count('msc_attach(d);'), 1)
        det = body('static void msc_detach(DEV *d)\n{')
        self.assertIn('mount_queue(v, 0);', det)
        self.assertIn('d->vol[i] = NULL;', det)                 # no second removal
        self.assertIn('d->nvol = 0;', det)
        self.assertIn('if (!d->used)\n        return;', drop)
        pres = body('static int port_present(DEV *d)\n{')
        self.assertIn('!d->gone', pres)
        self.assertIn('d->rport - 1', pres)
        # the NT 4.0 log names the stick by its path (p5, p5.2 behind a hub)
        self.assertIn('L"%c: = %s (%s, usb %04x:%04x, "', text)

    def test_readme(self):
        text = README.read_text(encoding='utf-8')
        self.assertIn('## USB mass storage on NT 4.0', text)
        self.assertIn('usb-storage-off.txt', text)
        self.assertIn('FAT32', text)


def find_zig() -> str | None:
    for cand in (ROOT / 'tools/zig/zig.exe', ROOT.parent.parent / 'Desktop/usos-x470-98se/tools/zig/zig.exe',
                 ROOT.parent.parent / 'Desktop/Universal_Service_OS/tools/zig/zig.exe'):
        if cand.exists():
            return str(cand)
    return shutil.which('zig')


def _bpb(oem: bytes, jmp: bytes = b'\xEB\x3C\x90') -> bytearray:
    s = bytearray(512)
    s[0:3] = jmp
    s[3:11] = oem.ljust(8)
    s[510:512] = b'\x55\xAA'
    return s


def fat16_bs(total: int) -> bytes:
    s = _bpb(b'MSDOS5.0')
    struct.pack_into('<HBHBHHBH', s, 11, 512, 4, 1, 2, 512, total if total < 65536 else 0, 0xF8, 16)
    struct.pack_into('<I', s, 32, total if total >= 65536 else 0)
    struct.pack_into('<I', s, 39, 0x1234ABCD)
    s[54:62] = b'FAT16   '
    return bytes(s)


def fat32_bs(total: int) -> bytes:
    s = _bpb(b'MSWIN4.1', b'\xEB\x58\x90')
    struct.pack_into('<HBHBHHBH', s, 11, 512, 8, 32, 2, 0, 0, 0xF8, 0)
    struct.pack_into('<II', s, 32, total, 1000)
    struct.pack_into('<I', s, 67, 0x0BADF00D)
    s[82:90] = b'FAT32   '
    return bytes(s)


def ntfs_bs() -> bytes:
    s = _bpb(b'NTFS    ', b'\xEB\x52\x90')
    struct.pack_into('<HB', s, 11, 512, 8)
    return bytes(s)


def exfat_bs() -> bytes:
    return bytes(_bpb(b'EXFAT   ', b'\xEB\x76\x90'))


def image(parts=(), lba0: bytes | None = None, secs: int = 16384) -> bytes:
    img = bytearray(secs * 512)
    if lba0 is not None:
        img[0:512] = lba0
        return bytes(img)
    mbr = bytearray(512)
    struct.pack_into('<I', mbr, 440, 0xCAFEBABE)
    for i, (ptype, start, count, bs) in enumerate(parts):
        e = 446 + i * 16
        mbr[e] = 0x80 if i == 0 else 0
        mbr[e + 4] = ptype
        struct.pack_into('<II', mbr, e + 8, start, count)
        if bs:
            img[start * 512:start * 512 + 512] = bs
    mbr[510:512] = b'\x55\xAA'
    img[0:512] = mbr
    return bytes(img)


class VolumeHostSimulation(unittest.TestCase):
    """The real volume publishing code of msc_attach (between "volumes: begin"
    and "volumes: end") with is_boot_sector / fs_kind / nt4_fs_ok, cut out of
    usosusb.c and run against stick images; tools/tests/nt4usb/vol_host.c
    supplies scsi_rw (reads the image), vol_create / gpt_volumes / diag_add
    (print what the driver would do)."""

    @classmethod
    def setUpClass(cls):
        zig = find_zig()
        if not zig:
            raise unittest.SkipTest('zig not found')
        text = SRC.read_text(encoding='utf-8')
        le32 = next(l for l in text.splitlines() if l.startswith('static ULONG le32('))
        ibs = text[text.index('static int is_boot_sector('):]
        ibs = ibs[:ibs.index('\n}\n') + 3]
        helpers = text[text.index('/* What a boot sector holds'):text.index('/* worker, after SET_CONFIGURATION')]
        block = text[text.index('    /* volumes: begin'):text.index('    /* volumes: end */')]
        cls.tmp = tempfile.mkdtemp(prefix='nt4usb-')
        Path(cls.tmp, 'pieces.h').write_text('\n'.join(['#define FS_FAT 1', '#define FS_NTFS 2', '#define FS_FAT32 3',
                                                        '#define FS_EXFAT 4', '#define FS_OTHER 5', le32, ibs, helpers]))
        Path(cls.tmp, 'block.h').write_text(block)
        cls.exe = {}
        for mode, defs in (('nt4', ['-DUSOSUSB_NT4MSC']), ('nt6', [])):
            exe = str(Path(cls.tmp, f'vol_{mode}.exe'))
            r = subprocess.run([zig, 'cc', '-std=c99', '-O1', '-g', '-fsanitize=undefined', '-fno-sanitize-recover=all',
                                '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-Wno-unused-parameter',
                                *defs, '-I', cls.tmp, '-DUSOSUSB_PIECES="pieces.h"', '-DUSOSUSB_BLOCK="block.h"',
                                str(HERE / 'nt4usb/vol_host.c'), '-o', exe], cwd=cls.tmp,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if r.returncode:
                raise AssertionError(r.stdout)
            cls.exe[mode] = exe

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_img(self, img: bytes, mode: str = 'nt4') -> list[str]:
        f = Path(self.tmp, 'stick.img')
        f.write_bytes(img)
        out = subprocess.run([self.exe[mode], str(f)], check=True, stdout=subprocess.PIPE, text=True).stdout
        return [l for l in out.splitlines() if not l.startswith('reads')]

    def test_mbr_fat16(self):
        self.assertEqual(self.run_img(image([(0x06, 63, 8000, fat16_bs(8000))])),
                         ['vol start=63 count=8000 type=06 boot=80 sig=cafebabe fs=1'])

    def test_mbr_fat16_and_ntfs(self):
        out = self.run_img(image([(0x0E, 63, 4000, fat16_bs(4000)), (0x07, 4096, 8000, ntfs_bs())]))
        self.assertEqual(out, ['vol start=63 count=4000 type=0e boot=80 sig=cafebabe fs=1',
                               'vol start=4096 count=8000 type=07 boot=00 sig=cafebabe fs=2'])

    def test_fat32_exfat_raw_skipped_on_nt4_kept_on_nt6(self):
        img = image([(0x0C, 63, 4000, fat32_bs(4000)), (0x07, 4096, 4000, exfat_bs()), (0x06, 8192, 4000, None)])
        self.assertEqual(self.run_img(img), ['diag  p1:fat32-skip', 'diag  p2:exfat-skip', 'diag  p3:other-skip'])
        self.assertEqual(len([l for l in self.run_img(img, 'nt6') if l.startswith('vol ')]), 3)

    def test_extended_and_beyond_the_end_ignored(self):
        out = self.run_img(image([(0x05, 63, 4000, None), (0x06, 20000, 100, None), (0x06, 4096, 9000, fat16_bs(9000))]))
        self.assertEqual(out, ['vol start=4096 count=9000 type=06 boot=00 sig=cafebabe fs=1'])

    def test_superfloppy(self):
        self.assertEqual(self.run_img(image(lba0=fat16_bs(16384))),
                         ['vol start=0 count=16384 type=06 boot=00 sig=1234abcd fs=1'])
        self.assertEqual(self.run_img(image(lba0=fat32_bs(16384))), ['diag  p0:fat32-skip'])
        self.assertEqual(self.run_img(image(lba0=ntfs_bs())), ['vol start=0 count=16384 type=07 boot=00 sig=00000000 fs=2'])
        # NT6 unchanged: FAT32 superfloppy kept as type 0C
        self.assertEqual(self.run_img(image(lba0=fat32_bs(16384)), 'nt6'),
                         ['vol start=0 count=16384 type=0c boot=00 sig=0badf00d fs=3'])

    def test_gpt_skipped_on_nt4_only(self):
        img = image([(0xEE, 1, 16383, None)])
        self.assertEqual(self.run_img(img), ['diag (gpt-skip)'])
        self.assertEqual(self.run_img(img, 'nt6'), ['gpt'])

    def test_bad_mbr_status_byte(self):
        img = bytearray(image([(0x06, 63, 8000, fat16_bs(8000))]))
        img[446] = 0x81
        self.assertEqual(self.run_img(bytes(img)), [])


class Flow(unittest.TestCase):
    def test_drivers_reg_parameters(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('USB_STORAGE=${NT4_USB_STORAGE:-1}', text)
        blk = text[text.index('if [ "$USB_STORAGE" = 0 ]; then'):]
        blk = blk[:blk.index('# NVMe target')]
        self.assertIn('usb_storage_dword=00000000', blk)
        self.assertIn('usb_storage_dword=00000001', blk)
        self.assertIn('[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\usosusb\\Parameters]', blk)
        self.assertIn('"Storage"=dword:$usb_storage_dword', blk)

    @unittest.skipUnless(shutil.which('sh'), 'no sh')
    def test_drivers_reg_rendered(self):
        # the DRIVERS.REG fragment of the target script run by sh: REGEDIT4
        # wants the backslashes of LogFile doubled, CRLF lines.
        text = TARGET.read_text(encoding='utf-8')
        start = text.index('crlf >> "$usos/DRIVERS.REG" <<EOF\n\n[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\usosusb\\Parameters]')
        end = text.index('\nEOF\n', start) + 5
        crlf = next(l for l in text.splitlines() if l.startswith('crlf() {'))
        with tempfile.TemporaryDirectory() as tmp:
            for dword in ('00000001', '00000000'):
                Path(tmp, 's.sh').write_text(f'{crlf}\nusos=.\nusb_storage_dword={dword}\n{text[start:end]}', newline='\n')
                Path(tmp, 'DRIVERS.REG').unlink(missing_ok=True)
                subprocess.run(['sh', 's.sh'], cwd=tmp, check=True)
                reg = Path(tmp, 'DRIVERS.REG').read_bytes().decode('ascii')
                self.assertIn('"Storage"=dword:' + dword + '\r\n', reg)
                self.assertIn('"LogFile"="\\\\DosDevices\\\\C:\\\\USOS\\\\NT4\\\\USOSUSB.LOG"\r\n', reg)

    def test_prepare_passes_the_switch(self):
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('NT4_USB_STORAGE="$nt4usb"', text)
        blk = text[text.index('    nt4usb=1\n'):]
        blk = blk[:blk.index('usos_ui_stage 4 5')]
        self.assertIn('[ "$nt_major" = 4 ]', blk)
        self.assertIn('Unattended/usb-storage-off.txt', blk)
        self.assertIn('nt4usb=0', blk)


if __name__ == '__main__':
    unittest.main()
