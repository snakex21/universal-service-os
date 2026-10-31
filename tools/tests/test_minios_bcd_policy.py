#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Deferring an external comparison never forges its PASS or drops layout checks."""
import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import bcd_policy as p


class Policy(unittest.TestCase):
    def setUp(self):
        self.ref=dict(schema=p.SCHEMA,authorization=p.AUTHORIZATION,external_comparison_skipped=True,
            bcdboot_passed=False,head='a'*40,dirty=0,native_receipt_sha256='b'*64,ours_sha256='c'*64,
            mode='uefi',route_receipt_sha256='d'*64)
        self.own=dict(schema='minios-bcd-independent-route-v1',status='OFFLINE_ROUTE_PASS',head='a'*40,dirty=0,
            native_receipt_sha256='b'*64,source_sha256='c'*64,mode='uefi',reference_route=None,
            external_comparison_passed=False,_actual_sha256='d'*64)

    def test_explicit_deferral_is_distinct_from_reference_pass(self):
        p.validate(self.ref,self.own,'b'*64,'c'*64,'uefi')
        self.assertTrue(p.deferred(self.ref));self.assertFalse(self.ref['bcdboot_passed'])
        self.assertNotIn('passed',self.ref)

    def test_missing_auth_forged_pass_and_unpinned_native_or_own_receipts_refused(self):
        for target,key,value in [('ref','authorization',''),('ref','external_comparison_skipped',False),
            ('ref','bcdboot_passed',True),('ref','mode','bios'),('ref','native_receipt_sha256','e'*64),
            ('ref','route_receipt_sha256','e'*64),('own','source_sha256','e'*64),
            ('own','dirty',1),('own','external_comparison_passed',True),('own','reference_route',{}),
            ('own','status','PASS')]:
            ref=copy.deepcopy(self.ref);own=copy.deepcopy(self.own)
            (ref if target=='ref' else own)[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):p.validate(ref,own,'b'*64,'c'*64,'uefi')


if __name__=='__main__':unittest.main()
