"""Windows 9x on NVMe: the boot disk is the only BIOS hard disk (csmwrap.ini
int13_boot_disk_only = true, CSMWrap patch 0014), docs/usb9x-hotswap-design-2026-10-19.md
section 2. Host only (Git sh): the int13 gate of tools/w9x_csmwrap_target.sh and the ini
gate of tools/xp_csmwrap_esp.sh are cut out of the scripts and run as they are."""
from pathlib import Path
import json
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
TARGET = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
ESP = (ROOT / 'tools/xp_csmwrap_esp.sh').read_text(encoding='utf-8')


def cut(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a) + len(end)]


GATE = cut(TARGET, 'int13_only=off\n', '\nfi\n')
INI = cut(ESP, 'if [ "${USOS_INT13_BOOT_DISK_ONLY:-}" = on ]; then\n', '\nfi\n')


class Int13BootDiskOnly(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-int13-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.flag = self.tmp / 'int13-all-disks.flag'

    def gate(self, nvme_ok, uds_ok=0):
        script = 'log() { printf "%s\\n" "$*" >&2; }\n' + f'nvme_ok={nvme_ok}\nuds_ok={uds_ok}\n' + \
            f'INT13_ALL_FLAG="{self.flag.as_posix()}"\n' + GATE + 'printf "%s" "$int13_only"\n'
        rc, out, err = sh(script)
        self.assertEqual(rc, 0, err)
        return out, err

    def test_gate(self):
        self.assertEqual(self.gate(0), ('off', ''))
        out, err = self.gate(1)
        self.assertEqual(out, 'on')
        self.assertIn('only the boot disk is a BIOS hard disk', err)
        self.flag.write_bytes(b'')
        out, err = self.gate(1)
        self.assertEqual(out, 'off')
        self.assertIn('int13-all-disks.flag', err)
        self.assertEqual(self.gate(0), ('off', ''))
        # USOSUSB.MPD (usb-storage-experimental.txt) on any target: test_w9x_usb_storage_flag.py
        self.assertEqual(self.gate(0, 1)[0], 'off')
        self.flag.unlink()
        self.assertEqual(self.gate(0, 1)[0], 'on')

    def ini(self, value):
        ini = self.tmp / 'csmwrap.ini'
        ini.write_bytes(b'serial = false\r\nverbose = false\r\n')
        script = 'log() { :; }\n' + f'ini="{ini.as_posix()}"\n' + INI
        rc, _, err = sh(script, {'USOS_INT13_BOOT_DISK_ONLY': value})
        self.assertEqual(rc, 0, err)
        return ini.read_bytes()

    def test_ini(self):
        base = b'serial = false\r\nverbose = false\r\n'
        self.assertEqual(self.ini('on'), base + b'int13_boot_disk_only = true\r\n')
        self.assertEqual(self.ini('off'), base)
        self.assertEqual(self.ini(''), base)

    def test_wiring(self):
        # the flag lives next to the other 9x flags on the USOS stick
        self.assertIn('INT13_ALL_FLAG=${W9X_INT13_ALL_FLAG:-$ESP_DIR/win9x/int13-all-disks.flag}', TARGET)
        # decided after usosnvme passed its check, handed to the ESP writer
        self.assertLess(TARGET.index('[ "$nvme_ok" = 1 ] || rm -f'), TARGET.index('int13_only=off'))
        self.assertIn('USOS_PCI_IRQ_ROUTING=on USOS_INT13_BOOT_DISK_ONLY=$int13_only sh "$LIB/xp_csmwrap_esp.sh"',
                      TARGET)
        self.assertLess(TARGET.index('int13_only=off'), TARGET.index('USOS_INT13_BOOT_DISK_ONLY=$int13_only'))
        # the ini line is written before the ini is copied to the ESP
        self.assertLess(ESP.index('int13_boot_disk_only = true'), ESP.index('mcopy -i "$image" "$ini"'))
        # no other flow script asks for it (DOS / 3.x keep the stick on INT 13h)
        for other in ROOT.glob('tools/*.sh'):
            if other.name not in ('w9x_csmwrap_target.sh', 'xp_csmwrap_esp.sh'):
                self.assertNotIn('USOS_INT13_BOOT_DISK_ONLY', other.read_text(encoding='utf-8', errors='replace'),
                                 other)

    def test_pinned_csmwrap_has_0014(self):
        # the binary pinned in xp_csmwrap_esp.sh parses the key (patch 0014 since 3.1.2-usos11-int13x)
        pinned = [l for l in ESP.splitlines() if l.startswith('PINNED=')]
        self.assertTrue(pinned, 'xp_csmwrap_esp.sh has no PINNED= line')
        digest = pinned[0].split('=', 1)[1].strip()
        found = []
        for manifest_path in (ROOT / 'tools/vendor/csmwrap').glob('*/manifest.json'):
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
            if manifest.get('files', {}).get('csmwrapx64.efi') == digest:
                found.append(manifest_path.parent)
                self.assertIn('0014-int13-boot-disk-only.patch', manifest['patches'])
                self.assertIn(b'int13_boot_disk_only', (manifest_path.parent / 'csmwrapx64.efi').read_bytes())
        self.assertTrue(found, f'no vendor folder has the pinned binary {digest}')


if __name__ == '__main__':
    unittest.main()
