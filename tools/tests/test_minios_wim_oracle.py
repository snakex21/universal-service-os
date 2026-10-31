# SPDX-License-Identifier: GPL-3.0-or-later
"""Host-oracle refusals and metadata fidelity; no Windows payload extraction."""
import ctypes as C
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wim_oracle", REPO / "tools/minios/wim_oracle.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def header(*, flags=0x40002, part=1, total=1, images=2):
    value = bytearray(208)
    value[:8] = b"MSWIM\0\0\0"
    struct.pack_into("<IIII", value, 8, 208, 0x10d00, flags, 32768)
    struct.pack_into("<HHI", value, 40, part, total, images)
    return value


class GuardTests(unittest.TestCase):
    def test_source_order_primary_is_independent_of_public_iteration_order(self):
        plan={(7,'11'*20):('B/long.dll','B~1.DLL')}
        a=dict(path='A/long.dll',short_name='A~1.DLL',hardlink_group_id=99,source_hardlink_group_id=7,source_data_sha1='11'*20,directory=False,reparse_tag=0,streams=[dict(sha1='11'*20)])
        b=a|dict(path='B/long.dll',short_name='B~1.DLL')
        self.assertTrue(m.normalize_short_name(a,plan))
        self.assertIsNone(a['short_name'])
        self.assertFalse(m.normalize_short_name(b,plan))
        self.assertEqual(b['short_name'],'B~1.DLL')

    def test_native_short_name_policy_keeps_source_and_uses_first_DOS_pair(self):
        primary = {}
        a = dict(path='A/long.dll',short_name='LONG~1.DLL',hardlink_group_id=7,directory=False,reparse_tag=0,streams=[dict(sha1='11'*20)])
        b = a | dict(path='B/long.dll',short_name='ABCDEF~1.DLL')
        self.assertFalse(m.normalize_short_name(a,primary))
        self.assertTrue(m.normalize_short_name(b,primary))
        self.assertEqual(b['source_short_name'],'ABCDEF~1.DLL')
        self.assertIsNone(b['short_name'])
        self.assertEqual(b['primary_short_name_value'],'LONG~1.DLL')
        self.assertEqual(b['primary_short_name_path'],'A/long.dll')
        self.assertFalse(b['short_name_index_created'])
        # Reused group IDs with different data are distinct native inodes.
        c = a | dict(path='C/other.dll',short_name='OTHER~1.DLL',streams=[dict(sha1='22'*20)])
        self.assertFalse(m.normalize_short_name(c,primary))

    def test_device_unc_ads_and_traversal_refused(self):
        for path in (r"\\.\PhysicalDrive0", r"\\server\share\install.wim", r"K:\file:secret", r"K:\safe\..\bad", "relative.wim"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                m.local(Path(path))

    def test_owned_rejects_root_and_siblings(self):
        for path in (m.RUNTIME, m.RUNTIME.parent / "other/install.wim", m.RUNTIME.parent / (m.RUNTIME.name + "-escape/install.wim")):
            with self.assertRaises(ValueError):
                m.owned(path)
        self.assertEqual(m.owned(m.RUNTIME / "inputs/install.wim"), m.RUNTIME / "inputs/install.wim")

    def test_reparse_ancestor_refused(self):
        with patch.object(Path, "exists", return_value=True), patch.object(Path, "is_symlink", return_value=True):
            with self.assertRaisesRegex(ValueError, "Reparse"):
                m.local(m.RUNTIME / "link/install.wim")

    def test_stage_refuses_untrusted_source_before_any_tool_or_output(self):
        with patch.object(m, "tool_pins") as tools, patch.object(m, "storage_guard") as storage:
            with self.assertRaisesRegex(ValueError, "collection"):
                m.stage_iso(Path(r"C:\Windows\foreign.iso"), m.RUNTIME / "test", 4096)
            tools.assert_not_called(); storage.assert_not_called()

    def test_stage_refuses_unbounded_size_before_side_effects(self):
        with patch.object(m, "tool_pins") as tools, patch.object(m, "storage_guard") as storage:
            for size in (-1, 0, 207, m.MAX_WIM + 1):
                with self.assertRaisesRegex(ValueError, "size"):
                    m.stage_iso(m.MEDIA_ROOTS[0] / "allowed.iso", m.RUNTIME / "test", size)
            tools.assert_not_called(); storage.assert_not_called()

    def test_overwrite_refused_before_tools(self):
        with patch.object(Path, "exists", return_value=True), patch.object(Path, "is_symlink", return_value=False), patch.object(Path, "lstat") as info, patch.object(m, "tool_pins") as tools:
            info.return_value.st_file_attributes = 0
            with self.assertRaises(FileExistsError):
                m.stage_iso(m.MEDIA_ROOTS[0] / "allowed.iso", m.RUNTIME / "existing", 4096)
            tools.assert_not_called()

    def test_pin_required_before_any_output_or_tool(self):
        with patch.object(m, "storage_guard") as storage:
            with self.assertRaisesRegex(ValueError, "Pinned"):
                m.manifest(m.RUNTIME / "source.wim", 1, "not-a-pin", m.RUNTIME / "new")
            storage.assert_not_called()

    def test_wrong_tool_pin_refused_before_execution(self):
        with patch.object(m, "digest", return_value="0" * 64), patch.object(m.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "pin mismatch"):
                m.tool_pins()
            run.assert_not_called()

    def test_storage_reserve_volume_identity_and_budget(self):
        api = unittest.mock.MagicMock()
        def correct(_root, output, _size):
            output.value = m.VOLUME
            return 1
        api.GetVolumeNameForVolumeMountPointW.side_effect = correct
        with patch.object(m, "VOLUME", r"\\?\Volume{11111111-2222-3333-4444-555555555555}" + "\\"), patch.object(m.C, "WinDLL", return_value=api), patch.object(m.shutil, "disk_usage", return_value=SimpleNamespace(free=101 * m.GiB)):
            m.storage_guard(m.GiB)
            with self.assertRaisesRegex(ValueError, "reserve"):
                m.storage_guard(m.GiB + 1)
            with self.assertRaisesRegex(ValueError, "pool"):
                m.storage_guard(100 * m.GiB + 1)
            api.GetVolumeNameForVolumeMountPointW.side_effect = lambda *_: 0
            with self.assertRaisesRegex(ValueError, "volume identity"):
                m.storage_guard()

    def test_missing_volume_pin_refused_before_any_native_storage_query(self):
        with patch.object(m, 'VOLUME', ''), patch.object(m.C, 'WinDLL') as native, patch.object(m.shutil, 'disk_usage') as space:
            with self.assertRaisesRegex(ValueError, 'identity pin'):
                m.storage_guard()
            native.assert_not_called(); space.assert_not_called()

    def test_header_magic_split_and_compression_validation(self):
        self.assertEqual(m.read_header(io.BytesIO(header()))["compression"], "LZX")
        self.assertEqual(m.read_header(io.BytesIO(header(flags=0x20002)))["compression"], "XPRESS")
        for value in (b"x" * 208, bytes(header())[:100], header(part=2), header(total=2), header(flags=0x4000a), header(flags=0x60002), header(images=0)):
            with self.assertRaises(ValueError):
                m.read_header(io.BytesIO(value))

    def test_explicit_numeric_single_index(self):
        for value in (0, -1, 3, "all", "1", True, None):
            with self.assertRaises(ValueError):
                m.validate_index(value, {"image_count": 2})
        self.assertEqual(m.validate_index(2, {"image_count": 2}), 2)

    def test_filetime_exact_100ns_and_epoch(self):
        self.assertEqual(m.filetime(m.Timespec(-11644473600, 0)), 0)
        self.assertEqual(m.filetime(m.Timespec(0, 123456700)), 116444736001234567)
        for value in (m.Timespec(0, 1), m.Timespec(0, -100), m.Timespec(0, 1000000000), m.Timespec(-11644473601, 0)):
            with self.assertRaises(ValueError):
                m.filetime(value)

    def test_path_refusals_and_root(self):
        self.assertEqual(m.relative("\\"), "")
        self.assertEqual(m.relative(r"\Windows\WinSxS\file.dll"), "Windows/WinSxS/file.dll")
        for path in ("relative", "//server/file", "/../file", "/Windows/:stream", "/Windows//file"):
            with self.assertRaises(ValueError):
                m.relative(path)

    def test_metadata_preserves_security_links_ads_reparse_and_subseconds(self):
        backing = C.create_string_buffer(C.sizeof(m.Entry) + 2 * C.sizeof(m.Stream))
        entry = m.Entry.from_buffer(backing)
        path = C.create_unicode_buffer(r"\Windows\linked")
        short = C.create_unicode_buffer("LINKED~1")
        name = C.create_unicode_buffer("Zone.Identifier")
        security = C.create_string_buffer(b"\x01\x00\x04\x80" + bytes(range(16)))
        entry.path = C.addressof(path); entry.dos_name = C.addressof(short)
        entry.security = C.addressof(security); entry.security_size = 20
        entry.links = 2; entry.link_group = 0x123456789abc
        entry.named_streams = 1; entry.attributes = 0x420; entry.reparse_tag = 0xa0000003
        entry.creation = m.Timespec(1, 100); entry.write = m.Timespec(2, 200); entry.access = m.Timespec(3, 300)
        streams = (m.Stream * 2).from_address(C.addressof(entry) + m.Entry.streams.offset)
        streams[0].resource.size = 32; streams[0].resource.part = 1
        streams[0].resource.sha1[:] = bytes(range(20))
        streams[1].name = C.addressof(name); streams[1].resource.size = 64; streams[1].resource.part = 1
        streams[1].resource.sha1[:] = bytes(range(20, 40))
        record, sd = m.entry_record(entry)
        self.assertEqual(sd, security.raw[:20])
        self.assertEqual(record["hardlink_group_id"], 0x123456789abc)
        self.assertEqual(record["link_count"], 2)
        self.assertEqual(record["reparse_tag"], 0xa0000003)
        self.assertEqual(record["streams"][0]["kind"], "reparse")
        self.assertEqual(record["streams"][1]["name"], "Zone.Identifier")
        self.assertEqual(record["streams"][1]["sha1"], bytes(range(20, 40)).hex())
        self.assertEqual(record["creation_filetime"], 116444736010000001)
        self.assertEqual(record["modified_filetime"], 116444736020000002)
        self.assertEqual(record["accessed_filetime"], 116444736030000003)
        self.assertIsNone(record["changed_filetime"])
        self.assertEqual(record["short_name"], "LINKED~1")
        streams[0].resource.flags = 32
        with self.assertRaisesRegex(ValueError, "solid"):
            m.entry_record(entry)
        streams[0].resource.flags = 16
        with self.assertRaisesRegex(ValueError, "missing"):
            m.entry_record(entry)

    @unittest.skipUnless(os.environ.get("MINIOS_ZIG"), "Set MINIOS_ZIG for independent native header ABI proof")
    def test_ffi_layout_against_pinned_native_wimlib_header(self):
        # Keep prior native evidence intact, including the proof from1b-2.
        folder = REPO / "runtime/wim-oracle-tests" / uuid.uuid4().hex
        folder.mkdir(parents=True, exist_ok=True)
        source = folder / "wim_abi.c"
        exe = folder / "wim_abi.exe"
        source.write_text('#include <stddef.h>\n#include <stdio.h>\n#include "wimlib.h"\nint main(void){ printf("%zu %zu %zu %zu %zu %zu %zu\\n", sizeof(struct wimlib_resource_entry), sizeof(struct wimlib_stream_entry), offsetof(struct wimlib_dir_entry,streams), offsetof(struct wimlib_dir_entry,security_descriptor), offsetof(struct wimlib_dir_entry,hard_link_group_id), offsetof(struct wimlib_dir_entry,creation_time), offsetof(struct wimlib_dir_entry,object_id)); return 0;}\n', encoding="utf-8")
        env = os.environ.copy()
        env.update(ZIG_LOCAL_CACHE_DIR=str(folder / "zig-cache"), ZIG_GLOBAL_CACHE_DIR=str(folder / "zig-global-cache"), TEMP=str(folder), TMP=str(folder))
        subprocess.run([os.environ["MINIOS_ZIG"], "cc", "-std=c11", "-I", str(m.VENDOR / "devel"), str(source), "-o", str(exe)], check=True, capture_output=True, env=env, timeout=120)
        actual = subprocess.run([str(exe)], check=True, capture_output=True, timeout=10).stdout.decode().strip()
        expected = [C.sizeof(m.Resource), C.sizeof(m.Stream), m.Entry.streams.offset, m.Entry.security.offset, m.Entry.link_group.offset, m.Entry.creation.offset, m.Entry.object_ids.offset]
        self.assertEqual([int(x) for x in actual.split()], expected)
        (folder / "abi-proof.json").write_text(json.dumps({"native_header_values": actual, "ctypes_values": expected, "pass": True, "public_header_sha256": m.digest(m.VENDOR / 'devel/wimlib.h')}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main(verbosity=2)
