#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read exact SD bytes and file references from closed raw NTFS $Secure:$SDS.

Independent existing host NTFS parser; no writer imports, mount or disk IOCTL.
Compare raw on-disk bytes to fixed expectations. Separately reconstruct the
owner/group/SACL/DACL layout of the already recorded Windows API SHA256, without
changing expected SD bytes or accepting an overall NTFS test from this check.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct

HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


oracle = load("security_oracle", "wim_oracle.py")
ntfs = load("security_ntfs_bytes", "inspect_ntfs.py")


def components(raw: bytes) -> dict:
    if not 20 <= len(raw) <= 1048576 or raw[0] != 1 or not int.from_bytes(raw[2:4], "little") & 0x8000:
        raise ValueError("Bounded self-relative SD required")
    result = {"revision": raw[0], "sbz": raw[1], "control": int.from_bytes(raw[2:4], "little")}
    regions = []
    for name, position in (("owner", 4), ("group", 8), ("sacl", 12), ("dacl", 16)):
        offset = int.from_bytes(raw[position:position + 4], "little")
        if offset == 0:
            result[name] = None
            continue
        if offset < 20 or offset % 4 or offset + 8 > len(raw):
            raise ValueError("SD section outside descriptor")
        if name in ("owner", "group"):
            if raw[offset] != 1 or raw[offset + 1] > 15:
                raise ValueError("Invalid SID")
            size = 8 + 4 * raw[offset + 1]
        else:
            if raw[offset] not in (2, 4) or not result["control"] & (0x10 if name == "sacl" else 4):
                raise ValueError("Invalid ACL revision/presence")
            size = int.from_bytes(raw[offset + 2:offset + 4], "little")
            if size < 8:
                raise ValueError("Invalid ACL size")
            cursor = offset + 8
            for _ in range(int.from_bytes(raw[offset + 4:offset + 6], "little")):
                if cursor + 4 > offset + size:
                    raise ValueError("ACE header outside ACL")
                count = int.from_bytes(raw[cursor + 2:cursor + 4], "little")
                if count < 4 or count % 4 or cursor + count > offset + size:
                    raise ValueError("ACE outside ACL")
                cursor += count
        if offset + size > len(raw):
            raise ValueError("SD section truncated")
        result[name] = dict(offset=offset, bytes=size, hex=raw[offset:offset + size].hex())
        for old_name, old_start, old_end in regions:
            if offset < old_end and old_start < offset + size:
                if not ({name, old_name} == {"owner", "group"} and offset == old_start and offset + size == old_end):
                    raise ValueError("Overlapping SD sections")
        regions.append((name, offset, offset + size))
    covered = bytearray(len(raw))
    covered[:20] = b"\1" * 20
    for _, start, end in regions:
        covered[start:end] = b"\1" * (end - start)
    if any(value and not covered[at] for at, value in enumerate(raw)):
        raise ValueError("Nonzero bytes outside validated SD sections")
    return result


def api_layout(raw: bytes) -> bytes:
    parts = components(raw)
    body, offsets = bytearray(), {}
    for name in ("owner", "group", "sacl", "dacl"):
        value = parts[name]
        if value is None:
            offsets[name] = 0
        else:
            body += bytes((-len(body)) % 4)
            offsets[name] = 20 + len(body)
            body += bytes.fromhex(value["hex"])
    return struct.pack("<BBHIIII", parts["revision"], parts["sbz"], parts["control"],
                       offsets["owner"], offsets["group"], offsets["sacl"], offsets["dacl"]) + body


def same_sections(a: bytes, b: bytes) -> bool:
    x, y = components(a), components(b)
    return all(x[key] == y[key] for key in ("revision", "sbz", "control")) and all(
        (None if x[key] is None else x[key]["hex"]) == (None if y[key] is None else y[key]["hex"])
        for key in ("owner", "group", "sacl", "dacl"))


def all_attributes(image, number: int) -> list:
    base = image.record(number)
    attrs = list(ntfs.attributes(base))
    selected = list(attrs)
    lists = [a for a in attrs if a["kind"] == 0x20]
    for listing in lists:
        for item in image.list_entries(image.attr_value(listing["data"])):
            target = item["reference"] & ((1 << 48) - 1)
            if target == number:
                continue
            extension = image.record(target)
            if ntfs.number(extension, 32, 8) & ((1 << 48) - 1) != number or ntfs.number(extension, 16, 2) != item["reference"] >> 48:
                raise ValueError("Invalid metadata continuation identity")
            match = [a for a in ntfs.attributes(extension) if a["kind"] == item["kind"] and a["name"] == item["name"] and a["lowest"] == item["lowest"] and a["id"] == item["id"]]
            if len(match) != 1:
                raise ValueError("Ambiguous metadata continuation")
            selected.extend(match)
    return selected


def stream_bytes(image, number: int, kind: int, name: str) -> bytes:
    selected = [a for a in all_attributes(image, number) if a["kind"] == kind and a["name"] == name]
    selected.sort(key=lambda a: a["lowest"])
    if not selected:
        raise ValueError("Metadata stream missing")
    if not selected[0]["data"][8]:
        if len(selected) != 1:
            raise ValueError("Resident metadata has continuations")
        return ntfs.resident(selected[0]["data"])
    data = selected[0]["data"]
    size = ntfs.number(data, 48, 8)
    if size > 32 * 1024**2 or any(ntfs.number(a["data"], 12, 2) for a in selected):
        raise ValueError("Uncompressed bounded metadata stream required")
    mapped = [run for a in selected for run in ntfs.runs(a["data"])]
    image.validate_runs(mapped, ntfs.number(data, 40, 8))
    return image.stream(mapped, 0, size)


def security_hash(raw: bytes) -> int:
    value = 0
    for offset in range(0, len(raw) - 3, 4):
        value = (((value << 3) | (value >> 29)) + int.from_bytes(raw[offset:offset + 4], "little")) & 0xffffffff
    return value


def sds_descriptors(sds: bytes) -> dict:
    result = {}
    cursor = 0
    while cursor + 20 <= len(sds):
        block = cursor // 0x80000 * 0x80000
        if cursor - block >= 0x40000:
            cursor = block + 0x80000
            continue
        if sds[cursor:cursor + 20] == bytes(20):
            cursor = block + 0x80000
            continue
        stored_hash, identifier, own_offset, size = struct.unpack_from("<IIQI", sds, cursor)
        if identifier < 256 or identifier in result or own_offset != cursor or not 20 <= size <= 65556 or cursor - block + size > 0x40000:
            raise ValueError("Invalid/duplicate SDS header")
        raw = sds[cursor + 20:cursor + size]
        if len(raw) != size - 20 or sds[cursor:cursor + size] != sds[cursor + 0x40000:cursor + 0x40000 + size]:
            raise ValueError("SDS primary/duplicate mismatch")
        components(raw)
        if security_hash(raw) != stored_hash:
            raise ValueError("SDS NTFS security hash differs")
        result[identifier] = raw
        cursor += (size + 15) & ~15
    return result


def object_id_index(image) -> dict:
    """Independent $ObjId:$O GUID/birth data, including all allocation pages."""
    root = stream_bytes(image, 25, 0x90, '$O')
    if len(root) < 32 or ntfs.number(root, 4, 4) != 0x13:
        raise ValueError('Invalid ObjId index root/collation')
    result = {}
    def entries(data, header):
        at = header + ntfs.number(data, header, 4)
        end = header + ntfs.number(data, header + 4, 4)
        if at < header + 16 or end > len(data):
            raise ValueError('Invalid ObjId index bounds')
        while at < end:
            size, keys, flags = struct.unpack_from('<HHH', data, at + 8)
            if size < 16 or size % 8 or at + size > end:
                raise ValueError('Invalid ObjId entry')
            if flags & 2: break
            offset, count = struct.unpack_from('<HH', data, at)
            if keys != 16 or offset != 32 or count != 56 or size < 88:
                raise ValueError('Invalid ObjId key/data shape')
            key = bytes(data[at + 16:at + 32])
            reference = ntfs.number(data, at + offset, 8)
            if reference in result:
                raise ValueError('Duplicate ObjId file reference')
            result[reference] = key + bytes(data[at + 40:at + 88])
            at += size
    entries(root, 16)
    if any(a['kind'] == 0xa0 and a['name'] == '$O' for a in all_attributes(image, 25)):
        allocation = stream_bytes(image, 25, 0xa0, '$O')
        bitmap = stream_bytes(image, 25, 0xb0, '$O')
        for page in range(len(allocation) // 4096):
            if page // 8 < len(bitmap) and bitmap[page // 8] & 1 << (page % 8):
                entries(ntfs.unprotect(allocation[page * 4096:(page + 1) * 4096], b'INDX'), 24)
    return result


def metadata_parent(nodes, parent, sequence, read_reserved):
    """Prove a directory ancestor is rooted at a reserved NTFS record.

    Invalid, stale and cyclic chains raise, including those under metadata.
    Record 5 is the visible root and never counts as a metadata root.
    """
    visited=set()
    while True:
        if parent in visited or len(visited)>512:raise ValueError('Cyclic/deep parent chain')
        visited.add(parent)
        if parent < 27 and parent != 5:
            node=read_reserved(parent)
            if not node['directory'] or node['sequence']!=sequence:raise ValueError('Stale reserved parent reference')
            return True
        if parent not in nodes or nodes[parent]['sequence']!=sequence:raise ValueError('Stale visible parent reference')
        node=nodes[parent]
        if not node['directory']:raise ValueError('Non-directory parent')
        if parent==5:return False
        if len(node['names'])!=1:raise ValueError('Expected single directory FILE_NAME')
        parent,sequence,_=node['names'][0]

def visible_security_references(image) -> dict:
    bitmap = stream_bytes(image, 0, 0xb0, "")
    objects = object_id_index(image)
    nodes = {}
    for number in range(image.mft_bytes // 1024):
        if number // 8 >= len(bitmap):
            raise ValueError("MFT bitmap does not cover initialized records")
        if not bitmap[number // 8] & 1 << (number % 8) or number < 27 and number != 5:
            continue
        record = image.record(number)
        if ntfs.number(record, 32, 8):
            continue
        attrs = all_attributes(image, number)
        standard = [a for a in attrs if a["kind"] == 0x10]
        if len(standard) != 1:
            raise ValueError("One SI per visible base record required")
        si_value = image.attr_value(standard[0]["data"])
        security_id = ntfs.number(si_value, 52, 4)
        inline = [a for a in attrs if a["kind"] == 0x50]
        if security_id == 0 and len(inline) != 1:
            raise ValueError("Missing inline security descriptor")
        names, dos_names, filename_attributes = [], [], []
        for attr in attrs:
            if attr["kind"] != 0x30:
                continue
            value = image.attr_value(attr["data"])
            if len(value) < 66 or 66 + 2 * value[64] != len(value):
                raise ValueError("Invalid FILE_NAME length")
            parent = ntfs.number(value, 0, 8)
            name = value[66:].decode("utf-16le")
            if number != 5 and (value[65] not in (0, 1, 2, 3) or not name or name in (".", "..") or any(c in name for c in "/\\:\0")):
                raise ValueError("Unexpected namespace or unsafe visible FILE_NAME")
            (dos_names if value[65] == 2 else names).append((parent & ((1 << 48) - 1), parent >> 48, name))
            filename_attributes.append(ntfs.number(value, 56, 4))
        object_ids = [image.attr_value(a['data']) for a in attrs if a['kind'] == 0x40]
        if len(object_ids) > 1 or any(len(x) != 16 for x in object_ids):
            raise ValueError('Invalid raw object ID count/length')
        reference = number | ntfs.number(record, 16, 2) << 48
        object_value = objects.pop(reference, None)
        if bool(object_value) != bool(object_ids) or object_ids and object_value[:16] != object_ids[0]:
            raise ValueError('Object ID file attribute/index mismatch')
        nodes[number] = dict(sequence=ntfs.number(record, 16, 2), directory=bool(ntfs.number(record, 22, 2) & 2),
                             names=names, dos_names=dos_names, object_id_hex=object_value.hex() if object_value else None,
                             security_id=security_id, si_attributes=ntfs.number(si_value, 32, 4),
                             filename_attributes=filename_attributes, inline=image.attr_value(inline[0]["data"]) if security_id == 0 else None)
    if objects: raise ValueError('Object ID index contains invisible/stale references')
    paths, active = {5: ""}, set()

    def read_reserved(number):
        if number//8>=len(bitmap) or not bitmap[number//8] & (1 << (number%8)):
            raise ValueError('Reserved parent not allocated')
        record=image.record(number)
        flags=ntfs.number(record,22,2)
        if not flags&1:raise ValueError('Reserved parent not in use')
        return dict(sequence=ntfs.number(record,16,2),directory=bool(flags&2))

    def directory_path(number):
        if number in paths:
            return paths[number]
        if number in active or len(active) > 512 or number not in nodes:
            raise ValueError("Cyclic/deep/missing parent directory")
        node = nodes[number]
        if not node["directory"] or len(node["names"]) != 1:
            raise ValueError("Expected single directory FILE_NAME")
        active.add(number)
        parent, sequence, name = node["names"][0]
        if parent not in nodes or sequence != nodes[parent]["sequence"]:
            raise ValueError("Stale parent reference")
        prefix = directory_path(parent)
        paths[number] = (prefix + "/" if prefix else "") + name
        active.remove(number)
        return paths[number]

    result = {}
    for number, node in nodes.items():
        entries = [""] if number == 5 else []
        if number != 5:
            for parent, sequence, name in node["names"]:
                try:
                    if metadata_parent(nodes,parent,sequence,read_reserved):continue
                except ValueError as exc:
                    raise ValueError(f"{exc}: record={number} parent={parent} sequence={sequence} name={name!r}") from exc
                prefix = directory_path(parent)
                entries.append((prefix + "/" if prefix else "") + name)
        for path in entries:
            if path in result:
                raise ValueError("Duplicate reconstructed visible path")
            result[path] = dict(record=number, security_id=node["security_id"], inline=node["inline"],
                                object_id_hex=node['object_id_hex'], dos_names=node['dos_names'],
                                directory=node["directory"], si_attributes=node["si_attributes"], filename_attributes=node["filename_attributes"])
    return result


def zero_attribute_proven(row: dict, actual: dict) -> bool:
    """Only a regular file with exact SI/FN zero can explain API NORMAL=0x80.

    No directory/root masking, clearing bits, or inference from API is allowed.
    All FILE_NAME attributes of a multiply linked inode must also be zero.
    """
    return (row.get("attributes") == 0 and row.get("directory") is False and
            actual.get("directory") is False and actual.get("si_attributes") == 0 and
            bool(actual.get("filename_attributes")) and
            all(value == 0 for value in actual["filename_attributes"]))


def root_reserved_metadata(row: dict, actual: dict) -> dict:
    """Root MFT5 is NTFS metadata: preserve HIDDEN|SYSTEM, keep source values.

    DIAG07 isolated one SI byte and changed native chkdsk3 to0. This is a
    declared root-only transformation, never a general attribute mask.
    """
    source = row["attributes"]
    expected_si = (source & ~0x10) | 6
    expected_fn = expected_si | 0x10000000
    passed = (row.get("path") == "" and row.get("directory") is True and
              actual.get("record") == 5 and actual.get("directory") is True and
              actual.get("si_attributes") == expected_si and
              actual.get("filename_attributes") == [expected_fn])
    return dict(passed=passed, path=row.get("path"), record=actual.get("record"),
                directory=actual.get("directory"), source_attributes=source,
                observed_native_expected=source | 6, root_reserved_metadata_flags=6,
                raw_si_attributes=actual.get("si_attributes"),
                raw_filename_attributes=actual.get("filename_attributes"),
                expected_raw_si_attributes=expected_si, expected_raw_filename_attributes=[expected_fn])


def verify_tree(raw: Path, expected_sha256: str, expected_security: Path, tree: Path, out: Path,
                *, vhd_partition: tuple[int, int] | None = None) -> dict:
    for path in (raw, expected_security, tree, out):
        oracle.owned(path)
    suffix = '.vhd' if vhd_partition is not None else '.raw'
    if raw.suffix != suffix or not raw.is_file() or not raw.stat().st_file_attributes & 1 or out.exists() or not re.fullmatch("[0-9a-f]{64}", expected_sha256):
        raise ValueError("New output and pinned closed readonly raw COPY required")
    if not expected_security.is_file() or not tree.is_file() or expected_security.stat().st_size > 64 * 1024**2 or tree.stat().st_size > 512 * 1024**2:
        raise ValueError("Bounded regular security/tree JSONL required")
    oracle.storage_guard(16 * 1024**2)
    security_pin, tree_pin = oracle.digest(expected_security), oracle.digest(tree)
    expected = {}
    with expected_security.open(encoding="utf-8") as source:
        for line in source:
            if len(line) > 2 * 1024**2 or len(expected) >= 200000:
                raise ValueError("Expected security metadata bound")
            row = json.loads(line)
            data = bytes.fromhex(row["hex"])
            if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"] or row["sha256"] in expected:
                raise ValueError("Invalid/duplicate expected raw SD")
            components(data)
            expected[row["sha256"]] = data
    with oracle.readonly(raw) as locked:
        if oracle.digest_stream(locked) != expected_sha256:
            raise ValueError("Closed raw pin differs")
        if vhd_partition is None:
            image = ntfs.Image(raw)
        else:
            from install_native import DynamicVhd
            virtual = DynamicVhd(raw)
            try:
                image = ntfs.Image(raw, file=virtual, partition_start=vhd_partition[0], partition_bytes=vhd_partition[1])
            except BaseException:
                virtual.close()
                raise
        try:
            descriptors = sds_descriptors(stream_bytes(image, 9, 0x80, "$SDS"))
            references = visible_security_references(image)
        finally:
            image.file.close()
        missing, different, seen_expected = [], [], set()
        zero_paths, zero_failures, root_metadata = [], [], None
        descriptor_output = out.with_suffix(".descriptors.jsonl")
        refs_output = out.with_suffix(".references.jsonl")
        with descriptor_output.open("x", encoding="utf-8", newline="\n") as target:
            for identifier, data in sorted(descriptors.items()):
                target.write(json.dumps(dict(security_id=identifier, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), hex=data.hex()), separators=(",", ":")) + "\n")
        with refs_output.open("x", encoding="utf-8", newline="\n") as target, tree.open(encoding="utf-8") as source:
            for line in source:
                if len(line) > 2 * 1024**2 or len(seen_expected) >= 1000000:
                    raise ValueError("Expected file reference bound")
                row = json.loads(line)
                path, required = row["path"], row["security_sha256"]
                if path in seen_expected or required not in expected:
                    raise ValueError("Ambiguous expected file/security reference")
                seen_expected.add(path)
                actual = references.pop(path, None)
                if actual is None:
                    missing.append(path)
                    continue
                zero_candidate = row.get("attributes") == 0 and row.get("directory") is False
                zero_proven = zero_attribute_proven(row, actual) if zero_candidate else False
                if zero_candidate:
                    (zero_paths if zero_proven else zero_failures).append(path)
                if path == "":
                    root_metadata = root_reserved_metadata(row, actual)
                data = actual["inline"] if actual["security_id"] == 0 else descriptors.get(actual["security_id"])
                passed = data == expected[required] and (row.get("source_security_id") is None or row["source_security_id"] == actual["security_id"])
                if 'object_id_hex' in row and row['object_id_hex'] != actual['object_id_hex']: passed = False
                if not passed:
                    different.append(path)
                target.write(json.dumps(dict(path=path, record=actual["record"], security_id=actual["security_id"], raw_sd_sha256=hashlib.sha256(data).hexdigest() if data else None,
                                             expected_sha256=required, raw_bytes_exact=passed, raw_si_attributes=actual["si_attributes"],
                                             raw_filename_attributes=actual["filename_attributes"], raw_directory=actual["directory"],
                                             expected_attributes=row.get("attributes"), zero_attributes_proven=zero_proven), ensure_ascii=True, separators=(",", ":")) + "\n")
        stored_hashes = {hashlib.sha256(data).hexdigest() for data in descriptors.values()}
        absent = sorted(set(expected) - stored_hashes)
        result = dict(kind="independent-all-raw-NTFS-security-and-file-references", source=str(raw), source_sha256=expected_sha256,
                      source_unchanged=oracle.digest_stream(locked) == expected_sha256, sds_descriptors=len(descriptors),
                      expected_descriptors=len(expected), expected_file_references=len(seen_expected), missing_paths=missing,
                      extra_paths=sorted(references), different_paths=different, absent_expected_sd_sha256=absent,
                      additional_unreferenced_sd_sha256=sorted(stored_hashes - set(expected)),
                      expected_security_sha256=security_pin, expected_tree_sha256=tree_pin,
                      expected_metadata_unchanged=oracle.digest(expected_security) == security_pin and oracle.digest(tree) == tree_pin,
                      raw_sd_descriptors_jsonl=str(descriptor_output), raw_sd_references_jsonl=str(refs_output),
                      zero_attribute_paths=zero_paths, zero_attribute_path_count=len(zero_paths), zero_attribute_failure_paths=zero_failures,
                      raw_zero_attributes_pass=not zero_failures,
                      root_reserved_metadata=root_metadata,
                      sds_primary_duplicate_and_ntfs_hash_verified=True, expected_bytes_modified=False, volume_mounted=False)
        if vhd_partition is not None:
            result.update(source_kind='dynamic-vhd', partition_start=vhd_partition[0], partition_bytes=vhd_partition[1])
        result["passed"] = (result["source_unchanged"] and result["expected_metadata_unchanged"] and
                            bool(root_metadata and root_metadata["passed"]) and
                            not (missing or references or different or absent or zero_failures))
        oracle.save(out, result)
        return result


def inspect(raw: Path, expected_sha256: str, expected_security: Path, recorded_api_sha256: str, out: Path) -> dict:
    oracle.owned(raw); oracle.owned(out); oracle.owned(expected_security)
    if raw.suffix != ".raw" or not raw.is_file() or not raw.stat().st_file_attributes & 1:
        raise ValueError("Closed regular read-only raw COPY required")
    if out.exists() or not all(re.fullmatch("[0-9a-f]{64}", h) for h in (expected_sha256, recorded_api_sha256)):
        raise ValueError("Fresh output and exact source/API pins required")
    with expected_security.open(encoding="utf-8") as expected:
        first = json.loads(expected.readline(1024 * 1024))
    if first.get("source_security_id") != 256:
        raise ValueError("Explicit default descriptor expectation required")
    expected_bytes = bytes.fromhex(first["hex"])
    if hashlib.sha256(expected_bytes).hexdigest() != first["sha256"]:
        raise ValueError("Expected SD hash differs")
    with oracle.readonly(raw) as locked:
        if oracle.digest_stream(locked) != expected_sha256:
            raise ValueError("Closed source pin differs")
        image = ntfs.Image(raw)
        try:
            standard = [a for a in ntfs.attributes(image.record(5)) if a["kind"] == 0x10]
            if len(standard) != 1:
                raise ValueError("Root SI missing")
            root_id = ntfs.number(image.attr_value(standard[0]["data"]), 52, 4)
            sds = stream_bytes(image, 9, 0x80, "$SDS")
            # The immutable formatter contract installs the default entry first.
            hash32, security_id, stored_offset, size = struct.unpack_from("<IIQI", sds)
            if security_id != root_id or security_id != 256 or stored_offset != 0 or not 20 <= size <= 65556:
                raise ValueError("SDS header does not identify root default SD")
            descriptor = sds[20:size]
            if len(descriptor) != size - 20 or sds[:size] != sds[0x40000:0x40000 + size]:
                raise ValueError("SDS primary/duplicate differ")
        finally:
            image.file.close()
        candidate = api_layout(descriptor)
        record = dict(kind="independent-raw-default-SDS-vs-recorded-native-SD-layout", source=str(raw),
                      source_sha256=expected_sha256, source_unchanged=oracle.digest_stream(locked) == expected_sha256,
                      root_security_id=root_id, sds_header_hash32=hash32, sds_entry_bytes=size,
                      sds_primary_duplicate_equal=True, raw_sd_hex=descriptor.hex(), raw_sd_sha256=hashlib.sha256(descriptor).hexdigest(),
                      raw_sd_equals_fixed_expected=descriptor == expected_bytes, raw_components=components(descriptor),
                      recorded_api_sha256=recorded_api_sha256, reconstructed_api_hex=candidate.hex(),
                      reconstructed_api_sha256=hashlib.sha256(candidate).hexdigest(), reconstructed_api_components=components(candidate),
                      native_api_hash_matches_reordered_unchanged_sections=hashlib.sha256(candidate).hexdigest() == recorded_api_sha256,
                      section_bytes_and_control_unchanged=same_sections(descriptor, candidate), expected_bytes_modified=False,
                      windows_test_rerun=False, volume_mounted=False, overall_ntfs_pass_claim=False)
        oracle.save(out, record)
        return record


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--raw", type=Path, required=True)
    p.add_argument("--sha256", required=True)
    p.add_argument("--expected-security", type=Path, required=True)
    p.add_argument("--recorded-api-sha256")
    p.add_argument("--tree", type=Path)
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()
    result = verify_tree(a.raw, a.sha256, a.expected_security, a.tree, a.out) if a.tree else inspect(a.raw, a.sha256, a.expected_security, a.recorded_api_sha256, a.out)
    print(json.dumps(result))
    if not result.get("passed", True):
        raise SystemExit(1)
