"""Acceptance-evidence rejection gates, using tiny synthetic local receipts."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import unittest
import uuid

HERE = Path(__file__).resolve().parents[1] / "minios"
spec = importlib.util.spec_from_file_location("scale_evidence_test", HERE / "scale_evidence.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
ROOT = Path(os.environ.get("USOS_MINIOS_TEST_WORKSPACE", HERE.parents[1] / "zig-out/minios-scale-unit"))


class Evidence(unittest.TestCase):
    def setUp(self):
        ROOT.mkdir(parents=True, exist_ok=True)
        self.root = ROOT.resolve()
        self.case = self.root / ("_unit-evidence-" + uuid.uuid4().hex)
        self.case.mkdir()

    def tearDown(self):
        if self.case.parent != self.root or not self.case.name.startswith("_unit-evidence-"):
            raise ValueError("Unit cleanup escaped owned directory")
        evidence.runtime.guarded(self.root, self.case)
        shutil.rmtree(self.case)

    def suite_fixture(self):
        validation = self.case / "validation"; validation.mkdir()
        (validation / "zig.log").write_text("Build Summary: 76/76 steps succeeded; 645/645 tests passed\n")
        (validation / "python.log").write_text("Ran 45 tests in 12.910s\n\nOK\n")
        value = {"schema": 1, "complete": True, "suites": [
            {"kind": "zig-build", "tests": 645, "returncode": 0, "transcript": "validation/zig.log"},
            {"kind": "python-unittest", "tests": 45, "returncode": 0, "transcript": "validation/python.log"}]}
        path = validation / "acceptance-tests.json"
        path.write_text(json.dumps(value))
        return path, value

    def test_portability_rejects_nested_profile_and_device_paths(self):
        for value in (r"C:\Users\private\file", "\\\\?\\Volume{test}\\", r"\\server\share\file", "K:/VM/private.raw"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                evidence.assert_portable({"nested": [value]})
        evidence.assert_portable({"receipt": "cases/own/result.json", "source": "https://example.org/spec"})

    def test_real_suite_count_and_hash_are_required(self):
        self.suite_fixture()
        result = evidence.test_evidence(self.case)
        self.assertEqual([row["tests"] for row in result["suites"]], [645, 45])
        self.assertEqual(len(result["suites"][0]["transcript"]["sha256"]), 64)
        (self.case / "validation/zig.log").write_text("Build Summary: 75/76 steps succeeded; 644/644 tests passed\n")
        with self.assertRaises(ValueError): evidence.test_evidence(self.case)

    def test_validation_cannot_hide_a_failed_or_missing_suite(self):
        path, value = self.suite_fixture()
        value["suites"][1]["returncode"] = 1
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError): evidence.test_evidence(self.case)
        value["suites"] = value["suites"][:1]
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError): evidence.test_evidence(self.case)

    def test_validation_transcript_cannot_escape_its_workspace(self):
        path, value = self.suite_fixture()
        value["suites"][0]["transcript"] = "../foreign.log"
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError): evidence.test_evidence(self.case)

    def test_cleanup_receipt_cannot_hide_a_remaining_image(self):
        (self.case / "validation").mkdir()
        report = self.case / "validation/final-report-pre-cleanup.md"
        report.write_text("# MiniOS 1b-1\nStatus: RAPORT KOŃCOWY\n", encoding="utf-8")
        (self.case / "cleanup-own-completed.json").write_text(json.dumps({
            "stage": "1b-1", "state": "complete", "removed_bytes": 1024, "images_count": 1,
            "report_before_cleanup": evidence.runtime.artifact(self.case, report)}))
        image = self.case / "remaining.raw"; image.write_bytes(b"unit data")
        with self.assertRaises(ValueError): evidence.cleanup_evidence(self.case)
        image.unlink()
        self.assertEqual(len(evidence.cleanup_evidence(self.case)), 1)

    def cpu_fixture(self):
        (self.case / "validation").mkdir()
        architectures, selected = {}, []
        for arch, cpu in (("bios", "486"), ("ia32", "qemu32"), ("x86_64", "qemu64")):
            key = "bios_build" if arch == "bios" else "efi"
            prepared = {"arch": arch, "hashes": {key: "a" * 64}}
            selected.append({"firmware": True, "prepared": prepared})
            runs = []
            settings = [(cpu, 18, True), (cpu, 17, False)]
            if arch == "bios": settings += [("486", 32, True), ("pentium", 32, True)]
            for index, (run_cpu, memory, passed) in enumerate(settings):
                case = self.case / "cases" / (arch + "-" + str(index))
                run = case / ("run-" + str(memory) + "m"); run.mkdir(parents=True)
                (case / "prepared.json").write_text(json.dumps(prepared))
                receipt = run / "completed.json"
                receipt.write_text(json.dumps({"command": ["own-qemu.exe", "-cpu", run_cpu, "-m", str(memory)],
                    "qemu_only": True, "returncode": 33 if passed else 35, "application_pass": passed, "timed_out": False}))
                runs.append({"cpu": run_cpu, "memory_mib": memory, "application_pass": passed,
                             "receipt": receipt.relative_to(self.case).as_posix()})
            architectures[arch] = {"artifact_sha256": "a" * 64,
                "application_cpu_baseline": "generic-x86_64" if arch == "x86_64" else "i486",
                "qemu_cpu_runs": runs, "minimum_ram_mib": 18, "preceding_failure_ram_mib": 17,
                "minimum_scope": "completed synthetic unit fixture; no real QEMU"}
        summary = {"schema": 1, "kind": "minios-1b1-cpu-ram", "complete": True, "architectures": architectures}
        path = self.case / "validation/cpu-ram.json"; path.write_text(json.dumps(summary))
        return path, summary, selected

    def test_cpu_gate_reads_actual_commands_and_pins_artifact(self):
        _, _, selected = self.cpu_fixture()
        result = evidence.cpu_evidence(self.case, selected)
        self.assertEqual(result["architectures"]["bios"]["minimum_ram_mib"], 18)
        prepared = self.case / "cases/ia32-0/prepared.json"
        value = json.loads(prepared.read_text()); value["hashes"]["efi"] = "b" * 64
        prepared.write_text(json.dumps(value))
        with self.assertRaises(ValueError): evidence.cpu_evidence(self.case, selected)

    def test_labeled486_cannot_hide_a_different_qemu_command(self):
        _, _, selected = self.cpu_fixture()
        path = self.case / "cases/bios-2/run-32m/completed.json"
        value = json.loads(path.read_text()); value["command"][2] = "qemu32"
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError): evidence.cpu_evidence(self.case, selected)

    def test_unexecuted_lower_ram_cannot_be_declared_minimum(self):
        path, value, selected = self.cpu_fixture()
        value["architectures"]["ia32"]["minimum_ram_mib"] = 16
        value["architectures"]["ia32"]["preceding_failure_ram_mib"] = 15
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError): evidence.cpu_evidence(self.case, selected)

    def test_bios_requires_both_old_cpu32mb_completions(self):
        path, value, selected = self.cpu_fixture()
        value["architectures"]["bios"]["qemu_cpu_runs"] = value["architectures"]["bios"]["qemu_cpu_runs"][:-1]
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError): evidence.cpu_evidence(self.case, selected)

    def test_lowest_confirmed_size_does_not_require_an_extra_ram_matrix(self):
        path, value, selected = self.cpu_fixture()
        for row in value["architectures"].values(): row["preceding_failure_ram_mib"] = None
        path.write_text(json.dumps(value))
        result = evidence.cpu_evidence(self.case, selected)
        self.assertFalse(result["architectures"]["ia32"]["adjacent_lower_failure_proven"])
        self.assertEqual(result["architectures"]["ia32"]["minimum_ram_mib"], 18)


if __name__ == "__main__": unittest.main()
