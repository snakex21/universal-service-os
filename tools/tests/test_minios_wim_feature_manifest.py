# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent fixed feature expectations: no NTFS read or image generation."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("own_feature_manifest", ROOT / "tools/minios/wim_feature_manifest.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class FeatureContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = list(m.entries())
        cls.tree = {row["path"]: row for row in cls.rows}

    def test_pattern_known_bytes_and_chunk_boundary_independence(self):
        self.assertEqual(m.pattern_sha1(8, 0x71), hashlib.sha1(bytes.fromhex("71543b1ee5c8af72")).hexdigest())
        self.assertEqual(m.pattern_sha1(8193, 0x71, block_size=17), m.pattern_sha1(8193, 0x71, block_size=65536))
        self.assertEqual(m.pattern_sha1(1048613, 0x53, True, 1001), m.pattern_sha1(1048613, 0x53, True))
        self.assertNotEqual(m.pattern_sha1(1048613, 0x53, True), m.pattern_sha1(1048613, 0x53, False))

    def test_all_security_descriptors_are_distinct_and_have_exact_SIDs(self):
        sd = m.default_security()
        self.assertEqual(len(sd), 124)
        self.assertEqual(sd[:20].hex(), "010004805c0000006c0000000000000014000000")
        self.assertEqual(sd[92:108], m.sid(5, 32, 544))
        self.assertEqual(sd[108:124], m.sid(5, 32, 544))
        hashes = {hashlib.sha256(sd).hexdigest()}
        for rid in range(1000, 6000):
            custom = m.custom_security(rid)
            self.assertEqual(len(custom), 48)
            self.assertEqual(struct.unpack_from("<HIIII", custom, 2), (0x8000, 20, 32, 0, 0))
            self.assertEqual(custom[20:32], m.sid(5, rid))
            self.assertEqual(custom[32:], m.sid(5, 32, 544))
            hashes.add(hashlib.sha256(custom).hexdigest())
        self.assertEqual(len(hashes), 5001)

    def test_unlinked_original_absent_and_two_survivors_share_ADS_and_security(self):
        self.assertNotIn("Links/original.bin", self.tree)
        a, b = self.tree["Links/third.bin"], self.tree["Streams/survivor.bin"]
        self.assertEqual((a["link_count"], b["link_count"]), (2, 2))
        self.assertEqual(a["hardlink_group_id"], b["hardlink_group_id"])
        self.assertEqual(a["streams"], b["streams"])
        self.assertEqual(a["security_sha256"], self.tree["Security/s0000"]["security_sha256"])
        self.assertEqual(a["attributes"], 0x27)
        self.assertEqual([(s["name"], s["size"]) for s in a["streams"]], [(None, 8193), ("Zone.Identifier", 37), ("large-世界", 196609)])

    def test_sparse_compressed_and_empty_keep_separate_layout_flags(self):
        compressed, sparse = self.tree["Streams/compressed.bin"], self.tree["Streams/dense-sparse.bin"]
        self.assertEqual(compressed["streams"], sparse["streams"])
        self.assertEqual((compressed["attributes"], sparse["attributes"]), (0x820, 0x220))
        self.assertEqual(self.tree["Streams/sparse.bin"]["streams"][0]["size"], 1048613)
        empty = self.tree["Streams/zero.bin"]
        self.assertEqual(empty["streams"][0]["sha1"], hashlib.sha1(b"").hexdigest())
        self.assertEqual(empty["attributes"], 0x220)

    def test_reparse_raw_targets_are_unchanged_and_hash_excludes_only_header(self):
        for name, tag, target in (("Reparse/junction", 0xa0000003, r"\??\C:\Links\Target"), ("Reparse/symlink", 0xa000000c, r"..\Links\third.bin")):
            row = self.tree[name]
            raw = bytes.fromhex(row["raw_reparse_hex"])
            self.assertEqual(struct.unpack_from("<I", raw)[0], tag)
            self.assertEqual(struct.unpack_from("<H", raw, 4)[0], len(raw) - 8)
            self.assertEqual(row["streams"][0]["sha1"], hashlib.sha1(raw[8:]).hexdigest())
            offset, size = struct.unpack_from("<HH", raw, 8)
            prefix = 20 if tag == 0xa000000c else 16
            self.assertEqual(raw[prefix + offset:prefix + offset + size].decode("utf-16le"), target)
        self.assertEqual(self.tree["Reparse/junction"]["attributes"], 0x410)
        self.assertEqual(self.tree["Reparse/symlink"]["attributes"], 0x420)

    def test_tree_is_complete_parents_precede_children_and_four_times_are_explicit(self):
        self.assertEqual(len(self.rows), len(self.tree))
        self.assertEqual(len(self.rows), 5014)
        seen = set()
        for row in self.rows:
            path = row["path"]
            if path:
                parent = path.rsplit("/", 1)[0] if "/" in path else ""
                self.assertIn(parent, seen)
            seen.add(path)
        link = self.tree["Links/third.bin"]
        self.assertEqual([link[k] for k in ("creation_filetime", "modified_filetime", "changed_filetime", "accessed_filetime")], list(m.FOUR_TIMES.values()))
        self.assertEqual(len({link[k] for k in ("creation_filetime", "modified_filetime", "changed_filetime", "accessed_filetime")}), 4)
        self.assertEqual(self.tree["Streams/zero.bin"]["changed_filetime"], m.FOUR_TIMES["changed"])

    def test_changed_fixture_contract_refused_before_output(self):
        with patch.object(m.oracle, "digest", return_value="0" * 64), patch.object(m.oracle, "storage_guard") as storage:
            with self.assertRaisesRegex(ValueError, "contract changed"):
                m.generate(m.oracle.RUNTIME / "NEVER-CREATED-contract-test")
            storage.assert_not_called()

    def test_output_never_overwrites_existing_evidence(self):
        with patch.object(Path, "exists", return_value=True), patch.object(Path, "is_symlink", return_value=False), patch.object(Path, "lstat") as st, patch.object(m.oracle, "digest") as read:
            st.return_value.st_file_attributes = 0
            with self.assertRaises(FileExistsError):
                m.generate(m.oracle.RUNTIME / "existing")
            read.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
