"""tools/nt4/usosusb build-nt6: USB keyboard / mouse for the installed
Vista / Server 2008 SP2 x86 on xHCI-only machines (csmwrap-integration 12.6).
Host-only, no Microsoft files: the committed NT 6.0 binary imports only
kernel / HAL routines that the Server 2008 SP2 x86 kernels (ntoskrnl,
ntkrnlpa) and HALs (halmacpi, halacpi) export (export-name fixture), it is
the NT6 variant, and the x86 CSMWrap WinPE step installs it offline for
6.0.6002 only.
"""
from __future__ import annotations
from pathlib import Path
import re, struct, sys, unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import check_nt4_driver_imports as nt4  # noqa: E402
from check_nt52_driver_imports import pe, resolve  # noqa: E402

DRV = ROOT / 'tools/nt4/usosusb'
SYS = DRV / 'bin/nt6/i386/usosusb.sys'
SRC = DRV / 'src/usosusb.c'
CMD = ROOT / 'tools/windows_x86_csmwrap.cmd'
BUILD = ROOT / 'tools/build_windows_native_support.py'
FIXTURE = HERE / 'data/nt60sp2_x86_exports.txt'


class Binary(unittest.TestCase):
    def test_imports_resolve_on_server_2008_sp2_x86(self):
        tables = nt4.parse(FIXTURE.read_text())
        _, imports = pe(SYS)
        self.assertEqual(sorted({m for m, _ in imports}), ['hal.dll', 'ntoskrnl.exe'])
        for kernel in ('ntoskrnl.exe', 'ntkrnlpa.exe'):
            for hal in ('halmacpi.dll', 'halacpi.dll'):
                view = {'ntoskrnl.exe': (tables[kernel], []), 'hal.dll': (tables[hal], [])}
                missing = sorted({m for m in (resolve(view, mod, fn) for mod, fn in imports) if m})
                self.assertEqual(missing, [], f'{kernel}+{hal}')

    def test_nt6_variant(self):
        data = SYS.read_bytes()
        self.assertIn('usosusb 1.1-nt6'.encode('utf-16-le'), data)
        self.assertIn(b'HalGetBusDataByOffset', data)      # PCI through the HAL lock
        for name in (b'_snwprintf', b'__security_check_cookie', b'IoRegisterPlugPlayNotification', b'usbd.sys'):
            self.assertNotIn(name, data)
        p = struct.unpack_from('<I', data, 60)[0]
        self.assertEqual(struct.unpack_from('<H', data, p + 4)[0], 0x14C)    # i386
        self.assertEqual(struct.unpack_from('<H', data, p + 24 + 68)[0], 1)  # native subsystem

    def test_source_nt6_paths(self):
        text = SRC.read_text(encoding='utf-8')
        self.assertIn('defined(USOSUSB_NT6)', text)
        self.assertIn('L"Conn"', text)
        # NT 4.0 / 3.1 builds keep the CF8h/CFCh access and the ENABLE gate.
        self.assertRegex(text, r'#else\n/\* PCI configuration mechanism 1')
        self.assertIn('return x->enabled > 0;', text)


class MassStorage(unittest.TestCase):
    """USB sticks (bulk-only transport) as removable volumes, NT6 build only."""

    def test_binary_has_volume_path(self):
        data = SYS.read_bytes()
        for s in ('\\Device\\UsosUsbDisk%u', '\\Device\\MountPointManager', 'Msc',
                  '\\Registry\\Machine\\SYSTEM\\MountedDevices'):
            self.assertIn(s.encode('utf-16-le'), data, s)
        _, imports = pe(SYS)
        names = {fn for _, fn in imports}
        for fn in ('IoBuildDeviceIoControlRequest', 'IoGetDeviceObjectPointer', 'MmMapLockedPagesSpecifyCache',
                   'ExfInterlockedInsertTailList', 'ExfInterlockedRemoveHeadList', 'ZwOpenSymbolicLinkObject'):
            self.assertIn(fn, names)

    def test_source_bot_and_scsi(self):
        text = SRC.read_text(encoding='utf-8')
        self.assertIn('#define USOSUSB_MSC 1', text)
        # only the NT6 block defines it
        self.assertLess(text.index('defined(USOSUSB_NT6)'), text.index('#define USOSUSB_MSC 1'))
        self.assertLess(text.index('#define USOSUSB_MSC 1'), text.index('#define USOSUSB_VERSION L"usosusb 1.0-nt4"'))
        for needle in ('0x43425355', '0x53425355',            # CBW / CSW signatures
                       'b[off + 5] == 8 && b[off + 6] == 6 && b[off + 7] == 0x50',   # class 08/06/50
                       "cdb[0] = (UCHAR)(wr ? 0x2A : 0x28);",  # WRITE(10) / READ(10)
                       'cdb[0] = 0x25;', 'cdb[0] = 0x12;', 'cdb[0] = 0x1A;', 'cdb[0] = 0x03;',
                       'FILE_REMOVABLE_MEDIA', 'IOCTL_MOUNTMGR_VOLUME_ARRIVAL_NOTIFICATION',
                       'IOCTL_MOUNTMGR_CREATE_POINT', 'IOCTL_MOUNTMGR_DELETE_POINTS'):
            self.assertIn(needle, text)

    def test_nt4_builds_keep_the_old_path(self):
        # the committed NT 4.0 / 3.1 binaries carry no storage code
        for rel in ('bin/i386/usosusb.sys', 'bin/nt31/i386/usosusb.sys'):
            data = (DRV / rel).read_bytes()
            self.assertNotIn('UsosUsbDisk'.encode('utf-16-le'), data)


class Flow(unittest.TestCase):
    def step(self) -> str:
        text = CMD.read_text(encoding='utf-8')
        return text[text.index(':nt60_usb\n'):]

    def test_called_after_gate(self):
        text = CMD.read_text(encoding='utf-8')
        self.assertIn('call :nt60_gate\ncall :nt60_usb\n', text)

    def test_only_nt60_sp2(self):
        s = self.step()
        self.assertIn('if not "%USOS_NT%"=="6.0" exit /b 0', s)
        self.assertIn('if not "%USOS_BUILD%"=="6002"', s)
        self.assertLess(s.index('"6002"'), s.index('copy /y'))

    def test_service_registration(self):
        s = self.step()
        self.assertIn(r'copy /y "%~dp0usosusb-nt6.sys" "%USOS_T%\Windows\System32\drivers\usosusb.sys"', s)
        self.assertIn(r'reg load HKLM\USOS_SYS "%USOS_T%\Windows\System32\config\SYSTEM"', s)
        self.assertIn(r'ControlSet00%USOS_CS%\Services\usosusb', s)
        self.assertIn('/v Start /t REG_DWORD /d 1 ', s)
        self.assertIn('/v Type /t REG_DWORD /d 1 ', s)
        self.assertIn('/v Group /t REG_SZ /d "Keyboard Port"', s)
        self.assertIn(r'/v ImagePath /t REG_EXPAND_SZ /d "system32\drivers\usosusb.sys"', s)
        self.assertIn(r'reg unload HKLM\USOS_SYS', s)
        # never fatal
        self.assertNotRegex(s, r'exit /b [1-9]')

    def test_packed_into_modern_support(self):
        text = BUILD.read_text(encoding='utf-8')
        self.assertIn("writer.add_file('usosusb-nt6.sys', root / 'tools/nt4/usosusb/bin/nt6/i386/usosusb.sys')", text)


if __name__ == '__main__':
    unittest.main()
