#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import json,sys,unittest,uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import diagnostic_boot_guard as guard
import diagnostic_boot_plan as plan

class Tests(unittest.TestCase):
    def test_reference_config_defers_comparison(self):
        cfg=plan.configuration('1'*64,'2'*64,uuid.UUID('00000001-0000-4000-8000-000000000000')).decode()
        self.assertIn('USOSBOOT_REFERENCE_QEMU_ONLY_V1\n',cfg)
        self.assertIn('bcd_gate=deferred\n',cfg);self.assertIn('mbr_signature=0\n',cfg)
        with self.assertRaises(ValueError):plan.configuration('1'*64,'1'*64,uuid.uuid4())
        with self.assertRaises(ValueError):plan.configuration('1'*64,'2'*64,uuid.UUID(guard.DISK))
    def test_qemu_plan_has_bounded_raw_nodes_and_no_network(self):
        paths=[Path(r'K:\case')/x for x in ('qemu.exe','code.fd','vars.fd','utility.raw','boot.qcow2','entropy.bin')]
        args=plan.command(*paths);nodes=[json.loads(args[i+1]) for i,x in enumerate(args) if x=='-blockdev']
        self.assertEqual([x['size'] for x in nodes if x.get('driver')=='raw'],[plan.UTILITY_BYTES,guard.BOOT_BOUND])
        self.assertIn('-nodefaults',args);self.assertEqual(args[args.index('-nic')+1],'none')
        pflash=[args[i+1] for i,x in enumerate(args) if x=='-drive']
        self.assertEqual(len(pflash),2);self.assertTrue(all('readonly=on' in x for x in pflash))
        self.assertLessEqual(sum(plan.LIMITS.values()),guard.AUX_BOUND)
        self.assertEqual(guard.BOOT_BOUND+guard.FIRSTBOOT_BOUND+guard.AUX_BOUND,2*1024**3)
        with self.assertRaises(ValueError):plan.command(Path('relative'),*paths[1:])
    def test_owned_direct_output_name(self):
        case=Path(r'K:\case');plan.plan_paths(case,case/'diag-boot-0123-abcd')
        with self.assertRaises(ValueError):plan.plan_paths(case,case/'other')
        with self.assertRaises(ValueError):plan.plan_paths(case,case/'diag-boot-0123'/'nested')

if __name__=='__main__':unittest.main()
