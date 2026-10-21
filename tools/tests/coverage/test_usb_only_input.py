"""Reject an ambiguous USB-only scenario before opening any VM fixture."""
from pathlib import Path
from types import SimpleNamespace
import asyncio
import importlib.util
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('menu',Path(__file__).with_name('boot_menu.py'))
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)


class UsbOnlyTests(unittest.TestCase):
    def test_usb_scenario_disables_the_real_q35_i8042_property(self):
        self.assertEqual(menu.aux.input_machine('q35',False,True),'q35,i8042=off')
        self.assertEqual(menu.aux.input_machine('q35',False,False),'q35')
        self.assertEqual(menu.aux.input_machine('pc',True,False),'pc')

    def test_conflicting_or_unverified_scenario_fails_before_fixture_access(self):
        for machine,ps2 in (('q35',True),('pc',False)):
            args=SimpleNamespace(interactive=False,machine=machine,ps2_input=ps2,usb_only_input=True)
            with self.subTest(machine=machine,ps2=ps2),patch.object(menu.Path,'resolve') as access:
                with self.assertRaises(ValueError):asyncio.run(menu.main(args))
                access.assert_not_called()

    def test_false_like_values_cannot_silently_keep_the_fallback(self):
        for value in (0,1,None,'false','true'):
            with self.subTest(value=value),self.assertRaises(ValueError):
                menu.aux.input_machine('q35',False,value)


if __name__=='__main__':unittest.main()
