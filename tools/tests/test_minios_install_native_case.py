#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Retained32MiB normalization/independent-VHD proof; never mounts an image."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'minios'))
import install_native as native
import logged_run
import wim_oracle as oracle
import wim_pool as pool

REPO = Path(__file__).resolve().parents[2]
SIZE = 32 * 1024**2


def execute(command, log, env, head):
    with log.open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(f'HEAD {head}\nWORKTREE_DIRTY 0\nCOMMAND {json.dumps(list(map(str, command)))}\n')
        stream.flush()
        result = subprocess.run(list(map(str, command)), cwd=REPO, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=120)
        stream.write(f'EXIT {result.returncode}\n')
    if result.returncode or logged_run.tree(REPO) != (head, 0):
        raise ValueError(f'QEMU format oracle or clean-tree guard failed: {log}')


def run(args):
    oracle.owned(args.out)
    oracle.local(args.qemu_img)
    capacity = pool.enforce(args.plan, args.out)
    head, dirty = logged_run.tree(REPO)
    if dirty or args.out.exists():
        raise ValueError('New output and clean frozen HEAD required')
    args.out.mkdir(parents=True)
    env = oracle.environment(args.out)
    raw, vhd = args.out / 'known.raw', args.out / 'fresh-export.vhd'
    with raw.open('xb') as stream:
        stream.truncate(SIZE)
        for index, (offset, size) in enumerate([(0, 1024), (12345, 41), (2 * 1024**2 + 511, 4097), (SIZE - 600, 600)]):
            stream.seek(offset)
            stream.write(bytes((position * 17 + 23 + index) % 256 for position in range(size)))
    raw_sha = oracle.digest(raw)
    os.chmod(raw, stat.S_IREAD)
    with oracle.readonly(raw):
        execute([args.qemu_img, 'convert', '-f', 'raw', '-O', 'vpc', '-o',
                 'subformat=dynamic,force_size=on', raw, vhd], args.out / 'convert.log', env, head)
        vhd_sha = oracle.digest(vhd)
        proof = native.normalize_fresh_vhd(vhd, args.out, vhd_sha, vhd.stat().st_size)
        execute([args.qemu_img, 'compare', '-f', 'raw', '-F', 'vpc', raw, vhd], args.out / 'qemu-compare.log', env, head)
        reader = native.DynamicVhd(vhd)
        try:
            digest = hashlib.sha256()
            while reader.position < reader.size:
                digest.update(reader.read(min(65536, reader.size - reader.position)))
            if reader.size != SIZE or digest.hexdigest() != raw_sha:
                raise ValueError('Independent VHD full logical stream differs from known raw bytes')
        finally:
            reader.close()
        # The exclusive normalizer must fail while a read lock exists; it may
        # not clear attributes through some other, less guarded handle.
        with oracle.readonly(vhd):
            try:
                native.normalize_fresh_vhd(vhd, args.out, vhd_sha, vhd.stat().st_size)
            except OSError:
                pass
            else:
                raise ValueError('Normalizer bypassed exclusive-handle guard')
        if oracle.digest(raw) != raw_sha or oracle.digest(vhd) != vhd_sha:
            raise ValueError('A retained source changed after guarded normalization')
    os.chmod(vhd, stat.S_IREAD)
    if logged_run.tree(REPO) != (head, 0):
        raise ValueError('Tree changed during normalization proof')
    result = dict(kind='fresh-vhd-normalization-and-independent-read', passed=True, head=head, dirty=0,
                  capacity_preflight=capacity, normalized=proof, qemu_compare_exit=0,
                  full_logical_sha256=raw_sha, logical_bytes=SIZE, exclusive_guard_pass=True,
                  mounted=False, deleted=False,
                  retained=[dict(path=path.name, bytes=path.stat().st_size, sha256=oracle.digest(path)) for path in (raw, vhd)])
    oracle.save(args.out / 'result.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--qemu-img', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args)))
