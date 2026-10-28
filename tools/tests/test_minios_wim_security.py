# SPDX-License-Identifier: GPL-3.0-or-later
"""Preserve raw SD expectations; distinguish serialization from changed ACLs."""
import importlib.util
from pathlib import Path
import struct
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


m = load("raw_security_probe", "tools/minios/wim_security_readonly.py")
fixture = load("raw_security_expectation", "tools/minios/wim_feature_manifest.py")


class SecurityLayout(unittest.TestCase):
    def test_root_reserved_flags_require_exact_root5_raw_SI_FN_and_keep_source(self):
        row = dict(path="", attributes=16, directory=True)
        raw = dict(record=5, si_attributes=6, filename_attributes=[0x10000006], directory=True)
        proof = m.root_reserved_metadata(row, raw)
        self.assertTrue(proof["passed"])
        self.assertEqual(proof["source_attributes"],16)
        self.assertEqual(proof["observed_native_expected"],22)
        self.assertEqual(row["attributes"],16)
        for change in (dict(record=27), dict(si_attributes=0), dict(si_attributes=0x26),
                       dict(filename_attributes=[0x10000000]),dict(filename_attributes=[]),
                       dict(directory=False)):
            self.assertFalse(m.root_reserved_metadata(row, raw | change)["passed"])
        for change in (dict(path="ordinary"),dict(directory=False),dict(attributes=0x30)):
            self.assertFalse(m.root_reserved_metadata(row | change, raw)["passed"])
        # Other source bits stay exact. Preserve ARCHIVE too, never just mask6.
        self.assertTrue(m.root_reserved_metadata(row | dict(attributes=0x30), raw | dict(si_attributes=0x26, filename_attributes=[0x10000026]))["passed"])

    def test_NORMAL_mapping_requires_every_raw_attribute_zero_and_regular_file(self):
        row = dict(attributes=0, directory=False)
        raw = dict(si_attributes=0, filename_attributes=[0, 0], directory=False)
        self.assertTrue(m.zero_attribute_proven(row, raw))
        for change in (dict(si_attributes=0x20), dict(filename_attributes=[0, 2]),
                       dict(filename_attributes=[]), dict(directory=True)):
            self.assertFalse(m.zero_attribute_proven(row, raw | change))
        for change in (dict(attributes=128), dict(attributes=2), dict(directory=True)):
            self.assertFalse(m.zero_attribute_proven(row | change, raw))

    def test_reordered_same_sections_match_actual_recorded_API_hash(self):
        import hashlib
        original = fixture.default_security()
        candidate = m.api_layout(original)
        self.assertNotEqual(candidate, original)
        self.assertEqual(len(candidate), len(original))
        self.assertEqual(m.components(original)["control"], 0x8004)
        self.assertEqual(m.components(candidate)["control"], 0x8004)
        self.assertEqual(hashlib.sha256(candidate).hexdigest(), "405e5a6992f06e338514ab9b0f03a37dbf855a46a9062af866548fd1b857108b")
        self.assertTrue(m.same_sections(original, candidate))
        self.assertEqual(original, fixture.default_security())

    def test_changed_control_or_ACE_is_not_serialization_equivalence(self):
        raw = fixture.default_security()
        changed = bytearray(m.api_layout(raw))
        changed[2:4] = (0xa004).to_bytes(2, "little")
        self.assertFalse(m.same_sections(raw, changed))
        changed = bytearray(m.api_layout(raw))
        dacl = m.components(changed)["dacl"]["offset"]
        changed[dacl + 8 + 4] ^= 1  # Change ACE access mask, not an offset.
        self.assertFalse(m.same_sections(raw, changed))

    def test_null_DACL_and_owner_group_are_preserved(self):
        raw = fixture.custom_security(1000)
        self.assertIsNone(m.components(raw)["sacl"])
        self.assertIsNone(m.components(raw)["dacl"])
        self.assertEqual(m.api_layout(raw), raw)

    def test_changed_SID_RMcontrol_and_ACE_order_are_not_equivalent(self):
        raw = fixture.default_security()
        sid = bytearray(m.api_layout(raw)); sid[20 + 12] ^= 1
        rm = bytearray(m.api_layout(raw)); rm[1] = 7
        order = bytearray(m.api_layout(raw))
        # Valid ACE records swapped whole, with identical masks/flags/SIDs.
        order[60:104] = order[80:104] + order[60:80]
        for changed in (sid, rm, order):
            self.assertFalse(m.same_sections(raw, changed))

    def test_partial_overlap_or_SID_inside_ACL_is_refused(self):
        raw = fixture.default_security()
        bad = bytearray(raw)
        struct.pack_into("<I", bad, 4, 36)  # Valid SYSTEM SID stored inside ACE.
        with self.assertRaisesRegex(ValueError, "Overlapping"):
            m.components(bad)
        bad = bytearray(raw)
        struct.pack_into("<I", bad, 8, 96)
        with self.assertRaises(ValueError):
            m.components(bad)

    def test_unreferenced_nonzero_bytes_are_not_just_offsets(self):
        raw = fixture.default_security()
        with self.assertRaisesRegex(ValueError, "Nonzero"):
            m.components(raw + b"\1\0\0\0")

    def test_raw_SDS_hash_duplicate_and_identity_are_checked(self):
        raw = fixture.default_security()
        entry = struct.pack("<IIQI", m.security_hash(raw), 256, 0, 20 + len(raw)) + raw
        stored = entry + bytes(0x40000 - len(entry)) + entry
        self.assertEqual(m.sds_descriptors(stored), {256: raw})
        for offset in (0, 8, 0x40000 + 30):
            bad = bytearray(stored); bad[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                m.sds_descriptors(bad)

    def test_rejects_truncation_nonrelative_and_out_of_bounds_SID_ACL(self):
        raw = fixture.default_security()
        examples = [raw[:19], b"\0" * 124]
        bad = bytearray(raw); struct.pack_into("<I", bad, 4, 10000); examples.append(bad)
        bad = bytearray(raw); bad[93] = 255; examples.append(bad)
        bad = bytearray(raw); struct.pack_into("<H", bad, 22, 8); examples.append(bad)
        bad = bytearray(raw); struct.pack_into("<H", bad, 30, 1000); examples.append(bad)
        for value in examples:
            with self.subTest(value=bytes(value[:20]).hex()), self.assertRaises(ValueError):
                m.components(value)

    def test_source_must_be_readonly_before_any_image_open(self):
        with patch.object(m.oracle, "owned"), patch.object(Path, "is_file", return_value=True), patch.object(Path, "stat", return_value=SimpleNamespace(st_file_attributes=0)), patch.object(m.ntfs, "Image") as image:
            with self.assertRaisesRegex(ValueError, "read-only"):
                m.inspect(Path("fixture.raw"), "0" * 64, Path("expected.jsonl"), "1" * 64, Path("out.json"))
            image.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
