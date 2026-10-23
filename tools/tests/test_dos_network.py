"""MS-DOS network staging: USOSPKT.COM + mTCP into C:\\NET (INSTALL.BAT),
NETSTART.BAT in AUTOEXEC.BAT, the installer payload list, the mTCP vendor
pins and licence / source files (GPL-3.0). The packet driver itself:
tools/tests/legacy_bios/test_usospkt.py; QEMU runs:
docs/dos-usospkt-2026-10-23.md.
Run: python tools/tests/test_dos_network.py
"""
from pathlib import Path
import hashlib
import json
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import build_dos_network as net

MSDOS = ROOT / 'src/platform/bios/msdos'
VENDOR = ROOT / 'tools/vendor/mtcp' / net.MTCP_VERSION


class DosNetworkTest(unittest.TestCase):
    def test_install_copies_every_file(self):
        text = (MSDOS / 'install.cmd').read_text(encoding='ascii')
        block = text[text.index('goto net_done'):text.index(':net_done')]
        lists = ' '.join(re.findall(r'for %%f in \(([^)]*)\)', block))
        names = set()
        for word in lists.split():
            names.add(word if '.' in word else word + '.EXE')
        self.assertEqual(names, set(net.NET_FILES))
        self.assertIn('echo call C:\\NET\\NETSTART.BAT>>C:\\AUTOEXEC.BAT', block)
        self.assertIn('copy C:\\NET\\MTCP.DEF C:\\NET\\MTCP.CFG', block)
        # only the plain MS-DOS install (no Windows 1.x-3.x start menu yet)
        self.assertIn('if exist %USRC%\\WINSETUP\\SETUP.EXE goto net_done', block)
        # before the branch that ends the MS-DOS-only install
        self.assertLess(text.index(':net_done'), text.index(':dos_done'))

    def test_netstart_never_blocks(self):
        lines = [l.strip() for l in (MSDOS / 'network_start.cmd').read_text(encoding='ascii').splitlines()]
        drv = lines.index('C:\\NET\\USOSPKT.COM 0x60 >C:\\NET\\USOSPKT.LOG')
        self.assertEqual(lines[drv + 1], 'if errorlevel 1 goto no_driver')
        dhcp = next(l for l in lines if l.startswith('C:\\NET\\DHCP.EXE'))
        self.assertIn('-retries 2', dhcp)
        self.assertIn('-timeout 6', dhcp)
        self.assertIn('set MTCPCFG=C:\\NET\\MTCP.CFG', lines)
        self.assertTrue(all(len(l) <= 127 for l in lines))

    def test_payload_list(self):
        go = (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8')
        for name in net.NET_FILES:
            self.assertIn('{`zig-out/dos-native/msdos/%s`, `EFI/USOS/dos-native/msdos/%s`}' % (name, name), go)

    def test_names_are_8_3(self):
        for name in net.NET_FILES:
            stem, _, ext = name.partition('.')
            self.assertTrue(1 <= len(stem) <= 8 and len(ext) <= 3 and name == name.upper(), name)

    def test_mtcp_vendor_pins(self):
        manifest = json.loads((VENDOR / 'manifest.json').read_text())
        self.assertIn('GPL-3.0', manifest['license'])
        files = manifest['files']
        for name in net.MTCP_TOOLS + ('COPYING.TXT', 'README.TXT', net.MTCP_SOURCE):
            self.assertIn(name, files)
        for name, digest in files.items():
            path = VENDOR / name
            if name == net.MTCP_SOURCE and not path.exists():
                continue                    # ignored *.zip: local pinned copy, checked by the build
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest, name)
        self.assertIn('GNU GENERAL PUBLIC LICENSE', (VENDOR / 'COPYING.TXT').read_text(encoding='latin-1'))
        self.assertIn('Version 3', (VENDOR / 'COPYING.TXT').read_text(encoding='latin-1'))
        sources = (VENDOR / 'SOURCES.txt').read_text(encoding='ascii')
        self.assertIn('MTCPSRC.ZIP', sources)
        self.assertIn(net.MTCP_SOURCE, manifest['source'])

    def test_driver_header(self):
        src = (MSDOS / 'usospkt.S').read_text(encoding='ascii')
        self.assertIn('GPL-3.0-or-later', src)
        self.assertIn('.asciz "PKT DRVR"', src)
        # no MS / third-party code: the igb programming names its own source
        self.assertIn('tools/nt/usosnet/src/usosnet_igb.c', src)


if __name__ == '__main__':
    unittest.main()
