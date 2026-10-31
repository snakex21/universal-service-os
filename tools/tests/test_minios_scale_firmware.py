"""Scaling-platform integration checks; no QEMU/build or host disk mounting."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parents[1] / "minios"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


api = load("scale_test_api", HERE / "uefi_case.py")
runner = load("scale_test_runner", HERE / "scale_firmware_case.py")
ROOT = Path(os.environ.get("USOS_MINIOS_TEST_WORKSPACE", HERE.parents[1] / "zig-out/minios-scale-unit"))


class ScaleFirmware(unittest.TestCase):
    def setUp(self):
        ROOT.mkdir(parents=True, exist_ok=True)
        api.ROOT = ROOT.resolve()
        self.case = api.checked(api.ROOT / ("_unit-" + uuid.uuid4().hex))
        self.case.mkdir()

    def tearDown(self):
        target = self.case.resolve()
        if target.parent != api.ROOT or not target.name.startswith("_unit-"):
            raise ValueError("Unit cleanup target escaped the owned test workspace")
        api.checked(target)
        shutil.rmtree(target)

    @staticmethod
    def manifest_module():
        return SimpleNamespace(manifest=lambda profile: {
            "files": {"Wide/file-00000.bin": {"size": 64, "sha256": "a" * 64}},
            "directories": ["Wide"],
        })

    def prepare_scale(self, arch):
        program = self.case / ("dummy.img" if arch == "bios" else "dummy.efi")
        with program.open("xb") as file:
            if arch == "bios": file.truncate(1024 * 1024)
            else: file.write(b"Own unit fixture; not executable")
        target = self.case / "prepared"
        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda _module: None))
        with patch.object(api.importlib.util, "spec_from_file_location", return_value=spec), \
             patch.object(api.importlib.util, "module_from_spec", return_value=self.manifest_module()), \
             patch.object(api, "large_blocks", side_effect=AssertionError("Scaling must generate guest sources")), \
             patch.object(api.shutil, "disk_usage", return_value=SimpleNamespace(free=200 * 1024**3)):
            api.prepare(target, arch, "gpt", program, 512 * 1024**2, profile="scale-firmware")
        return target

    def test_uefi_scaling_configuration_does_not_copy_large_fixture(self):
        case = self.prepare_scale("ia32")
        prepared = json.loads((case / "prepared.json").read_text())
        self.assertEqual(prepared["profile"], "scale-firmware")
        self.assertNotIn("large", prepared["hashes"])
        with (case / "esp-base.raw").open("rb") as file:
            data = file.read(5 * 1024 * 1024)
        self.assertIn(b"profile=scale-firmware\n", data)
        self.assertNotIn(b"LARGE   BIN", data)
        self.assertEqual(json.loads((case / "manifest.json").read_text())["directories"], ["Wide"])

    def test_bios_profile_has_explicit_versioned_slot_and_no_large_data(self):
        case = self.prepare_scale("bios")
        with (case / "esp-base.raw").open("rb") as file:
            file.seek(1024 * 512); cfg = file.read(512)
            file.seek(2056 * 512); unused = file.read(4096)
        self.assertEqual(cfg[:16], b"USOSPREP BIOS v1")
        self.assertEqual(cfg[128:130], b"\x81\x80")
        self.assertEqual(struct.unpack_from("<I", cfg, 132)[0], 1)
        self.assertEqual(unused, bytes(4096))

    def test_unknown_profile_fails_before_creating_case(self):
        absent = self.case / "invalid"
        with self.assertRaises(ValueError):
            api.prepare(absent, "ia32", "gpt", self.case / "absent.efi", 512 * 1024**2, "unknown")
        self.assertFalse(absent.exists())

    def execute_with_log(self, text):
        (self.case / "prepared.json").write_text(json.dumps({"arch": "x86_64", "profile": "scale-firmware"}))
        process = SimpleNamespace(wait=lambda timeout=None: 33)
        def extract(_source, destination):
            destination.write_bytes(text)
            return True
        with patch.object(api, "run_command"), patch.object(api.shutil, "copyfile"), \
             patch.object(api, "hash_file", return_value="0" * 64), \
             patch.object(api, "extract_log", side_effect=extract), \
             patch.object(api.subprocess, "Popen", return_value=process):
            return api.execute(self.case, 64, 60)

    def test_stage1a_pass_text_cannot_pass_scaling(self):
        self.assertFalse(self.execute_with_log(b"USOSPREP PASS; old fixture\n"))

    def test_scaling_requires_its_completion_marker(self):
        self.assertTrue(self.execute_with_log(b"USOSPREP SCALE PASS files=10257\n"))

    def test_summary_reads_closed_profile_and_exact_expected_counts(self):
        (self.case / "prepared.json").write_text(json.dumps({"profile": "scale-firmware", "arch": "bios", "kind": "gpt"}))
        (self.case / "manifest.json").write_text(json.dumps(self.manifest_module().manifest("firmware")))
        (self.case / "program-footprint.json").write_text(json.dumps({"loaded_image_bytes": 65536,
            "own_stack_already_in_allocator_peak": False, "own_stack_reserved_bytes": 253952,
            "thunk_and_bootstrap_low_memory_budget_bytes": 131072}))
        run = self.case / "run-64m"; run.mkdir()
        (run / "completed.json").write_text(json.dumps({"application_pass": True, "elapsed_seconds": 1.25}))
        (run / "USOSPREP.LOG").write_text("MEM alloc_peak=1234\nHEAP physical_current=0 physical_peak=1400 extent_peak=2048 reserved=8388608\nUSOSPREP SCALE PASS\n")
        summary = runner.summarize(self.case)
        self.assertEqual((summary["expected_files"], summary["expected_directories"], summary["expected_bytes"]), (1, 1, 64))
        self.assertEqual(summary["program_memory_evidence"], ["MEM alloc_peak=1234"])
        self.assertEqual(summary["program_ram_conservative_upper_bound_bytes"], 8839168)

    def test_requested_bytes_without_reclaimed_physical_arena_cannot_pass(self):
        (self.case / "prepared.json").write_text(json.dumps({"profile": "scale-firmware", "arch": "bios", "kind": "gpt"}))
        (self.case / "manifest.json").write_text(json.dumps(self.manifest_module().manifest("firmware")))
        (self.case / "program-footprint.json").write_text(json.dumps({"loaded_image_bytes": 65536,
            "own_stack_already_in_allocator_peak": False, "own_stack_reserved_bytes": 253952,
            "thunk_and_bootstrap_low_memory_budget_bytes": 131072}))
        run = self.case / "run-64m"; run.mkdir()
        (run / "completed.json").write_text(json.dumps({"application_pass": True, "elapsed_seconds": 1.25}))
        for heap in ("", "HEAP physical_current=1 physical_peak=1536 extent_peak=2048 reserved=4096\n",
                     "HEAP physical_current=0 physical_peak=1536 extent_peak=5000 reserved=4096\n"):
            (run / "USOSPREP.LOG").write_text("MEM alloc_peak=1234\nUSOSPREP SCALE PASS\n" + heap)
            with self.subTest(heap=heap), self.assertRaises(ValueError): runner.summarize(self.case)

    def test_efi_loaded_image_uses_pe_virtual_size_not_file_length(self):
        program = self.case / "dummy.efi"
        image = bytearray(256); image[:2] = b"MZ"
        struct.pack_into("<I", image, 60, 64)
        image[64:68] = b"PE\0\0"
        struct.pack_into("<H", image, 88, 0x20b)
        struct.pack_into("<I", image, 144, 65536)
        program.write_bytes(image)
        footprint = runner.program_footprint(program, "x86_64", self.case / "unused.elf")
        self.assertEqual(footprint["loaded_image_bytes"], 65536)
        self.assertTrue(footprint["own_stack_already_in_allocator_peak"])

    def test_windows_acceptance_requires_chkdsk_and_exact_virtual_disk_bytes(self):
        record = {"kind": "windows-readonly-chkdsk", "passed": True,
            "readonly_chkdsk_pass": True, "readonly_file_tree_pass": True,
            "chkdsk_issued": True, "chkdsk_exit": 0, "chkdsk_flags": [],
            "repair_flags_used": False, "access": "ReadOnly", "chkdsk_target_guard": {
                "passed": True, "readonly": True, "expected_image_bytes": 512 * 1024**2,
                "actual_disk_bytes": 512 * 1024**2, "system": False, "boot": False}}
        self.assertTrue(runner.windows_acceptance(record, 0, 512 * 1024**2))
        self.assertFalse(runner.windows_acceptance(record, 0, 2 * 1024**3))
        record["chkdsk_issued"] = False
        self.assertFalse(runner.windows_acceptance(record, 0, 512 * 1024**2))

    def test_bios_footprint_requires_matching_linked_payload(self):
        program, linked = self.case / "dummy.img", self.case / "dummy.elf"
        elf = bytearray(256); elf[:6] = b"\x7fELF\x01\x01"
        struct.pack_into("<I", elf, 32, 52)
        struct.pack_into("<HH", elf, 46, 40, 2)
        struct.pack_into("<IIIIIIIIII", elf, 92, 0, 1, 2, 0x20000, 200, 4, 0, 0, 1, 0)
        elf[200:204] = b"TEST"; linked.write_bytes(elf)
        image = bytearray(1024 * 1024); slot = 64 * 512
        image[slot:slot + 8] = b"USOSCORE"
        struct.pack_into("<III", image, slot + 24, 16384, 4, 0x20000)
        image[slot + 16384:slot + 16388] = b"TEST"; program.write_bytes(image)
        result = runner.program_footprint(program, "bios", linked)
        self.assertEqual(result["loaded_image_bytes"], 4)
        self.assertTrue(result["linked_elf_matches_payload"])
        elf[200] ^= 1; linked.write_bytes(elf)
        with self.assertRaises(ValueError): runner.program_footprint(program, "bios", linked)


if __name__ == "__main__":
    unittest.main()
