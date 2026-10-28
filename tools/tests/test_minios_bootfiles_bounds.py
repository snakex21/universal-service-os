# SPDX-License-Identifier: GPL-3.0-or-later
import asyncio
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
import uuid

import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import bootfiles_bounds as bounded

class BoundsTest(unittest.TestCase):
    def test_qmp_creates_fixed_container_with_backing(self):
        if 'USOS_QEMU_FIXTURE_DIR' not in os.environ: self.skipTest('explicit retained fixture path required')
        root=Path(os.environ['USOS_QEMU_FIXTURE_DIR'])
        target=root/('qmp-bounded-'+uuid.uuid4().hex+'.qcow2')
        base=root/'bound-synthetic-base.qcow2'
        asyncio.run(bounded.create_bounded(os.environ['USOS_QEMU_SYSTEM'],target,bounded.BOOT,32*bounded.MIB,base,'qcow2',os.environ.copy()))
        self.assertEqual(target.stat().st_size,bounded.BOOT)
        with target.open('rb') as f:self.assertEqual(f.read(4),b'QFI\xfb')

    def test_qmp_snapshot_stays_within_fixed_container(self):
        if 'USOS_QEMU_FIXTURE_DIR' not in os.environ:self.skipTest('explicit retained fixture path required')
        root=Path(os.environ['USOS_QEMU_FIXTURE_DIR']);target=root/('qmp-snapshot-'+uuid.uuid4().hex+'.qcow2')
        qemu=os.environ['USOS_QEMU_SYSTEM'];base=root/'bound-synthetic-base.qcow2'
        asyncio.run(bounded.create_bounded(qemu,target,bounded.TARGET,32*bounded.MIB,base,'qcow2',os.environ.copy()))
        asyncio.run(bounded.snapshot_bounded(qemu,target,bounded.TARGET,os.environ.copy()))
        info=subprocess.run([os.environ['USOS_QEMU_IMG'],'info','--output=json',str(target)],check=True,capture_output=True,text=True,timeout=30)
        self.assertEqual(target.stat().st_size,bounded.TARGET)
        self.assertTrue(any(s.get('name')=='bootfiles' for s in json.loads(info.stdout).get('snapshots',[])))

    def test_devices_have_distinct_fixed_raw_limits(self):
        both=[]
        for name,maximum in [('boot',bounded.BOOT),('target',bounded.TARGET)]:
            args=bounded.nodes(Path('example.qcow2'),name,maximum)
            nodes=[json.loads(args[i]) for i in (1,3,5)]
            self.assertEqual(nodes[1]['size'],maximum)
            self.assertEqual(nodes[1]['file'],name+'-file')
            self.assertEqual(nodes[2]['file'],name+'-limit')
            both.extend(node['node-name'] for node in nodes)
        self.assertEqual(len(set(both)),6)
        with self.assertRaises(ValueError):bounded.nodes(Path('bad'), 'target', bounded.MIB)

    def test_output_overflow_wakes_owner_and_does_not_exceed_limit(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)
            async def run():
                command=[sys.executable,'-c','import sys; sys.stdout.buffer.write(b"x"*65536); sys.stdout.flush()']
                with self.assertRaisesRegex(ValueError,'Bounded QEMU output'):
                    await bounded.run_qemu(command,path/'debug',path/'error',os.environ.copy(),30,debug_limit=1024)
            asyncio.run(run())
            self.assertLessEqual((path/'debug').stat().st_size,1024)

    def test_success_keeps_exit_code_33(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)
            result=asyncio.run(bounded.run_qemu([sys.executable,'-c','import sys; print("PASS"); sys.exit(33)'],
                path/'debug',path/'error',os.environ.copy(),30))
            self.assertEqual(result,33);self.assertIn('PASS',(path/'debug').read_text())

if __name__=='__main__':unittest.main()
