"""Delete explicitly selected, accepted1b-1 images; preserve logs/manifests.

Never recursive deletion. Every image is identified by an allowlist, checked
detached, opened with no sharing, hashed, and deleted through that same held
handle. A passing receipt alone cannot remove an open or different image.
"""
from __future__ import annotations
import argparse
import contextlib
import ctypes
import hashlib
import importlib.util
import json
import msvcrt
import os
from pathlib import Path
import shutil
import subprocess
spec = importlib.util.spec_from_file_location("cleanup_scale_runtime", Path(__file__).with_name("scale_runtime.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def report_ready(root: Path) -> dict:
    """Preserve the final report BEFORE any image is removed, never a draft."""
    path = runtime.guarded(root, root / "validation/final-report-pre-cleanup.md")
    text = path.read_text(encoding="utf-8-sig")
    if "1b-1" not in text[:256] or "Status: RAPORT KOŃCOWY" not in text[:1024]:
        raise ValueError("A completed final report is required before image cleanup")
    return runtime.artifact(root, path)


def candidates(root: Path, case: dict) -> list[Path]:
    directory = case["case"]
    if case["firmware"]:
        run = directory / "run-64m"
        selected = [directory / name for name in ("esp-base.raw", "target-base.raw")]
        selected += [run / name for name in ("esp.qcow2", "target.qcow2", "esp-closed.raw", "entropy.bin")]
        if case["prepared"]["arch"] != "bios": selected.append(run / "vars.fd")
        selected.append(case["image"])
    else:
        selected = [directory / name for name in ("blank-base.qcow2", "fresh-test-cow.qcow2", "target.raw")]
    selected += [case["windows_dir"] / name for name in ("converted-fixed.vhd", "readonly-copy.vhd")]
    for path in selected:
        runtime.guarded(root, path)
        if not path.exists() or not path.is_file() or path.stat().st_nlink != 1:
            raise ValueError("Missing/nonregular/hard-linked selected image: " + str(path))
    return selected


class BasicInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_int64) for name in ("creation", "access", "write", "change")] + [("attributes", ctypes.c_uint32)]


class DispositionInfo(ctypes.Structure):
    _fields_ = [("delete", ctypes.c_ubyte)]


class AtomicImage:
    """The DELETE/read/attributes handle never permits another file opener."""
    def __init__(self, path: Path):
        self.path, self.file = path, None

    def __enter__(self):
        if os.name != "nt":
            raise ValueError("Atomic image cleanup requires the approved Windows host")
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        self.api.CreateFileW.restype = ctypes.c_void_p
        self.api.CloseHandle.argtypes = [ctypes.c_void_p]
        self.api.GetFileInformationByHandleEx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.api.GetFileInformationByHandleEx.restype = ctypes.c_int
        self.api.SetFileInformationByHandle.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.api.SetFileInformationByHandle.restype = ctypes.c_int
        handle = self.api.CreateFileW(str(self.path), 0x80010100, 0, None, 3, 0x00200000, None)
        if handle == ctypes.c_void_p(-1).value:
            raise OSError(ctypes.get_last_error(), "Image open/attached/inaccessible: " + str(self.path))
        try:
            fd = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
        except BaseException:
            self.api.CloseHandle(handle)
            raise
        self.file = os.fdopen(fd, "rb")
        self.handle = msvcrt.get_osfhandle(self.file.fileno())
        self.original = BasicInfo()
        if not self.api.GetFileInformationByHandleEx(self.handle, 0, ctypes.byref(self.original), ctypes.sizeof(self.original)):
            error = ctypes.get_last_error(); self.file.close(); self.file = None
            raise OSError(error, "Cannot inspect image attributes")
        return self

    def digest(self) -> tuple[int, str]:
        self.file.seek(0)
        digest = hashlib.sha256(); size = 0
        while data := self.file.read(1024 * 1024):
            digest.update(data); size += len(data)
        return size, digest.hexdigest()

    def delete(self):
        # Update only this exact held image's readonly bit, then mark deletion
        # without closing/reopening the path (no pathname race after hashing).
        writable = BasicInfo.from_buffer_copy(self.original)
        writable.attributes &= ~1
        if writable.attributes == 0: writable.attributes = 0x80
        if not self.api.SetFileInformationByHandle(self.handle, 0, ctypes.byref(writable), ctypes.sizeof(writable)):
            raise OSError(ctypes.get_last_error(), "Cannot clear owned image readonly flag")
        disposition = DispositionInfo(1)
        if not self.api.SetFileInformationByHandle(self.handle, 4, ctypes.byref(disposition), ctypes.sizeof(disposition)):
            error = ctypes.get_last_error()
            self.api.SetFileInformationByHandle(self.handle, 0, ctypes.byref(self.original), ctypes.sizeof(self.original))
            raise OSError(error, "Cannot mark exact held image for deletion")

    def __exit__(self, *_):
        if self.file: self.file.close()


def write_new(root: Path, path: Path, value):
    with runtime.guarded(root, path).open("x", encoding="utf-8", newline="\n") as output:
        json.dump(value, output, indent=2); output.write("\n")


def cleanup(root: Path, host: list[Path], firmware: list[Path], tag: str) -> dict:
    import re
    if not re.fullmatch(r"[a-z0-9-]+", tag): raise ValueError("Invalid cleanup receipt tag")
    report = report_ready(root)
    selections = runtime.cases(root, host, firmware)
    selected = [path for case in selections for path in candidates(root, case)]
    if len({str(path).casefold() for path in selected}) != len(selected):
        raise ValueError("Cleanup selections overlap")
    plan_path = runtime.guarded(root, root / ("cleanup-" + tag + "-plan.json"))
    done_path = runtime.guarded(root, root / ("cleanup-" + tag + "-completed.json"))
    if plan_path.exists() or done_path.exists():
        raise ValueError("A cleanup receipt already exists; never overwrite")
    preflight_path = root / ("cleanup-" + tag + "-detached.ps1")
    script = "param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Images) $ErrorActionPreference='Stop'; foreach($path in $Images) { $image=Get-DiskImage -ImagePath $path -ErrorAction Stop; if($image.Attached) { throw ('Selected VHD is still attached: '+$path) } }; 'ALL_SELECTED_VHDS_DETACHED'"
    with runtime.guarded(root, preflight_path).open("x", encoding="utf-8") as output: output.write(script)
    shell = shutil.which("pwsh.exe")
    if shell is None: raise ValueError("PowerShell7 required for explicit detached-image checks")
    vhds = [str(path) for path in selected if path.suffix.lower() == ".vhd"]
    app_data = runtime.guarded(root, root / ("cleanup-" + tag + "-host-runtime"))
    app_data.mkdir(exist_ok=False)
    environment = dict(os.environ)
    for name in ("APPDATA", "LOCALAPPDATA", "TMP", "TEMP"): environment[name] = str(app_data)
    process = subprocess.run([shell, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(preflight_path), *vhds],
        check=True, capture_output=True, text=True, timeout=120, env=environment,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    write_new(root, root / ("cleanup-" + tag + "-detached.json"), {
        "returncode": process.returncode, "stdout": process.stdout,
        "vhd_count": len(vhds), "all_detached": "ALL_SELECTED_VHDS_DETACHED" in process.stdout})
    if "ALL_SELECTED_VHDS_DETACHED" not in process.stdout:
        raise ValueError("Detached-image preflight did not produce its completion marker")
    files, deleted = [], []
    try:
        with contextlib.ExitStack() as locks:
            opened = []
            for path in selected:
                runtime.guarded(root, path)
                image = locks.enter_context(AtomicImage(path))
                size, digest = image.digest()
                files.append({"path": path.relative_to(root).as_posix(), "bytes": size, "sha256": digest})
                opened.append(image)
            # Pin the accepted target and readonly VHD hashes, not only names.
            observed = {root / row["path"]: row["sha256"] for row in files}
            for case in selections:
                if observed[case["image"]] != case["image_sha256"]:
                    raise ValueError("Accepted target image changed before cleanup")
                if observed[case["windows_dir"] / "readonly-copy.vhd"] != case["windows"]["vhd_sha256_after"]:
                    raise ValueError("Accepted readonly VHD changed before cleanup")
            write_new(root, plan_path, {"stage": "1b-1", "state": "all-exclusively-open-and-hashed",
                "files": files, "total_bytes": sum(row["bytes"] for row in files),
                "report_before_cleanup": report})
            for image, row in zip(opened, files):
                image.delete(); deleted.append(row["path"])
        if any(runtime.guarded(root, root / name).exists() for name in deleted):
            raise ValueError("A marked image remained after handle close")
    except BaseException as error:
        write_new(root, root / ("cleanup-" + tag + "-failed.json"), {"deleted": deleted, "error": repr(error)})
        raise
    result = {"stage": "1b-1", "state": "complete", "deleted": deleted,
              "files_count": len(files), "images_count": sum(Path(row["path"]).suffix != ".bin" for row in files),
              "removed_bytes": sum(row["bytes"] for row in files),
              "logs_and_manifests_preserved": True, "deletion_by_same_exclusive_handle": True,
              "report_before_cleanup": report}
    write_new(root, done_path, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    runtime.add_arguments(parser)
    parser.add_argument("--receipt-tag", default="final")
    args = parser.parse_args()
    root = Path(os.path.abspath(args.workspace))
    print(json.dumps(cleanup(root, args.host_case, args.firmware_case, args.receipt_tag)))


if __name__ == "__main__": main()
