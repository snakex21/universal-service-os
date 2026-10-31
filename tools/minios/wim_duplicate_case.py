#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare duplicate-resource policy on own tiny WIMs; never Windows inputs."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import time
import wim_oracle as oracle
from logged_run import tree


def duplicate_lookup(raw: bytes, *, conflicting=False, relocated=False, different_size=False) -> bytes:
    if len(raw) < 208 or raw[:8] != b'MSWIM\0\0\0':
        raise ValueError('Own complete WIM required')
    count = int.from_bytes(raw[48:55], 'little')
    start, size = struct.unpack_from('<QQ', raw, 56)
    if raw[55] & ~2 or count != size or not count or count % 50 or start + count > len(raw):
        raise ValueError('Bounded uncompressed lookup required')
    table = raw[start:start + count]
    candidates = [table[i:i+50] for i in range(0, count, 50) if not table[i+7] & 3]
    if not candidates: raise ValueError('Own data resource missing')
    extra = bytearray(candidates[0])
    result = bytearray(raw)
    if sum((conflicting, relocated, different_size)) > 1:
        raise ValueError('Choose exactly one duplicate variant')
    if conflicting or different_size:
        # Same declared hash, other bytes: the oracle must verify content,
        # not merely accept a directory listing. Never modify an input file.
        length = int.from_bytes(extra[16:24], 'little')
        if not 1 < length <= 65536: raise ValueError('Small own resource required')
        if different_size:
            length -= 1
        extra[:8] = length.to_bytes(8, 'little')
        struct.pack_into('<Q', extra, 8, len(result))
        struct.pack_into('<Q', extra, 16, length)
        result += b'\xff' * length
    elif relocated:
        stored = int.from_bytes(extra[:7], 'little')
        source_at = int.from_bytes(extra[8:16], 'little')
        if not 0 < stored <= 65536 or source_at > len(raw) or stored > len(raw) - source_at:
            raise ValueError('Small bounded own resource required')
        struct.pack_into('<Q', extra, 8, len(result))
        result += raw[source_at:source_at + stored]
    offset = len(result)
    table += extra
    result += table
    result[48:56] = len(table).to_bytes(8, 'little')
    result[55] = raw[55]
    struct.pack_into('<QQ', result, 56, offset, len(table))
    result[124:148] = bytes(24)  # no stale integrity table for the new fixture
    return bytes(result)


def capture_fixture(source: Path, out: Path, env: dict, revision: tuple[str, int]) -> dict:
    """Create one labelled log and its receipt once; preserve earlier evidence."""
    log_path=oracle.owned(out/'capture.txt')
    receipt_path=oracle.owned(out/'capture.json')
    image_path=oracle.owned(out/'original.wim')
    if any(path.exists() for path in (log_path,receipt_path,image_path)):
        raise FileExistsError('Capture requires new log, receipt and image paths')
    command=[str(oracle.VENDOR/'wimlib-imagex.exe'),'capture',str(source),str(image_path),
             'Own fixture','--compress=none','--threads=1']
    started=time.monotonic()
    with log_path.open('xb') as output:
        output.write(f'HEAD {revision[0]}\nWORKTREE_DIRTY {revision[1]}\n'.encode('ascii'))
        output.flush()
        result=subprocess.run(command,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,
                              cwd=out,env=env,timeout=60,check=False)
    receipt=dict(argv=command,exit=result.returncode,duration_seconds=time.monotonic()-started,
                 log=str(log_path),sha256=oracle.digest(log_path),head=revision[0],dirty=revision[1])
    oracle.save(receipt_path,receipt)
    if result.returncode:
        raise ValueError('Own fixture capture failed; log and receipt retained')
    return receipt


def run(out: Path, inspector: Path):
    oracle.owned(out); oracle.local(inspector)
    if out.exists() or not inspector.is_file(): raise ValueError('New owned case required')
    oracle.storage_guard(16 * 1024**2); pins = oracle.tool_pins()
    program_sha256 = oracle.digest(inspector)
    repo = Path(__file__).resolve().parents[2]
    revision = tree(repo)
    log_header = f'HEAD {revision[0]}\nWORKTREE_DIRTY {revision[1]}\n'.encode('ascii')
    out.mkdir(); source=out/'own-source'; source.mkdir()
    (source/'hello.txt').write_bytes(b'own duplicate-resource policy fixture\n' * 31)
    env=oracle.environment(out)
    capture=capture_fixture(source,out,env,revision)
    raw=(out/'original.wim').read_bytes(); results=[]
    cases = [('original', raw), ('identical-duplicate', duplicate_lookup(raw)),
             ('relocated-identical-duplicate', duplicate_lookup(raw, relocated=True)),
             ('conflicting-duplicate', duplicate_lookup(raw, conflicting=True)),
             ('size-conflicting-duplicate', duplicate_lookup(raw, different_size=True))]
    for name, modified in cases:
        path=out/(name+'.wim')
        if name!='original':path.write_bytes(modified)
        native=subprocess.run([str(oracle.VENDOR/'wimlib-imagex.exe'),'verify',str(path)],capture_output=True,timeout=60,env=env)
        (out/(name+'-wimlib.log')).write_bytes(log_header+native.stdout+native.stderr)
        own=subprocess.run([str(inspector),str(path),'1','--verify'],capture_output=True,timeout=60,env=env)
        (out/(name+'-own.log')).write_bytes(log_header+own.stdout+own.stderr)
        results.append(dict(case=name,sha256=oracle.digest(path),wimlib_exit=native.returncode,own_exit=own.returncode,
                            wimlib_log_sha256=oracle.digest(out/(name+'-wimlib.log')),
                            own_log_sha256=oracle.digest(out/(name+'-own.log')),
                            own_hash_or_conflict_refusal=any(error in own.stdout+own.stderr for error in (b'WimHashMismatch',b'ConflictingResourceHash'))))
    unchanged = oracle.digest(inspector) == program_sha256
    after_revision = tree(repo)
    clean_unchanged = revision == after_revision and revision[1] == 0
    result=dict(schema='minios-duplicate-resource-policy-v3',oracle=pins,cases=results,own_payload_only=True,
                inspector_sha256=program_sha256, inspector_unchanged=unchanged,
                capture=capture,
                head=revision[0], dirty=revision[1], clean_tree_unchanged=clean_unchanged,
                passed=unchanged and clean_unchanged and all(r['own_exit']==0 and r['wimlib_exit']==0 for r in results[:3])
                and all(r['own_exit']!=0 and r['own_hash_or_conflict_refusal'] for r in results[3:]))
    oracle.save(out/'result.json',result);return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--inspector',type=Path,required=True)
    a=p.parse_args();r=run(a.out,a.inspector);print(json.dumps(r));raise SystemExit(0 if r['passed'] else 1)
