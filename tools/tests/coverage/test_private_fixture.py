"""Reject ambiguous or out-of-directory key input without exposing values."""
from pathlib import Path
import argparse
import asyncio
import importlib.util
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fixture',Path(__file__).with_name('prepare_stick.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class PrivateInputTests(unittest.TestCase):
    def test_missing_donor_leaves_no_private_fixture(self):
        scratch=Path(__file__).resolve().parents[3]/'artifacts/coverage/private-input-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root=Path(directory);assets=root/'assets'
            for name in ('usb','micro-linux','xp-uefi-csm'):(assets/'zig-out'/name).mkdir(parents=True)
            for name in ('dos-native/msdos/INSTALL.BAT','bin/usos-x86_64.efi'):
                p=assets/'zig-out'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'')
            source=root/'source.iso';source.write_bytes(b'')
            out=root/'_vm'/'unused'
            args=argparse.Namespace(out=out,assets=assets,iso=source,folder='Windows 7',dos=None,
                donor=root/'missing.iso',boot_floppy=None,first_logon_observer=False,
                legacy_first_logon=False,trace_menus=False)
            for field in ('donor','legacy_service_pack'):
                args.donor=None
                args.legacy_service_pack=None
                setattr(args,field,root/'missing-input')
                with self.subTest(field=field),patch.object(fixture,'COLLECTION',root),patch.object(fixture,'check_resources',return_value={}):
                    with self.assertRaises(FileNotFoundError):asyncio.run(fixture.main(args))
                self.assertFalse(out.exists())

    def test_boundary_and_ambiguity(self):
        scratch=Path(__file__).resolve().parents[3]/'artifacts/coverage/private-input-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root=Path(directory)/'approved';root.mkdir()
            inside=root/'key.txt';outside=Path(directory)/'outside.txt'
            dummy='AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
            outside.write_text(dummy)
            inside.write_text(dummy+'\n'+dummy)
            self.assertEqual(fixture.private_key(inside,root),dummy)
            with self.assertRaisesRegex(ValueError,'approved private-key'):
                fixture.private_key(outside,root)
            inside.write_text(dummy+'\n11111-22222-33333-44444-55555')
            with self.assertRaisesRegex(ValueError,'unambiguous'):
                fixture.private_key(inside,root)
            self.assertEqual(fixture.private_key(inside,root,index=0),dummy)
            with self.assertRaisesRegex(ValueError,'outside'):
                fixture.private_key(inside,root,index=2)


if __name__ == '__main__':
    unittest.main()
