#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real hardlink-alias refusal, without formatting or deleting any image.

Both source and outputs are our small ISO fixture. A single-link destination
passes the hardlink guard and fails the size guard; the hardlink destination
must fail earlier, with LinkedTargetNotAllowed. Preserve every input/log.
Run through logged_run.py for clean-tree evidence and bounded CPU priority.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

import optical_fixtures

REPO = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', type=Path, required=True)
    args = parser.parse_args()
    exe = args.exe.resolve(strict=True)
    if not exe.is_file():
        raise ValueError('Regular optical executable required')
    runtime = REPO / 'runtime'
    runtime.mkdir(exist_ok=True)
    if any(path.is_symlink() or path.is_junction() for path in (runtime, *runtime.parents)):
        raise ValueError('Runtime must be an owned local directory')
    output = runtime / ('optical-target-guard-' + str(uuid.uuid4()))
    output.mkdir()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
    dirty = len(subprocess.check_output(['git', 'status', '--porcelain=v1', '-uall'], cwd=REPO, text=True).splitlines())
    label = f'HEAD {head}\nWORKTREE_DIRTY {dirty}\n'
    source = output / 'own-source.iso'
    source.write_bytes(optical_fixtures.iso9660())
    linked = output / 'alias.raw'
    linked.hardlink_to(source)
    separate = output / 'separate.raw'
    separate.write_bytes(source.read_bytes())
    if source.stat().st_nlink != 2 or separate.stat().st_nlink != 1:
        raise ValueError('This test requires native hardlink counts')
    initial = {str(path.name): dict(bytes=path.stat().st_size, sha256=digest(path))
               for path in (source, linked, separate)}
    results = []
    for mode in ('pack-ntfs', 'apply'):
        for target, expected in ((linked, 'LinkedTargetNotAllowed'), (separate, 'InvalidArgument')):
            command = [str(exe), mode, str(source), str(target)]
            if mode == 'apply':
                command.append('1')
            command.extend(['--image-only', str(output)])
            result = subprocess.run(command, capture_output=True, timeout=60)
            text = (result.stdout + result.stderr).decode('utf8')
            log = output / (mode + '-' + target.stem + '.log')
            log.write_text(label + text + f'\nEXIT {result.returncode}\n', encoding='utf8')
            if result.returncode == 0 or ('error: ' + expected) not in text:
                raise ValueError(f'{mode}/{target.name}: expected {expected}')
            if any(path.stat().st_size != initial[path.name]['bytes'] or digest(path) != initial[path.name]['sha256']
                   for path in (source, linked, separate)):
                raise ValueError('Guard modified source or destination')
            results.append(dict(mode=mode, target=target.name, expected=expected,
                                exit=result.returncode, unchanged=True, log=log.name))
    receipt = dict(passed=True, head=head, dirty=dirty, exe_sha256=digest(exe),
                   sources=initial, results=results, deleted=[])
    (output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf8')
    print(json.dumps(dict(passed=True, result=str(output / 'result.json'))))


if __name__ == '__main__':
    main()
