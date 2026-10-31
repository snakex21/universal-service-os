#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare independently captured, pinned NTFS metadata, without mounting disks.

Only compares evidence files: it does not capture metadata or authenticate a
producer's claimed observations. The receipt must be produced by a reviewed
collector while the exact image chain was locked for read-only access.
"""
from __future__ import annotations
import argparse, contextlib, ctypes, hashlib, json, os, re
from collections import Counter
from pathlib import Path

FIELDS = ('attrs', 'reparse', 'ea', 'ads', 'security')
SHA = re.compile(r'^[0-9a-f]{64}$')

def digest(stream):
    stream.seek(0); h = hashlib.sha256()
    while block := stream.read(1024 * 1024): h.update(block)
    stream.seek(0)
    return h.hexdigest()

def checked_path(root, name):
    p = Path(name)
    if not p.is_absolute() or '..' in p.parts or str(p).startswith('\\\\') or ':' in str(p)[3:]:
        raise ValueError('Explicit local regular file required')
    if not p.is_relative_to(root) or p == root:
        raise ValueError('Path is outside explicitly permitted runtime')
    for node in (p, *p.parents):
        if node.is_symlink() or (node.exists() and getattr(node.lstat(), 'st_file_attributes', 0) & 0x400):
            raise ValueError('Reparse path forbidden')
    if not p.is_file(): raise ValueError('Existing regular file required')
    return p

@contextlib.contextmanager
def locked(path):
    if os.name != 'nt':
        raise ValueError('Windows deny-write lock required')
    import msvcrt
    k = ctypes.WinDLL('kernel32', use_last_error=True)
    k.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    k.CreateFileW.restype = ctypes.c_void_p
    k.CloseHandle.argtypes = [ctypes.c_void_p]
    h = k.CreateFileW(str(path), 0x80000000, 1, None, 3, 0x08000000, None)
    if h == ctypes.c_void_p(-1).value: raise ctypes.WinError(ctypes.get_last_error())
    try: fd = msvcrt.open_osfhandle(h, os.O_RDONLY | os.O_BINARY)
    except BaseException:
        k.CloseHandle(h); raise
    with os.fdopen(fd, 'rb') as f: yield f

def path_key(s):
    if not isinstance(s, str) or '\\' in s or '\0' in s or s.startswith('/') or any(x in ('.', '..') for x in s.split('/')):
        raise ValueError('Invalid relative evidence path')
    return s  # Deliberately exact: do not invent Windows Unicode case folding.

def hex_value(v):
    if not isinstance(v, str) or len(v) % 2 or not re.fullmatch('[0-9a-f]*', v): raise ValueError('Expected lowercase bytes in hex')
    return v

def canonical(field, v):
    if field == 'attrs':
        if type(v) is not int or not 0 <= v <= 0xffffffff: raise ValueError('Invalid attributes')
        return v
    if field == 'reparse':
        if v is None: return None
        if not isinstance(v, dict) or set(v) != {'tag', 'data_hex'} or type(v['tag']) is not int or not 0 <= v['tag'] <= 0xffffffff: raise ValueError('Invalid reparse')
        return {'tag': v['tag'], 'data_hex': hex_value(v['data_hex'])}
    if field in ('ea', 'ads'):
        if not isinstance(v, list): raise ValueError('Incomplete EA/ADS inventory')
        normalized = []
        for item in v:
            if not isinstance(item, dict): raise ValueError('Invalid stream or EA')
            if field == 'ea':
                if set(item) != {'name','flags','value_hex'} or not isinstance(item['name'], str) or type(item['flags']) is not int or not 0 <= item['flags'] <= 255: raise ValueError('Invalid EA')
                hex_value(item['value_hex'])
            else:
                if set(item) != {'name','size','sha256'} or not isinstance(item['name'], str) or not item['name'] or type(item['size']) is not int or item['size'] < 0 or not isinstance(item['sha256'], str) or not SHA.fullmatch(item['sha256']): raise ValueError('Invalid ADS')
            normalized.append(item)
        if len({x['name'] for x in normalized}) != len(normalized): raise ValueError('Duplicate EA/ADS name')
        return sorted(normalized, key=lambda x: x['name'])
    if field == 'security':
        if not isinstance(v, dict) or set(v) != {'revision','sbz','control','owner','group','sacl','dacl'} or type(v['revision']) is not int or not 0 <= v['revision'] <= 255 or type(v['sbz']) is not int or not 0 <= v['sbz'] <= 255 or type(v['control']) is not int or not 0 <= v['control'] <= 65535: raise ValueError('Incomplete security descriptor')
        return {k: v[k] if k in ('revision','sbz','control') or v[k] is None else hex_value(v[k]) for k in ('revision','sbz','control','owner','group','sacl','dacl')}
    raise ValueError('Unknown field')

def get_field(row, field):
    obj = row.get(field)
    if obj is None: return ('UNKNOWN', None)
    if not isinstance(obj, dict) or type(obj.get('known')) is not bool: raise ValueError('Field must state known')
    if not obj['known']:
        if 'value' in obj: raise ValueError('Unknown cannot contain a value')
        return ('UNKNOWN', None)
    if set(obj) != {'known','value'}: raise ValueError('Known field missing value')
    if field == 'security' and isinstance(obj['value'],dict) and any(obj['value'].get(k) is None for k in ('revision','sbz','control')):
        return ('UNKNOWN', None)
    return ('KNOWN', canonical(field, obj['value']))

def jsonl(stream):
    for line in stream:
        if len(line) > 4*1024*1024: raise ValueError('JSONL row too large')
        yield json.loads(line)

def compare_rows(manifest_rows, left_rows, right_rows):
    selected = {}
    item_count = 0
    for row in manifest_rows:
        path = path_key(row['path'])
        tags = [t for t in row.get('tagged_metadata', []) if t.get('type') == 4]
        if tags:
            if path in selected: raise ValueError('Duplicate tagged path')
            for tag in tags: hex_value(tag['hex'])
            item_count += len(tags); selected[path] = tags
    if not selected: raise ValueError('No tagged type 4 entries')
    def index(rows):
        result = {}
        for row in rows:
            path = path_key(row['path'])
            if path in result: raise ValueError('Duplicate observed path')
            result[path] = row
        return result
    left, right = index(left_rows), index(right_rows)
    counts = {name: Counter() for name in FIELDS}; outcome = Counter(); out = []
    for path, tags in selected.items():
        a, b = left.get(path, {}), right.get(path, {})
        values = {}
        for name in FIELDS:
            left_known, lv = get_field(a, name); right_known, rv = get_field(b, name)
            status = 'UNKNOWN' if 'UNKNOWN' in (left_known, right_known) else 'MATCH' if lv == rv else 'DIFF'
            counts[name][status] += 1
            values[name] = {'status': status, 'left': lv if left_known == 'KNOWN' else None, 'right': rv if right_known == 'KNOWN' else None, 'left_known': left_known == 'KNOWN', 'right_known': right_known == 'KNOWN'}
        states = [v['status'] for v in values.values()]
        overall = 'DIFF' if 'DIFF' in states else 'UNKNOWN' if 'UNKNOWN' in states else 'MATCH'
        outcome[overall] += 1
        out.append({'path': path, 'type4': tags, 'overall': overall, 'fields': values})
    return out, {'tag4_items': item_count, 'tag4_paths': len(selected), 'outcome': dict(outcome), 'fields': {k: dict(v) for k,v in counts.items()}}

def run(root, volume_guid, manifest, manifest_sha, wim_receipt, wim_receipt_sha, lreceipt, lsha, rreceipt, rsha, out):
    root = Path(root)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir(): raise ValueError('Existing absolute runtime root required')
    if not re.fullmatch(r'\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\', volume_guid): raise ValueError('Explicit volume GUID required')
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    volume = ctypes.create_unicode_buffer(64)
    kernel.GetVolumeNameForVolumeMountPointW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
    if not kernel.GetVolumeNameForVolumeMountPointW(str(root.anchor),volume,len(volume)) or volume.value.lower() != volume_guid.lower(): raise ValueError('Unexpected runtime volume')
    if not all(SHA.fullmatch(x) for x in (manifest_sha, wim_receipt_sha, lsha, rsha)): raise ValueError('Pinned SHA256 required')
    out = Path(out)
    if not out.is_absolute() or not out.is_relative_to(root) or out.exists() or not out.parent.is_dir(): raise ValueError('New runtime output required')
    for node in (out.parent, *out.parent.parents):
        if node.is_symlink() or (node.exists() and getattr(node.lstat(), 'st_file_attributes', 0) & 0x400): raise ValueError('Output reparse path forbidden')
    with contextlib.ExitStack() as locks:
        def pinned(name, sha):
            if not SHA.fullmatch(sha): raise ValueError('Invalid SHA256 pin')
            path = checked_path(root, name)
            f = locks.enter_context(locked(path))
            if digest(f) != sha: raise ValueError('Pinned input differs')
            return f
        mf = pinned(manifest, manifest_sha)
        wrf = pinned(wim_receipt, wim_receipt_sha)
        wim = json.load(wrf)
        if wim.get('schema') != 'usos-wim-oracle-manifest-v1' or not SHA.fullmatch(wim.get('wim_sha256', '')) or type(wim.get('index')) is not int or wim.get('tree_sha256') != manifest_sha: raise ValueError('Invalid pinned WIM oracle receipt or tree hash')
        lrf, rrf = pinned(lreceipt, lsha), pinned(rreceipt, rsha)
        l, r = json.load(lrf), json.load(rrf)
        def verify(receipt):
            if receipt.get('schema') != 'minios-tag4-capture-v1' or receipt.get('locked_readonly_during_capture') is not True: raise ValueError('Invalid collector receipt')
            if receipt.get('manifest_sha256') != manifest_sha or receipt.get('source_wim_sha256') is None or type(receipt.get('wim_index')) is not int: raise ValueError('No source/manifest identity')
            if not SHA.fullmatch(receipt['source_wim_sha256']): raise ValueError('Invalid WIM identity')
            size, start, length = (receipt.get(k) for k in ('virtual_bytes','partition_offset','partition_bytes'))
            if any(type(x) is not int for x in (size,start,length)) or size <= 0 or start < 0 or length <= 0 or start+length > size: raise ValueError('Invalid virtual partition geometry')
            chain = receipt.get('chain')
            if not isinstance(chain,list) or not 1 <= len(chain) <= 16: raise ValueError('Invalid image chain')
            streams = []
            for entry in chain:
                if set(entry) != {'path','sha256'}: raise ValueError('Invalid chain identity')
                streams.append((pinned(entry['path'], entry['sha256']),entry['sha256']))
            e = receipt['evidence']; ef = pinned(e['path'], e['sha256'])
            return ef, streams
        le, ls = verify(l); re_, rs = verify(r)
        if (l['source_wim_sha256'],l['wim_index']) != (r['source_wim_sha256'],r['wim_index']) or (l['source_wim_sha256'],l['wim_index']) != (wim['wim_sha256'],wim['index']): raise ValueError('WIMs or indices differ')
        if [v['sha256'] for v in l['chain']] == [v['sha256'] for v in r['chain']]: raise ValueError('Identical image chains are not an independent comparison')
        rows, summary = compare_rows(jsonl(mf), jsonl(le), jsonl(re_))
        if wim.get('tagged_metadata_histogram', {}).get('0x00000004') != summary['tag4_items']: raise ValueError('Type 4 count differs from WIM receipt')
        for f, expected in ls+rs:
            if digest(f) != expected: raise ValueError('Image changed during comparison')
        with out.open('x', encoding='utf-8', newline='\n') as dst:
            written=0
            for row in rows:
                line=json.dumps(row, ensure_ascii=True, sort_keys=True) + '\n'
                written+=len(line.encode('utf-8'))
                if written>256*1024**2:raise ValueError('Diff evidence size bound exceeded')
                dst.write(line)
        return {'schema':'minios-tag4-diff-v1', 'manifest_sha256':manifest_sha, 'wim_receipt_sha256':wim_receipt_sha, 'source_wim_sha256':wim['wim_sha256'], 'wim_index':wim['index'], 'left_receipt_sha256':lsha, 'right_receipt_sha256':rsha, 'output_sha256':hashlib.sha256(out.read_bytes()).hexdigest(), 'capture_independence':'producer assertion; independently review collector', 'images_rehashed_and_locked':True, 'normalization':'exact paths/attributes/reparse; sort EA/ADS by exact name; security component bytes and control; no RP_FIX adjustment', **summary}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for option in ('root','volume-guid','manifest','manifest-sha256','wim-receipt','wim-receipt-sha256','left-receipt','left-receipt-sha256','right-receipt','right-receipt-sha256','out'): p.add_argument('--'+option, required=True)
    a=p.parse_args()
    print(json.dumps(run(a.root,a.volume_guid,a.manifest,a.manifest_sha256,a.wim_receipt,a.wim_receipt_sha256,a.left_receipt,a.left_receipt_sha256,a.right_receipt,a.right_receipt_sha256,a.out),indent=2))
if __name__ == '__main__': main()
