# SPDX-License-Identifier: GPL-3.0-or-later
"""In-memory cleanup state-machine/Win32 guards; never delete host files.

No runtime discovery, images, physical devices, mount or native delete calls
are used. The fake backend records opens/hashes/report publication/removals so
tests can verify operation ordering and fail-closed behavior independently.
"""
import contextlib
import copy
import ctypes as C
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wim_cleanup", REPO / "tools/minios/wim_cleanup.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MemoryHandle:
    def __init__(self, ops, path, role):
        self.ops, self.path, self.role = ops, path, role
        self.closed = False

    def __enter__(self):
        node = self.ops.nodes[self.path]
        if (node.get("active") or node.get("held") or node.get("links", 1) != 1
                or node.get("attributes", 0) & (0x10 | 0x400) or node.get("foreign_canonical")):
            raise ValueError("Exclusive canonical regular-file guard refused")
        node["held"] = True
        self.ops.events.append(("open", self.path, self.role))
        return self

    def read_document(self):
        return self.ops.nodes[self.path]["data"]

    def describe(self):
        self.ops.events.append(("hash", self.path))
        node = self.ops.nodes[self.path]
        if node.get("foreign_canonical"):
            raise ValueError("Canonical handle identity changed")
        return dict(path=str(self.path), bytes=len(node["data"]), sha256=m.sha(node["data"]),
                    file_id=node["file_id"], attributes=node["attributes"])

    def append(self, data):
        if self.ops.fail_append:
            raise OSError("Report append failed")
        self.ops.events.append(("append-report", self.path))
        self.ops.nodes[self.path]["data"] += data

    def remove(self):
        self.ops.events.append(("remove-request", self.path))
        # This models only the owned in-memory record. It does not invoke a
        # filesystem removal API, even in the successful execution tests.
        if self.path in self.ops.fail_remove:
            raise OSError("Simulated image deletion failure")
        self.ops.nodes[self.path]["removed"] = True
        self.ops.nodes[self.path]["held"] = False
        self.closed = True
        self.ops.events.append(("removed", self.path))
        if self.path in self.ops.interrupt_after_remove:
            raise KeyboardInterrupt("Simulated interrupt after kernel deletion")

    def close(self):
        if not self.closed:
            self.ops.nodes[self.path]["held"] = False
            self.closed = True

    def __exit__(self, *_):
        self.close()


class MemoryOps:
    def __init__(self):
        self.nodes, self.events = {}, []
        self.fail_remove, self.fail_append = set(), False
        self.interrupt_after_remove = set()
        self.wrong_volume = False

    def add(self, path, data, **options):
        self.nodes[path] = dict(data=data, file_id=f"aabbccdd:{len(self.nodes)+1:016x}",
                                attributes=0x20, **options)

    def volume(self):
        if self.wrong_volume:
            raise ValueError("Wrong volume")

    @contextlib.contextmanager
    def parents(self, paths):
        self.events.append(("pin-parents", tuple(paths)))
        yield

    def open(self, path, role):
        if path not in self.nodes or self.nodes[path].get("removed"):
            raise FileNotFoundError(str(path))
        return MemoryHandle(self, path, role)

    def exists(self, path):
        return path in self.nodes and not self.nodes[path].get("removed")

    def new(self, path):
        if self.exists(path):
            raise FileExistsError(str(path))

    def save(self, path, value, immutable=False):
        self.new(path)
        self.events.append(("save-immutable" if immutable else "save", path))
        self.add(path, m.encoded(value))
        if immutable:
            self.nodes[path]["attributes"] |= 1


class CleanupTests(unittest.TestCase):
    def setUp(self):
        # All names are fictitious; neither the real K runtime nor its report
        # is inspected by these tests.
        self.root = Path(r"C:\USOS-Cleanup-Unit")
        self.report = self.root / "final-report.md"
        self.patch_runtime = patch.object(m.oracle, "RUNTIME", self.root)
        self.patch_report = patch.object(m, "FINAL_REPORT", self.report)
        self.patch_runtime.start(); self.patch_report.start()
        self.addCleanup(self.patch_runtime.stop); self.addCleanup(self.patch_report.stop)
        self.reset_nodes()

    def reset_nodes(self):
        self.ops = MemoryOps()
        self.ops.add(self.report, ("# Final report\n" + m.FINAL_TAG + "\nResult: completed tests.\n").encode())
        self.images = [self.root / "own-case" / leaf for leaf in ("target.raw", "readonly-copy.vhd", "target.qcow2")]
        for i, path in enumerate(self.images):
            self.ops.add(path, bytes((i,)) * (37 + i))
        self.plan_path = self.root / "cleanup-plan.json"
        self.authorization = self.root / "cleanup-authorization.json"
        self.result = self.root / "cleanup-result.json"

    def prepare(self):
        return m.prepare_plan(self.images, self.report, m.sha(self.ops.nodes[self.report]["data"]),
                              self.plan_path, self.authorization, self.ops)

    def execute(self, auth=None):
        auth = auth or self.prepare()
        return m.execute_plan(self.report, auth["report_sha256"], self.plan_path,
                              auth["plan_sha256"], self.result, self.ops)

    def removals(self):
        return [event for event in self.ops.events if event[0] == "remove-request"]

    def test_plan_is_durable_and_exactly_published_before_authorization_without_deletion(self):
        auth = self.prepare()
        self.assertEqual(auth["state"], "planned-not-executed")
        self.assertEqual(auth["images_deleted"], 0)
        self.assertEqual(self.removals(), [])
        plan = json.loads(self.ops.nodes[self.plan_path]["data"])
        self.assertEqual([row["path"] for row in plan["files"]], list(map(str, self.images)))
        block = m.plan_block(self.plan_path, auth["plan_sha256"], plan)
        self.assertEqual(self.ops.nodes[self.report]["data"].count(block), 1)
        self.assertEqual(m.sha(self.ops.nodes[self.report]["data"]), auth["report_sha256"])
        events = [x[0] for x in self.ops.events]
        self.assertLess(events.index("save-immutable"), events.index("append-report"))
        self.assertEqual(self.ops.events[-1], ("save-immutable", self.authorization))
        self.assertTrue(self.ops.nodes[self.plan_path]["attributes"] & 1)

    def test_no_plan_or_report_mutation_when_any_candidate_is_active(self):
        self.ops.nodes[self.images[-1]]["active"] = True
        before = self.ops.nodes[self.report]["data"]
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.ops.nodes[self.report]["data"], before)
        self.assertFalse(self.ops.exists(self.plan_path))
        self.assertEqual(self.removals(), [])
        self.assertTrue(all(not node.get("held") for node in self.ops.nodes.values()))

    def test_execute_holds_and_rehashes_every_candidate_before_first_removal(self):
        auth = self.prepare(); self.ops.events.clear()
        result = self.execute(auth)
        self.assertEqual(result["state"], "complete")
        self.assertTrue(result["all_candidates_validated_before_delete"])
        self.assertEqual([row["path"] for row in result["removed"]], list(map(str, self.images)))
        first_remove = next(i for i, event in enumerate(self.ops.events) if event[0] == "remove-request")
        for path in self.images:
            self.assertIn(("open", path, "image"), self.ops.events[:first_remove])
            self.assertIn(("hash", path), self.ops.events[:first_remove])
        self.assertEqual(result["failed"], [])
        self.assertIn(b"CLEANUP RESULT", self.ops.nodes[self.report]["data"])
        self.assertEqual(json.loads(self.ops.nodes[self.result]["data"]), result)

    def test_active_last_image_refuses_entire_execution_and_preserves_readonly_first(self):
        auth = self.prepare()
        self.ops.nodes[self.images[-1]]["active"] = True
        before = copy.deepcopy(self.ops.nodes[self.images[0]])
        result = self.execute(auth)
        self.assertEqual(result["state"], "refused")
        self.assertEqual(self.removals(), [])
        self.assertFalse(result["all_candidates_validated_before_delete"])
        self.assertEqual(self.ops.nodes[self.images[0]], {**before, "held": False})
        self.assertEqual(len(result["failed"]), len(self.images))

    def test_changed_hash_identity_attributes_or_canonical_path_never_deletes(self):
        for field, value in (("data", b"replacement"), ("file_id", "aabbccdd:000000000000abcd"),
                             ("attributes", 1), ("foreign_canonical", True), ("links", 2)):
            with self.subTest(field=field):
                self.reset_nodes()
                auth = self.prepare(); self.ops.nodes[self.images[-1]][field] = value
                result = self.execute(auth)
                self.assertEqual(result["state"], "refused")
                self.assertEqual(self.removals(), [])

    def test_draft_or_changed_report_and_missing_exact_plan_block_refuse(self):
        for mutation in (lambda data: data.replace(m.FINAL_TAG.encode(), b"draft"),
                         lambda data: data + b"changed",
                         lambda data: data.split(b"<!-- MINIOS1B2 CLEANUP PLAN")[0]):
            with self.subTest(mutation=mutation):
                self.reset_nodes(); auth = self.prepare()
                self.ops.nodes[self.report]["data"] = mutation(self.ops.nodes[self.report]["data"])
                # Even when the caller explicitly pins the newly edited
                # report, the final tag and exact plan block remain required.
                if b"changed" not in self.ops.nodes[self.report]["data"]:
                    auth["report_sha256"] = m.sha(self.ops.nodes[self.report]["data"])
                self.assertEqual(self.execute(auth)["state"], "refused")
                self.assertEqual(self.removals(), [])

    def test_plan_hash_corruption_and_duplicate_report_block_refuse(self):
        for mode in ("plan-byte", "duplicate-block"):
            with self.subTest(mode=mode):
                self.reset_nodes(); auth = self.prepare()
                if mode == "plan-byte":
                    self.ops.nodes[self.plan_path]["data"] += b" "
                else:
                    plan = json.loads(self.ops.nodes[self.plan_path]["data"])
                    self.ops.nodes[self.report]["data"] += m.plan_block(self.plan_path, auth["plan_sha256"], plan)
                    auth["report_sha256"] = m.sha(self.ops.nodes[self.report]["data"])
                self.assertEqual(self.execute(auth)["state"], "refused")
                self.assertEqual(self.removals(), [])

    def test_partial_failure_reports_exact_actual_removed_and_unattempted(self):
        auth = self.prepare(); self.ops.fail_remove.add(self.images[1])
        result = self.execute(auth)
        self.assertEqual(result["state"], "partial")
        self.assertEqual([row["path"] for row in result["removed"]], [str(self.images[0])])
        self.assertEqual([row["path"] for row in result["failed"]], list(map(str, self.images[1:])))
        self.assertEqual(len(self.removals()), 2)
        self.assertFalse(self.ops.nodes[self.images[2]].get("removed", False))
        self.assertEqual(json.loads(self.ops.nodes[self.result]["data"]), result)

    def test_interrupt_after_actual_removal_is_not_reported_as_an_existing_image(self):
        auth = self.prepare(); self.ops.interrupt_after_remove.add(self.images[0])
        result = self.execute(auth)
        self.assertEqual(result["state"], "partial")
        self.assertEqual([row["path"] for row in result["removed"]], [str(self.images[0])])
        self.assertEqual([row["path"] for row in result["failed"]], list(map(str, self.images[1:])))
        self.assertIn("KeyboardInterrupt", result["operation_error"])
        self.assertEqual(len(self.removals()), 1)

    def test_reparse_and_hardlinked_images_refuse_plan_before_publication(self):
        for field, value in (("attributes", 0x420), ("links", 2), ("foreign_canonical", True)):
            with self.subTest(field=field):
                self.reset_nodes(); self.ops.nodes[self.images[-1]][field] = value
                with self.assertRaises(ValueError): self.prepare()
                self.assertFalse(self.ops.exists(self.plan_path))
                self.assertEqual(self.removals(), [])

    def test_plan_publication_failure_does_not_authorize_any_deletion(self):
        self.ops.fail_append = True
        with self.assertRaises(OSError): self.prepare()
        self.assertTrue(self.ops.exists(self.plan_path))
        self.assertFalse(self.ops.exists(self.authorization))
        self.assertEqual(self.removals(), [])

    def test_evidence_append_failure_never_returns_complete(self):
        auth = self.prepare(); self.ops.fail_append = True
        result = self.execute(auth)
        self.assertEqual(result["state"], "evidence-failed")
        self.assertEqual(len(result["removed"]), len(self.images))
        self.assertEqual(result["failed"], [])
        self.assertIn("Report append failed", result["error"])

    def test_source_and_evidence_extensions_are_ineligible_even_when_explicit(self):
        for leaf in ("log.txt", "result.json", "tree.jsonl", "capture.pcap", "install.wim", "install.esd",
                     "part.swm", "program.exe", "program.efi", "provider.dll", "entropy.bin", "other.fd"):
            with self.subTest(leaf=leaf), self.assertRaises(ValueError):
                m.selection([self.root / "own-case" / leaf])
        for folder in m.EXCLUDED_DIRS:
            with self.subTest(folder=folder), self.assertRaises(ValueError):
                m.selection([self.root / folder / "misleading.raw"])
        self.assertEqual(m.selection([self.root / "own-case" / "vars.fd"])[0].name, "vars.fd")

    def test_foreign_device_traversal_empty_duplicate_lists_and_report_are_rejected(self):
        for paths in ([], [self.images[0], self.images[0]], [Path(r"\\.\PhysicalDrive0")],
                      [Path(r"C:\elsewhere\disk.raw")], [self.root / ".." / "disk.raw"]):
            with self.subTest(paths=paths), self.assertRaises(ValueError):
                m.selection(paths)
        with self.assertRaises(ValueError):
            m.report_path(self.root / "another-report.md")

    def test_wrong_volume_or_preexisting_output_fails_before_any_delete(self):
        auth = self.prepare(); self.ops.wrong_volume = True
        with self.assertRaises(ValueError):
            self.execute(auth)
        self.ops.wrong_volume = False
        self.ops.add(self.result, b"retained evidence")
        with self.assertRaises(FileExistsError):
            self.execute(auth)
        self.assertEqual(self.ops.nodes[self.result]["data"], b"retained evidence")
        self.assertEqual(self.removals(), [])

    def test_plan_type_volume_totals_and_file_metadata_are_all_validated(self):
        self.prepare()
        valid = json.loads(self.ops.nodes[self.plan_path]["data"])
        mutations = [lambda x: x.update(schema="other"), lambda x: x.update(stage="1b-1"),
                     lambda x: x.update(state="success"), lambda x: x.update(volume="other"),
                     lambda x: x.update(total_bytes=1), lambda x: x["files"][0].update(bytes=-1),
                     lambda x: x["files"][0].update(attributes=0x400),
                     lambda x: x["files"][0].update(file_id="not-an-id"),
                     lambda x: x["files"][0].update(sha256="A" * 64)]
        for mutation in mutations:
            value = copy.deepcopy(valid); mutation(value)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                m.validate_plan(value, self.report)

    def test_report_tag_must_be_whole_unique_line_and_sha_pin_exact(self):
        for text in ("draft", "prefix " + m.FINAL_TAG, m.FINAL_TAG + "\n" + m.FINAL_TAG):
            data = text.encode()
            with self.assertRaises(ValueError):
                m.check_report(data, m.sha(data))
        for value in (None, "A" * 64, "g" * 64, "a" * 63, "a" * 64 + "\n"):
            with self.assertRaises(ValueError): m.pin(value)

    def test_native_handle_guard_rejects_wrong_resolved_path_reparse_and_hardlinks(self):
        class API:
            def __init__(self):
                self.path = str(self_path)
                self.attributes, self.links = 0x20, 1
            def GetFileInformationByHandle(self, _, output):
                info = C.cast(output, C.POINTER(m.FileInfo)).contents
                info.attributes, info.links = self.attributes, self.links
                return 1
            def GetFinalPathNameByHandleW(self, _, output, __, ___):
                output.value = "\\\\?\\" + self.path
                return len(output.value)
        self_path = self.images[0]
        api = API(); ops = object.__new__(m.WindowsOps); ops.api = api
        with patch.object(Path, "resolve", lambda path, strict=False: path):
            self.assertEqual(ops.inspect_handle(1, self_path, False)["attributes"], 0x20)
            for field, value in (("path", str(self.root / "another.raw")), ("attributes", 0x420),
                                 ("attributes", 0x10), ("links", 2)):
                original = getattr(api, field); setattr(api, field, value)
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    ops.inspect_handle(1, self_path, False)
                setattr(api, field, original)


if __name__ == "__main__":
    unittest.main()
