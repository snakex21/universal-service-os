"""tools/nt4/usosusb: the NT 4.0 USB keyboard/mouse port driver (own GPL
code). Host-only, no Microsoft files: the committed binary is a PE 4.00
native driver whose imports resolve on the NT 4.0 RTM and SP6a kernels and
HALs (export-name fixtures in tools/tests/data), the scan code table holds
the usual set 1 codes, and the NT4 flow installs and registers the driver.
"""
from __future__ import annotations
from pathlib import Path
import re, sys, unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import check_nt4_driver_imports as nt4  # noqa: E402

DRV = ROOT / 'tools/nt4/usosusb'
SYS = DRV / 'bin/i386/usosusb.sys'
SRC = DRV / 'src/usosusb.c'
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
MICRO = ROOT / 'tools/build_micro_linux.py'
# RTM 1381.1, SP6a 1381.335, Terminal Server Edition 1381.32772 (RTM TSE CD).
FIXTURES = [HERE / 'data/nt4rtm_exports.txt', HERE / 'data/nt4sp6a_exports.txt', HERE / 'data/nt4tse_exports.txt']


def set1_table() -> list[int]:
    text = SRC.read_text(encoding='utf-8')
    body = re.search(r'g_set1\[0x68\] = \{(.*?)\};', text, re.S).group(1)
    body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)
    return [int(x, 0) for x in re.findall(r'0x[0-9A-Fa-f]+|\b\d+\b', body)]


class Binary(unittest.TestCase):
    def test_imports_resolve_on_rtm_and_sp6a(self):
        for f in FIXTURES:
            r = nt4.check(nt4.parse(f.read_text()), [SYS])['usosusb.sys']
            self.assertEqual(r['missing'], [], f.name)
            self.assertEqual(r['subsystem'], '4.00')
            self.assertEqual(r['modules'], ['hal.dll', 'ntoskrnl.exe'])

    def test_no_c_runtime_or_wdm(self):
        data = SYS.read_bytes()
        for name in (b'_snwprintf', b'__security_check_cookie', b'IoRegisterPlugPlayNotification', b'usbd.sys'):
            self.assertNotIn(name, data)


class ScanCodes(unittest.TestCase):
    def test_table(self):
        t = set1_table()
        self.assertEqual(len(t), 0x68)
        self.assertEqual(t[0x04], 0x1E)    # a
        self.assertEqual(t[0x1D], 0x2C)    # z
        self.assertEqual(t[0x1E], 0x02)    # 1
        self.assertEqual(t[0x27], 0x0B)    # 0
        self.assertEqual(t[0x28], 0x1C)    # Enter
        self.assertEqual(t[0x29], 0x01)    # Esc
        self.assertEqual(t[0x2C], 0x39)    # Space
        self.assertEqual(t[0x3A], 0x3B)    # F1
        self.assertEqual(t[0x45], 0x58)    # F12
        self.assertEqual(t[0x4C], 0x153)   # Delete (E0 53)
        self.assertEqual(t[0x52], 0x148)   # Up (E0 48)
        self.assertEqual(t[0x58], 0x11C)   # keypad Enter (E0 1C)
        self.assertEqual(t[0x64], 0x56)    # non-US backslash (102-key)
        letters = [t[u] for u in range(0x04, 0x1E)]
        self.assertEqual(len(set(letters)), 26)

    def test_modifiers_altgr(self):
        text = SRC.read_text(encoding='utf-8')
        # Right Alt (AltGr, Polish letters) is E0 38, right Ctrl E0 1D.
        self.assertIn('g_mod[8] = { 0x1D, 0x2A, 0x38, 0x15B, 0x11D, 0x36, 0x138, 0x15C }', text)


class Flow(unittest.TestCase):
    def test_post_installs_and_registers(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('"$LIB/nt4/USOSUSB.SYS"', text)
        self.assertIn(r'copy C:\USOS\NT4\USOSUSB.SYS %SystemRoot%\system32\drivers\usosusb.sys', text)
        block = text[text.index(r'Services\usosusb]'):]
        block = block[:block.index('EOF')]
        self.assertIn('"Start"=dword:00000001', block)
        self.assertIn('"Group"="Keyboard Port"', block)
        self.assertIn('"ErrorControl"=dword:00000000', block)
        self.assertIn(r'Services\Kbdclass\Parameters]' + '\n"ConnectMultiplePorts"=dword:00000001', block)
        self.assertIn(r'Services\Mouclass\Parameters]' + '\n"ConnectMultiplePorts"=dword:00000001', block)

    def test_micro_linux_carries_the_driver(self):
        text = MICRO.read_text(encoding='utf-8')
        self.assertIn('("tools/nt4/usosusb/bin/i386/usosusb.sys", "usr/lib/usos/nt4/USOSUSB.SYS")', text)


if __name__ == '__main__':
    unittest.main()
