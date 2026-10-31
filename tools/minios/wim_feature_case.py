#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the final own NTFS-feature program on an owned, newly created COW image.

No physical devices, existing NTFS targets, mounts or progress queries here.
The independent read-only Windows oracle is a subsequent, separately pinned step.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import wim_oracle as oracle

SIZE = 256 * 1024**2


def run(case: Path, program: Path, qemu_img: Path, mode: str) -> dict:
    oracle.owned(case)
    oracle.local(program); oracle.local(qemu_img)
    if mode not in ('gpt', 'mbr') or case.exists() or not program.is_file() or not qemu_img.is_file():
        raise ValueError('New owned case, existing explicit tools and gpt/mbr required')
    oracle.storage_guard(4 * SIZE)
    case.mkdir(parents=True)
    base, overlay, target = (case / n for n in ('blank-base.qcow2', 'test-cow.qcow2', 'target.raw'))
    commands = ([str(qemu_img), 'create', '-f', 'qcow2', str(base), str(SIZE)],
                [str(qemu_img), 'snapshot', '-c', 'base', str(base)],
                [str(qemu_img), 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(base), str(overlay)],
                [str(qemu_img), 'convert', '-f', 'qcow2', '-O', 'raw', str(overlay), str(target)])
    for i, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, timeout=180)
        (case / ('prepare-%d.log' % i)).write_bytes(result.stdout + result.stderr)
        if result.returncode: raise RuntimeError('Virtual image preparation failed; evidence retained')
    before = oracle.digest(target)
    command = [str(program.resolve()), str(target), mode, '--image-only', '--workspace', str(oracle.RUNTIME)]
    oracle.save(case / 'inputs.json', dict(command=command, program_sha256=oracle.digest(program),
                                         target_size=SIZE, blank_sha256=before, fresh_cow=True))
    start = time.monotonic()
    result = subprocess.run(command, capture_output=True, timeout=3600)
    (case / 'program.log').write_bytes(result.stdout + result.stderr)
    receipt = dict(returncode=result.returncode, elapsed_seconds=time.monotonic()-start,
                   target=str(target), target_bytes=target.stat().st_size, target_sha256=oracle.digest(target),
                   program_sha256=oracle.digest(program), fresh_format=True,
                   pass_core=result.returncode == 0 and b'HOST NTFS_FEATURES PASS' in result.stdout+result.stderr,
                   independent_windows_gate_not_yet_run=True)
    oracle.save(case / 'core-result.json', receipt)
    return receipt


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case', type=Path, required=True)
    p.add_argument('--program', type=Path, required=True)
    p.add_argument('--qemu-img', type=Path, required=True)
    p.add_argument('--mode', choices=('gpt', 'mbr'), default='gpt')
    a = p.parse_args()
    outcome = run(a.case, a.program, a.qemu_img, a.mode)
    print(json.dumps(outcome, indent=2))
    raise SystemExit(0 if outcome['pass_core'] else 1)
