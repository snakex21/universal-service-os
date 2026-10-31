#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Logical-byte accounting on tiny own files; never traverses active scopes."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'minios'))
import wim_pool as pool


class IncrementalCapacityTests(unittest.TestCase):
    def setUp(self):
        folder = Path(__file__).resolve().parents[2] / 'runtime'
        folder.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='boot-capacity-unit-', dir=folder)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scope = self.root/'closed'
        self.active = self.root/'active'
        self.scope.mkdir(); self.active.mkdir()
        (self.scope/'retained.txt').write_bytes(b'x'*700)
        self.plan = self.root/'plan.json'
        self.record = dict(schema='usos-wim-pool-plan-v1', unreserved_files_declared_closed=True,
                           reservations=[dict(path='closed', bytes=1000),dict(path='active',bytes=1000)])
        self.save()
        self.case = self.scope/'boot-case'

    def save(self): self.plan.write_text(json.dumps(self.record),encoding='utf-8')

    def invoke(self,growth=200,closed=True):
        original = os.scandir
        def guard(path):
            if Path(path)==self.active or Path(path).is_relative_to(self.active):
                raise AssertionError('A running reserved scope was traversed')
            return original(path)
        with patch.object(pool.oracle,'RUNTIME',self.root), \
             patch.object(pool.oracle,'storage_guard') as storage, patch.object(pool.os,'scandir',side_effect=guard):
            result=pool.enforce_incremental(self.plan,self.case,growth,closed_scope=closed)
            storage.assert_called_once_with(growth)
            return result

    def test_existing_bytes_are_charged_once_and_only_actual_growth_reserves_free_space(self):
        result=self.invoke()
        self.assertEqual(result['incremental_existing_bytes'],700)
        self.assertEqual(result['incremental_growth_bytes'],200)
        self.assertEqual(result['incremental_scope_limit'],1000)
        self.assertTrue(result['only_selected_closed_scope_traversed'])

    def test_closed_declaration_growth_bound_and_whole_scope_cap_required(self):
        for growth,closed in [(200,False),(0,True),(True,True),(301,True),(2*pool.GiB+1,True)]:
            with self.subTest(growth=growth,closed=closed):
                with self.assertRaises(ValueError):self.invoke(growth,closed)

    def test_firstboot_two_gib_growth_still_requires_whole_scope_capacity(self):
        self.record['reservations'][0]['bytes']=3*pool.GiB
        self.save()
        value=self.invoke(2*pool.GiB)
        self.assertEqual(value['incremental_growth_bytes'],2*pool.GiB)
        self.assertEqual(value['incremental_existing_bytes'],700)

    def test_aggregate_cap_is_not_relaxed_for_incremental_case(self):
        self.record['reservations']=[dict(path='closed',bytes=100*pool.GiB),dict(path='active',bytes=1)]
        self.save()
        with self.assertRaises(ValueError):self.invoke()

    def test_hardlink_in_declared_closed_scope_is_rejected(self):
        os.link(self.scope/'retained.txt',self.scope/'alias.txt')
        with self.assertRaises(ValueError):self.invoke()

    def test_case_without_reservation_and_undeclared_plan_are_refused(self):
        self.case=self.root/'unreserved/boot-case'
        with self.assertRaises(ValueError):self.invoke()
        self.case=self.scope/'boot-case'
        self.record['unreserved_files_declared_closed']=False;self.save()
        with self.assertRaises(ValueError):self.invoke()


if __name__=='__main__':unittest.main()
