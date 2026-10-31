#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import diagnostic_firstboot_runner as runner
import diagnostic_boot_guard as guard

class Tests(unittest.TestCase):
    def test_shared_auxiliary_budget(self):
        reserve=runner.validate_budget(64*1024**2,runner.output.LIMITS)
        self.assertLessEqual(reserve+64*1024**2,guard.AUX_BOUND)
        with self.assertRaises(ValueError):runner.validate_budget(guard.AUX_BOUND,runner.output.LIMITS)
        with self.assertRaises(ValueError):runner.validate_budget(-1,runner.output.LIMITS)
    def test_reference_receipt_fail_closed(self):
        path=Path('C:/test/boot.qcow2')
        good={'schema':'minios-reference-boot-preparation-v1','passed':True,'source_image_sha256':guard.IMAGE_SHA,
              'overlay_sha256':runner.BOOT_SHA,'overlay':str(path),'qemu_exit':33,
              'first_windows_boot_attempted':False,'external_bcd_comparison':'deferred'}
        runner.receipt_ok(good,path)
        for key,value in [('passed',False),('source_image_sha256','0'*64),('first_windows_boot_attempted',True)]:
            bad=good.copy();bad[key]=value
            with self.assertRaises(ValueError):runner.receipt_ok(bad,path)

if __name__=='__main__':unittest.main()
