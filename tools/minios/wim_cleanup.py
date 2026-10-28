#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit, two-phase MiniOS 1b-2 image cleanup AFTER the final report.

No discovery, recursive deletion, source cleanup or best-effort sharing is
provided. `plan` opens and hashes every explicitly selected image, writes a new
read-only plan, then appends that exact plan to the pinned final report. Its
authorization receipt supplies the new report hash for a separate `execute`.
Execution revalidates everything and holds all candidate handles exclusively
before changing any attribute. Deletion uses those same handles, never a path.
Logs, manifests, packet captures, WIM inputs and compiled programs are excluded.
"""
from __future__ import annotations

import argparse
import contextlib
import ctypes as C
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat

spec = importlib.util.spec_from_file_location("cleanup_wim_oracle", Path(__file__).with_name("wim_oracle.py"))
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)

FINAL_TAG = "<!-- FINALNY RAPORT MINIOS1B2 -->"
FINAL_REPORT = Path(os.environ.get("USOS_MINIOS_FINAL_REPORT", str(oracle.REPO / "docs/RAPORT-MINIOS-ETAP1B2.md")))
PLAN_SCHEMA = "minios-wim-cleanup-plan-v1"
RESULT_SCHEMA = "minios-wim-cleanup-result-v1"
MAX_FILES = 4096
MAX_DOCUMENT = 16 * 1024**2
# Even a misleading image suffix must not permit removing a WIM source tree,
# build cache or compiler output. Oracle copies outside these folders can be
# selected explicitly; no file under a source/inputs folder is eligible.
EXCLUDED_DIRS = frozenset(("synthetic", "source", "sources", "input", "inputs", "vendor",
                           "build", "builds", "compiled", "artifacts", "zig-out",
                           ".zig-cache", "cache", "tools", "bin", "lib"))


def pin(value: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("An explicit lowercase SHA256 pin is required")
    return value


def encoded(value) -> bytes:
    return (json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def same_path(left: Path, right: Path) -> bool:
    return str(left).casefold() == str(right).casefold()


def candidate(path: Path) -> Path:
    """Lexical scope is checked before any file is opened or resolved."""
    oracle.owned(path)
    relative = path.relative_to(oracle.RUNTIME)
    if any(part.casefold() in EXCLUDED_DIRS for part in relative.parts[:-1]):
        raise ValueError("Source, WIM input, build or compiled-artifact directory excluded")
    if path.suffix.casefold() not in (".raw", ".vhd", ".qcow2") and path.name.casefold() != "vars.fd":
        raise ValueError("Only explicit .raw/.vhd/.qcow2/vars.fd test images are eligible")
    return path


def selection(paths: list[Path]) -> list[Path]:
    if not 1 <= len(paths) <= MAX_FILES:
        raise ValueError("A nonempty bounded explicit image list is required")
    result = [candidate(path) for path in paths]
    if len({str(path).casefold() for path in result}) != len(result):
        raise ValueError("Duplicate image selections are forbidden")
    return result


def document(path: Path) -> Path:
    oracle.owned(path)
    if path.suffix.casefold() != ".json":
        raise ValueError("Cleanup receipts must be .json files inside the approved runtime")
    return path


def report_path(path: Path) -> Path:
    oracle.local(path)
    if not same_path(path, FINAL_REPORT):
        raise ValueError("Only the explicit final MiniOS 1b-2 report is accepted")
    return path


def check_report(data: bytes, expected_sha: str) -> None:
    if len(data) > MAX_DOCUMENT or sha(data) != pin(expected_sha):
        raise ValueError("Final report hash/size mismatch")
    if data.decode("utf-8-sig").splitlines().count(FINAL_TAG) != 1:
        raise ValueError("The completed final-report tag must occur on exactly one whole line")


def plan_block(plan_path: Path, plan_sha: str, value: dict) -> bytes:
    # The exact list, not merely a link or a promise, is preserved in the report.
    return ("\n<!-- MINIOS1B2 CLEANUP PLAN " + pin(plan_sha) + " -->\n"
            + "Plan: `" + str(plan_path) + "`\n\nSHA256: `" + plan_sha + "`\n\n"
            + "```json\n").encode("utf-8") + encoded(value) + b"```\n<!-- END MINIOS1B2 CLEANUP PLAN -->\n"


def validate_plan(value: dict, report: Path) -> list[Path]:
    if (value.get("schema") != PLAN_SCHEMA or value.get("stage") != "1b-2"
            or value.get("state") != "all-exclusively-open-and-hashed"
            or value.get("runtime") != str(oracle.RUNTIME)
            or value.get("volume") != oracle.VOLUME
            or value.get("report") != str(report)):
        raise ValueError("Wrong cleanup plan identity/state")
    pin(value.get("report_sha256_before_plan"))
    rows = value.get("files")
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise ValueError("Invalid cleanup image list")
    paths = selection([Path(row.get("path", "")) for row in rows])
    for row in rows:
        pin(row.get("sha256"))
        if (type(row.get("bytes")) is not int or row["bytes"] < 0
                or not isinstance(row.get("file_id"), str)
                or re.fullmatch(r"[0-9a-f]{8}:[0-9a-f]{16}", row["file_id"]) is None
                or type(row.get("attributes")) is not int
                or not 0 <= row["attributes"] <= 0xffffffff
                or row["attributes"] & (0x10 | 0x400)):
            raise ValueError("Invalid regular-image identity/size/attributes")
    if type(value.get("total_bytes")) is not int or value["total_bytes"] != sum(row["bytes"] for row in rows):
        raise ValueError("Cleanup byte total does not match the exact list")
    return paths


class BasicInfo(C.Structure):
    _fields_ = [(name, C.c_int64) for name in ("creation", "access", "write", "change")] + [("attributes", C.c_uint32)]


class FileTime(C.Structure):
    _fields_ = [("low", C.c_uint32), ("high", C.c_uint32)]


class FileInfo(C.Structure):
    _fields_ = [("attributes", C.c_uint32), ("created", FileTime), ("accessed", FileTime),
                ("written", FileTime), ("volume", C.c_uint32), ("size_high", C.c_uint32),
                ("size_low", C.c_uint32), ("links", C.c_uint32),
                ("index_high", C.c_uint32), ("index_low", C.c_uint32)]


class Disposition(C.Structure):
    _fields_ = [("delete", C.c_ubyte)]  # Win32 BOOLEAN, not a four-byte BOOL.


class WindowsHandle:
    def __init__(self, ops, path: Path, role: str):
        self.ops, self.path, self.role, self.file = ops, path, role, None

    def __enter__(self):
        import msvcrt
        access = {"image": 0x80010100, "report": 0xC0000000, "read": 0x80000000}[self.role]
        handle = self.ops.api.CreateFileW(str(self.path), access, 0, None, 3, 0x00200000, None)
        if handle == C.c_void_p(-1).value:
            raise OSError(C.get_last_error(), "Exclusive open refused; image may be active: " + str(self.path))
        try:
            descriptor = msvcrt.open_osfhandle(handle, (os.O_RDWR if self.role == "report" else os.O_RDONLY) | os.O_BINARY)
        except BaseException:
            self.ops.api.CloseHandle(handle)
            raise
        self.file = os.fdopen(descriptor, "r+b" if self.role == "report" else "rb")
        self.handle = msvcrt.get_osfhandle(self.file.fileno())
        try:
            self.ops.inspect_handle(self.handle, self.path, directory=False)
            self.original = BasicInfo()
            if not self.ops.api.GetFileInformationByHandleEx(self.handle, 0, C.byref(self.original), C.sizeof(self.original)):
                raise C.WinError(C.get_last_error())
        except BaseException:
            self.close()
            raise
        return self

    def read_document(self) -> bytes:
        self.file.seek(0)
        data = self.file.read(MAX_DOCUMENT + 1)
        if len(data) > MAX_DOCUMENT:
            raise ValueError("Cleanup document exceeds its bound")
        return data

    def describe(self) -> dict:
        before = self.ops.inspect_handle(self.handle, self.path, directory=False)
        self.file.seek(0)
        digest = hashlib.sha256()
        size = 0
        while block := self.file.read(1024**2):
            size += len(block)
            digest.update(block)
        after = self.ops.inspect_handle(self.handle, self.path, directory=False)
        if before != after or size != before["bytes"]:
            raise ValueError("An exclusively held image changed during hashing")
        return {"path": str(self.path), **before, "sha256": digest.hexdigest()}

    def append(self, data: bytes) -> None:
        if self.role != "report":
            raise ValueError("Only the final report can be appended")
        self.file.seek(0, 2)
        self.file.write(data)
        self.file.flush()
        os.fsync(self.file.fileno())

    def remove(self) -> None:
        if self.role != "image":
            raise ValueError("Only a validated image handle can delete")
        changed = BasicInfo.from_buffer_copy(self.original)
        changed.attributes &= ~1
        if not changed.attributes:
            changed.attributes = 0x80
        if not self.ops.api.SetFileInformationByHandle(self.handle, 0, C.byref(changed), C.sizeof(changed)):
            raise C.WinError(C.get_last_error())
        disposition = Disposition(1)
        if not self.ops.api.SetFileInformationByHandle(self.handle, 4, C.byref(disposition), C.sizeof(disposition)):
            error = C.get_last_error()
            self.ops.api.SetFileInformationByHandle(self.handle, 0, C.byref(self.original), C.sizeof(self.original))
            raise OSError(error, "Exact held image could not be marked for deletion")
        self.close()  # Actual deletion is completed by closing this handle.
        if self.path.exists():
            raise ValueError("Image path still exists after closing the delete-pending handle")

    def close(self):
        if self.file is not None:
            self.file.close()
            self.file = None

    def __exit__(self, *_):
        self.close()


class WindowsOps:
    def __init__(self):
        if os.name != "nt":
            raise ValueError("The approved Windows host is required")
        self.api = C.WinDLL("kernel32", use_last_error=True)
        self.api.CreateFileW.argtypes = [C.c_wchar_p, C.c_uint32, C.c_uint32, C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p]
        self.api.CreateFileW.restype = C.c_void_p
        self.api.CloseHandle.argtypes = [C.c_void_p]
        self.api.GetFileInformationByHandle.argtypes = [C.c_void_p, C.POINTER(FileInfo)]
        self.api.GetFileInformationByHandle.restype = C.c_int
        self.api.GetFinalPathNameByHandleW.argtypes = [C.c_void_p, C.c_wchar_p, C.c_uint32, C.c_uint32]
        self.api.GetFinalPathNameByHandleW.restype = C.c_uint32
        self.api.GetFileInformationByHandleEx.argtypes = [C.c_void_p, C.c_int, C.c_void_p, C.c_uint32]
        self.api.GetFileInformationByHandleEx.restype = C.c_int
        self.api.SetFileInformationByHandle.argtypes = [C.c_void_p, C.c_int, C.c_void_p, C.c_uint32]
        self.api.SetFileInformationByHandle.restype = C.c_int
        self.api.GetVolumeNameForVolumeMountPointW.argtypes = [C.c_wchar_p, C.c_wchar_p, C.c_uint32]
        self.api.GetVolumeNameForVolumeMountPointW.restype = C.c_int

    def volume(self):
        oracle.local(oracle.RUNTIME)
        name = C.create_unicode_buffer(64)
        if (not self.api.GetVolumeNameForVolumeMountPointW(oracle.RUNTIME.anchor, name, len(name))
                or name.value.casefold() != oracle.VOLUME.casefold()):
            raise ValueError("The approved Kioxia runtime volume identity does not match")
        if not oracle.RUNTIME.is_dir():
            raise ValueError("Existing approved runtime required")

    def regular(self, path: Path):
        oracle.local(path)
        resolved = path.resolve(strict=True)
        if not same_path(path, resolved):
            raise ValueError("Candidate must have its full canonical resolved path")
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or getattr(info, "st_file_attributes", 0) & (0x10 | 0x400)):
            raise ValueError("Only a regular non-reparse single-link file is allowed")

    def inspect_handle(self, handle, expected: Path, directory: bool) -> dict:
        info = FileInfo()
        final = C.create_unicode_buffer(32768)
        if not self.api.GetFileInformationByHandle(handle, C.byref(info)):
            raise C.WinError(C.get_last_error())
        length = self.api.GetFinalPathNameByHandleW(handle, final, len(final), 0)
        if not length or length >= len(final):
            raise ValueError("Cannot obtain the complete held file's canonical path")
        actual = final.value
        if actual.startswith("\\\\?\\"):
            actual = actual[4:]
        if (not same_path(Path(actual), expected.resolve(strict=True)) or info.attributes & 0x400
                or bool(info.attributes & 0x10) != directory or (not directory and info.links != 1)):
            raise ValueError("Held file identity/path/type/reparse/hard-link guard failed")
        return {"bytes": (info.size_high << 32) | info.size_low,
                "file_id": f"{info.volume:08x}:{(info.index_high << 32) | info.index_low:016x}",
                "attributes": info.attributes}

    @contextlib.contextmanager
    def parents(self, paths: list[Path]):
        # Deny directory deletion/rename for the entire operation. Reads/writes
        # by unrelated tasks remain possible; no directory is ever deleted.
        unique = {str(parent).casefold(): parent for path in paths for parent in path.parents}
        with contextlib.ExitStack() as stack:
            for parent in sorted(unique.values(), key=lambda p: len(p.parts)):
                oracle.local(parent)
                handle = self.api.CreateFileW(str(parent), 0x80, 3, None, 3, 0x02200000, None)
                if handle == C.c_void_p(-1).value:
                    raise OSError(C.get_last_error(), "Cannot pin parent directory: " + str(parent))
                stack.callback(self.api.CloseHandle, handle)
                self.inspect_handle(handle, parent, directory=True)
            yield

    def open(self, path: Path, role: str):
        self.regular(path)
        return WindowsHandle(self, path, role)

    def new(self, path: Path):
        document(path)
        if path.exists():
            raise FileExistsError("Never overwrite a cleanup plan/receipt")
        if not path.parent.is_dir():
            raise ValueError("Cleanup output parent must already exist")

    def exists(self, path: Path) -> bool:
        return path.exists()

    def save(self, path: Path, value, immutable: bool = False):
        self.new(path)
        with path.open("xb") as out:
            out.write(encoded(value))
            out.flush()
            os.fsync(out.fileno())
        if immutable:
            path.chmod(stat.S_IREAD)


def prepare_plan(paths: list[Path], report: Path, report_sha: str, plan_path: Path,
                 authorization_path: Path, ops=None) -> dict:
    ops = ops or WindowsOps()
    paths = selection(paths)
    report_path(report)
    document(plan_path)
    document(authorization_path)
    if same_path(plan_path, authorization_path):
        raise ValueError("Plan and authorization receipt must be different files")
    ops.volume()
    ops.new(plan_path)
    ops.new(authorization_path)
    with ops.parents([*paths, report, plan_path, authorization_path]), contextlib.ExitStack() as stack:
        final = stack.enter_context(ops.open(report, "report"))
        check_report(final.read_document(), report_sha)
        images = [stack.enter_context(ops.open(path, "image")) for path in paths]
        rows = [image.describe() for image in images]
        value = {"schema": PLAN_SCHEMA, "stage": "1b-2", "state": "all-exclusively-open-and-hashed",
                 "runtime": str(oracle.RUNTIME), "volume": oracle.VOLUME,
                 "report": str(report), "report_sha256_before_plan": pin(report_sha),
                 "files": rows, "total_bytes": sum(row["bytes"] for row in rows)}
        validate_plan(value, report)
        ops.save(plan_path, value, immutable=True)
        # Hold the newly written plan against modification while publishing its
        # exact list in the report. A crash before this append cannot authorize
        # execute, which requires the block and fresh explicit report hash.
        held_plan = stack.enter_context(ops.open(plan_path, "read"))
        plan_data = held_plan.read_document()
        if plan_data != encoded(value):
            raise ValueError("New cleanup plan changed before report publication")
        plan_sha = sha(plan_data)
        final.append(plan_block(plan_path, plan_sha, value))
        report_after = sha(final.read_document())
        result = {"schema": "minios-wim-cleanup-authorization-v1", "state": "planned-not-executed",
                  "plan": str(plan_path), "plan_sha256": plan_sha, "report": str(report),
                  "report_sha256": report_after, "files": len(rows), "total_bytes": value["total_bytes"],
                  "all_images_exclusively_hashed": True, "images_deleted": 0}
        ops.save(authorization_path, result, immutable=True)
        return result


def execute_plan(report: Path, report_sha: str, plan_path: Path, plan_sha: str,
                 result_path: Path, ops=None) -> dict:
    ops = ops or WindowsOps()
    report_path(report)
    document(plan_path)
    document(result_path)
    pin(report_sha)
    pin(plan_sha)
    if same_path(plan_path, result_path):
        raise ValueError("Execution result must not overwrite its immutable plan")
    ops.volume()
    ops.new(result_path)
    receipt = {"schema": RESULT_SCHEMA, "stage": "1b-2", "state": "refused",
               "plan": str(plan_path), "plan_sha256": plan_sha,
               "report": str(report), "report_sha256_before_execute": report_sha,
               "all_candidates_validated_before_delete": False,
               "removed": [], "failed": [], "logs_jsonl_pcap_preserved": True}
    rows = []
    try:
        with ops.open(plan_path, "read") as held_plan:
            data = held_plan.read_document()
            if sha(data) != plan_sha:
                raise ValueError("Immutable cleanup plan hash mismatch")
            value = json.loads(data)
            paths = validate_plan(value, report)
            rows = value["files"]
            with ops.parents([*paths, report, plan_path, result_path]), contextlib.ExitStack() as stack:
                final = stack.enter_context(ops.open(report, "report"))
                report_data = final.read_document()
                check_report(report_data, report_sha)
                # Parent names are now held against rename/reparse changes;
                # recheck the same still-held plan's canonical identity too.
                if held_plan.read_document() != data:
                    raise ValueError("Held cleanup plan changed before execution")
                held_plan.describe()
                block = plan_block(plan_path, plan_sha, value)
                if report_data.count(block) != 1:
                    raise ValueError("The exact immutable plan is not published once in the final report")
                opened = []
                for path, expected in zip(paths, rows):
                    image = stack.enter_context(ops.open(path, "image"))
                    if image.describe() != expected:
                        raise ValueError("Image size/SHA256/file identity/attributes changed: " + str(path))
                    opened.append(image)
                # All candidates, report and plan remain held. No readonly bit
                # or file has been changed before this point.
                receipt["all_candidates_validated_before_delete"] = True
                receipt["state"] = "partial"
                for index, (image, row) in enumerate(zip(opened, rows)):
                    try:
                        image.remove()
                        receipt["removed"].append(row)
                    except BaseException as error:
                        # An interrupt can arrive just after the kernel marked
                        # deletion but before remove() returned. Close that
                        # exact handle now and classify the resulting state,
                        # rather than publishing a false "not removed" row.
                        image.close()
                        if not ops.exists(Path(row["path"])):
                            receipt["removed"].append(row)
                            receipt["operation_error"] = repr(error)
                        else:
                            receipt["failed"].append({**row, "error": repr(error)})
                        receipt["failed"].extend({**later, "error": "not attempted after an earlier deletion failure"}
                                                 for later in rows[index + 1:])
                        break
                if len(receipt["removed"]) == len(rows) and "operation_error" not in receipt:
                    receipt["state"] = "complete"
                # A durable exact result precedes the final report append. If
                # saving fails, the exception exposes that evidence failure;
                # the caller must never infer success from delete requests.
                ops.save(result_path, receipt, immutable=True)
                final.append(("\n<!-- MINIOS1B2 CLEANUP RESULT " + sha(encoded(receipt)) + " -->\n```json\n").encode("utf-8")
                             + encoded(receipt) + b"```\n<!-- END MINIOS1B2 CLEANUP RESULT -->\n")
                return receipt
    except BaseException as error:
        if receipt["removed"]:
            receipt["state"] = "evidence-failed" if receipt["state"] == "complete" else "partial"
        receipt["error"] = repr(error)
        if not receipt["failed"]:
            removed_paths = {row["path"] for row in receipt["removed"]}
            receipt["failed"] = [{**row, "error": "not removed: operation refused"}
                                 for row in rows if row["path"] not in removed_paths]
        # Refusal receipts do not change the pinned report or any image. If a
        # completed result already exists, preserve it instead of overwriting.
        if not ops.exists(result_path):
            ops.save(result_path, receipt, immutable=True)
        return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    for name in ("plan", "execute"):
        command = commands.add_parser(name)
        command.add_argument("--report", type=Path, required=True)
        command.add_argument("--report-sha256", required=True)
        command.add_argument("--plan", type=Path, required=True)
        if name == "plan":
            command.add_argument("--candidate", type=Path, action="append", required=True)
            command.add_argument("--authorization", type=Path, required=True)
        else:
            command.add_argument("--plan-sha256", required=True)
            command.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "plan":
        result = prepare_plan(args.candidate, args.report, args.report_sha256, args.plan, args.authorization)
    else:
        result = execute_plan(args.report, args.report_sha256, args.plan, args.plan_sha256, args.result)
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result["state"] in ("planned-not-executed", "complete") else 1


if __name__ == "__main__":
    raise SystemExit(main())
