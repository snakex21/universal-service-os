"""Only own synthetic fixtures; no existing VM/VHD or actual case cleanup."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import unittest
import uuid

HERE = Path(__file__).resolve().parents[1] / "minios"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cleanup = load("scale_cleanup_test", HERE / "cleanup_scale.py")
runtime = cleanup.runtime
ROOT = Path(os.environ.get("USOS_MINIOS_TEST_WORKSPACE", HERE.parents[1] / "zig-out/minios-scale-unit"))


class Runtime(unittest.TestCase):
    def setUp(self):
        ROOT.mkdir(parents=True, exist_ok=True)
        self.root = ROOT.resolve()
        self.case = self.root / ("_unit-" + uuid.uuid4().hex)
        self.case.mkdir()

    def tearDown(self):
        target = self.case.resolve()
        if target.parent != self.root or not target.name.startswith("_unit-"):
            raise ValueError("Unit cleanup escaped its exact owned directory")
        runtime.guarded(self.root, target)
        for path in target.rglob("*"):
            if path.is_file(): path.chmod(stat.S_IREAD | stat.S_IWRITE)
        shutil.rmtree(target)

    def test_guard_rejects_sibling_root_device_and_control_paths(self):
        for path in (self.root, self.root.parent / "sibling" / "file.raw",
                     Path(r"\\.\PhysicalDrive0"), self.case / ".." / "escape.raw",
                     self.case / "bad,comma.raw", self.case / "bad\nfile.raw"):
            with self.subTest(path=path), self.assertRaises(ValueError): runtime.guarded(self.root, path)
        self.assertEqual(runtime.guarded(self.root, self.case / "target.raw"), self.case / "target.raw")

    def test_nonstage1b_runtime_cannot_select_any_cases(self):
        with self.assertRaises(ValueError): runtime.cases(self.case, [], [])

    def test_no_sharing_handle_blocks_another_writer(self):
        image = self.case / "own-synthetic.bin"; image.write_bytes(b"synthetic image bytes")
        with cleanup.AtomicImage(image) as opened:
            size, digest = opened.digest()
            self.assertEqual(size, 21)
            self.assertEqual(len(digest), 64)
            with self.assertRaises(PermissionError):
                with image.open("r+b"): pass
        self.assertEqual(image.read_bytes(), b"synthetic image bytes")

    def test_cleanup_requires_a_preserved_final_report_not_a_draft(self):
        (self.case / "validation").mkdir()
        path = self.case / "validation/final-report-pre-cleanup.md"
        with self.assertRaises(FileNotFoundError): cleanup.report_ready(self.case)
        path.write_text("# MiniOS etap 1b-1\nStatus: raport roboczy\n", encoding="utf-8")
        with self.assertRaises(ValueError): cleanup.report_ready(self.case)
        path.write_text("# MiniOS etap 1b-1\nStatus: RAPORT KOŃCOWY\n", encoding="utf-8")
        result = cleanup.report_ready(self.case)
        self.assertEqual(result["path"], "validation/final-report-pre-cleanup.md")
        self.assertEqual(len(result["sha256"]), 64)

    def test_delete_same_held_handle_handles_readonly_and_preserves_neighbor(self):
        image = self.case / "own-synthetic.bin"; image.write_bytes(b"safe synthetic fixture")
        neighbor = self.case / "preserved.log"; neighbor.write_bytes(b"preserve")
        image.chmod(stat.S_IREAD)
        with cleanup.AtomicImage(image) as opened:
            size, _ = opened.digest()
            self.assertEqual(size, 22)
            opened.delete()
        self.assertFalse(image.exists())
        self.assertEqual(neighbor.read_bytes(), b"preserve")

    def test_explicit_candidates_never_include_unknown_images(self):
        for name in ("blank-base.qcow2", "fresh-test-cow.qcow2", "target.raw", "unknown.img"):
            (self.case / name).write_bytes(b"synthetic")
        windows = self.case / "windows"; windows.mkdir()
        for name in ("converted-fixed.vhd", "readonly-copy.vhd"):
            (windows / name).write_bytes(b"not a real VHD")
        case = {"case": self.case, "firmware": False, "windows_dir": windows}
        selected = cleanup.candidates(self.root, case)
        self.assertEqual(len(selected), 5)
        self.assertNotIn(self.case / "unknown.img", selected)
        self.assertTrue((self.case / "unknown.img").exists())

    def accepted_receipt_fixture(self):
        def save(path, value): path.write_text(json.dumps(value))
        size = 512 * 1024**2; digest = "a" * 64
        save(self.case / "prepared.json", {"image_only": True, "profile": "tree150k", "image_bytes": size})
        save(self.case / "manifest.json", {"files": {"own.bin": {"size": 1, "sha256": "b" * 64}}, "directories": []})
        save(self.case / "completed.json", {"application_pass": True, "returncode": 0, "raw_sha256": digest})
        save(self.case / "windows-invocation.json", {"returncode": 0})
        (self.case / "writer.log").write_text("USOSPREP SCALE PASS alloc_peak=1234\n")
        save(self.case / "structure.json", {"kind": "independent-readonly-NTFS-byte-inspection",
            "mft_mirror_equal": True, "files": 1, "directories": 0, "mft_records": 16384,
            "mft_runs": 2, "mft_physical_extent_count": 2, "fragmented_files": []})
        windows = self.case / "windows"; windows.mkdir()
        record = {"kind": "windows-readonly-chkdsk", "passed": True, "readonly_chkdsk_pass": True,
            "readonly_file_tree_pass": True, "chkdsk_issued": True, "chkdsk_exit": 0,
            "chkdsk_flags": [], "repair_flags_used": False, "access": "ReadOnly",
            "dismounted": True, "temporary_dos_alias_removed": True,
            "source_sha256_before": digest, "source_sha256_after": digest,
            "vhd_sha256_before": "c" * 64, "vhd_sha256_after": "c" * 64,
            "chkdsk_target_guard": {"passed": True, "readonly": True, "expected_image_bytes": size,
                "actual_disk_bytes": size, "system": False, "boot": False},
            "file_tree": {"files": [{"path": "own.bin", "size": 1, "sha256": "b" * 64}], "directories": []}}
        save(windows / "result.json", record)
        return record

    def test_receipt_validation_compares_actual_bytes_against_manifest_again(self):
        record = self.accepted_receipt_fixture()
        accepted = runtime.validated_case(self.root, self.case, False)
        self.assertEqual(accepted["profile"], "tree150k")
        record["file_tree"]["files"][0]["sha256"] = "d" * 64
        (self.case / "windows/result.json").write_text(json.dumps(record))
        with self.assertRaises(ValueError): runtime.validated_case(self.root, self.case, False)

    def test_success_receipt_cannot_replace_missing_dismount(self):
        record = self.accepted_receipt_fixture()
        record["dismounted"] = False
        (self.case / "windows/result.json").write_text(json.dumps(record))
        with self.assertRaises(ValueError): runtime.validated_case(self.root, self.case, False)

    def test_independent_structure_must_cross_mft_limit_and_match_mirror(self):
        expected = {"files": {}, "directories": []}
        value = {"kind": "independent-readonly-NTFS-byte-inspection", "mft_mirror_equal": True,
            "files": 0, "directories": 0, "mft_records": 8192, "mft_runs": 2, "mft_physical_extent_count": 2}
        with self.assertRaises(ValueError): runtime.validate_structure(value, "tree150k", expected)
        value["mft_records"] = 16384
        runtime.validate_structure(value, "tree150k", expected)
        value["mft_mirror_equal"] = False
        with self.assertRaises(ValueError): runtime.validate_structure(value, "tree150k", expected)

    def test_fragmentation_requires_large_bytes_and_attribute_overflow(self):
        expected = {"files": {"Frag/fragmented.bin": {"size": 5 * 1024**3}}, "directories": ["Frag"]}
        fragment = {"run_count": 128, "physical_extent_count": 128, "size": 5 * 1024**3, "attribute_list": True, "extension_records": 2}
        value = {"kind": "independent-readonly-NTFS-byte-inspection", "mft_mirror_equal": True,
            "files": 1, "directories": 1, "fragmented_files": [fragment]}
        runtime.validate_structure(value, "fragment5g", expected)
        fragment["attribute_list"] = False
        with self.assertRaises(ValueError): runtime.validate_structure(value, "fragment5g", expected)


if __name__ == "__main__": unittest.main()
