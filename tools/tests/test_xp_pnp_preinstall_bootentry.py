"""X470 XP SP3 2026-10-22 (B261022-211645, Micron NVMe, CSMWrap): two NT5
flow fixes, host-only.

1. usosnet staged in C:\\USOS\\Drivers\\USOSNET + OemPnPDriversPath, but
   OemPreinstall=No: text-mode Setup appends OemPnPDriversPath to DevicePath
   only in preinstall mode, so DevicePath stayed %SystemRoot%\\inf and GUI
   Setup gave the I211 a null driver (setupapi.log 0xe0000228).
   usos_nt5_oem_pnp_preinstall (tools/nt5_user_drivers.sh) sets
   OemPreinstall=Yes for any answer with OemPnPDriversPath.
2. After the preparation the firmware restarted the still-plugged USOS
   stick: the XP flow wrote no boot entry. legacy_xp_staging.sh now runs
   uefi_boot_entry.sh add for the target's CSMWrap ESP (BootOrder first +
   BootNext), checked here on the exact X470 MBR layout.
"""
from pathlib import Path
import shutil
import tempfile
import unittest

from test_w9x_phase1_qemu import sh
from test_uefi_boot_entry import mbr_disk, load_option, GLOBAL, HELPER

ROOT = Path(__file__).resolve().parents[2]
LIB = (ROOT / 'tools/nt5_user_drivers.sh').as_posix()


def preinstall(text: bytes) -> bytes:
    tmp = Path(tempfile.mkdtemp(prefix='usos-pnp-'))
    try:
        src = tmp / 'in.sif'
        src.write_bytes(text)
        dst = tmp / 'out.sif'
        rc, out, err = sh(f'. "{LIB}"; usos_nt5_oem_pnp_preinstall < "{src.as_posix()}" > "{dst.as_posix()}"')
        assert rc == 0, out + err
        return dst.read_bytes()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# The [Unattended] / [GuiUnattended] of the X470 run's WINNT.SIF (no secrets).
X470 = (b'[Data]\r\nmsdosinitiated="1"\r\n[Unattended]\r\nOemPnPDriversPath="USOS\\Drivers\\USOSNET"\r\n'
        b'DriverSigningPolicy=Ignore\r\nUnattendMode=DefaultHide\r\nOemSkipEula=Yes\r\nOemPreinstall=No\r\n'
        b'Repartition=No\r\n[GuiUnattended]\r\nOEMSkipRegional=1\r\nOemSkipWelcome=1\r\nTimeZone=100\r\n')


class OemPnpPreinstall(unittest.TestCase):
    def test_x470_answer_gets_preinstall(self):
        out = preinstall(X470).decode()
        self.assertEqual(out.count('OemPreinstall='), 1)
        self.assertIn('[Unattended]\r\nOemPreinstall=Yes\r\nOemPnPDriversPath="USOS\\Drivers\\USOSNET"\r\n', out)
        self.assertNotIn('OemPreinstall=No', out)
        # The skip keys were there already: not added twice.
        self.assertEqual(out.count('OEMSkipRegional='), 1)
        self.assertEqual(out.count('OemSkipWelcome='), 1)
        self.assertIn('DriverSigningPolicy=Ignore\r\n', out)
        self.assertNotIn(b'\n', out.encode().replace(b'\r\n', b''))

    def test_missing_skip_keys_are_added(self):
        out = preinstall(b'[Unattended]\nOemPnPDriversPath="A;B"\n[GuiUnattended]\nTimeZone=100\n').decode()
        self.assertIn('[GuiUnattended]\r\nOEMSkipRegional=1\r\nOemSkipWelcome=1\r\nTimeZone=100\r\n', out)
        self.assertIn('[Unattended]\r\nOemPreinstall=Yes\r\n', out)

    def test_existing_skip_value_is_kept(self):
        out = preinstall(b'[Unattended]\nOemPnPDriversPath="A"\n[GuiUnattended]\nOemSkipWelcome=0\n').decode()
        self.assertIn('OemSkipWelcome=0', out)
        self.assertEqual(out.count('OemSkipWelcome='), 1)
        self.assertIn('OEMSkipRegional=1', out)

    def test_no_gui_section_is_appended(self):
        out = preinstall(b'[Unattended]\r\nOemPnPDriversPath="A"\r\n').decode()
        self.assertTrue(out.endswith('[GuiUnattended]\r\nOEMSkipRegional=1\r\nOemSkipWelcome=1\r\n'), out)

    def test_unchanged_without_driver_path_or_already_yes(self):
        for text in (b'[Unattended]\nOemPreinstall=No\n[GuiUnattended]\nTimeZone=4\n',
                     b'[Unattended]\r\nOemPreinstall=Yes\r\nOemPnPDriversPath="A"\r\n',
                     b'[Unattended]\nOemPreinstall = "Yes"\nOemPnPDriversPath="A"\n',
                     # The key in another section is not a driver path.
                     b'[Data]\nOemPnPDriversPath="A"\n[Unattended]\nOemPreinstall=No\n'):
            with self.subTest(text=text):
                self.assertEqual(preinstall(text), text)

    def test_wired_before_winnt_sif_is_written(self):
        src = (ROOT / 'tools/prepare_xp_windows_partition.sh').read_text(encoding='utf-8')
        call = src.index('usos_nt5_oem_pnp_preinstall < "$work/winnt.base" > "$work/winnt.sif"')
        # After every answer writer (LAN, user drivers), before the write.
        self.assertGreater(call, src.index('usos_net_w2k_sif < "$work/winnt.base"'))
        self.assertGreater(call, src.index('usos_nt5_user_drivers_sif "$user_paths"'))
        self.assertLess(call, src.index('put_verified "$work/winnt.sif" WINNT.SIF'))
        self.assertNotIn('works without it since XP', (ROOT / 'tools/network_setup.sh').read_text(encoding='utf-8'))


class XpBootEntry(unittest.TestCase):
    def test_staging_writes_entry_after_csmwrap_esp(self):
        src = (ROOT / 'tools/legacy_xp_staging.sh').read_text(encoding='utf-8')
        esp = src.index("printf '[LEGACY_XP] CSMWRAP ESP PASS\\n'")
        entry = src.index('sh /usr/lib/usos/uefi_boot_entry.sh add')
        self.assertLess(esp, entry)
        self.assertLess(entry, src.index('xp_stage_set prepare-xpsetup-pass'))
        block = src[esp:entry]
        self.assertIn('env TARGET_DEVICE="$TARGET_DEVICE"', block)
        self.assertIn('ENTRY_NAME=', block)
        # Default order (first): every Setup restart must reach the disk,
        # not only the one BootNext covers.
        self.assertNotIn('ENTRY_ORDER', src[esp:entry + 200])
        self.assertIn('tools/uefi_boot_entry.sh', (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8'))

    def test_x470_xp_layout_entry(self):
        # legacy-xp-csmwrap.log: MBR slot 1 NTFS at 2048, CSMWRAP ESP slot 2
        # start=1000083456 sectors=131072; disk id 0xa463ffab.
        tmp = Path(tempfile.mkdtemp(prefix='usos-xpentry-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        disk = tmp / 'disk.raw'
        sig = bytes.fromhex('abff63a4')
        disk.write_bytes(mbr_disk(signature=sig, esp_slot=1, start=1000083456, size=131072))
        efivars = tmp / 'efivars'
        efivars.mkdir()
        (efivars / f'Boot0000-{GLOBAL}').write_bytes(b'\x07\0\0\0usos-stick')
        (efivars / f'BootOrder-{GLOBAL}').write_bytes(b'\x07\0\0\0\x00\x00')
        env = {'TARGET_DEVICE': disk.as_posix(), 'ENTRY_NAME': 'Windows XP', 'SECTOR_SIZE': '512',
               'EFIVARS_DIR': efivars.as_posix()}
        rc, out, err = sh(f'sh "{HELPER.as_posix()}" add', env=env)
        self.assertEqual(rc, 0, out + err)
        self.assertIn('boot_entry=Boot0001', out)
        option = load_option('Windows XP', 2, 1000083456, 131072, sig + b'\0' * 12, 1, 1)
        self.assertEqual((efivars / f'Boot0001-{GLOBAL}').read_bytes(), b'\x07\0\0\0' + option)
        # XP first, the stick after it; BootNext = XP.
        self.assertEqual((efivars / f'BootOrder-{GLOBAL}').read_bytes(), b'\x07\0\0\0\x01\x00\x00\x00')
        self.assertEqual((efivars / f'BootNext-{GLOBAL}').read_bytes(), b'\x07\0\0\0\x01\x00')


if __name__ == '__main__':
    unittest.main()
