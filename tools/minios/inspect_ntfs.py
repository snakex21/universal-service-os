"""Independent, read-only NTFS extent/MFT/mirror evidence for stage1b-1.

This inspects emitted bytes, not the writer's statistics. Windows chkdsk and
Windows file hashes remain the acceptance gate; this is extra structural
evidence for actual fragmentation and ATTRIBUTE_LIST use.
SPDX-License-Identifier: GPL-3.0-or-later
Format reference: public Linux-NTFS attribute/record documentation.
"""
from __future__ import annotations
import argparse
from bisect import bisect_right
import json
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import uefi_case as api


def number(data, offset, size, signed=False):
    if offset < 0 or offset + size > len(data):
        raise ValueError("NTFS field outside record")
    return int.from_bytes(data[offset:offset+size], "little", signed=signed)


def unprotect(raw: bytes, signature: bytes) -> bytearray:
    if len(raw) % 512 or raw[:4] != signature:
        raise ValueError("Bad NTFS protected record signature/size")
    result = bytearray(raw)
    usa, count = number(raw, 4, 2), number(raw, 6, 2)
    if count != len(raw)//512+1 or usa+count*2 > 510:
        raise ValueError("Bad NTFS update sequence geometry")
    for i in range(1, count):
        end = i*512-2
        if raw[end:end+2] != raw[usa:usa+2]:
            raise ValueError("Torn NTFS protected record")
        result[end:end+2] = raw[usa+2*i:usa+2*i+2]
    return result


def attributes(record):
    position, used = number(record,20,2), number(record,24,4)
    if not 48 <= position < used <= len(record):
        raise ValueError("Bad FILE attribute bounds")
    seen = set()
    while position+8 <= used:
        kind, length = number(record,position,4), number(record,position+4,4)
        if kind == 0xffffffff:
            return
        if length < 24 or length%8 or position+length > used:
            raise ValueError("Invalid attribute record length")
        attr = bytes(record[position:position+length])
        attr_id = number(attr,14,2)
        if attr_id in seen:
            raise ValueError("Duplicate attribute instance in FILE record")
        seen.add(attr_id)
        n, start = attr[9], number(attr,10,2)
        name = attr[start:start+2*n].decode("utf-16le") if n else ""
        if n and start+2*n > len(attr):
            raise ValueError("Attribute name outside record")
        yield dict(kind=kind, name=name, id=attr_id, data=attr,
                   lowest=number(attr,16,8) if attr[8] else 0)
        position += length
    raise ValueError("No FILE attribute terminator")


def resident(attr):
    if attr[8]:
        raise ValueError("Resident value requested from nonresident attribute")
    length, offset = number(attr,16,4), number(attr,20,2)
    if offset < 24 or offset+length > len(attr):
        raise ValueError("Resident value outside attribute")
    return attr[offset:offset+length]


def runs(attr):
    if attr[8] != 1 or len(attr) < 64:
        raise ValueError("Nonresident runlist required")
    offset = number(attr,32,2)
    vcn, previous = number(attr,16,8), 0
    result = []
    while offset < len(attr):
        head = attr[offset]
        offset += 1
        if head == 0:
            if result and vcn != number(attr,24,8)+1:
                raise ValueError("Runlist highest VCN differs")
            return result
        length_bytes, delta_bytes = head & 15, head >> 4
        if not 1 <= length_bytes <= 8 or delta_bytes > 8 or offset+length_bytes+delta_bytes > len(attr):
            raise ValueError("Invalid mapping pair")
        count = number(attr,offset,length_bytes)
        offset += length_bytes
        if count == 0:
            raise ValueError("Empty nonterminal run")
        lcn = None
        if delta_bytes:
            previous += number(attr,offset,delta_bytes,True)
            lcn = previous
            if lcn < 0:
                raise ValueError("Negative disk cluster")
        offset += delta_bytes
        result.append((vcn,count,lcn))
        vcn += count
    raise ValueError("Unterminated mapping pairs")


def physical_extent_count(mapped):
    """Adjacent mapping records are one physical extent, not fragmentation."""
    count, previous_vcn_end, previous_lcn_end = 0, None, None
    for vcn, clusters, lcn in sorted(mapped):
        if lcn is None:
            previous_vcn_end = previous_lcn_end = None
            continue
        if vcn != previous_vcn_end or lcn != previous_lcn_end:
            count += 1
        previous_vcn_end, previous_lcn_end = vcn+clusters, lcn+clusters
    return count


class Image:
    def __init__(self, path, *, file=None, partition_start=None, partition_bytes=None):
        # The old closed-raw/first-partition API remains unchanged. A caller
        # supplying an independent virtual reader must also provide exact
        # partition geometry, proven separately from the partition table.
        if file is None:
            if partition_start is not None or partition_bytes is not None:
                raise ValueError('Explicit NTFS partition requires a virtual reader')
            self.file = path.open("rb")
            mbr = self.at(0,512)
            if mbr[510:512] != b"\x55\xaa":
                raise ValueError("Missing MBR")
            start = number(mbr,454,4)
            if mbr[450] == 0xee:
                header = self.at(512,512)
                if header[:8] != b"EFI PART":
                    raise ValueError("Missing GPT")
                entry = self.at(number(header,72,8)*512,128)
                start = number(entry,32,8)
            self.partition = start*512
            self.partition_bytes = None
        else:
            if (type(partition_start) is not int or type(partition_bytes) is not int or partition_start < 0
                    or partition_bytes <= 0 or partition_start % 512 or partition_bytes % 512
                    or partition_start > file.size or partition_bytes > file.size - partition_start):
                raise ValueError('Virtual NTFS partition geometry outside reader')
            self.file, self.partition, self.partition_bytes = file, partition_start, partition_bytes
        self.boot = self.at(self.partition,512)
        if self.boot[3:11] != b"NTFS    ":
            raise ValueError("Missing NTFS BPB")
        self.cluster = number(self.boot,11,2)*self.boot[13]
        record_size = number(self.boot,64,1,True)
        self.record_bytes = 1 << -record_size if record_size < 0 else record_size*self.cluster
        if self.cluster != 4096 or self.record_bytes != 1024:
            raise ValueError("Unexpected stage1b-1 NTFS geometry")
        first = self.relative(number(self.boot,48,8)*self.cluster,1024)
        self.zero = unprotect(first,b"FILE")
        base_attrs = list(attributes(self.zero))
        data = [a for a in base_attrs if a["kind"]==0x80 and a["name"]==""]
        if len(data) != 1:
            raise ValueError("Missing base MFT DATA")
        self.mft_runs = runs(data[0]["data"])
        self.mft_bytes = number(data[0]["data"],48,8)
        self.mft_allocated = number(data[0]["data"],40,8)
        lists = [a for a in base_attrs if a["kind"] == 0x20]
        if lists:
            entries = self.list_entries(self.attr_value(lists[0]["data"]))
            pending = [e for e in entries if e["kind"]==0x80 and e["name"]=="" and e["lowest"]>0]
            while pending:
                progress = False
                for entry in list(pending):
                    try:
                        record = self.record(entry["reference"] & ((1<<48)-1))
                    except ValueError:
                        continue
                    match = [a for a in attributes(record) if a["kind"]==0x80 and a["name"]=="" and a["lowest"]==entry["lowest"]]
                    if len(match) != 1:
                        raise ValueError("Missing MFT DATA continuation")
                    self.mft_runs.extend(runs(match[0]["data"]))
                    self.mft_runs.sort()
                    pending.remove(entry)
                    progress = True
                if not progress:
                    raise ValueError("MFT ATTRIBUTE_LIST cannot bootstrap its continuations")
        self.validate_runs(self.mft_runs, self.mft_allocated)

    def at(self, offset, count):
        self.file.seek(offset)
        data = self.file.read(count)
        if len(data) != count:
            raise ValueError("Short NTFS image read")
        return data

    def relative(self, offset, count):
        if self.partition_bytes is not None and (offset < 0 or count < 0 or offset > self.partition_bytes or count > self.partition_bytes - offset):
            raise ValueError('NTFS read outside explicit virtual partition')
        return self.at(self.partition+offset,count)

    def stream(self, mapped, offset, count):
        chunks = []
        starts = [r[0] for r in mapped]
        while count:
            index = bisect_right(starts,offset//self.cluster)-1
            if index < 0:
                raise ValueError("Stream offset precedes mapping")
            vcn, length, lcn = mapped[index]
            displacement = offset-vcn*self.cluster
            n = min(count,length*self.cluster-displacement)
            if n <= 0:
                raise ValueError("Stream has an unmapped VCN")
            chunks.append(bytes(n) if lcn is None else self.relative(lcn*self.cluster+displacement,n))
            offset += n
            count -= n
        return b"".join(chunks)

    def record(self, record_number):
        data = self.stream(self.mft_runs,record_number*self.record_bytes,self.record_bytes)
        decoded = unprotect(data,b"FILE")
        if number(decoded,44,4) != record_number:
            raise ValueError("MFT record number disagrees with position")
        return decoded

    def attr_value(self, attr):
        if not attr[8]:
            return resident(attr)
        size = number(attr,48,8)
        if size > 32*1024*1024:
            raise ValueError("Metadata attribute exceeds inspection buffer bound")
        return self.stream(runs(attr),0,size)

    @staticmethod
    def list_entries(value):
        offset = 0
        result = []
        while offset < len(value):
            kind, length = number(value,offset,4), number(value,offset+4,2)
            if length < 26 or length%8 or offset+length > len(value):
                raise ValueError("Invalid ATTRIBUTE_LIST entry")
            n, start = value[offset+6:offset+8]
            name = value[offset+start:offset+start+2*n].decode("utf-16le") if n else ""
            result.append(dict(kind=kind,name=name,lowest=number(value,offset+8,8),
                               reference=number(value,offset+16,8),id=number(value,offset+24,2)))
            offset += length
        return result

    @staticmethod
    def validate_runs(mapped, allocation):
        cursor = 0
        for vcn,count,_ in sorted(mapped):
            if vcn != cursor:
                raise ValueError("Nonresident stream has VCN gap/overlap")
            cursor += count
        if cursor*4096 != allocation:
            raise ValueError("Runlist allocation differs from allocated byte size")

    def file_extents(self, record_number, kind=0x80, name=""):
        base = self.record(record_number)
        attrs = list(attributes(base))
        selected = [a for a in attrs if a["kind"]==kind and a["name"]==name]
        lists = [a for a in attrs if a["kind"] == 0x20]
        continuation_records = set()
        if lists:
            for entry in self.list_entries(self.attr_value(lists[0]["data"])):
                target = entry["reference"] & ((1<<48)-1)
                if entry["kind"] != kind or entry["name"] != name or target == record_number:
                    continue
                extension = self.record(target)
                if number(extension,32,8) & ((1<<48)-1) != record_number:
                    raise ValueError("Extension FILE does not point back to base")
                if number(extension,16,2) != entry["reference"] >> 48:
                    raise ValueError("Stale ATTRIBUTE_LIST record sequence")
                matches = [a for a in attributes(extension) if a["kind"]==kind and a["name"]==name and a["lowest"]==entry["lowest"] and a["id"]==entry["id"]]
                if len(matches) != 1:
                    raise ValueError("ATTRIBUTE_LIST does not identify one attribute")
                selected.extend(matches)
                continuation_records.add(target)
        selected.sort(key=lambda a:a["lowest"])
        if not selected:
            raise ValueError("Missing file stream")
        if not selected[0]["data"][8]:
            return dict(size=len(resident(selected[0]["data"])),run_count=0,physical_extent_count=0,attribute_list=bool(lists),extension_records=len(continuation_records))
        mapped = [run for attr in selected for run in runs(attr["data"])]
        self.validate_runs(mapped,number(selected[0]["data"],40,8))
        return dict(size=number(selected[0]["data"],48,8),run_count=len(mapped),physical_extent_count=physical_extent_count(mapped),
                    attribute_list=bool(lists),extension_records=len(continuation_records),
                    first_runs=mapped[:8],last_runs=mapped[-8:])

    def evidence(self):
        first_four = self.stream(self.mft_runs,0,4096)
        mirror = self.relative(number(self.boot,56,8)*self.cluster,4096)
        if first_four != mirror:
            raise ValueError("$MFTMirr bytes differ from first four MFT records")
        bitmap_attr = [a for a in attributes(self.zero) if a["kind"]==0xb0 and a["name"]==""]
        if len(bitmap_attr) != 1:
            raise ValueError("Missing MFT allocation bitmap")
        bitmap = self.attr_value(bitmap_attr[0]["data"])
        used_records, files, directories, extensions = 0,0,0,0
        fragmented = []
        for i in range(self.mft_bytes//1024):
            if i//8 >= len(bitmap):
                raise ValueError("MFT bitmap shorter than initialized record range")
            if not bitmap[i//8] & (1<<(i%8)):
                continue
            record = self.record(i)
            used_records += 1
            if number(record,32,8):
                extensions += 1
                continue
            if i < 27:
                continue
            flags = number(record,22,2)
            if flags & 2:
                directories += 1
            else:
                files += 1
            names = [resident(a["data"]) for a in attributes(record) if a["kind"]==0x30]
            for value in names:
                if value[66:66+2*value[64]].decode("utf-16le") == "fragmented.bin":
                    fragmented.append(dict(record=i,**self.file_extents(i)))
        return dict(kind="independent-readonly-NTFS-byte-inspection", mft_records=self.mft_bytes//1024,
                    mft_runs=len(self.mft_runs),mft_physical_extent_count=physical_extent_count(self.mft_runs),mft_first_runs=self.mft_runs[:8],
                    mft_mirror_equal=True, used_records=used_records,files=files,
                    directories=directories,extension_records=extensions,fragmented_files=fragmented)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image",type=Path)
    parser.add_argument("--workspace",type=Path,required=True)
    parser.add_argument("--qemu-dir",type=Path,required=True)
    parser.add_argument("--out",type=Path,required=True)
    args = parser.parse_args()
    api.configure(args.workspace,args.qemu_dir)
    image, out = api.checked(args.image),api.checked(args.out)
    if image.suffix != ".raw" or not image.is_file():
        raise ValueError("Only a regular raw image under the owned workspace is allowed")
    inspected = Image(image)
    try:
        result = inspected.evidence()
    finally:
        inspected.file.close()
    with out.open("x",encoding="utf-8",newline="\n") as output:
        json.dump(result,output,indent=2)
        output.write("\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
