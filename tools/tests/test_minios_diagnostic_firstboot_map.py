#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import diagnostic_firstboot_map as m

class Tests(unittest.TestCase):
    def test_vhdx_bat_splits_and_checks_qemu_offsets(self):
        base=[{'start':0,'length':4,'offset':100,'data':True,'zero':False},
              {'start':4,'length':4,'offset':200,'data':True,'zero':False}]
        rows=[{'start':0,'length':2,'depth':0,'data':True,'zero':False,'offset':20},
              {'start':2,'length':6,'depth':2,'data':True,'zero':False}]
        out=m.materialize(rows,base,8)
        self.assertEqual([(x['start'],x['length'],x['offset']) for x in out],[(0,2,20),(2,2,102),(4,4,200)])
        rows[1]['offset']=102
        with self.assertRaises(ValueError):m.materialize(rows,base,8)
    def test_bad_chain_geometry_or_missing_physical_offset_refused(self):
        base=[{'start':0,'length':4,'offset':100,'data':True,'zero':False}]
        for row in ({'start':1,'length':4,'depth':2,'data':True,'zero':False},
                    {'start':0,'length':4,'depth':3,'data':True,'zero':False},
                    {'start':0,'length':4,'depth':1,'data':True,'zero':False}):
            with self.assertRaises(ValueError):m.materialize([row],base,4)

if __name__=='__main__':unittest.main()
