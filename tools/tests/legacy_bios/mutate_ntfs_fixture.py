#!/usr/bin/env python3
import argparse
import os
import shutil
import struct
from pathlib import Path

SECTOR = 512


def u16(b, o):
    return struct.unpack_from('<H', b, o)[0]


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def u64(b, o):
    return struct.unpack_from('<Q', b, o)[0]


def p16(b, o, v):
    struct.pack_into('<H', b, o, v)


def p32(b, o, v):
    struct.pack_into('<I', b, o, v)


def find_ntfs_partition(image):
    mbr = image[:SECTOR]
    if mbr[510:512] != b'\x55\xaa':
        raise RuntimeError('MBR signature missing')
    found = []
    for i in range(4):
        off = 446 + i * 16
        if mbr[off + 4] != 0x07:
            continue
        start = u32(mbr, off + 8)
        sectors = u32(mbr, off + 12)
        if start and sectors:
            found.append((start * SECTOR, sectors * SECTOR))
    if len(found) != 1:
        raise RuntimeError(f'expected one NTFS MBR partition, got {len(found)}')
    return found[0]


def record_bytes_from_code(code, cluster_bytes):
    if code >= 128:
        code -= 256
    if code > 0:
        return code * cluster_bytes
    if code < 0:
        return 1 << (-code)
    raise RuntimeError('invalid NTFS record size code')


def fixup_record(raw, bytes_per_sector, expected_sig=None):
    fixed = bytearray(raw)
    if expected_sig is not None and fixed[:4] != expected_sig:
        raise RuntimeError(f'bad record signature: {fixed[:4]!r}')
    usa_off = u16(fixed, 4)
    usa_count = u16(fixed, 6)
    sectors = len(fixed) // bytes_per_sector
    if usa_count != sectors + 1:
        raise RuntimeError('unexpected USA count')
    if usa_off + usa_count * 2 > len(fixed):
        raise RuntimeError('USA outside record')
    usn = u16(fixed, usa_off)
    for i in range(sectors):
        trailer = (i + 1) * bytes_per_sector - 2
        if u16(fixed, trailer) != usn:
            raise RuntimeError('USA trailer mismatch')
        replacement = u16(fixed, usa_off + 2 + i * 2)
        p16(fixed, trailer, replacement)
    return fixed


def serialize_fixup(fixed, bytes_per_sector):
    raw = bytearray(fixed)
    usa_off = u16(raw, 4)
    usa_count = u16(raw, 6)
    sectors = len(raw) // bytes_per_sector
    if usa_count != sectors + 1:
        raise RuntimeError('unexpected USA count during serialize')
    usn = u16(raw, usa_off)
    for i in range(sectors):
        trailer = (i + 1) * bytes_per_sector - 2
        logical = u16(raw, trailer)
        p16(raw, usa_off + 2 + i * 2, logical)
        p16(raw, trailer, usn)
    return raw


def find_unnamed_data_attr(record):
    used = u32(record, 24)
    off = u16(record, 20)
    while off + 16 <= used:
        typ = u32(record, off)
        if typ == 0xFFFFFFFF:
            break
        length = u32(record, off + 4)
        if length < 24 or off + length > used:
            raise RuntimeError('invalid attribute while finding $MFT data')
        nonresident = record[off + 8]
        name_len = record[off + 9]
        if typ == 0x80 and nonresident == 1 and name_len == 0:
            return off, length
        off += length
    raise RuntimeError('unnamed $MFT DATA attribute missing')


def read_unsigned(buf):
    return int.from_bytes(buf, 'little', signed=False)


def read_signed(buf):
    return int.from_bytes(buf, 'little', signed=True)


def decode_runs(record, attr_off, attr_len):
    mapping_off = u16(record, attr_off + 32)
    pos = attr_off + mapping_off
    end = attr_off + attr_len
    runs = []
    current_lcn = 0
    while pos < end:
        header = record[pos]
        pos += 1
        if header == 0:
            return runs
        len_bytes = header & 0x0F
        off_bytes = header >> 4
        if len_bytes == 0 or len_bytes > 8 or off_bytes > 8 or pos + len_bytes + off_bytes > end:
            raise RuntimeError('invalid mapping pairs')
        clusters = read_unsigned(record[pos:pos + len_bytes])
        pos += len_bytes
        if clusters == 0:
            raise RuntimeError('zero-length run')
        if off_bytes == 0:
            runs.append((clusters, None))
        else:
            delta = read_signed(record[pos:pos + off_bytes])
            pos += off_bytes
            current_lcn += delta
            runs.append((clusters, current_lcn))
    raise RuntimeError('unterminated mapping pairs')


def min_unsigned(v):
    if v <= 0:
        raise RuntimeError('run length must be positive')
    n = max(1, (v.bit_length() + 7) // 8)
    return v.to_bytes(n, 'little', signed=False)


def min_signed(v):
    for n in range(1, 9):
        lo = -(1 << (n * 8 - 1))
        hi = (1 << (n * 8 - 1)) - 1
        if lo <= v <= hi:
            return v.to_bytes(n, 'little', signed=True)
    raise RuntimeError('LCN delta does not fit i64')


def encode_runs(runs):
    out = bytearray()
    current_lcn = 0
    for clusters, lcn in runs:
        lb = min_unsigned(clusters)
        if lcn is None:
            ob = b''
        else:
            ob = min_signed(lcn - current_lcn)
            current_lcn = lcn
        out.append((len(ob) << 4) | len(lb))
        out += lb
        out += ob
    out.append(0)
    return bytes(out)


def rewrite_runs(record, runs):
    attr_off, attr_len = find_unnamed_data_attr(record)
    mapping_off = u16(record, attr_off + 32)
    pairs = encode_runs(runs)
    capacity = attr_len - mapping_off
    if len(pairs) > capacity:
        needed = len(pairs) - capacity
        extra = (needed + 7) & ~7
        used = u32(record, 24)
        allocated = u32(record, 28)
        attr_end = attr_off + attr_len
        if used + extra > allocated or used + extra > len(record):
            raise RuntimeError(f'no record slack to expand mapping pairs by {extra} bytes')
        tail = bytes(record[attr_end:used])
        record[attr_end + extra:used + extra] = tail
        record[attr_end:attr_end + extra] = b'\x00' * extra
        attr_len += extra
        p32(record, attr_off + 4, attr_len)
        p32(record, 24, used + extra)
        capacity += extra
    start = attr_off + mapping_off
    record[start:start + capacity] = b'\x00' * capacity
    record[start:start + len(pairs)] = pairs
    total_clusters = sum(length for length, _ in runs)
    struct.pack_into('<Q', record, attr_off + 16, 0)
    struct.pack_into('<Q', record, attr_off + 24, total_clusters - 1)


def locate(image):
    part_off, part_size = find_ntfs_partition(image)
    boot = image[part_off:part_off + SECTOR]
    if boot[3:11] != b'NTFS    ':
        raise RuntimeError('NTFS OEM marker missing')
    bps = u16(boot, 11)
    spc = boot[13]
    cluster_bytes = bps * spc
    total_clusters = u64(boot, 40) // spc
    mft_lcn = u64(boot, 48)
    record_bytes = record_bytes_from_code(boot[64], cluster_bytes)
    mft0_off = part_off + mft_lcn * cluster_bytes
    raw = image[mft0_off:mft0_off + record_bytes]
    fixed = fixup_record(raw, bps, b'FILE')
    attr_off, attr_len = find_unnamed_data_attr(fixed)
    runs = decode_runs(fixed, attr_off, attr_len)
    return {
        'part_off': part_off,
        'part_size': part_size,
        'bps': bps,
        'spc': spc,
        'cluster_bytes': cluster_bytes,
        'total_clusters': total_clusters,
        'mft_lcn': mft_lcn,
        'record_bytes': record_bytes,
        'mft0_off': mft0_off,
        'mft0_fixed': fixed,
        'mft_runs': runs,
    }


def ensure_fragmented_mft(image, reserve_lcn, reserve_clusters):
    info = locate(image)
    runs = info['mft_runs']
    if len(runs) >= 2:
        print(f'[PASS] fixture MFT already fragmented runs={len(runs)}')
        return
    if len(runs) != 1 or runs[0][1] is None:
        raise RuntimeError(f'unsupported original MFT run layout: {runs}')
    clusters, lcn = runs[0]
    keep = 2
    if clusters <= keep:
        raise RuntimeError(f'MFT run too small to fragment: {clusters} clusters')
    tail = clusters - keep
    if reserve_clusters < tail:
        raise RuntimeError(f'reserved free extent too small: have {reserve_clusters}, need {tail} clusters')
    if reserve_lcn < 0 or reserve_lcn + tail > info['total_clusters']:
        raise RuntimeError('reserved extent outside NTFS partition')
    if reserve_lcn < lcn + clusters and lcn < reserve_lcn + tail:
        raise RuntimeError('reserved extent overlaps original MFT')

    cb = info['cluster_bytes']
    part = info['part_off']
    src = part + (lcn + keep) * cb
    dst = part + reserve_lcn * cb
    length = tail * cb
    image[dst:dst + length] = image[src:src + length]

    fixed = info['mft0_fixed']
    rewrite_runs(fixed, [(keep, lcn), (tail, reserve_lcn)])
    raw = serialize_fixup(fixed, info['bps'])
    image[info['mft0_off']:info['mft0_off'] + len(raw)] = raw

    check = locate(image)
    if len(check['mft_runs']) != 2:
        raise RuntimeError('MFT fragmentation rewrite did not produce two runs')
    print(f"[PASS] fragmented $MFT runs=2 first_lcn={lcn} first_clusters={keep} second_lcn={reserve_lcn} second_clusters={tail}")


def mutate_bad_vbr(image):
    info = locate(image)
    image[info['part_off'] + 3:info['part_off'] + 11] = b'BROKEN!!'


def mutate_bad_mft_signature(image):
    info = locate(image)
    image[info['mft0_off']:info['mft0_off'] + 4] = b'FAIL'


def mutate_bad_fixup(image):
    info = locate(image)
    trailer = info['mft0_off'] + info['bps'] - 2
    image[trailer] ^= 0x5A


def mutate_run_outside(image):
    info = locate(image)
    fixed = info['mft0_fixed']
    runs = info['mft_runs']
    if len(runs) < 2:
        raise RuntimeError('run-outside mutation requires fragmented fixture')
    lengths = [r[0] for r in runs]
    first_lcn = runs[0][1]
    bad_lcn = info['total_clusters'] + 16
    new_runs = [(lengths[0], first_lcn), (lengths[1], bad_lcn)]
    for length, lcn in runs[2:]:
        new_runs.append((length, lcn))
    rewrite_runs(fixed, new_runs)
    raw = serialize_fixup(fixed, info['bps'])
    image[info['mft0_off']:info['mft0_off'] + len(raw)] = raw


def mutate_run_loop(image):
    info = locate(image)
    fixed = info['mft0_fixed']
    runs = info['mft_runs']
    if len(runs) < 2:
        raise RuntimeError('run-loop mutation requires fragmented fixture')
    first_len, first_lcn = runs[0]
    second_len, _ = runs[1]
    overlap_lcn = first_lcn + max(0, first_len - 1)
    new_runs = [(first_len, first_lcn), (second_len, overlap_lcn)]
    for length, lcn in runs[2:]:
        new_runs.append((length, lcn))
    rewrite_runs(fixed, new_runs)
    raw = serialize_fixup(fixed, info['bps'])
    image[info['mft0_off']:info['mft0_off'] + len(raw)] = raw


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--mode', required=True, choices=['valid-hard', 'bad-vbr', 'bad-mft-signature', 'bad-fixup', 'run-outside', 'run-loop'])
    parser.add_argument('--reserve-lcn', type=lambda x: int(x, 0))
    parser.add_argument('--reserve-clusters', type=lambda x: int(x, 0))
    args = parser.parse_args()

    source = Path(args.source)
    output = Path(args.output)
    shutil.copyfile(source, output)
    with output.open('r+b', buffering=0) as f:
        import mmap
        mm = mmap.mmap(f.fileno(), 0)
        try:
            if args.mode == 'valid-hard':
                if args.reserve_lcn is None or args.reserve_clusters is None:
                    raise RuntimeError('valid-hard requires reserve LCN/clusters')
                ensure_fragmented_mft(mm, args.reserve_lcn, args.reserve_clusters)
            elif args.mode == 'bad-vbr':
                mutate_bad_vbr(mm)
            elif args.mode == 'bad-mft-signature':
                mutate_bad_mft_signature(mm)
            elif args.mode == 'bad-fixup':
                mutate_bad_fixup(mm)
            elif args.mode == 'run-outside':
                mutate_run_outside(mm)
            elif args.mode == 'run-loop':
                mutate_run_loop(mm)
            mm.flush()
        finally:
            mm.close()
    print(f'[PASS] NTFS fixture mode={args.mode} output={output}')


if __name__ == '__main__':
    main()
