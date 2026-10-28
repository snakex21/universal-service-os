# SPDX-License-Identifier: GPL-3.0-or-later
"""No exception values or policy mutation in MiniOS production modules."""
import ast
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/minios'))
import host_dism_capacity as capacity
import diagnostic_boot_runner as boot
import diagnostic_firstboot_runner as firstboot


def constant(node):
    if isinstance(node,ast.Constant) and type(node.value) is int:return node.value
    if isinstance(node,ast.Name) and node.id in ('GIB','GiB'):return 1024**3
    if isinstance(node,ast.BinOp):
        a,b=constant(node.left),constant(node.right)
        if a is not None and b is not None:
            if isinstance(node.op,ast.Mult):return a*b
            if isinstance(node.op,ast.Pow) and 0<=b<=4:return a**b
    return None


class Tests(unittest.TestCase):
    def test_no_production_module_embeds_exception_or_mutates_max_cap(self):
        forbidden={n*1024**3 for n in (74,175,36)}
        for path in (ROOT/'tools/minios').glob('*.py'):
            for node in ast.walk(ast.parse(path.read_text(encoding='utf-8-sig'))):
                if isinstance(node,ast.BinOp):
                    self.assertNotIn(constant(node),forbidden,str(path))
                if isinstance(node,(ast.Assign,ast.AnnAssign,ast.AugAssign)):
                    targets=node.targets if isinstance(node,ast.Assign) else [node.target]
                    for target in targets:
                        if isinstance(target,ast.Attribute):self.assertNotEqual(target.attr,'MAX_CAP',str(path))
        self.assertEqual(capacity.pool.MAX_CAP,150*1024**3)
        self.assertEqual(capacity.POOL_CAP_BYTES,150*1024**3)
        self.assertEqual(capacity.MIN_FREE_BYTES,100*1024**3)

    def test_both_runners_use_normal_preflight_with_pinned_plan(self):
        root=Path('K:/pool');case=root/'1c7/host-dism-abc'
        job={'capacity_plan':str(root/'plan.json'),'capacity_plan_sha256':'a'*64}
        for runner in (boot,firstboot):
            with patch.object(capacity,'preflight',return_value={'pool_cap_bytes':capacity.POOL_CAP_BYTES,
                       'minimum_free_bytes':capacity.MIN_FREE_BYTES}) as call:
                if runner is boot:
                    result=runner.capacity_preflight(root,case,job)
                    growth=boot.guard.BOOT_BOUND+boot.guard.AUX_BOUND
                else:
                    reserve=1024**2
                    result=runner.capacity_preflight(root,case,job,reserve)
                    growth=firstboot.guard.FIRSTBOOT_BOUND+reserve
                call.assert_called_once_with(root,Path(job['capacity_plan']),'a'*64,case,
                                             image_exists=True,growth_bytes=growth)
                self.assertEqual(result['pool_cap_bytes'],150*1024**3)
                self.assertEqual(result['minimum_free_bytes'],100*1024**3)

    def test_real_normal_preflight_does_not_modify_policy_or_accept_legacy_plan(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'runtime') as folder:
            root=Path(folder);case=root/'1c7/host-dism-abc';plan=root/'plan.json'
            document={'schema':'usos-wim-pool-plan-v1','cap_bytes':150*1024**3,
                      'unreserved_files_declared_closed':True,
                      'reservations':[{'path':'1c7/host-dism-abc','bytes':2*1024**3}]}
            def save():
                data=json.dumps(document).encode();plan.write_bytes(data)
                return hashlib.sha256(data).hexdigest()
            with patch.object(capacity.pool.oracle,'RUNTIME',root),patch.object(capacity,'verify_runtime_volume'), \
                 patch.object(capacity.pool,'audit',return_value={'passed':True,'projected_total_bytes':2*1024**3}) as audit, \
                 patch.object(capacity.shutil,'disk_usage',return_value=type('Usage',(),{'free':102*1024**3})()):
                result=capacity.preflight(root,plan,save(),case,image_exists=False)
                self.assertEqual(result['minimum_free_bytes'],100*1024**3)
                self.assertEqual(result['pool_cap_bytes'],150*1024**3)
                audit.assert_called_once_with(root,document['reservations'],limit=150*1024**3)
                self.assertEqual(capacity.pool.MAX_CAP,150*1024**3)
                document['cap_bytes']+=1
                with self.assertRaises(ValueError):capacity.preflight(root,plan,save(),case,image_exists=False)
                document['cap_bytes']=150*1024**3;document['reservations']=[]
                with self.assertRaises(ValueError):capacity.preflight(root,plan,save(),case,image_exists=False)

    def test_new_growth_cannot_exceed_either_logical_or_allocated_reservation(self):
        gib=1024**3
        self.assertEqual(capacity.budget(gib,gib,0,0,101*gib,2*gib,gib),gib)
        # Existing bytes fit, but one new byte would overrun the plan.
        with self.assertRaises(ValueError):capacity.budget(gib,gib,0,0,200*gib,gib,1)
        # Sparse envelopes are charged logically, not just by allocated space.
        with self.assertRaises(ValueError):capacity.budget(gib,1,0,0,200*gib,gib,1)


if __name__=='__main__':unittest.main()
