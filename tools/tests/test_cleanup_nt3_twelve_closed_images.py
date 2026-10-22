"""Read-only safety contracts; never execute cleanup or inspect VM processes."""
import json
import os
from pathlib import Path
import unittest

import cleanup_nt3_twelve_closed_images as cleanup


@unittest.skipUnless(os.name == "nt", "Win32 exclusive file handles")
class SafetyContracts(unittest.TestCase):
    def setUp(self):
        # Test only our source file, never the G: cleanup candidates.
        self.own_source = Path(cleanup.__file__).resolve()
        self.expected = cleanup.metadata(self.own_source)

    def test_exact_twelve_and_plan_pin(self):
        plan = json.loads(cleanup.PLAN.read_text(encoding="utf-8"))
        self.assertEqual(cleanup.sha(cleanup.PLAN), cleanup.PLAN_SHA)
        self.assertEqual(tuple(plan["eligible_leaf_order"]), cleanup.TAGS)
        paths = {str(cleanup.VM / tag / name)
                 for tag in cleanup.TAGS for name in cleanup.NAMES}
        self.assertEqual(len(paths), 12)
        self.assertEqual(sum(f["bytes"] for f in plan["files"]
                             if f["path"] in paths), 801771008)

    def test_native_identity_matches_preopen_python_stat(self):
        handle = cleanup.ExclusiveFile(self.own_source, self.expected)
        try:
            self.assertEqual(handle.actual, self.expected)
        finally:
            handle.close()

    def test_exclusive_handle_refuses_another_open(self):
        handle = cleanup.ExclusiveFile(self.own_source, self.expected)
        try:
            with self.assertRaises(OSError) as caught:
                cleanup.ExclusiveFile(self.own_source, self.expected)
            self.assertEqual(caught.exception.errno, 32)  # ERROR_SHARING_VIOLATION
        finally:
            handle.close()

    def test_wrong_id_is_refused_and_handle_released(self):
        wrong = {**self.expected, "file_id": ["0", "0"]}
        with self.assertRaises(ValueError):
            cleanup.ExclusiveFile(self.own_source, wrong)
        handle = cleanup.ExclusiveFile(self.own_source, self.expected)
        handle.close()


if __name__ == "__main__":
    unittest.main()
