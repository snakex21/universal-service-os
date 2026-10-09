"""xp_driver_overlay on integrated SP3 media (no I386\\SP3.CAB, the SP3 files
merged into DRIVER.CAB; e.g. the XP Tablet PC Edition 2005 SP3 'updated'
disc): the bundle's own SP3.CAB is registered as a driver cabinet in
TXTSETUP.SIF. Host-only, no Microsoft files.

    python tools/tests/test_xp_overlay_integrated.py
"""
from pathlib import Path
import sys, unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import xp_driver_overlay as overlay  # noqa: E402

SIF = ('[SetupData]\r\nArchitecture = i386\r\nDriverCabName=driver.cab\r\n\r\n'
       '[SourceDisksFiles]\r\ndriver.cab   = 1,,,,,,_x,39,0,0\r\n\r\n'
       '[FileFlags]\r\ndriver.cab =16\r\n')


def rows(text, section):
    out, inside = [], False
    for line in text.splitlines():
        if line.strip().startswith('['):
            inside = line.strip().lower() == '[' + section.lower() + ']'
            continue
        if inside and line.strip():
            out.append(line.strip())
    return out


class IntegratedCab(unittest.TestCase):
    def test_registers_the_bundle_cabinet(self):
        text = overlay.register_integrated_cab(SIF, 'SP3.CAB')
        self.assertEqual(rows(text, 'SetupData'), ['Architecture = i386', 'DriverCabName = driver.cab,sp3.cab'])
        self.assertEqual(rows(text, 'SourceDisksFiles'), ['driver.cab   = 1,,,,,,_x,39,0,0', 'sp3.cab = 1,,,,,,_x,39,0,0'])
        self.assertEqual(rows(text, 'FileFlags'), ['driver.cab =16', 'sp3.cab = 16'])

    def test_idempotent(self):
        once = overlay.register_integrated_cab(SIF, 'SP3.CAB')
        self.assertEqual(overlay.register_integrated_cab(once, 'SP3.CAB'), once)

    def test_slipstreamed_media_unchanged_path(self):
        # Media that already list sp3.cab keep their order.
        text = overlay.register_integrated_cab(SIF.replace('DriverCabName=driver.cab', 'DriverCabName = driver.cab,sp3.cab'), 'SP3.CAB')
        self.assertEqual(rows(text, 'SetupData')[-1], 'DriverCabName = driver.cab,sp3.cab')


if __name__ == '__main__':
    unittest.main()
