"""One-use, exact-scope NT3 cleanup authorized after plan 4c309e57.

No wildcard deletion, recursive deletion, force sharing, or QEMU mutation.
All filesystem operations use Python/Win32; PowerShell only supplies one
read-only CIM process snapshot, with command lines retained only in RAM.
"""
from __future__ import annotations

import ctypes as C
from ctypes import wintypes as W
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

WORK = Path(__file__).resolve().parents[2]
PLAN = WORK / "docs/nt3-closed-vm-cleanup-plan.json"
PLAN_SHA = "dd2c75b4374714d8f8728437f395b6425c948f09064a9e11adfc2bd86c8cb545"
VM = Path(r"G:\USOS-Kolekcja\_vm")
TAGS = (
    "r18c-nt351-cold-i8042-off", "r24b-nt31-image-entry",
    "nt351-client-apply01", "nt35-client-apply01",
    "nt35-client-apply02", "nt35-client-baseline01",
)
NAMES = ("target.qcow2", "stick.qcow2")
QIMG = Path(r"C:\Users\ASRock\usos-work\bety-instalacja\tools\qemu\qemu-img.exe")
OUT = WORK / "artifacts/nt3-cleanup-execution"
RECEIPT = OUT / "receipt.json"


def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def norm(path):
    return os.path.normcase(os.path.normpath(str(path)))


def metadata(path):
    p = Path(path)
    s = p.stat(follow_symlinks=False)
    if not stat.S_ISREG(s.st_mode) or s.st_file_attributes & 0x400:
        raise ValueError(f"Not a regular non-reparse file: {p}")
    return {"path": str(p), "bytes": s.st_size,
            "file_id": [str(s.st_dev), str(s.st_ino)],
            "hardlink_count": s.st_nlink}


def compare(actual, expected):
    for key in ("bytes", "file_id", "hardlink_count"):
        if actual[key] != expected[key]:
            raise ValueError(f"Changed {key}: {actual['path']}")


def safe_path(path):
    p = Path(path)
    if not p.is_absolute() or norm(p.resolve(strict=True)) != norm(p):
        raise ValueError(f"Unresolved/redirected path: {p}")
    if norm(p) not in {norm(VM), norm(VM.parent)} and VM not in p.parents:
        raise ValueError(f"Outside literal VM root: {p}")
    for a in (p, *p.parents):
        if a.stat(follow_symlinks=False).st_file_attributes & 0x400:
            raise ValueError(f"Reparse ancestor: {a}")
    return p


def leaves(obj, key=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, key + "." + k)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from leaves(v, key + f"[{i}]")
    elif isinstance(obj, str):
        yield key, obj


def preparation_check(plan, candidates):
    # Static preparation metadata only; no active logs, images, NT4 or macOS.
    source = WORK.parent
    known = {(norm(x["file"]), x["key"], norm(x["value"]))
             for x in plan["static_references"]}
    documents, matches = [], []
    for tree in sorted(source.iterdir()):
        if not tree.name.lower().startswith("nt3") or not tree.is_dir():
            continue
        root = tree / "artifacts"
        for f in sorted(root.rglob("*.json")):
            if "prepar" not in f.name.lower():
                continue
            if f.stat().st_size > 2 * 1024 * 1024:
                raise ValueError(f"Unbounded preparation document: {f}")
            raw = f.read_bytes()
            data = json.loads(raw.decode("utf-8-sig"))
            documents.append({"path": str(f), "sha256": hashlib.sha256(raw).hexdigest()})
            for key, value in leaves(data):
                value_n = norm(value)
                for p in candidates:
                    # Also catch a reference to the candidate's containing case.
                    if norm(p.parent) not in value_n:
                        continue
                    if (norm(f), key, value_n) not in known:
                        raise ValueError(f"New candidate reference: {f} {key}")
                    matches.append({"file": str(f), "key": key, "value": value})
    return {"documents": documents, "known_candidate_references": matches,
            "scope": "Static preparation JSON under literal nt3* worktree artifacts; no global hidden-descendant claim"}


def process_gate(candidates, env):
    # One process query only. Never persist or print arbitrary command lines.
    script = ("$ErrorActionPreference='Stop'; "
              "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); "
              "$p=@(Get-CimInstance Win32_Process -Filter \"Name LIKE 'qemu-system%'\" "
              "| Select-Object ProcessId,Name,CommandLine); "
              "ConvertTo-Json -InputObject $p -Compress")
    r = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                       capture_output=True, check=False, timeout=45, env=env)
    if r.returncode:
        raise ValueError("One-shot QEMU command-line safety query failed")
    processes = json.loads(r.stdout.decode("utf-8-sig"))
    if not isinstance(processes, list):
        raise ValueError("Invalid QEMU safety snapshot")
    matches = []
    for proc in processes:
        if not proc.get("CommandLine"):
            raise ValueError("QEMU command line unavailable; fail closed")
        text = proc["CommandLine"].replace("\\\\", "\\").replace("/", "\\").casefold()
        for p in candidates:
            if str(p).casefold() in text:
                matches.append({"pid": proc["ProcessId"], "candidate": str(p)})
    if matches:
        raise ValueError("A selected candidate is referenced by a live QEMU command line")
    return {"queried_at": stamp(), "query_count": 1,
            "qemu_process_count": len(processes), "candidate_matches": [],
            "command_lines_persisted": False}


class FileID(C.Structure):
    _fields_ = [("volume", C.c_ulonglong), ("id", C.c_ubyte * 16)]


class BasicInfo(C.Structure):
    _fields_ = [("attributes", W.DWORD), ("creation", W.FILETIME),
                ("access", W.FILETIME), ("write", W.FILETIME),
                ("volume", W.DWORD), ("size_high", W.DWORD),
                ("size_low", W.DWORD), ("links", W.DWORD),
                ("index_high", W.DWORD), ("index_low", W.DWORD)]


class Disposition(C.Structure):
    _fields_ = [("delete", W.BOOL)]


class ExclusiveFile:
    """Pin exact file identity and refuse every other open until deletion/close."""
    def __init__(self, path, expected):
        self.path, self.handle = path, None
        k = self.k = C.WinDLL("kernel32", use_last_error=True)
        k.CreateFileW.argtypes = [W.LPCWSTR, W.DWORD, W.DWORD, W.LPVOID, W.DWORD, W.DWORD, W.HANDLE]
        k.CreateFileW.restype = W.HANDLE
        k.CloseHandle.argtypes = [W.HANDLE]
        k.CloseHandle.restype = W.BOOL
        k.GetFileInformationByHandleEx.argtypes = [W.HANDLE, C.c_int, W.LPVOID, W.DWORD]
        k.GetFileInformationByHandleEx.restype = W.BOOL
        k.GetFileInformationByHandle.argtypes = [W.HANDLE, C.POINTER(BasicInfo)]
        k.GetFileInformationByHandle.restype = W.BOOL
        k.GetFinalPathNameByHandleW.argtypes = [W.HANDLE, W.LPWSTR, W.DWORD, W.DWORD]
        k.GetFinalPathNameByHandleW.restype = W.DWORD
        k.SetFileInformationByHandle.argtypes = [W.HANDLE, C.c_int, W.LPVOID, W.DWORD]
        k.SetFileInformationByHandle.restype = W.BOOL
        # DELETE | FILE_READ_ATTRIBUTES, share=0, OPEN_EXISTING, no reparse following.
        h = k.CreateFileW(str(path), 0x10000 | 0x80, 0, None, 3, 0x200000, None)
        if h == C.c_void_p(-1).value:
            raise OSError(C.get_last_error(), f"Exclusive open refused: {path}")
        self.handle = h
        try:
            fid, basic, name = FileID(), BasicInfo(), C.create_unicode_buffer(32768)
            if not k.GetFileInformationByHandleEx(h, 18, C.byref(fid), C.sizeof(fid)):
                raise C.WinError(C.get_last_error())
            if not k.GetFileInformationByHandle(h, C.byref(basic)):
                raise C.WinError(C.get_last_error())
            n = k.GetFinalPathNameByHandleW(h, name, len(name), 0)
            if not n or n >= len(name):
                raise ValueError("Cannot resolve exclusive handle path")
            final = name.value.removeprefix("\\\\?\\")
            actual = {"path": str(path), "bytes": (basic.size_high << 32) | basic.size_low,
                      "file_id": [str(fid.volume), str(int.from_bytes(bytes(fid.id), "little"))],
                      "hardlink_count": basic.links}
            if basic.attributes & (0x400 | 0x10) or norm(final) != norm(path):
                raise ValueError(f"Exclusive handle path/type mismatch: {path}")
            compare(actual, expected)
            self.actual = actual
        except BaseException:
            self.close()
            raise

    def unlink_exact_handle(self):
        # FileDispositionInfo, not recursive/path-based deletion. No force flags.
        d = Disposition(True)
        if not self.k.SetFileInformationByHandle(self.handle, 4, C.byref(d), C.sizeof(d)):
            raise C.WinError(C.get_last_error())

    def close(self):
        if self.handle is not None:
            h, self.handle = self.handle, None
            if not self.k.CloseHandle(h):
                raise C.WinError(C.get_last_error())


def main():
    if sys.argv[1:] != ["--execute-authorized-twelve"] or os.name != "nt":
        raise SystemExit("Requires explicit exact-scope execution flag on Windows")
    if RECEIPT.exists() or (OUT / "events.jsonl").exists():
        raise SystemExit("Existing receipt/event journal: refuse repeat execution")
    plan = json.loads(PLAN.read_text(encoding="utf-8"))
    if sha(PLAN) != PLAN_SHA or tuple(plan["eligible_leaf_order"]) != TAGS:
        raise SystemExit("Changed literal plan/pin")
    candidates = [VM / tag / name for tag in TAGS for name in NAMES]
    expected = {norm(f["path"]): f for f in plan["files"]}
    if len(candidates) != 12 or len({norm(p) for p in candidates}) != 12:
        raise SystemExit("Invalid exact twelve")
    receipt = {"started": stamp(), "authorization": "Parent /root explicitly authorized only target.qcow2 and stick.qcow2 in the six plan leaves",
               "plan_commit": "4c309e5790fe30849352bf3ed97789e7b0c3ef43",
               "plan_sha256": PLAN_SHA, "helper_sha256": sha(__file__),
               "selected": [], "closure_checks": [], "backing_checks": [],
               "removed": [], "refused": [], "status": "PREFLIGHT"}
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    local = OUT / "runtime-local"
    local.mkdir(exist_ok=True)
    for key in ("TEMP", "TMP", "APPDATA", "LOCALAPPDATA"):
        env[key] = str(local)
    journal = (OUT / "events.jsonl").open("x", encoding="utf-8", newline="\n")

    def save(event):
        journal.write(json.dumps({"at": stamp(), **event}, ensure_ascii=False) + "\n")
        journal.flush()
        os.fsync(journal.fileno())
        raw = (json.dumps(receipt, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        tmp = OUT / "receipt.tmp"
        tmp.write_bytes(raw)
        os.replace(tmp, RECEIPT)

    handles = []
    try:
        safe_path(VM)
        for tag in TAGS:
            case = plan["cases"][tag]
            if not case["closed_proof_valid"] or norm(case["directory"]) != norm(VM / tag):
                raise ValueError(f"Case scope/closure mismatch: {tag}")
            safe_path(VM / tag)
        # Revalidate closure pins for the complete owned closed graph before
        # opening those known closed headers; no new/nonowned images opened.
        for tag, case in plan["cases"].items():
            if not case["closed_proof_valid"]:
                raise ValueError(f"Unclosed graph member: {tag}")
            for proof in case["closure"]:
                if sha(proof["path"]) != proof["sha256"]:
                    raise ValueError(f"Changed closure proof: {proof['path']}")
                receipt["closure_checks"].append({"case": tag, **proof, "matched": True})
        for p in candidates:
            safe_path(p)
            actual = metadata(p)
            compare(actual, expected[norm(p)])
            if actual["hardlink_count"] != 1:
                raise ValueError(f"Candidate has another hardlink: {p}")
            receipt["selected"].append(actual)
        receipt["preparation_reference_check"] = preparation_check(plan, candidates)
        parents = set()
        for image in plan["images"]:
            p = safe_path(image["path"])
            compare(metadata(p), expected[norm(p)])
            r = subprocess.run([str(QIMG), "info", "--output=json", str(p)],
                               capture_output=True, timeout=30, env=env)
            if r.returncode:
                raise ValueError(f"Closed image metadata open refused: {p}")
            info = json.loads(r.stdout)
            backing = info.get("full-backing-filename", info.get("backing-filename"))
            backing = str((p.parent / backing).resolve()) if backing and not Path(backing).is_absolute() else backing
            if (info.get("format") != image["format"] or
                    info.get("virtual-size") != image["virtual_size"] or
                    bool(info.get("dirty-flag", False)) != image["dirty"] or
                    (norm(backing) if backing else None) != (norm(image["backing"]) if image["backing"] else None)):
                raise ValueError(f"Changed backing/header: {p}")
            if backing and norm(backing) in {norm(c) for c in candidates}:
                raise ValueError(f"Candidate has a child: {p}")
            if backing:
                safe_path(backing)
                parents.add(str(Path(backing)))
            receipt["backing_checks"].append({"path": str(p), "backing": backing,
                                              "matched_plan": True, "dirty": False})
        # Metadata-only snapshots, including external parents: no parent bytes read.
        preserved = {norm(f["path"]): metadata(f["path"]) for f in plan["files"]
                     if norm(f["path"]) not in {norm(c) for c in candidates}}
        for parent in parents:
            preserved[norm(parent)] = metadata(parent)
        receipt["retained_parents"] = [preserved[norm(p)] for p in sorted(parents)]
        receipt["preserved_file_count"] = len(preserved)
        receipt["process_safety_gate"] = process_gate(candidates, env)
        # Acquire every exact file before any deletion. A sharing violation is
        # a refusal, never retried or bypassed. Holding all handles closes races.
        for p in candidates:
            handles.append(ExclusiveFile(p, expected[norm(p)]))
        receipt["status"] = "PREFLIGHT_PASSED_EXCLUSIVE_HANDLES_HELD"
        save({"event": "all_twelve_preflight_passed", "candidate_count": 12})
        for h in handles:
            save({"event": "before_exact_handle_unlink", **h.actual})
            h.unlink_exact_handle()
            h.close()
            if h.path.exists():
                raise ValueError(f"Path still exists after exact handle unlink: {h.path}")
            receipt["removed"].append({**h.actual, "removed_at": stamp(),
                                       "method": "exclusive Win32 handle, FileDispositionInfo, CloseHandle",
                                       "path_absent_after_close": True})
            save({"event": "removed", **h.actual})
        for actual in preserved.values():
            compare(metadata(actual["path"]), actual)
        receipt["preserved_file_metadata_unchanged"] = True
        receipt["removed_bytes_logical"] = sum(x["bytes"] for x in receipt["removed"])
        receipt["allocated_space_reclaimed_not_measured"] = True
        receipt["finished"] = stamp()
        receipt["status"] = "COMPLETED_EXACTLY_TWELVE"
        save({"event": "completed", "removed_count": len(receipt["removed"]),
              "logical_bytes": receipt["removed_bytes_logical"]})
    except BaseException as exc:
        receipt["status"] = "REFUSED_OR_PARTIAL_STOP_NO_RETRY"
        receipt["refused"].append({"error": type(exc).__name__, "reason": str(exc)})
        receipt["finished"] = stamp()
        save({"event": "refused_or_partial_stop", "error": type(exc).__name__, "reason": str(exc)})
        raise
    finally:
        for h in handles:
            h.close()
        journal.close()
    print(json.dumps({"status": receipt["status"], "removed_count": len(receipt["removed"]),
                      "logical_bytes": receipt["removed_bytes_logical"], "receipt": str(RECEIPT)}))


if __name__ == "__main__":
    main()
