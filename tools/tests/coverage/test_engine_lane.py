"""A one-engine lane must reject products which start a nested emulator."""
from pathlib import Path
import importlib.util
import unittest
import subprocess

spec=importlib.util.spec_from_file_location('plan',Path(__file__).with_name('run_plan.py'))
plan=importlib.util.module_from_spec(spec);spec.loader.exec_module(plan)


class LaneTests(unittest.TestCase):
    def test_default_nt5_disk_satisfies_the_actual_partition_planner(self):
        root=Path(__file__).resolve().parents[3]
        spec=importlib.util.spec_from_file_location('partition_tests',root/'tools/tests/legacy_bios/test_xp_windows_plan.py')
        fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
        capacity=plan.target_capacity({'system':'windows-2000'})
        for gib,ok in ((8,False),(capacity,True)):
            result=subprocess.run([fixture.AWK,'-f',str(root/'tools/xp_windows_partition_plan.awk')],
                input=fixture.snapshot(size_bytes=str(gib*1024**3)),capture_output=True,text=True)
            self.assertEqual(result.returncode==0,ok,result.stderr)
        with self.assertRaises(ValueError):plan.target_capacity({'system':'windows-xp','target_gib':8})
        self.assertEqual(plan.target_capacity({'system':'windows-nt-4'}),4)
    def test_explicit_nested_reservation(self):
        for system in ('windows-95','windows-nt-4','windows-embedded-posready-2009'):
            with self.assertRaises(ValueError):plan.validate_system(system,False)
            plan.validate_system(system,True)
        plan.validate_system('windows-7',False)
        with self.assertRaises(ValueError):plan.validate_system('windows-7',True)
        with self.assertRaises(ValueError):plan.validate_system('unrecognized',False)


if __name__=='__main__':unittest.main()
