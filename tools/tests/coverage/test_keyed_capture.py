"""Unknown private Setup screens must not be persisted as evidence."""
from pathlib import Path
import importlib.util
import unittest

spec=importlib.util.spec_from_file_location('menu',Path(__file__).with_name('boot_menu.py'))
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)


class CaptureTests(unittest.TestCase):
    def test_keyless_and_verified_first_logon(self):
        self.assertTrue(menu.capture_permitted(False,False,False))
        self.assertTrue(menu.capture_permitted(True,False,False,True))

    def test_staging_does_not_prove_key_acceptance(self):
        self.assertFalse(menu.capture_permitted(True,False,True))
        self.assertFalse(menu.capture_permitted(True,True,False))
        self.assertTrue(menu.capture_permitted(True,True,True))


if __name__=='__main__':unittest.main()
