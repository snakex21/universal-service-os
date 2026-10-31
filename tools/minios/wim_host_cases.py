#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pinned host WIM cases on newly owned COW-derived regular images.

Only own generated fixtures, never physical disks/mounts. Blocking child waits;
complete logs/images are retained. Windows RO verification is a separate gate.
"""
from __future__ import annotations
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import time
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import wim_oracle as oracle

GiB = 1024**3
SIZE = 256 * 1024**2
MAX_FIXTURE = 64 * 1024**2
SCHEMA = 'usos-own-wim-fixtures-v1'
HEX = re.compile(r'[0-9a-f]{64}\Z')

def pin(value: str) -> str:
    if not isinstance(value, str) or not HEX.fullmatch(value):
        raise ValueError('Explicit lowercase SHA256 pin required')
    return value

def pe_stack(path: Path) -> int:
    with oracle.local(path).open('rb') as f:
        head = f.read(64)
        if len(head) != 64 or head[:2] != b'MZ': raise ValueError('Pinned host program must be PE')
        at = struct.unpack_from('<I', head, 60)[0]
        if not 64 <= at <= 1024**2: raise ValueError('Invalid PE header offset')
        f.seek(at); image = f.read(112)
        if len(image) < 112 or image[:4] != b'PE\0\0' or struct.unpack_from('<H', image, 24)[0] != 0x20b:
            raise ValueError('Expected x64 PE32+ host program')
        reserve = struct.unpack_from('<Q', image, 24 + 72)[0]
        if reserve < 1024**2: raise ValueError('Host program needs at least1MiB stack reserve')
        return reserve

def plan(manifest: dict) -> list[dict]:
    if manifest.get('schema') != SCHEMA or manifest.get('own_generated_data') is not True:
        raise ValueError('Only own immutable generated fixture set is accepted')
    records = manifest.get('cases')
    if not isinstance(records, list): raise ValueError('Missing fixture cases')
    large = manifest.get('profile') == 'large'
    ads = manifest.get('profile') == 'ads'
    if manifest.get('profile', 'smoke') not in ('smoke', 'large', 'ads'):
        raise ValueError('Unknown workload profile')
    if large and (type(manifest.get('source_file_count')) is not int or manifest['source_file_count'] < 1200
                  or type(manifest.get('source_largest_file_bytes')) is not int
                  or manifest['source_largest_file_bytes'] <= 100 * 1024**2):
        raise ValueError('Large profile must prove file-count and individual-file thresholds')
    if ads and manifest.get('source_named_stream_count') != 2:
        raise ValueError('ADS profile must contain the two explicit own streams')
    result = []
    selected = {}
    for row in records:
        if row.get('own_generated_data') is not True or row.get('read_only_attribute') is not True:
            raise ValueError('Own readonly fixture required')
        source = oracle.owned(Path(row['wim']))
        sha = pin(row['sha256'])
        if row.get('solid') is True:
            result.append(dict(name='refuse-solid-lzms', source=source, source_sha256=sha, index=1,
                               positive=False, error='UnsupportedSolid'))
            continue
        key = row.get('header', {}).get('compression')
        if row.get('header', {}).get('image_count') == 2: key = 'MULTI'
        if key not in ('XPRESS', 'LZX', 'LZMS', 'MULTI') or key in selected:
            raise ValueError('Unexpected or duplicate positive codec case')
        selected[key] = row
    keys = ('XPRESS',) if ads else ('XPRESS', 'LZX', 'LZMS') if large else ('XPRESS', 'LZX', 'LZMS', 'MULTI')
    if set(selected) != set(keys) or sum(not x['positive'] for x in result) != (0 if large or ads else 1):
        raise ValueError('Exactly four codecs/index positives and one solid negative required')
    positives = []
    for key in keys:
        row = selected[key]; index = 2 if key == 'MULTI' else 1
        image = [entry for entry in row['images'] if entry['index'] == index]
        if len(image) != 1 or image[0].get('own_bytes_vs_wimlib') != 'PASS':
            raise ValueError('Missing independent own source/image proof')
        refs = {name: oracle.owned(Path(image[0][name])) for name in ('tree', 'security', 'manifest')}
        positives.append(dict(name={'XPRESS':'xpress', 'LZX':'lzx', 'LZMS':'lzms-nonsolid', 'MULTI':'multi-index2'}[key],
                              source=oracle.owned(Path(row['wim'])), source_sha256=pin(row['sha256']),
                              index=index, positive=True, oracle=refs))
    if large or ads:
        return positives
    split = manifest['split_negative']['parts']
    if len(split) != 2 or {x['part'] for x in split} != {1, 2} or any(x['total'] != 2 for x in split):
        raise ValueError('Exactly the two pinned split parts required')
    for row in split:
        result.append(dict(name='refuse-split-part%d' % row['part'], source=oracle.owned(Path(row['path'])),
                           source_sha256=pin(row['sha256']), index=1, positive=False, error='UnsupportedSplitWim'))
    multi = selected['MULTI']
    for index in (0, 3):
        result.append(dict(name='refuse-index%d' % index, source=oracle.owned(Path(multi['wim'])),
                           source_sha256=pin(multi['sha256']), index=index, positive=False, error='InvalidImageIndex'))
    return positives + result

def corrupt_metadata_hash(f) -> dict:
    """Change exactly one metadata SHA1 in the raw lookup. Recompute optional
    container-integrity SHA1 blocks so the resource hash check is the failure.
    Public WIM layouts; this function never opens a path itself.
    """
    f.seek(0, 2); size = f.tell(); f.seek(0); head = f.read(208)
    if size > MAX_FIXTURE or len(head) != 208 or head[:8] != b'MSWIM\0\0\0':
        raise ValueError('Bounded own WIM fixture required')
    packed, offset, length = struct.unpack_from('<QQQ', head, 48)
    stored, flags = packed & 0x00ffffffffffffff, packed >> 56
    if flags & 4 or stored != length or length % 50 or offset < 208 or offset + length > size:
        raise ValueError('Only a raw bounded lookup table can be mutated')
    selected = None
    for row in range(length // 50):
        f.seek(offset + row * 50); entry = f.read(50)
        if len(entry) != 50: raise ValueError('Truncated lookup')
        if entry[7] & 2:
            selected = (row, offset + row * 50 + 30, entry[30:50]); break
    if selected is None or not any(selected[2]): raise ValueError('No metadata hash to mutate')
    row, location, old = selected; new = bytes([old[0] ^ 1]) + old[1:]
    f.seek(location); f.write(new); f.flush()
    ipacked, ioffset, ilength = struct.unpack_from('<QQQ', head, 124)
    istored, iflags = ipacked & 0x00ffffffffffffff, ipacked >> 56
    blocks = 0
    if ilength:
        if iflags & 4 or istored != ilength or ioffset < offset + length or ioffset + ilength > size:
            raise ValueError('Unsupported integrity layout')
        f.seek(ioffset); table = f.read(12)
        declared, count, block_size = struct.unpack('<III', table)
        end = offset + stored
        if not block_size or declared != ilength or 12 + count * 20 != ilength or count != (end - 208 + block_size - 1) // block_size:
            raise ValueError('Invalid integrity table')
        for number in range(count):
            start = 208 + number * block_size; remain = min(block_size, end - start)
            h = hashlib.sha1(); f.seek(start)
            while remain:
                chunk = f.read(min(65536, remain))
                if not chunk: raise ValueError('Truncated integrity region')
                h.update(chunk); remain -= len(chunk)
            f.seek(ioffset + 12 + number * 20); f.write(h.digest()); f.flush()
        blocks = count
    return dict(metadata_lookup_row=row, sha1_offset=location, old_sha1=old.hex(), new_sha1=new.hex(),
                container_integrity_blocks_recomputed=blocks,
                mutation='metadata-resource-expected-SHA1-only; optional container-integrity updated')


def verify_large_tree(path: Path) -> dict:
    """Read only the independent wimlib expected tree, never our NTFS output."""
    files = 0
    largest = 0
    with oracle.readonly(path) as source:
        before = oracle.digest_stream(source)
        source.seek(0)
        for line in source:
            row = json.loads(line)
            if row['directory']:
                continue
            files += 1
            for stream in row['streams']:
                if stream['name'] is None:
                    largest = max(largest, stream['size'])
        if oracle.digest_stream(source) != before:
            raise ValueError('Expected large tree changed while reading')
    if files < 1000 or largest <= 100 * 1024**2:
        raise ValueError('Independent WIM tree does not meet large-workload gate')
    return dict(tree_sha256=before, files=files, largest_file_bytes=largest)


def verify_ads_tree(path: Path) -> dict:
    with oracle.readonly(path) as source:
        before = oracle.digest_stream(source); source.seek(0)
        matches = []
        for line in source:
            row = json.loads(line)
            named = {stream['name']: stream for stream in row.get('streams', []) if stream['name'] is not None}
            if 'Zone.Identifier' in named and 'large-世界' in named:
                if named['Zone.Identifier']['size'] != 37 or named['large-世界']['size'] != 196609:
                    raise ValueError('ADS expected sizes differ')
                matches.append(dict(path=row['path'], streams=named))
        if oracle.digest_stream(source) != before: raise ValueError('Expected ADS tree changed')
    if len(matches) != 1: raise ValueError('Expected one own file with both resident and nonresident ADS')
    return dict(tree_sha256=before, named_streams=2, files=matches)

def mutation(source: Path, expected: str, out: Path) -> dict:
    oracle.owned(out); oracle.owned(source)
    if out.exists() or not source.is_file(): raise ValueError('New mutation and existing own source required')
    out.parent.mkdir(parents=True, exist_ok=False)
    with oracle.readonly(source) as locked:
        before = oracle.digest_stream(locked)
        if before != pin(expected): raise ValueError('Immutable source pin mismatch')
        locked.seek(0)
        with out.open('x+b') as target:
            copied = 0
            while block := locked.read(65536):
                copied += len(block)
                if copied > MAX_FIXTURE: raise ValueError('Mutation exceeds own fixture size bound')
                target.write(block)
            detail = corrupt_metadata_hash(target)
            target.flush(); os.fsync(target.fileno())
        if oracle.digest_stream(locked) != before: raise ValueError('Source changed during copy')
    out.chmod(stat.S_IREAD)
    detail.update(source_sha256=before, derived_sha256=oracle.digest(out), derived_bytes=out.stat().st_size,
                  source_unchanged=True, own_generated_data=True, readonly=True)
    oracle.save(out.parent / 'mutation.json', detail)
    return detail

def runtime_environment(out: Path) -> dict:
    oracle.owned(out); out.mkdir()
    return oracle.environment(out)

def prepare(case: Path, qemu_img: Path, negative: bool) -> dict:
    oracle.owned(case); oracle.local(qemu_img)
    if case.exists(): raise ValueError('Never overwrite a case')
    oracle.storage_guard(4 * SIZE)
    case.mkdir(parents=True)
    base, cow, target = (case / name for name in ('blank-base.qcow2', 'test-cow.qcow2', 'target.raw'))
    commands = ([str(qemu_img), 'create', '-f', 'qcow2', str(base), str(SIZE)],
                [str(qemu_img), 'snapshot', '-c', 'base', str(base)],
                [str(qemu_img), 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(base), str(cow)],
                [str(qemu_img), 'convert', '-f', 'qcow2', '-O', 'raw', str(cow), str(target)])
    for number, command in enumerate(commands):
        done = subprocess.run(command, capture_output=True, timeout=180, env=runtime_environment(case / ('prepare-%d' % number)))
        (case / ('prepare-%d.log' % number)).write_bytes(done.stdout + done.stderr)
        if done.returncode: raise ValueError('COW image preparation failed; evidence retained')
    if target.stat().st_size != SIZE or target.stat().st_nlink != 1: raise ValueError('Wrong virtual target size/links')
    if negative:
        # These nonzero sentinels make an accidental formatter write visible.
        marker = hashlib.sha256(case.name.encode('ascii')).digest() * 16
        with target.open('r+b') as image:
            for offset in (0, SIZE // 2, SIZE - 512): image.seek(offset); image.write(marker)
            image.flush(); os.fsync(image.fileno())
    return dict(target=target, base=base, cow=cow, blank_sha256=oracle.digest(target),
                base_sha256=oracle.digest(base), cow_sha256=oracle.digest(cow), marker=negative)

def accepts(receipt: dict, positive: bool, error: str | None = None) -> bool:
    common = (receipt.get('kind') == 'own-wim-host-case-v1' and receipt.get('fresh_cow') is True
              and receipt.get('physical_or_mounts_used') is False and type(receipt.get('returncode')) is int
              and receipt.get('stack_reserve_bytes', 0) >= 1024**2 and receipt.get('source_unchanged') is True and receipt.get('program_unchanged') is True
              and receipt.get('source_pin_matches') is True and receipt.get('program_pin_matches') is True
              and receipt.get('target_bytes') == SIZE and receipt.get('base_unchanged') is True
              and receipt.get('cow_unchanged') is True and receipt.get('timed_out') is False)
    if not common: return False
    if positive:
        peak = receipt.get('alloc_peak')
        return (receipt.get('returncode') == 0 and receipt.get('pass_marker') is True
                and receipt.get('host_complete') is True and receipt.get('target_unchanged') is False
                and type(peak) is int and 0 < peak < 16 * 1024**2)
    return (type(error) is str and receipt.get('returncode') != 0 and receipt.get('target_unchanged') is True
            and receipt.get('pass_marker') is False and receipt.get('expected_error') == error
            and receipt.get('error_marker') is True)

def invoke(spec: dict, program: Path, program_sha256: str, qemu_img: Path, case: Path, timeout: int = 900) -> dict:
    if type(timeout) is not int or not 1 <= timeout <= 3600: raise ValueError('Bounded blocking timeout required')
    source = oracle.owned(spec['source']); oracle.local(program)
    if not source.is_file() or not program.is_file() or oracle.digest(program) != pin(program_sha256):
        raise ValueError('Pinned existing own source and host executable required')
    if source.stat().st_size > MAX_FIXTURE: raise ValueError('Only small own generated fixtures')
    with oracle.readonly(source) as locked_source, oracle.readonly(program) as locked_program:
        before = oracle.digest_stream(locked_source); before_program = oracle.digest_stream(locked_program)
        if before != pin(spec['source_sha256']) or before_program != program_sha256: raise ValueError('Pin mismatch before target creation')
        stack = pe_stack(program)
        ready = prepare(case, qemu_img, not spec['positive'])
        command = [str(program.resolve()), str(ready['target']), 'gpt', str(source), str(spec['index']), '--image-only', '--workspace', str(oracle.RUNTIME)]
        refs = {name: dict(path=str(path), sha256=oracle.digest(path)) for name, path in spec.get('oracle', {}).items()}
        oracle.save(case / 'inputs.json', dict(command=command, program_sha256=program_sha256, stack_reserve_bytes=stack,
                    source_sha256=before, index=spec['index'], target_bytes=SIZE, fresh_cow=True, negative_target_markers=ready['marker'],
                    oracle=refs, expected_error=spec.get('error'), expected_positive=spec['positive']))
        start = time.monotonic(); timed_out = False
        try:
            done = subprocess.run(command, capture_output=True, timeout=timeout, env=runtime_environment(case / 'program-runtime'))
            stdout, stderr, code = done.stdout, done.stderr, done.returncode
        except subprocess.TimeoutExpired as exc:
            timed_out = True; stdout, stderr, code = exc.stdout or b'', exc.stderr or b'', None
        (case / 'stdout.txt').write_bytes(stdout); (case / 'stderr.txt').write_bytes(stderr)
        logs = stdout + stderr
        after = oracle.digest_stream(locked_source); after_program = oracle.digest_stream(locked_program)
    peaks = [int(x) for x in re.findall(rb'alloc_peak=(\d+)', logs)]
    receipt = dict(kind='own-wim-host-case-v1', name=spec['name'], returncode=code, timed_out=timed_out,
                   elapsed_seconds=time.monotonic()-start, expected_positive=spec['positive'], expected_error=spec.get('error'),
                   source_sha256=after, source_unchanged=before == after, source_pin_matches=before == spec['source_sha256'],
                   program_sha256=after_program, program_unchanged=before_program == after_program,
                   program_pin_matches=before_program == program_sha256, stack_reserve_bytes=stack,
                   target=str(ready['target']), target_bytes=ready['target'].stat().st_size,
                   target_before_sha256=ready['blank_sha256'], target_sha256=oracle.digest(ready['target']),
                   base_unchanged=oracle.digest(ready['base']) == ready['base_sha256'],
                   cow_unchanged=oracle.digest(ready['cow']) == ready['cow_sha256'],
                   pass_marker=b'USOSPREP WIM PASS' in logs, host_complete=b'HOST WIM COMPLETE alloc_current=0' in logs,
                   error_marker=bool(spec.get('error')) and re.search(rb'\b'+str(spec.get('error')).encode('ascii')+rb'\b',logs) is not None,
                   alloc_peak=max(peaks, default=0), fresh_cow=True, physical_or_mounts_used=False,
                   oracle={name:str(path) for name,path in spec.get('oracle',{}).items()}, independent_windows_gate_not_yet_run=spec['positive'])
    receipt['target_unchanged'] = receipt['target_before_sha256'] == receipt['target_sha256']
    receipt['pass'] = accepts(receipt,spec['positive'],spec.get('error'))
    receipt['log_sha256'] = {name:oracle.digest(case/name) for name in ('stdout.txt','stderr.txt')}
    oracle.save(case/'result.json',receipt)
    return receipt

def run(fixtures: Path, fixtures_sha256: str, out: Path, program: Path, program_sha256: str, qemu_img: Path) -> dict:
    oracle.owned(fixtures); oracle.owned(out); oracle.local(program); oracle.local(qemu_img)
    if out.exists(): raise ValueError('New immutable batch directory required')
    if oracle.digest(fixtures) != pin(fixtures_sha256) or oracle.digest(program) != pin(program_sha256): raise ValueError('Batch input pin mismatch')
    stack = pe_stack(program)
    with oracle.readonly(fixtures) as locked_fixtures:
        if oracle.digest_stream(locked_fixtures) != fixtures_sha256: raise ValueError('Fixture pin changed')
        locked_fixtures.seek(0); manifest = json.load(locked_fixtures)
        if oracle.digest_stream(locked_fixtures) != fixtures_sha256: raise ValueError('Fixture changed while reading')
    specs = plan(manifest)
    oracle.storage_guard(3 * SIZE + 16 * 1024**2 if manifest.get('profile') == 'ads' else 4 * SIZE * (len(specs)+1)); out.mkdir(parents=True)
    large_proofs = {}
    ads_proofs = {}
    if manifest.get('profile') == 'large':
        for spec in specs:
            large_proofs[spec['name']] = verify_large_tree(spec['oracle']['tree'])
    elif manifest.get('profile') == 'ads':
        for spec in specs:
            ads_proofs[spec['name']] = verify_ads_tree(spec['oracle']['tree'])
    else:
        original = specs[0]
        derived = out/'corrupt-source'/'install.wim'
        detail = mutation(original['source'],original['source_sha256'],derived)
        specs.append(dict(name='refuse-resource-sha1',source=derived,source_sha256=detail['derived_sha256'],index=1,positive=False,error='WimHashMismatch'))
    results=[]
    for spec in specs:
        result=invoke(spec,program,program_sha256,qemu_img,out/spec['name'])
        results.append(dict(name=spec['name'],positive=spec['positive'],pass_core=result['pass'],result=str(out/spec['name']/'result.json')))
        # Completion evidence, never a progress/status query of a live child.
        print(json.dumps(results[-1]),flush=True)
    summary=dict(kind='own-wim-host-batch-v1',fixtures_sha256=fixtures_sha256,program_sha256=program_sha256,
                 workload_profile=manifest.get('profile','smoke'), large_workload_proofs=large_proofs, ads_proofs=ads_proofs,
                 stack_reserve_bytes=stack,positive_count=sum(x['positive'] for x in results),negative_count=sum(not x['positive'] for x in results),
                 cases=results,pass_core=all(x['pass_core'] for x in results),independent_windows_gates_pending=True,
                 physical_or_mounts_used=False,no_cleanup_performed=True)
    oracle.save(out/'summary.json',summary);return summary

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures',type=Path,required=True);parser.add_argument('--fixtures-sha256',required=True)
    parser.add_argument('--out',type=Path,required=True);parser.add_argument('--program',type=Path,required=True)
    parser.add_argument('--program-sha256',required=True);parser.add_argument('--qemu-img',type=Path,required=True)
    args=parser.parse_args();result=run(args.fixtures,args.fixtures_sha256,args.out,args.program,args.program_sha256,args.qemu_img)
    print(json.dumps(result,indent=2));raise SystemExit(0 if result['pass_core'] else 1)
