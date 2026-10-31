# SPDX-License-Identifier: GPL-3.0-or-later
"""Firmware acceptance must require real completion, image pins and native gates."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wim_firmware_case", REPO / "tools/minios/wim_firmware_case.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
TMP = REPO / "runtime/wim-codec/tmp"; TMP.mkdir(parents=True, exist_ok=True)


class FirmwareCaseTests(unittest.TestCase):
    def test_small_fat32_directory_and_file_bytes_follow_the_actual_bpb_geometry(self):
        class SparseMemoryFile:
            def __init__(self): self.position = 0; self.pages = {}; self.length = 0
            def seek(self, position): self.position = position
            def truncate(self, size): self.length = size
            def write(self, value):
                for offset in range(len(value)):
                    at = self.position + offset; page = self.pages.setdefault(at // 4096, bytearray(4096))
                    page[at % 4096] = value[offset]
                self.position += len(value); self.length = max(self.length, self.position)
                return len(value)
            def read_at(self, position, size):
                return bytes(self.pages.get(at // 4096, bytes(4096))[at % 4096] for at in range(position, position + size))
            def flush(self): pass
            def fileno(self): return 0
            def close(self): pass
        memory = SparseMemoryFile()
        path = SimpleNamespace(open=lambda *_: memory)
        payload = bytes((i * 17 + 11) & 255 for i in range(6007))
        with patch.object(m.api, "checked", return_value=path), patch.object(m.api.os, "fsync"):
            esp = m.SmallEsp(Path("not-a-real-file"))
            esp.add("EFI/BOOT/BOOTX64.EFI", len(payload), [payload[:513], payload[513:]])
            esp.finish()
        # Independent FAT reader derives every address from the MBR/BPB,
        # rather than using the writer's class constants or cluster offsets.
        partition = struct.unpack_from("<I", memory.read_at(0, 512), 454)[0]
        bpb = memory.read_at(partition * 512, 512)
        spc, reserved, fats, spf = bpb[13], struct.unpack_from("<H", bpb, 14)[0], bpb[16], struct.unpack_from("<I", bpb, 36)[0]
        data = (partition + reserved + fats * spf) * 512
        def chain(cluster):
            result = bytearray()
            for _ in range(100):
                result += memory.read_at(data + (cluster - 2) * spc * 512, spc * 512)
                cluster = struct.unpack("<I", memory.read_at((partition + reserved) * 512 + cluster * 4, 4))[0] & 0xfffffff
                if cluster >= 0xffffff8: return bytes(result)
            self.fail("Independent FAT reader found an unterminated chain")
        directory = struct.unpack_from("<I", bpb, 44)[0]
        for short in (b"EFI        ", b"BOOT       ", b"BOOTX64 EFI"):
            raw = chain(directory)
            matches = [raw[at:at + 32] for at in range(0, len(raw), 32) if raw[at:at + 11] == short]
            self.assertEqual(len(matches), 1)
            entry = matches[0]
            directory = struct.unpack_from("<H", entry, 20)[0] << 16 | struct.unpack_from("<H", entry, 26)[0]
        size = struct.unpack_from("<I", entry, 28)[0]
        self.assertEqual(chain(directory)[:size], payload)

    def test_small_esp_is_genuine_fat32_and_target_size_is_record_specific(self):
        clusters = (m.SmallEsp.total - m.SmallEsp.reserved - 2 * m.SmallEsp.fat_sectors) // m.SmallEsp.spc
        self.assertEqual(clusters, m.SmallEsp.capacity)
        self.assertGreaterEqual(clusters, 65525)  # FAT32, not FAT16 by cluster count.
        self.assertGreater(m.SmallEsp.fat_sectors * 512 // 4, clusters + 2)
        self.assertEqual((m.SmallEsp.start + m.SmallEsp.total) * 512, 65 * 1024**2)
        for size in (128 * 1024**2, 512 * 1024**2):
            m.target_bounds(size, "gpt"); m.target_bounds(size, "mbr")
        for size, kind in ((64 * 1024**2, "gpt"), (128 * 1024**2 + 1, "gpt"), (1024**3, "gpt"), (128 * 1024**2, "other")):
            with self.assertRaises(ValueError): m.target_bounds(size, kind)

    def test_guest_requires_actual_debug_exit_and_wim_pass_after_completion(self):
        self.assertTrue(m.guest_acceptance(33, False, False, b"USOSPREP WIM PASS", True))
        for status, timeout, interrupted, log, bases in (
            (35, False, False, b"USOSPREP WIM PASS", True),
            (33, True, False, b"USOSPREP WIM PASS", True),
            (33, False, True, b"USOSPREP WIM PASS", True),
            (33, False, False, b"USOSPREP PASS;", True),
            (33, False, False, b"USOSPREP WIM PASS\nTERMINAL FAIL Io", True),
            (33, False, False, b"USOSPREP WIM PASS", False)):
            self.assertFalse(m.guest_acceptance(status, timeout, interrupted, log, bases))

    def test_windows_acceptance_requires_native_invocation_chkdsk_security_and_exact_virtual_target(self):
        record = dict(kind="windows-readonly-chkdsk", passed=True, readonly_chkdsk_pass=True,
                      readonly_wim_tree_pass=True, raw_security_pass=True, chkdsk_issued=True,
                      dismounted=True, temporary_dos_alias_removed=True, chkdsk_exit=0,
                      chkdsk_flags=[], repair_flags_used=False, access="ReadOnly",
                      chkdsk_target_guard=dict(passed=True, readonly=True, expected_image_bytes=m.TARGET_BYTES,
                                              actual_disk_bytes=m.TARGET_BYTES, system=False, boot=False))
        self.assertTrue(m.windows_acceptance(record, 0, m.TARGET_BYTES))
        mutations = {"kind": "files-only", "chkdsk_issued": False, "chkdsk_flags": ["/f"],
                     "readonly_wim_tree_pass": False, "raw_security_pass": False,
                     "dismounted": False, "temporary_dos_alias_removed": False,
                     "chkdsk_exit": 1, "repair_flags_used": True, "access": "ReadWrite"}
        for key, value in mutations.items():
            bad = copy.deepcopy(record); bad[key] = value
            self.assertFalse(m.windows_acceptance(bad, 0, m.TARGET_BYTES), key)
        for key, value in {"actual_disk_bytes": m.TARGET_BYTES + 512, "readonly": False, "system": True, "boot": True}.items():
            bad = copy.deepcopy(record); bad["chkdsk_target_guard"][key] = value
            self.assertFalse(m.windows_acceptance(bad, 0, m.TARGET_BYTES), key)
        self.assertFalse(m.windows_acceptance(record, 1, m.TARGET_BYTES))

    def test_selected_fixture_binds_archive_tree_security_and_explicit_index(self):
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            root = Path(temporary)
            archive, tree, security = (root / name for name in ("own.wim", "tree.jsonl", "security.jsonl"))
            archive.write_bytes(b"own-data-test"); tree.write_text("own tree"); security.write_text("own SD")
            digest = m.oracle.digest(archive)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(dict(wim_sha256=digest, index=1, tree_sha256=m.oracle.digest(tree),
                                                security_sha256=m.oracle.digest(security))))
            fixture = root / "fixture.json"
            row = dict(own_generated_data=True, solid=False, wim=str(archive), sha256=digest,
                       images=[dict(index=1, tree=str(tree), security=str(security), manifest=str(manifest))])
            fixture.write_text(json.dumps(row))
            with patch.object(m.oracle, "RUNTIME", root):
                self.assertEqual(m.selected_fixture(fixture, 1)[0]["sha256"], digest)
                for index in (0, 2, True, "1"):
                    with self.assertRaises(ValueError): m.selected_fixture(fixture, index)
                row["images"].append(row["images"][0]); fixture.write_text(json.dumps(row))
                with self.assertRaises(ValueError): m.selected_fixture(fixture, 1)
                row["images"].pop(); fixture.write_text(json.dumps(row)); tree.write_text("tampered")
                with self.assertRaisesRegex(ValueError, "pins"):
                    m.selected_fixture(fixture, 1)
                archive.write_bytes(b"changed source")
                with self.assertRaisesRegex(ValueError, "SHA256"):
                    m.selected_fixture(fixture, 1)

    def test_case_names_cannot_escape_owned_workspace(self):
        workspace = m.oracle.RUNTIME / "firmware-tests"
        qemu = REPO / "tools/qemu"
        for name in ("../other", "a/b", "", "a,b", "a\n", "A", "a" * 65):
            with self.assertRaises(ValueError): m.case_path(workspace, name, qemu)


if __name__ == "__main__":
    unittest.main()
