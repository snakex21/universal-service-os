"""Verify a closed 64 MiB guest image through independent read-only hosts.

No running target is copied. Export receipts pin both the COW and its base
before/after conversion, then make the independent copy read-only.
"""
from __future__ import annotations
import argparse
import contextlib
import ctypes
import importlib.util
import json
import msvcrt
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import struct
import uuid

spec = importlib.util.spec_from_file_location("prep_case", Path(__file__).with_name("uefi_case.py"))
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)
REPO = Path(__file__).resolve().parents[2]
ORACLE = REPO / "zig-out/minios-oracle"
SOURCE = REPO
QIMG = REPO / "tools/qemu/qemu-img.exe"
QEMU = QIMG.with_name("qemu-system-x86_64.exe")

def configure(workspace: Path, oracle: Path, qemu_dir: Path, source: Path):
    global ORACLE, QIMG, QEMU, SOURCE
    api.configure(workspace, qemu_dir)
    ORACLE = oracle.resolve()
    if ORACLE == Path(ORACLE.anchor): raise ValueError("Oracle root must be an application directory")
    oracle_path(ORACLE / "guard")
    SOURCE = source.resolve()
    QIMG = api.QEMU / "qemu-img.exe"
    QEMU = api.QEMU / "qemu-system-x86_64.exe"

def oracle_path(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    if not path.is_relative_to(ORACLE) or path == ORACLE:
        raise ValueError("Oracle output must stay in the owned oracle root")
    for node in (path, *path.parents):
        if node.exists() and (node.is_symlink() or getattr(node.lstat(), "st_file_attributes", 0) & 0x400):
            raise ValueError("Reparse point refused")
        if node == ORACLE: break
    return path

def write_json(path: Path, value):
    with oracle_path(path).open("x", encoding="utf-8", newline="\n") as f:
        json.dump(value, f, indent=2); f.write("\n")

@contextlib.contextmanager
def read_lock(path: Path):
    """Allow qemu-img reads while denying all write/delete opens until done."""
    api32 = ctypes.WinDLL("kernel32", use_last_error=True)
    api32.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    api32.CreateFileW.restype = ctypes.c_void_p
    api32.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = api32.CreateFileW(str(path), 0x80000000, 1, None, 3, 0, None)
    if handle == ctypes.c_void_p(-1).value:
        raise OSError(ctypes.get_last_error(), "Image still writable/in use: " + str(path))
    try: fd = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except BaseException:
        api32.CloseHandle(handle); raise
    with os.fdopen(fd, "rb") as file: yield file

def wait_owned(args: list[str]):
    """No outer timeout may kill a host oracle before its cleanup finally."""
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    while True:
        try:
            stdout, stderr = proc.communicate()
            return subprocess.CompletedProcess(args, proc.returncode, stdout, stderr)
        except KeyboardInterrupt:
            # Continue blocking for the owned oracle's cleanup/completion.
            # communicate() waits for process exit; this is not status polling.
            continue

def export(case: Path, memory: int = 64) -> tuple[Path, str, Path]:
    case = api.checked(case)
    prepared = json.loads((case / "prepared.json").read_text())
    if not 1 <= memory <= 512: raise ValueError("Invalid explicitly selected completed guest RAM")
    run = case / f"run-{memory}m"
    receipt = json.loads((run / "completed.json").read_text())
    if prepared.get("qemu_only") is not True or receipt.get("application_pass") is not True or receipt.get("returncode") != 33:
        raise ValueError("A completed passing explicitly selected guest is required")
    source, base = run / "target.qcow2", case / "target-base.raw"
    out = oracle_path(ORACLE / "inputs" / case.name)
    out.mkdir(parents=True, exist_ok=False)
    raw, manifest = out / "target.raw", out / "manifest.json"
    with read_lock(source), read_lock(base):
        before = {str(p): api.hash_file(p) for p in (source, base)}
        subprocess.run([str(QIMG), "convert", "-f", "qcow2", "-O", "raw", str(source), str(raw)], check=True, capture_output=True, timeout=120)
        after = {str(p): api.hash_file(p) for p in (source, base)}
    if before != after: raise ValueError("Source chain changed during export")
    shutil.copyfile(case / "manifest.json", manifest)
    sha = api.hash_file(raw)
    with raw.open('rb') as f:
        mbr=f.read(512)
        start=struct.unpack_from('<I',mbr,454)[0]
        ids={'mbr_signature':mbr[440:444].hex()}
        if prepared['kind']=='gpt':
            f.seek(512); header=f.read(512)
            ids['disk_guid']=str(uuid.UUID(bytes_le=header[56:72]))
            f.seek(1024); entry=f.read(128)
            ids['partition_guid']=str(uuid.UUID(bytes_le=entry[16:32]))
            start=struct.unpack_from('<Q',entry,32)[0]
            if any(uuid.UUID(ids[k]).version!=4 for k in ('disk_guid','partition_guid')):
                raise ValueError('GPT identity is not an RFC4122 v4 GUID')
        f.seek(start*512); boot=f.read(512)
        if boot[3:11]!=b'NTFS    ': raise ValueError('Missing target NTFS boot signature')
        ids['ntfs_serial']=f'{struct.unpack_from("<Q",boot,72)[0]:016x}'
    if int(ids['mbr_signature'],16)==0 or int(ids['ntfs_serial'],16)==0: raise ValueError('Zero disk identifier')
    write_json(out/'identifiers.json',ids)
    raw.chmod(stat.S_IREAD)
    write_json(out / "export.json", {"qemu_only": True, "source_receipt": str(run / "completed.json"), "chain_before": before, "chain_after": after, "raw_sha256": sha, "manifest_sha256": api.hash_file(manifest), "raw_readonly": True})
    return raw, sha, manifest

def verify(case: Path, windows_files: bool):
    case = api.checked(case)
    raw, sha, manifest = export(case)
    out = oracle_path(ORACLE / (case.name + "-linux01"))
    args = [sys.executable, "-I", "-B", str(REPO / "tools/tests/minios_ntfs_oracle.py"), "check", "--workspace", str(ORACLE), "--source-root", str(SOURCE), "--pack", str(ORACLE / "pack01"), "--out", str(out), "--qemu", str(QEMU), "--image", str(raw), "--sha256", sha, "--manifest", str(manifest)]
    process = wait_owned(args)
    write_json(raw.parent / "linux-invocation.json", {"command": args, "returncode": process.returncode, "stdout": process.stdout, "stderr": process.stderr})
    result = {"case": case.name, "image_sha256": sha, "linux": process.returncode == 0, "linux_result": str(out / "result.json")}
    if windows_files:
        out = oracle_path(ORACLE / (case.name + "-windows01"))
        shell = shutil.which("pwsh.exe")
        if shell is None: raise ValueError("The read-only Windows helper requires PowerShell 7")
        args = [shell, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(REPO / "tools/tests/minios_chkdsk_readonly.ps1"), "-Workspace", str(ORACLE), "-RawCopy", str(raw), "-ExpectedImageBytes", str(raw.stat().st_size), "-ExpectedSha256", sha, "-QemuImg", str(QIMG), "-Out", str(out), "-ExpectedManifest", str(manifest)]
        process = wait_owned(args)
        write_json(raw.parent / "windows-files-invocation.json", {"command": args, "returncode": process.returncode, "stdout": process.stdout, "stderr": process.stderr})
        result.update(windows_files=process.returncode == 0, windows_result=str(out / "result.json"), readonly_chkdsk_pass=process.returncode == 0)
    write_json(raw.parent / "verification.json", result)
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", type=Path)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--oracle-root", type=Path, required=True)
    parser.add_argument("--qemu-dir", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--linux-only", action="store_true", help="Diagnostic only; does not satisfy the Windows gate")
    args = parser.parse_args()
    configure(args.workspace, args.oracle_root, args.qemu_dir, args.source_root)
    result = verify(args.case, not args.linux_only)
    print(json.dumps(result))
    if not result["linux"] or result.get("windows_files") is False: raise SystemExit(1)

if __name__ == "__main__": main()
