# SPDX-License-Identifier: GPL-3.0-or-later
"""Aggregate pool counts retained closed files and never traverses active paths."""
import importlib.util
import contextlib
import json
from pathlib import Path
import stat
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wim_pool", REPO / "tools/minios/wim_pool.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
TMP = REPO / "runtime/wim-codec/tmp"; TMP.mkdir(parents=True, exist_ok=True)


class PoolTests(unittest.TestCase):
    def test_default100_and_explicit150_plan_budget_with_hard_maximum(self):
        self.assertEqual(m.plan_limit({}), 100 * m.GiB)
        self.assertEqual(m.plan_limit({"cap_bytes": 100 * m.GiB}), 100 * m.GiB)
        self.assertEqual(m.plan_limit({"cap_bytes": 150 * m.GiB}), 150 * m.GiB)
        for bad in (True, "161061273600", 0, 120 * m.GiB, 150 * m.GiB + 1):
            with self.assertRaises(ValueError): m.plan_limit({"cap_bytes": bad})
        with patch.object(m.os, "scandir") as scan:
            with self.assertRaises(ValueError): m.audit(m.oracle.RUNTIME, [], limit=m.MAX_CAP + 1)
            scan.assert_not_called()

    def test150_boundary_counts_closed_bytes_and_requires_explicit_opt_in(self):
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            root = Path(temporary); (root / "closed.log").write_bytes(b"x")
            reserved = [{"path": "future", "bytes": 150 * m.GiB - 1}]
            with patch.object(m.oracle, "RUNTIME", root):
                with self.assertRaises(ValueError): m.audit(root, reserved)
                exact = m.audit(root, reserved, limit=m.plan_limit({"cap_bytes": 150 * m.GiB}))
                self.assertTrue(exact["passed"])
                self.assertEqual(exact["projected_total_bytes"], 150 * m.GiB)
                self.assertEqual(exact["headroom_bytes"], 0)
                over = m.audit(root, [{"path": "future", "bytes": 150 * m.GiB}], limit=m.MAX_CAP)
                self.assertFalse(over["passed"])
                self.assertEqual(over["headroom_bytes"], -1)

    def test_enforce_uses_explicit_budget_and_preserves_per_operation_free_guard(self):
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            root = Path(temporary)
            plan = root / "plan.json"
            record = {"schema": "usos-wim-pool-plan-v1", "unreserved_files_declared_closed": True,
                      "cap_bytes": 150 * m.GiB,
                      "reservations": [{"path": "active", "bytes": 90 * m.GiB},
                                       {"path": "future", "bytes": 40 * m.GiB}]}
            plan.write_text(json.dumps(record), encoding="utf-8")
            with patch.object(m.oracle, "RUNTIME", root), patch.object(m.oracle, "owned", side_effect=lambda p: p), \
                 patch.object(m.oracle, "storage_guard") as guard:
                result = m.enforce(plan, root / "future")
                self.assertTrue(result["passed"])
                self.assertEqual(result["cap_bytes"], 150 * m.GiB)
                guard.assert_called_once_with(40 * m.GiB)
                record.pop("cap_bytes"); plan.write_text(json.dumps(record), encoding="utf-8")
                with self.assertRaises(ValueError): m.enforce(plan, root / "future")
                guard.assert_called_once_with(40 * m.GiB)

    def test_native_reparse_fixture_is_opaque_and_target_is_never_opened(self):
        root = m.oracle.RUNTIME
        class Entry:
            path = str(root / "relative-link")
            def stat(self, *, follow_symlinks):
                self_test.assertFalse(follow_symlinks)
                return SimpleNamespace(st_file_attributes=0x400, st_mode=stat.S_IFDIR, st_size=27)
            def is_symlink(self): return True
        self_test = self
        @contextlib.contextmanager
        def scan(path):
            self.assertEqual(Path(path), root)
            yield [Entry()]
        with patch.object(m.os, "scandir", side_effect=scan):
            result = m.audit(root, [], limit=100)
        self.assertEqual(result["closed_logical_bytes"], 27)
        self.assertEqual(result["opaque_reparse_leaves_not_followed"], ["relative-link"])

    def test_closed_plus_declared_reservations_and_no_active_traversal(self):
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            root = Path(temporary)
            (root / "closed.raw").write_bytes(b"x" * 20)
            active = root / "active"; active.mkdir(); (active / "ongoing.raw").write_bytes(b"x" * 50)
            original = m.os.scandir
            def scan(path):
                self.assertNotEqual(Path(path), active, "Active subtree must never be opened")
                return original(path)
            with patch.object(m.oracle, "RUNTIME", root), patch.object(m.os, "scandir", side_effect=scan):
                result = m.audit(root, [{"path": "active", "bytes": 100}, {"path": "future", "bytes": 30}], limit=150)
                self.assertTrue(result["passed"])
                self.assertEqual(result["closed_logical_bytes"], 20)
                self.assertEqual(result["projected_total_bytes"], 150)
                self.assertFalse(m.audit(root, [{"path": "active", "bytes": 100}, {"path": "future", "bytes": 30}], limit=149)["passed"])

    def test_individual_active_file_excluded_without_size_count_double_charge(self):
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            root = Path(temporary); (root / "base.raw").write_bytes(b"x" * 14)
            (root / "active.raw").write_bytes(b"x" * 9)
            with patch.object(m.oracle, "RUNTIME", root):
                value = m.audit(root, [{"path": "active.raw", "bytes": 42}], limit=100)
                self.assertEqual(value["closed_logical_bytes"], 14)
                self.assertEqual(value["projected_total_bytes"], 56)

    def test_overlap_escape_and_unbounded_budget_refused_before_scan(self):
        root = m.oracle.RUNTIME
        cases = ([{"path": "a", "bytes": 1}, {"path": "a/b", "bytes": 1}],
                 [{"path": "../escape", "bytes": 1}], [{"path": "", "bytes": 1}],
                 [{"path": "a", "bytes": 0}], [{"path": "a", "bytes": m.CAP + 1}])
        with patch.object(m.os, "scandir") as scan:
            for reservations in cases:
                with self.assertRaises(ValueError): m.audit(root, reservations)
            scan.assert_not_called()


if __name__ == "__main__": unittest.main()
