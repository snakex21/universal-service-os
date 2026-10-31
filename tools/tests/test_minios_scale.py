"""Scaling fixture/independent-byte-oracle contracts; no guest or target IO."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import unittest

HERE = Path(__file__).resolve().parents[1] / "minios"


def load(name):
    spec = importlib.util.spec_from_file_location("minios_unit_" + name, HERE / (name+".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fixtures = load("scale_case")
inspect = load("inspect_ntfs")


class Fixtures(unittest.TestCase):
    def test_seed_is_little_endian_and_pattern_repeats_at_cluster_boundary(self):
        seed = 0x1122334455667788
        block = fixtures.generated_block(seed)
        self.assertEqual(block[:8],bytes.fromhex("8877665544332211"))
        self.assertEqual(block[8:12],bytes((51,88,125,162)))
        self.assertEqual(fixtures.generated_sha(4097,seed),hashlib.sha256(block+block[:1]).hexdigest())
        self.assertEqual(fixtures.generated_sha(0,seed),hashlib.sha256(b"").hexdigest())

    def test_large_hash_streaming_crosses_bulk_chunk_boundary(self):
        block = fixtures.generated_block(7)
        size = 1024*1024+123
        expected = hashlib.sha256(block*256+block[:123]).hexdigest()
        self.assertEqual(fixtures.generated_sha(size,7),expected)

    def test_firmware_manifest_counts_and_real_fragmentation_survivors(self):
        tree = fixtures.manifest("firmware")
        self.assertEqual(len(tree["files"]),10257)
        self.assertEqual(len(tree["directories"]),104)
        self.assertEqual(tree["files"]["Frag/fragmented.bin"]["size"],16*1024*1024)
        self.assertFalse(any("hole-" in path for path in tree["files"]))
        self.assertEqual(tree["files"]["Tree/dir-099/file-00049.bin"]["sha256"],fixtures.generated_sha(64,9999))

    def test_single_directory_manifest_has_fifty_thousand_distinct_names_and_data(self):
        tree = fixtures.manifest("single50k")
        self.assertEqual(tree["directories"],["Wide"])
        self.assertEqual(len(tree["files"]),50000)
        self.assertEqual(len({row["sha256"] for row in tree["files"].values()}),50000)

    def test_invalid_profile_and_u64_rejected(self):
        with self.assertRaises(ValueError): fixtures.manifest("wim")
        for size,seed in ((-1,0),(0,-1),(1<<64,0),(0,1<<64)):
            with self.assertRaises(ValueError): fixtures.generated_sha(size,seed)


class ByteOracle(unittest.TestCase):
    def test_adjacent_runlist_entries_are_not_evidence_of_fragmentation(self):
        self.assertEqual(inspect.physical_extent_count([(0,4,100),(4,3,104),(7,2,200)]),2)
        self.assertEqual(inspect.physical_extent_count([(0,4,100),(4,3,104)]),1)
        self.assertEqual(inspect.physical_extent_count([(0,4,100),(4,3,None),(7,2,104)]),2)

    def test_mapping_pairs_include_negative_lcn_deltas_and_sparse_run(self):
        attr = bytearray(80)
        attr[8] = 1
        struct.pack_into("<Q",attr,24,8)
        struct.pack_into("<H",attr,32,64)
        attr[64:73] = bytes.fromhex("1104641103f6010200")
        self.assertEqual(inspect.runs(attr),[(0,4,100),(4,3,90),(7,2,None)])
        struct.pack_into("<Q",attr,24,9)
        with self.assertRaises(ValueError): inspect.runs(attr)

    def test_torn_mft_fixup_is_rejected(self):
        record = bytearray(1024)
        record[:4] = b"FILE"
        struct.pack_into("<HH",record,4,48,3)
        record[48:54] = b"\x34\x12\x01\x02\x03\x04"
        record[510:512] = record[1022:1024] = b"\x34\x12"
        fixed = inspect.unprotect(record,b"FILE")
        self.assertEqual(fixed[510:512],b"\x01\x02")
        self.assertEqual(fixed[1022:1024],b"\x03\x04")
        record[1022] ^= 1
        with self.assertRaises(ValueError): inspect.unprotect(record,b"FILE")

    def test_attribute_list_continuation_reference_and_lowest_vcn(self):
        entry = bytearray(32)
        struct.pack_into("<IHBBQQH",entry,0,0x80,32,0,26,900,0x0001000000001234,4)
        parsed = inspect.Image.list_entries(entry)
        self.assertEqual(parsed,[dict(kind=0x80,name="",lowest=900,reference=0x0001000000001234,id=4)])
        entry[4] = 24
        with self.assertRaises(ValueError): inspect.Image.list_entries(entry)

    def test_stream_run_gap_or_inconsistent_size_rejected(self):
        inspect.Image.validate_runs([(0,2,9),(2,3,20)],5*4096)
        with self.assertRaises(ValueError): inspect.Image.validate_runs([(0,2,9),(3,3,20)],5*4096)
        with self.assertRaises(ValueError): inspect.Image.validate_runs([(0,2,9)],3*4096)


if __name__ == "__main__":
    unittest.main()
