"""A one-engine lane must reject products which start a nested emulator."""
from pathlib import Path
import importlib.util
import unittest

spec=importlib.util.spec_from_file_location('plan',Path(__file__).with_name('run_plan.py'))
plan=importlib.util.module_from_spec(spec);spec.loader.exec_module(plan)


class LaneTests(unittest.TestCase):
    def test_explicit_nested_reservation(self):
        for system in ('windows-95','windows-nt-4','windows-embedded-posready-2009'):
            with self.assertRaises(ValueError):plan.validate_system(system,False)
            plan.validate_system(system,True)
        plan.validate_system('windows-7',False)
        with self.assertRaises(ValueError):plan.validate_system('windows-7',True)
        with self.assertRaises(ValueError):plan.validate_system('unrecognized',False)


if __name__=='__main__':unittest.main()
