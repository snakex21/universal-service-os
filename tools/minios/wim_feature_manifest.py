#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Expected NTFS feature metadata from the fixed public fixture CONTRACT.

Does not open any NTFS image, parse formatter output, or apply a WIM. The
pattern, names and metadata come from src/prep/wim_ntfs_tests.zig's stable
populate()/Pattern/securityDescriptor/reparseBuffer specification. Independent
Python SID/ACL/reparse serialization and hashlib produce the expected values.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("feature_oracle_guard", HERE / "wim_oracle.py")
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)
REPO = HERE.parents[1]
FIXTURE = REPO / "src/prep/wim_ntfs_tests.zig"
FIXTURE_SHA256 = "400b080f32bb2c02680fe30ba9ed395a98bbb9346fecb101e389bc4222f46ed8"
DEFAULT_TIME = 132537600000000000
FOUR_TIMES = dict(created=132537600000000001, modified=132537600100000002,
                  changed=132537600200000003, accessed=132537600300000004)
EMPTY_SHA1 = hashlib.sha1(b"").hexdigest()


def sid(authority: int, *subauthorities: int) -> bytes:
    return bytes((1, len(subauthorities))) + authority.to_bytes(6, "big") + struct.pack("<" + "I" * len(subauthorities), *subauthorities)


def custom_security(rid: int) -> bytes:
    owner, group = sid(5, rid), sid(5, 32, 544)
    return struct.pack("<BBHIIII", 1, 0, 0x8000, 20, 20 + len(owner), 0, 0) + owner + group


def default_security() -> bytes:
    administrators = sid(5, 32, 544)
    aces = []
    for principal, mask in ((sid(5, 18), 0x1f01ff), (administrators, 0x1f01ff), (sid(1, 0), 0x1200a9)):
        aces.append(struct.pack("<BBHI", 0, 3, 8 + len(principal), mask) + principal)
    acl = struct.pack("<BBHHH", 2, 0, 8 + sum(map(len, aces)), 3, 0) + b"".join(aces)
    header = struct.pack("<BBHIIII", 1, 0, 0x8004, 20 + len(acl), 20 + len(acl) + len(administrators), 0, 20)
    return header + acl + administrators + administrators


def pattern_sha1(size: int, seed: int, sparse: bool = False, block_size: int = 65536) -> str:
    if size < 0 or not 0 <= seed <= 255 or not 1 <= block_size <= 1024 * 1024:
        raise ValueError("Bounded deterministic own pattern required")
    result = hashlib.sha1()
    for start in range(0, size, block_size):
        chunk = bytes((seed ^ ((at * 37 + (at >> 12) * 11) & 255))
                      if not sparse or at < 4096 or at >= max(0, size - 4096) else 0
                      for at in range(start, min(size, start + block_size)))
        result.update(chunk)
    return result.hexdigest()


def reparse(tag: int, substitute: str, display: str, relative: bool) -> bytes:
    a, b = substitute.encode("utf-16le"), display.encode("utf-16le")
    payload = struct.pack("<HHHH", 0, len(a), len(a) + 2, len(b))
    if tag == 0xa000000c:
        payload += struct.pack("<I", int(relative))
    elif tag != 0xa0000003 or relative:
        raise ValueError("Only the two specified fixture reparse forms are supported")
    payload += a + b"\0\0" + b + b"\0\0"
    return struct.pack("<IHH", tag, len(payload), 0) + payload


def data(size: int, seed: int, sparse: bool = False, name=None) -> dict:
    return dict(name=name, size=size, sha1=pattern_sha1(size, seed, sparse), kind="named_data" if name else "data")


def entries():
    default = default_security()
    no_data = [dict(name=None, size=0, sha1="0" * 40, kind="data")]

    def row(path, attrs, streams=None, *, sd=default, security_id=256, times=None, links=1, group=0, tag=0, raw_reparse=None):
        time = times or dict.fromkeys(("created", "modified", "changed", "accessed"), DEFAULT_TIME)
        directory = bool(attrs & 0x10)
        result = dict(path=path, directory=directory, attributes=attrs, short_name=None,
                      short_name_policy="not_created_POSIX_namespace_0", reparse_tag=tag,
                      hardlink_group_id=group, link_count=links, creation_filetime=time["created"],
                      modified_filetime=time["modified"], changed_filetime=time["changed"], accessed_filetime=time["accessed"],
                      security_sha256=hashlib.sha256(sd).hexdigest(), security_bytes=len(sd), source_security_id=security_id,
                      streams=streams if streams is not None else no_data,
                      si_attributes=attrs & ~0x10, filename_attributes=(attrs & ~0x10) | (0x10000000 if directory else 0),
                      source="independent_own_feature_contract")
        if raw_reparse is not None:
            result["raw_reparse_hex"] = raw_reparse.hex()
        if path in ('Security', 'Streams/dense-sparse.bin'):
            result['short_name'] = 'SECURI~1' if path == 'Security' else 'DENSES~1.BIN'
            result['short_name_policy'] = 'preserve_explicit_DOS_alias'
        if path in ('Links/third.bin', 'Streams/survivor.bin'):
            result['short_name'] = 'THIRD~1.BIN' if path.startswith('Links/') else None
            result['short_name_index_created'] = path.startswith('Links/')
            result['source_short_name'] = 'THIRD~1.BIN' if path.startswith('Links/') else 'SURVIV~1.BIN'
            result['short_name_policy'] = 'single_DOS_pair_per_inode; secondary hardlink stays POSIX'
        if path == 'Streams/compressed.bin': result['object_id_hex'] = bytes(range(1, 65)).hex()
        if path in ('Streams/dense-sparse.bin', 'Streams/zero.bin'):
            large = path.endswith('/zero.bin')
            name = b'USOS.LARGE' if large else b'USOS.DATA'
            value = bytes((i * 13) & 255 for i in range(768)) if large else bytes((7, 0, 9))
            result['ea_wim_hex'] = (struct.pack('<HBB', len(value), len(name), 0) + name + b'\0' + value).hex()
        return result

    # Formatter root policy is SYSTEM|HIDDEN, directory synthesized by Windows.
    yield row("", 0x16)
    for name in ("Security", "Links", "Streams", "Reparse", "Links/Target"):
        yield row(name, 0x30)
    for i in range(5000):
        yield row(f"Security/s{i:04d}", 0x20, [data(0, 0)], sd=custom_security(1000 + i), security_id=257 + i)
    linked_streams = [data(8193, 0x71), data(37, 0x32, name="Zone.Identifier"), data(196609, 0xa5, name="large-世界")]
    for path in ("Links/third.bin", "Streams/survivor.bin"):
        yield row(path, 0x27, linked_streams, times=FOUR_TIMES, sd=custom_security(1000), security_id=257, links=2, group=1)
    yield row("Streams/sparse.bin", 0x220, [data(1048613, 0x53, True)])
    yield row("Streams/compressed.bin", 0x820, [data(32769, 0xb8)])
    yield row("Streams/dense-sparse.bin", 0x220, [data(32769, 0xb8)])
    yield row("Streams/zero.bin", 0x220, [data(0, 0)], times=FOUR_TIMES)
    junction = reparse(0xa0000003, r"\??\C:\Links\Target", r"C:\Links\Target", False)
    link = reparse(0xa000000c, r"..\Links\third.bin", r"..\Links\third.bin", True)
    for path, attrs, raw, times in (("Reparse/junction", 0x410, junction, FOUR_TIMES), ("Reparse/symlink", 0x420, link, None)):
        yield row(path, attrs, [dict(name=None, size=len(raw) - 8, sha1=hashlib.sha1(raw[8:]).hexdigest(), kind="reparse")],
                  tag=struct.unpack_from("<I", raw)[0], raw_reparse=raw, times=times)


def generate(out: Path) -> dict:
    oracle.owned(out)
    if out.exists():
        raise FileExistsError("Keep existing independent expectations unchanged")
    actual = oracle.digest(FIXTURE)
    if actual != FIXTURE_SHA256:
        raise ValueError("Feature contract changed; review before regenerating expectations")
    oracle.storage_guard(16 * 1024**2)
    out.mkdir(parents=True)
    seen, security = set(), {}
    counts = dict(entries=0, files=0, directories=0, hardlink_names=0, named_streams=0, reparses=0)
    with (out / "tree.jsonl").open("x", encoding="utf-8", newline="\n") as tree:
        for record in entries():
            if record["path"] in seen:
                raise ValueError("Internal expected path collision")
            seen.add(record["path"])
            tree.write(json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n")
            counts["entries"] += 1
            counts["directories" if record["directory"] else "files"] += 1
            counts["hardlink_names"] += int(record["link_count"] > 1)
            counts["named_streams"] += sum(s["name"] is not None for s in record["streams"])
            counts["reparses"] += int(bool(record["reparse_tag"]))
    descriptors = [default_security(), *(custom_security(1000 + i) for i in range(5000))]
    with (out / "security.jsonl").open("x", encoding="utf-8", newline="\n") as target:
        for index, descriptor in enumerate(descriptors):
            sha = hashlib.sha256(descriptor).hexdigest()
            if sha in security:
                raise ValueError("Expected security descriptor collision")
            security[sha] = len(descriptor)
            target.write(json.dumps(dict(source_security_id=256 + index, sha256=sha, bytes=len(descriptor), hex=descriptor.hex()), separators=(",", ":")) + "\n")
    result = dict(schema="usos-independent-ntfs-feature-manifest-v1", fixture_source=str(FIXTURE), fixture_sha256=actual,
                  generator_sha256=oracle.digest(Path(__file__)), counts=counts, unique_security_descriptors=len(security),
                  tree_sha256=oracle.digest(out / "tree.jsonl"), security_sha256=oracle.digest(out / "security.jsonl"),
                  ntfs_image_read=False, wim_applied=False, source="fixed public own fixture contract; independently serialized in Python",
                  changed_time_policy="four explicit feature timestamps, not the three-time WIM transform",
                  attributes_policy="raw SI/FN attrs retained separately from Windows DIRECTORY synthesis",
                  reparse_policy="unchanged bytes/tag; never rewrite C: or follow target", short_8_3_creation_claim=True)
    oracle.save(out / "manifest.json", result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(generate(args.out)))
