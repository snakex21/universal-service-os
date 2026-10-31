#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fresh COW-derived owned image, own Zig WIM apply, retained closed evidence."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parent))
import wim_oracle as oracle


def run(case, program, qemu_img, source, index, gib, mode):
    for p in (case, source): oracle.owned(p)
    for p in (program, qemu_img): oracle.local(p)
    if case.exists() or not program.is_file() or not qemu_img.is_file() or not source.is_file():
        raise ValueError('Explicit existing tools/source and new owned output required')
    if not 1 <= index <= 64 or not 1 <= gib <= 16 or mode not in ('gpt', 'mbr'):
        raise ValueError('Bounded explicit WIM image/index/mode required')
    size = gib * 1024**3
    oracle.storage_guard(size * 4)  # raw plus later RO copy and two VHDs
    case.mkdir(parents=True)
    base, cow, target = (case / n for n in ('blank-base.qcow2', 'test-cow.qcow2', 'target.raw'))
    commands = ([str(qemu_img), 'create', '-f', 'qcow2', str(base), str(size)],
                [str(qemu_img), 'snapshot', '-c', 'base', str(base)],
                [str(qemu_img), 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(base), str(cow)],
                [str(qemu_img), 'convert', '-f', 'qcow2', '-O', 'raw', str(cow), str(target)])
    for i, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, timeout=300)
        (case / ('prepare-%d.log' % i)).write_bytes(result.stdout + result.stderr)
        if result.returncode: raise RuntimeError('Fresh virtual image creation failed')
    command = [str(program.resolve()), str(target), mode, str(source), str(index), '--image-only', '--workspace', str(oracle.RUNTIME)]
    with oracle.readonly(source) as locked:
        before = oracle.digest_stream(locked)
        oracle.save(case / 'inputs.json', dict(command=command, program_sha256=oracle.digest(program),
                    source_sha256=before, index=index, target_bytes=size, blank_sha256=oracle.digest(target), fresh_cow=True))
        start = time.monotonic()
        result = subprocess.run(command, capture_output=True, timeout=14400, env=oracle.environment(case))
        (case / 'program.log').write_bytes(result.stdout + result.stderr)
        after = oracle.digest_stream(locked)
    outcome = dict(returncode=result.returncode, elapsed_seconds=time.monotonic()-start,
                   target=str(target), target_bytes=target.stat().st_size, target_sha256=oracle.digest(target),
                   source_sha256=after, source_unchanged=before == after, program_sha256=oracle.digest(program),
                   pass_core=result.returncode == 0 and before == after and b'USOSPREP WIM PASS' in result.stdout + result.stderr,
                   independent_windows_gate_not_yet_run=True)
    oracle.save(case / 'core-result.json', outcome)
    return outcome


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case', type=Path, required=True)
    p.add_argument('--program', type=Path, required=True)
    p.add_argument('--qemu-img', type=Path, required=True)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--index', type=int, required=True)
    p.add_argument('--gib', type=int, required=True)
    p.add_argument('--mode', choices=('gpt', 'mbr'), default='gpt')
    a = p.parse_args()
    result = run(a.case, a.program, a.qemu_img, a.source, a.index, a.gib, a.mode)
    print(json.dumps(result, indent=2)); raise SystemExit(0 if result['pass_core'] else 1)
