# SPDX-License-Identifier: GPL-3.0-or-later
"""RAM probes reuse verified baselines, bound retained COWs, and reject stale pins."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wim_ram_case", REPO / "tools/minios/wim_ram_case.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class RamProbeTests(unittest.TestCase):
    def test_native_receipt_must_match_this_target_and_both_oracle_pins(self):
        prepared = {"image": {"tree": str(REPO / "tree.jsonl"), "security": str(REPO / "security.jsonl")},
                    "tree_sha256": "t" * 64, "security_sha256": "s" * 64}
        completed = {"target": str(REPO / "target.raw"), "target_sha256": "a" * 64}
        native = {"source": completed["target"], "source_sha256_before": "a" * 64,
                  "source_sha256_after": "a" * 64, "wim_manifest": prepared["image"]["tree"],
                  "wim_manifest_sha256_before": "t" * 64, "wim_manifest_sha256_after": "t" * 64,
                  "wim_security_manifest": prepared["image"]["security"],
                  "wim_security_manifest_sha256_before": "s" * 64, "wim_security_manifest_sha256_after": "s" * 64}
        self.assertTrue(m.native_baseline_matches(prepared, completed, native))
        for key in native:
            changed = dict(native); changed[key] = "another-image" if key.endswith("source") else "f" * 64
            self.assertFalse(m.native_baseline_matches(prepared, completed, changed), key)
        for key in native:
            changed = dict(native); changed.pop(key)
            self.assertFalse(m.native_baseline_matches(prepared, completed, changed), key)

    def test_geometry_and_full_virtual_write_bound_reject512MiB_baseline(self):
        m.geometry_bounds(256 * m.MiB, 256 * m.MiB, 65 * m.MiB)
        m.geometry_bounds(128 * m.MiB, 128 * m.MiB, 65 * m.MiB)
        self.assertGreaterEqual(m.NEXT_CASE_BOUND, (256 + 65 + 65 + 8 + 4 + 16) * m.MiB)
        for args in ((512*m.MiB,512*m.MiB,65*m.MiB), (256*m.MiB,128*m.MiB,65*m.MiB),
                     (256*m.MiB,256*m.MiB,66*m.MiB), (True,1,65*m.MiB)):
            with self.assertRaises(ValueError): m.geometry_bounds(*args)

    def test_closed_accounting_counts_retained_cows_and_esp_export(self):
        temporary_root = REPO / "runtime/wim-codec/tmp"
        temporary_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root) as folder:
            root = Path(folder)
            self.assertEqual(m.closed_footprint(root / "future"), 0)
            run = root / "x64-m048"; run.mkdir()
            (run / "target.qcow2").write_bytes(b"target" * 11)
            (run / "esp-closed.raw").write_bytes(b"esp" * 7)
            (root / "manifest.json").write_bytes(b"{}")
            self.assertEqual(m.closed_footprint(root), 66 + 21 + 2)

    def test_accepts_only_matching64MiB_uefi_baseline_after_windows_gate(self):
        prepared = {"arch": "ia32", "qemu_only": True, "program_sha256": "a" * 64}
        completed = {"qemu_only": True, "guest_completion_wait": True, "application_pass": True,
                     "bases_unchanged": True, "memory_mib": 64, "program_sha256": "a" * 64}
        windows = {"passed": True}
        self.assertTrue(m.baseline_acceptance(prepared, completed, windows, "a" * 64))
        for source, key, bad in ((prepared,"arch","bios"), (prepared,"qemu_only",False),
                                 (completed,"application_pass",False), (completed,"guest_completion_wait",False),
                                 (completed,"bases_unchanged",False), (completed,"memory_mib",32),
                                 (completed,"program_sha256","b" * 64), (windows,"passed",False)):
            old = source[key]; source[key] = bad
            self.assertFalse(m.baseline_acceptance(prepared, completed, windows, "a" * 64))
            source[key] = old
        self.assertFalse(m.baseline_acceptance(prepared, completed, windows, "b" * 64))

    def test_next_probe_must_fit_full_cow_esp_retention_bound(self):
        m.probe_bounds(16, 30, 0)
        m.probe_bounds(64, 900, m.RAM_SCOPE_BYTES - m.NEXT_CASE_BOUND)
        for args in ((15,180,0),(65,180,0),(True,180,0),(32,29,0),(32,901,0),
                     (32,180,-1),(32,180,m.RAM_SCOPE_BYTES-m.NEXT_CASE_BOUND+1)):
            with self.assertRaises(ValueError): m.probe_bounds(*args)


if __name__ == "__main__": unittest.main()
