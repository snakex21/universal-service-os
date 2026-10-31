#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent HOST-only wimlib 1.14.5 oracle. Never linked into usosprep.

Stage only sources/install.wim from an explicitly named local ISO. No apply,
mount, physical device, archive update or extracted Windows tree is supported.
dir --detailed loses subsecond times; the public wimlib.h iteration ABI supplies
exact 100ns timestamps and raw security descriptors, streamed as JSONL.
ABI/source: https://github.com/ebiggers/wimlib/blob/v1.14.5/include/wimlib.h
CLI: https://github.com/ebiggers/wimlib/blob/v1.14.5/programs/imagex.c
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
import shutil
import stat
import struct
import subprocess
import threading
import time

REPO = Path(__file__).resolve().parents[2]
RUNTIME = Path(os.environ.get("USOS_MINIOS_RUNTIME", str(REPO / "runtime/wim")))
VOLUME = os.environ.get("USOS_MINIOS_VOLUME_GUID", "")
VENDOR = REPO / "tools/vendor/wimlib/1.14.5"
PINS = {"wimlib-imagex.exe": "34c0c4165591ad1f592837ed99d08273c58d6ed3fe0ed6360cf34e7b0739b353",
        "libwim-15.dll": "ba853ee1e3fc5f5798581f02e8e066ba07a0a2375f0bf444fe981431fd508495"}
SEVENZIP = Path(os.environ.get("USOS_MINIOS_7ZIP", shutil.which("7z") or str(REPO / "tools/7zip/7z.exe")))
MEDIA_ROOTS = tuple(Path(value) for value in os.environ.get("USOS_MINIOS_MEDIA_ROOTS", str(REPO / "media")).split(os.pathsep) if value)
GiB = 1024**3
MAX_WIM = 16 * GiB
MAX_RECORDS = 1_000_000
TIMEOUT = 3600


def local(path: Path) -> Path:
    text = str(path)
    if not path.is_absolute() or text.startswith("\\\\") or any(c in text for c in ",\r\n\0") or ":" in text[3:]:
        raise ValueError("Explicit local regular path required; no devices, UNC, ADS or controls")
    if ".." in path.parts:
        raise ValueError("Parent traversal forbidden")
    for node in (path, *path.parents):
        if node.is_symlink() or (node.exists() and getattr(node.lstat(), "st_file_attributes", 0) & 0x400):
            raise ValueError("Reparse point forbidden: " + str(node))
    return path


def owned(path: Path) -> Path:
    local(path)
    if path == RUNTIME or not path.is_relative_to(RUNTIME):
        raise ValueError("Only a child of the explicit WIM runtime is permitted")
    return path


def storage_guard(bytes_needed: int = 0) -> None:
    if os.name != "nt" or not 0 <= bytes_needed <= 100 * GiB:
        raise ValueError("Windows host and bounded 100 GiB pool required")
    if not re.fullmatch(r"\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\", VOLUME):
        raise ValueError("Explicit runtime volume identity pin required")
    local(RUNTIME)
    volume = C.create_unicode_buffer(64)
    kernel = C.WinDLL("kernel32", use_last_error=True)
    kernel.GetVolumeNameForVolumeMountPointW.argtypes = [C.c_wchar_p, C.c_wchar_p, C.c_uint32]
    if not kernel.GetVolumeNameForVolumeMountPointW(str(RUNTIME.anchor), volume, len(volume)) or volume.value.lower() != VOLUME.lower():
        raise ValueError("Unexpected runtime volume identity")
    if shutil.disk_usage(RUNTIME.anchor).free < 100 * GiB + bytes_needed:
        raise ValueError("Operation would violate the 100 GiB free-space reserve")


def save(path: Path, value) -> None:
    with owned(path).open("x", encoding="utf-8", newline="\n") as out:
        json.dump(value, out, ensure_ascii=True, indent=2)
        out.write("\n")


def digest_stream(source) -> str:
    source.seek(0)
    result = hashlib.sha256()
    while block := source.read(1024 * 1024):
        result.update(block)
    return result.hexdigest()


def digest(path: Path) -> str:
    with local(path).open("rb") as source:
        return digest_stream(source)


@contextlib.contextmanager
def readonly(path: Path):
    """Deny writes/deletion for the lifetime of hashing + independent oracle."""
    local(path)
    if not path.is_file():
        raise ValueError("Existing regular file required")
    if os.name != "nt":
        raise ValueError("Read-lock proof requires Windows")
    import msvcrt
    kernel = C.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [C.c_wchar_p, C.c_uint32, C.c_uint32, C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p]
    kernel.CreateFileW.restype = C.c_void_p
    kernel.CloseHandle.argtypes = [C.c_void_p]
    handle = kernel.CreateFileW(str(path), 0x80000000, 1, None, 3, 0x08000000, None)
    if handle == C.c_void_p(-1).value:
        raise C.WinError(C.get_last_error())
    try:
        descriptor = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except BaseException:
        kernel.CloseHandle(handle)
        raise
    with os.fdopen(descriptor, "rb") as source:
        yield source


def environment(out: Path) -> dict:
    temp = owned(out / "tmp")
    temp.mkdir()
    value = os.environ.copy()
    value.update(TEMP=str(temp), TMP=str(temp), HOME=str(out), USERPROFILE=str(out),
                 APPDATA=str(out), LOCALAPPDATA=str(out), LC_ALL="C", TZ="UTC")
    return value


def tool_pins() -> dict:
    for name, expected in PINS.items():
        if digest(VENDOR / name) != expected:
            raise ValueError("wimlib 1.14.5 pin mismatch: " + name)
    result = subprocess.run([str(VENDOR / "wimlib-imagex.exe"), "--version"], check=True,
                            capture_output=True, timeout=30)
    text = result.stdout.decode("utf-8", "strict")
    if not text.startswith("wimlib-imagex 1.14.5 (using wimlib 1.14.5)"):
        raise ValueError("Wrong host oracle version")
    return {"version": "1.14.5", "files": PINS.copy()}


def read_header(source) -> dict:
    source.seek(0)
    head = source.read(208)
    if len(head) != 208 or head[:8] != b"MSWIM\0\0\0":
        raise ValueError("Not a complete WIM header")
    size, version, flags, chunk = struct.unpack_from("<IIII", head, 8)
    part, total, count = struct.unpack_from("<HHI", head, 40)
    if size != 208 or not 1 <= count <= 1024:
        raise ValueError("Unsupported header or image count")
    if part != 1 or total != 1 or flags & 8:
        raise ValueError("Split/spanned WIM refused")
    compression = flags & 0xe0000
    names = {0: "None", 0x20000: "XPRESS", 0x40000: "LZX", 0x80000: "LZMS"}
    if compression not in names:
        raise ValueError("Conflicting compression flags")
    return {"header_bytes": size, "version": version, "flags": flags, "chunk_size": chunk,
            "part_number": part, "total_parts": total, "image_count": count, "compression": names[compression]}


def validate_index(index: int, header: dict) -> int:
    if type(index) is not int or not 1 <= index <= header["image_count"]:
        raise ValueError("Explicit 1-based image index required")
    return index


def run_cli(args: list[str], out: Path, leaf: str, env: dict) -> dict:
    # All commands are assembled here; no user-provided wimlib operation/options.
    command = [str(VENDOR / "wimlib-imagex.exe"), *args]
    start = time.time()
    with owned(out / (leaf + ".txt")).open("xb") as log:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                cwd=out, env=env, timeout=TIMEOUT, check=False)
    record = {"argv": command, "exit": result.returncode, "duration_seconds": time.time() - start,
              "log": str(out / (leaf + ".txt")), "sha256": digest(out / (leaf + ".txt"))}
    save(out / (leaf + ".json"), record)
    if result.returncode:
        raise ValueError("Host oracle failed: " + leaf)
    return record


def stage_iso(iso: Path, out: Path, expected_bytes: int) -> dict:
    local(iso); owned(out)
    if not any(iso.is_relative_to(root) for root in MEDIA_ROOTS) or iso.suffix.lower() != ".iso":
        raise ValueError("ISO must be in the explicitly authorized Windows media collection")
    if not 208 <= expected_bytes <= MAX_WIM:
        raise ValueError("Explicit bounded install.wim size required")
    if out.exists():
        raise FileExistsError("Never overwrite an oracle case")
    storage_guard(expected_bytes + GiB)
    pins = tool_pins()
    local(SEVENZIP)
    out.mkdir(parents=True)
    env = environment(out)
    archive = out / "install.wim"
    partial = out / "install.wim.partial"
    command = [str(SEVENZIP), "e", "-so", "-bd", "-spd", str(iso), "sources/install.wim"]
    with readonly(iso) as source:
        original_stat = os.fstat(source.fileno())
        before = digest_stream(source)
        size = 0
        h = hashlib.sha256()
        with partial.open("xb") as target, (out / "extract-stderr.txt").open("xb") as errors:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=errors, cwd=out, env=env)
            timer = threading.Timer(TIMEOUT, child.kill)
            timer.start()
            try:
                while block := child.stdout.read(1024 * 1024):
                    size += len(block)
                    if size > expected_bytes:
                        raise ValueError("ISO member exceeds exact expected size")
                    target.write(block)
                    h.update(block)
                if child.wait() != 0 or size != expected_bytes:
                    raise ValueError("Incomplete install.wim extraction")
                target.flush(); os.fsync(target.fileno())
            except BaseException:
                child.kill(); child.wait()
                raise
            finally:
                timer.cancel()
                child.stdout.close()
        after_stat = os.fstat(source.fileno())
        if digest_stream(source) != before or any(getattr(after_stat, field) != getattr(original_stat, field) for field in ("st_size", "st_mtime_ns", "st_dev", "st_ino")):
            raise ValueError("Source ISO changed")
        with partial.open("rb") as stream:
            header = read_header(stream)
        partial.rename(archive)
        archive.chmod(stat.S_IREAD)
        run_cli(["info", str(archive)], out, "info", env)
        result = {"schema": "usos-wim-oracle-input-v1", "source_iso": str(iso), "source_bytes": original_stat.st_size,
                  "source_sha256": before, "source_unchanged": True, "source_write_delete_denied": True,
                  "member": "sources/install.wim", "wim": str(archive), "wim_bytes": size, "wim_sha256": h.hexdigest(),
                  "wim_header": header, "oracle": pins, "extract_argv": command,
                  "windows_payload_tree_extracted": False, "apply_or_mount_executed": False}
        save(out / "input.json", result)
    return result


# Public wimlib 1.14.5 Win64 ABI, kept only in this host oracle.
class Timespec(C.Structure):
    _fields_ = [("seconds", C.c_int64), ("nanoseconds", C.c_int32)]


class Resource(C.Structure):
    _fields_ = [("size", C.c_uint64), ("compressed_size", C.c_uint64), ("offset", C.c_uint64),
                ("sha1", C.c_ubyte * 20), ("part", C.c_uint32), ("references", C.c_uint32),
                ("flags", C.c_uint32), ("raw_offset", C.c_uint64), ("raw_compressed", C.c_uint64),
                ("raw_size", C.c_uint64), ("reserved", C.c_uint64)]


class Stream(C.Structure):
    _fields_ = [("name", C.c_void_p), ("resource", Resource), ("reserved", C.c_uint64 * 4)]


class Entry(C.Structure):
    _fields_ = [("filename", C.c_void_p), ("dos_name", C.c_void_p), ("path", C.c_void_p), ("depth", C.c_size_t),
                ("security", C.c_void_p), ("security_size", C.c_size_t), ("attributes", C.c_uint32),
                ("reparse_tag", C.c_uint32), ("links", C.c_uint32), ("named_streams", C.c_uint32),
                ("link_group", C.c_uint64), ("creation", Timespec), ("write", Timespec), ("access", Timespec),
                ("unix", C.c_uint32 * 4), ("object_ids", C.c_ubyte * 64), ("time_high", C.c_int32 * 4),
                ("reserved", C.c_uint64 * 4), ("streams", Stream * 0)]


def filetime(value: Timespec) -> int:
    if not 0 <= value.nanoseconds < 1_000_000_000 or value.nanoseconds % 100:
        raise ValueError("Invalid WIM timestamp resolution")
    result = (value.seconds + 11644473600) * 10_000_000 + value.nanoseconds // 100
    if not 0 <= result < 2**64:
        raise ValueError("Timestamp outside FILETIME range")
    return result


def wide(pointer) -> str | None:
    if not pointer:
        return None
    # Bounds apply to public library strings, not arbitrary guest pointers.
    value = C.wstring_at(pointer)
    if len(value) > 32768 or any(c in value for c in "\0\r\n"):
        raise ValueError("Invalid/bounded WIM string")
    return value


def relative(value: str) -> str:
    value = value.replace("\\", "/")
    if value == "/":
        return ""
    if not value.startswith("/") or value.startswith("//"):
        raise ValueError("Invalid image-root-relative WIM path")
    value = value[1:]
    if any(p in ("", ".", "..") or ":" in p for p in value.split("/")):
        raise ValueError("Unsafe WIM path")
    return value


def entry_record(entry: Entry) -> tuple[dict, bytes]:
    if entry.named_streams > 1024 or entry.security_size > 1024 * 1024 or not entry.links:
        raise ValueError("WIM metadata bound exceeded")
    security = C.string_at(entry.security, entry.security_size) if entry.security else b""
    if bool(entry.security) != bool(entry.security_size):
        raise ValueError("Inconsistent security descriptor")
    streams = (Stream * (entry.named_streams + 1)).from_address(C.addressof(entry) + Entry.streams.offset)
    result_streams = []
    for i, stream in enumerate(streams):
        resource = stream.resource
        name = wide(stream.name)
        if (i == 0 and name is not None) or (i > 0 and not name) or (name and any(c in name for c in ":/\\")):
            raise ValueError("Invalid WIM stream name")
        if resource.flags & (8 | 16 | 32):
            raise ValueError("Spanned, missing or solid resource refused")
        if resource.part not in (0, 1):
            raise ValueError("Split resource refused")
        result_streams.append({"name": name, "sha1": bytes(resource.sha1).hex(), "size": resource.size,
                               "compressed_size": resource.compressed_size, "offset": resource.offset,
                               "part": resource.part, "reference_count": resource.references,
                               "flags": resource.flags,
                               "kind": "named_data" if name else "reparse" if entry.attributes & 0x400 else "data"})
    path = relative(wide(entry.path) or "")
    short = wide(entry.dos_name)
    return {"path": path, "directory": bool(entry.attributes & 0x10), "attributes": entry.attributes,
            "short_name": short, "short_name_policy": "preserve_image_DOS_alias",
            "reparse_tag": entry.reparse_tag, "hardlink_group_id": entry.link_group, "link_count": entry.links,
            "creation_filetime": filetime(entry.creation), "modified_filetime": filetime(entry.write),
            "accessed_filetime": filetime(entry.access), "changed_filetime": None,
            "changed_time_wim_policy": "not_stored; target_uses_modified_time",
            "security_sha256": hashlib.sha256(security).hexdigest() if security else None,
            "security_bytes": len(security), "streams": result_streams}, security


def normalize_short_name(record: dict, primary: dict) -> bool:
    """Public wimlib win32_apply.c creates one DOS pair before other links.

    A secondary POSIX hardlink has no alternate name for that path.
    Keep the unmodified source spelling and explicitly mark secondary aliases;
    no source file/hash/security expectation is changed by this policy.
    """
    short = record.get('short_name')
    group = record.get('source_hardlink_group_id', record.get('hardlink_group_id'))
    if not short or not group or record['directory'] or record['reparse_tag']:
        return False
    record['source_short_name'] = short
    key = (group, record.get('source_data_sha1',record['streams'][0]['sha1']))
    if key not in primary:
        primary[key] = (record['path'], short)
    path, expected = primary[key]
    if path == record['path']:
        record['short_name_index_created'] = True
        return False
    record.update(short_name=None, short_name_index_created=False,
                  primary_short_name_path=path,
                  primary_short_name_value=expected,
                  short_name_policy='native_single_DOS_pair_per_inode; secondary hardlink POSIX')
    return True


def manifest(wim: Path, index: int, expected_sha256: str, out: Path, target_drive: str = 'C') -> dict:
    owned(wim); owned(out)
    if wim.suffix.lower() != ".wim" or not re.fullmatch("[0-9a-f]{64}", expected_sha256):
        raise ValueError("Pinned .wim and explicit SHA256 required")
    if out.exists():
        raise FileExistsError("Never overwrite oracle evidence")
    storage_guard(GiB)
    pins = tool_pins()
    with readonly(wim) as source:
        if digest_stream(source) != expected_sha256:
            raise ValueError("Source WIM pin mismatch")
        header = read_header(source)
        validate_index(index, header)
        extra_spec = importlib.util.spec_from_file_location('independent_wim_extras', Path(__file__).with_name('wim_extra_oracle.py'))
        extra_api = importlib.util.module_from_spec(extra_spec); extra_spec.loader.exec_module(extra_api)
        raw_archive = extra_api.Archive(source, VENDOR / 'libwim-15.dll')
        extras = {}
        for row in raw_archive.extras(index, target_drive):
            if row['path'] in extras: raise ValueError('Duplicate independently decoded WIM path')
            extras[row['path']] = row
        if C.sizeof(C.c_void_p) != 8 or C.sizeof(C.c_wchar) != 2 or C.sizeof(Resource) != 88 or C.sizeof(Stream) != 128 or Entry.streams.offset != 248:
            raise ValueError("Only pinned Win64 wimlib ABI supported")
        out.mkdir(parents=True)
        env = environment(out)
        verify = run_cli(["verify", str(wim)], out, "verify", env)
        details = run_cli(["dir", str(wim), str(index), "--detailed"], out, "dir-detailed", env)
        lib = C.CDLL(str(VENDOR / "libwim-15.dll"))
        lib.wimlib_get_version.restype = C.c_uint32
        if lib.wimlib_get_version() != (1 << 20 | 14 << 10 | 5):
            raise ValueError("DLL version disagrees with pinned header")
        callback_type = C.CFUNCTYPE(C.c_int, C.POINTER(Entry), C.c_void_p)
        lib.wimlib_open_wim.argtypes = [C.c_wchar_p, C.c_int, C.POINTER(C.c_void_p)]
        lib.wimlib_open_wim.restype = C.c_int
        lib.wimlib_iterate_dir_tree.argtypes = [C.c_void_p, C.c_int, C.c_wchar_p, C.c_int, callback_type, C.c_void_p]
        lib.wimlib_iterate_dir_tree.restype = C.c_int
        lib.wimlib_free.argtypes = [C.c_void_p]
        handle = C.c_void_p()
        if lib.wimlib_open_wim(str(wim), 0, C.byref(handle)):
            raise ValueError("wimlib readonly open failed")
        counts = dict(entries=0, files=0, directories=0, hardlink_names=0, reparses=0, named_streams=0,
                      zero_data_files=0, short_names=0, unique_security_descriptors=0)
        attributes = {}
        reparse_tags = {}
        tagged_types = {}
        features = dict(ntfs_compression_files=0, encrypted_files=0, sparse_files=0, wof_entries=0,
                        entries_with_subsecond_times=0)
        failures = []
        seen_security = set()
        # Public wimlib iteration sorts some directory names differently from
        # their stored order. Select the primary from independently decoded
        # source offsets (DFS key), never from output image observations.
        primary_short_names = {}
        for extra in sorted(extras.values(), key=lambda r: r['source_order']):
            if extra['source_hardlink_group_id'] and extra['short_name']:
                primary_short_names.setdefault((extra['source_hardlink_group_id'],extra['source_data_sha1']), (extra['path'],extra['short_name']))
        counts['secondary_short_names_normalized'] = 0
        counts['source_short_names'] = 0
        try:
            with (out / "tree.jsonl").open("x", encoding="utf-8", newline="\n") as tree, (out / "security.jsonl").open("x", encoding="utf-8", newline="\n") as descriptors:
                @callback_type
                def accept(pointer, _):
                    try:
                        if counts["entries"] >= MAX_RECORDS:
                            raise ValueError("Manifest entry bound exceeded")
                        record, security = entry_record(pointer.contents)
                        extra = extras.pop(record['path'])
                        if extra['short_name'] != record['short_name']:
                            raise ValueError('Raw DOS alias disagrees with public wimlib iteration')
                        record['source_hardlink_group_id'] = extra['source_hardlink_group_id']
                        record['source_data_sha1'] = extra['source_data_sha1']
                        counts['source_short_names'] += int(bool(record['short_name']))
                        counts['secondary_short_names_normalized'] += int(normalize_short_name(record, primary_short_names))
                        record['tagged_metadata'] = extra['tagged']
                        record['object_id_hex'] = None
                        record['ea_wim_hex'] = None
                        for tagged in extra['tagged']:
                            key = '0x%08x' % tagged['type']
                            tagged_types[key] = tagged_types.get(key, 0) + 1
                            if tagged['type'] == 1:
                                record['object_id_hex'] = tagged['hex'].ljust(128, '0')
                                if record['object_id_hex'] != bytes(pointer.contents.object_ids).hex():
                                    raise ValueError('Raw object ID disagrees with public wimlib iteration')
                            elif tagged['type'] == 2: record['ea_wim_hex'] = tagged['hex']
                        if record['attributes'] & 0x400:
                            record['reparse_flags'] = extra['reparse_flags']
                            record['reparse_fixed'] = extra['reparse_fixed']
                            record['logical_target_drive'] = target_drive
                            for stream in record['streams']:
                                if stream['kind'] == 'reparse':
                                    if stream['sha1'] != extra['reparse_source_sha1']:
                                        raise ValueError('Raw reparse hash disagrees with public wimlib iteration')
                                    stream['source_sha1'] = stream['sha1']
                                    stream['sha1'] = extra['reparse_applied_sha1']
                        tree.write(json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n")
                        counts["entries"] += 1
                        counts["directories" if record["directory"] else "files"] += 1
                        counts["hardlink_names"] += int(record["link_count"] > 1)
                        counts["reparses"] += int(bool(record["attributes"] & 0x400))
                        counts["named_streams"] += pointer.contents.named_streams
                        counts["zero_data_files"] += int(not record["directory"] and not record["streams"][0]["size"])
                        counts["short_names"] += int(bool(record["short_name"]))
                        attr = record["attributes"]
                        key = f"0x{attr:08x}"
                        attributes[key] = attributes.get(key, 0) + 1
                        if attr & 0x400:
                            tag = f"0x{record['reparse_tag']:08x}"
                            reparse_tags[tag] = reparse_tags.get(tag, 0) + 1
                        for flag, name in ((0x800, "ntfs_compression_files"), (0x4000, "encrypted_files"), (0x200, "sparse_files")):
                            features[name] += int(not record["directory"] and bool(attr & flag))
                        features["wof_entries"] += int(record["reparse_tag"] == 0x80000017)
                        features["entries_with_subsecond_times"] += int(any(record[field] % 10_000_000 for field in ("creation_filetime", "modified_filetime", "accessed_filetime")))
                        sdhash = record["security_sha256"]
                        if sdhash and sdhash not in seen_security:
                            seen_security.add(sdhash)
                            descriptors.write(json.dumps({"sha256": sdhash, "bytes": len(security), "hex": security.hex()}, separators=(",", ":")) + "\n")
                        return 0
                    except BaseException as error:
                        failures.append(str(error))
                        return 1
                status = lib.wimlib_iterate_dir_tree(handle, index, "\\", 1 | 4, accept, None)
                if status or failures or not counts["entries"] or extras:
                    raise ValueError("Independent manifest failed: " + repr((status, failures)))
        finally:
            lib.wimlib_free(handle)
        counts["unique_security_descriptors"] = len(seen_security)
        if digest_stream(source) != expected_sha256:
            raise ValueError("WIM changed during verification")
        result = {"schema": "usos-wim-oracle-manifest-v1", "wim": str(wim), "wim_sha256": expected_sha256,
                  "source_unchanged": True, "source_write_delete_denied": True, "index": index, "header": header,
                  "oracle": pins, "counts": counts, "attribute_histogram": attributes, "reparse_tag_histogram": reparse_tags,
                  "features": features, "verify": verify, "detailed_cli": details,
                  "tagged_metadata_histogram": tagged_types, "target_drive": target_drive,
                  "duplicate_lookup_hashes": raw_archive.duplicates,
                  "tree_sha256": digest(out / "tree.jsonl"), "security_sha256": digest(out / "security.jsonl"),
                  "timestamps": "3 raw FILETIME from wimlib; CLI is seconds only; WIM has no changedTime",
                  "resource_sha1_scope": "wimlib verify reads all images/resources; tree manifest selects explicit index",
                  "windows_payload_tree_extracted": False, "apply_or_mount_executed": False}
        save(out / "manifest.json", result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    stage = sub.add_parser("stage-iso")
    stage.add_argument("--iso", type=Path, required=True)
    stage.add_argument("--expected-wim-bytes", type=int, required=True)
    stage.add_argument("--out", type=Path, required=True)
    inventory = sub.add_parser("manifest")
    inventory.add_argument("--wim", type=Path, required=True)
    inventory.add_argument("--index", type=int, required=True)
    inventory.add_argument("--sha256", required=True)
    inventory.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.operation == "stage-iso":
        value = stage_iso(args.iso, args.out, args.expected_wim_bytes)
    else:
        value = manifest(args.wim, args.index, args.sha256, args.out)
    print(json.dumps(value, ensure_ascii=True))


if __name__ == "__main__":
    main()
