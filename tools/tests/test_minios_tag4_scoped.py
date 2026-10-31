#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import tag4_scoped_capture as scope
import wim_security_readonly as security

class ScopedTests(unittest.TestCase):
    def test_budget_preserves_evidence_and_overlay_reserve(self):
        limit=scope.GIB-640*1024**2
        scope.check_budget({'other_logical_bytes':limit,'other_allocated_bytes':limit})
        for key in ('other_logical_bytes','other_allocated_bytes'):
            x={'other_logical_bytes':0,'other_allocated_bytes':0};x[key]=limit+1
            with self.assertRaises(ValueError):scope.check_budget(x)

    def test_exact_dism_image_and_partition(self):
        case=Path('runtime')/scope.CASE
        good={'virtual_bytes':32*scope.GIB,'chain':[{'path':str(case/'install.vhdx'),'sha256':scope.IMAGE_SHA}],
              'partition_guid':scope.GUID,'partition_offset':289406976,'partition_bytes':34069282816}
        scope.check_image_plan(good,case)
        for field in ('virtual_bytes','chain','partition_guid','partition_offset','partition_bytes'):
            bad=copy.deepcopy(good);bad[field]=None
            with self.assertRaises(ValueError):scope.check_image_plan(bad,case)

    def test_metadata_parent_must_be_proven_and_sequence_checked(self):
        nodes={5:{'sequence':5,'directory':True,'names':[]},
               27:{'sequence':2,'directory':True,'names':[(11,11,'$RmMetadata')]},
               60:{'sequence':3,'directory':True,'names':[(5,5,'Windows')]}}
        reserved=lambda n:{'sequence':11,'directory':n==11}
        self.assertTrue(security.metadata_parent(nodes,27,2,reserved))
        self.assertFalse(security.metadata_parent(nodes,60,3,reserved))
        for parent,sequence in ((27,9),(11,9),(99,1)):
            with self.assertRaises(ValueError):security.metadata_parent(nodes,parent,sequence,reserved)
        nodes[27]['names']=[(27,2,'loop')]
        with self.assertRaises(ValueError):security.metadata_parent(nodes,27,2,reserved)

if __name__=='__main__':unittest.main()
