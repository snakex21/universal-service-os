# SPDX-License-Identifier: GPL-3.0-or-later
"""Own-data generation fidelity and immutable-output refusals; no physical disks."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wim_fixtures", REPO / "tools/minios/wim_fixtures.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
TMP = REPO / "runtime/wim-codec/tmp"
TMP.mkdir(parents=True, exist_ok=True)


class FixtureTests(unittest.TestCase):
    def test_payload_streams_and_random_data_are_reproducible_and_bounded(self):
        for mode in ("random", "repeat"):
            blocks = list(m.payload(3 * 65536 + 17, mode, 23))
            self.assertEqual([len(block) for block in blocks], [65536, 65536, 65536, 17])
            self.assertEqual(b"".join(blocks), b"".join(m.payload(3 * 65536 + 17, mode, 23)))
        self.assertNotEqual(b"".join(m.payload(100, "random", 23)), b"".join(m.payload(100, "random", 24)))

    def test_generated_names_zeroes_hashes_and_large_files_match_actual_bytes(self):
        with tempfile.TemporaryDirectory(dir=TMP) as temporary, patch.object(m, "set_times"):
            root = Path(temporary) / "source"
            manifest = m.write_source(root, count=17)
            self.assertGreater(manifest["logical_bytes"], 7 * m.MiB)
            self.assertTrue(any("🚀" in row["path"] for row in manifest["files"]))
            self.assertTrue(any(row["size"] == 0 for row in manifest["files"]))
            for row in manifest["files"]:
                actual = (root / row["path"]).read_bytes()
                self.assertEqual(len(actual), row["size"])
                self.assertEqual(hashlib.sha1(actual).hexdigest(), row["sha1"])
            self.assertEqual(len([p for p in root.rglob("*") if p.is_file()]), manifest["file_count"])
            with self.assertRaises(FileExistsError):
                m.write_source(root)

    def test_bad_count_refused_before_output(self):
        for count in (0, -1, 4097, True, "7"):
            with self.assertRaises(ValueError):
                m.write_source(TMP / "MUST-NOT-BE-CREATED", count=count)
        self.assertFalse((TMP / "MUST-NOT-BE-CREATED").exists())

    def test_large_profile_has_1200plus_files_and_bounded_compressible_128mib_file(self):
        specs = m.source_specs(count=1200, large_file_bytes=128 * m.MiB + 123)
        self.assertGreaterEqual(len(specs), 1200)
        huge = [row for row in specs if row[1] > 100 * m.MiB]
        self.assertEqual(len(huge), 1)
        self.assertEqual(huge[0][1], 128 * m.MiB + 123)
        self.assertEqual(huge[0][2], "repeat")
        self.assertLess(sum(row[1] for row in specs), 150 * m.MiB)
        iterator = m.payload(huge[0][1], huge[0][2], huge[0][3])
        first, second = next(iterator), next(iterator)
        self.assertEqual(len(first), 65536)
        self.assertEqual(first, second)

    def test_large_file_parameter_is_checked_before_creating_source(self):
        for size in (-1, True, 100 * m.MiB, 193 * m.MiB, "128"):
            with self.assertRaises(ValueError):
                m.write_source(TMP / "MUST-NOT-BE-CREATED", large_file_bytes=size)
        self.assertFalse((TMP / "MUST-NOT-BE-CREATED").exists())

    def test_output_is_only_fresh_child_of_synthetic_runtime(self):
        root = m.oracle.RUNTIME / "synthetic"
        self.assertEqual(m.output_guard(root / "new-fixture"), root / "new-fixture")
        for path in (root, m.oracle.RUNTIME / "inputs/new-fixture", Path(r"\\.\PhysicalDrive0")):
            with self.assertRaises(ValueError):
                m.output_guard(path)
        with patch.object(Path, "exists", return_value=True), patch.object(Path, "is_symlink", return_value=False), patch.object(Path, "lstat") as info:
            info.return_value.st_file_attributes = 0
            with self.assertRaises(FileExistsError):
                m.output_guard(root / "old-fixture")

    def test_source_capture_comparison_rejects_wrong_hash_size_and_extra_names(self):
        source = {"file_count": 1, "directory_count": 1,
                  "files": [{"path": "own", "size": 3, "sha1": hashlib.sha1(b"own").hexdigest()}]}
        rows = [{"path": "", "directory": True}, {"path": "own", "directory": False,
                "streams": [{"name": None, "size": 3, "sha1": source["files"][0]["sha1"]}]}]
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            path = Path(temporary) / "tree.jsonl"
            def write():
                path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
            write(); m.verify_source_tree(source, path)
            rows[1]["streams"][0]["sha1"] = "0" * 40
            write()
            with self.assertRaisesRegex(ValueError, "SHA1"):
                m.verify_source_tree(source, path)
            rows[1]["streams"][0]["size"] = 4
            write()
            with self.assertRaisesRegex(ValueError, "length"):
                m.verify_source_tree(source, path)
            rows.append({"path": "extra", "directory": False})
            write()
            with self.assertRaisesRegex(ValueError, "names/counts"):
                m.verify_source_tree(source, path)

    def test_source_capture_requires_exact_ads_names_sizes_and_sha1(self):
        streams = [{"name": "Zone.Identifier", "size": 37, "sha1": "1" * 40},
                   {"name": "large-世界", "size": 196609, "sha1": "2" * 40}]
        source = {"file_count": 1, "directory_count": 1,
                  "files": [{"path": "own", "size": 3, "sha1": "3" * 40, "named_streams": streams}]}
        rows = [{"path": "", "directory": True}, {"path": "own", "directory": False,
                "streams": [{"name": None, "size": 3, "sha1": "3" * 40}, *[row.copy() for row in streams]]}]
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            path = Path(temporary) / "tree.jsonl"
            def write(): path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf8")
            write(); m.verify_source_tree(source, path)
            rows[1]["streams"][2]["sha1"] = "f" * 40; write()
            with self.assertRaisesRegex(ValueError, "SHA1"): m.verify_source_tree(source, path)
            rows[1]["streams"].pop(); write()
            with self.assertRaisesRegex(ValueError, "stream"): m.verify_source_tree(source, path)


if __name__ == "__main__":
    unittest.main()
