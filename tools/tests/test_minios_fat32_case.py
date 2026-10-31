#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Small clean-tree FAT32 gate, retained own images and no physical devices."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'minios'))
import logged_run
import wim_oracle as oracle
import wim_pool as pool
from test_minios_fat32 import expected_fixture, verify, guarded_image

REPO = Path(__file__).resolve().parents[2]
IMAGE_BYTES = 302 * 1024 * 1024
UNMOUNTABLE_ATTRIBUTES = 0x200 | 0x800 | 0x4000  # SparseFile, Compressed, Encrypted


def normal_copy(source, destination):
    """New ordinary file, never change the sparse state of the QEMU output."""
    source = guarded_image(source)
    destination = Path(destination)
    if (not destination.is_absolute() or destination.parent != source.parent
            or destination.exists() or destination == source):
        raise ValueError('Fresh same-owned-directory destination required')
    before = source.stat()
    digest = oracle.digest(source)
    with source.open('rb') as reader, destination.open('xb') as writer:
        while block := reader.read(1024 * 1024):
            writer.write(block)
        writer.flush()
        os.fsync(writer.fileno())
    after = source.stat()
    clone = destination.stat()
    if (after.st_size != before.st_size or clone.st_size != before.st_size
            or getattr(after, 'st_file_attributes', 0) != getattr(before, 'st_file_attributes', 0)
            or oracle.digest(source) != digest or oracle.digest(destination) != digest):
        raise ValueError('Ordinary VHD clone or unchanged source SHA/attributes differs')
    if getattr(clone, 'st_file_attributes', 0) & UNMOUNTABLE_ATTRIBUTES:
        raise ValueError('Ordinary VHD clone has unsupported host attributes')
    return dict(bytes=clone.st_size, sha256=digest,
                source_attributes=getattr(after, 'st_file_attributes', 0),
                destination_attributes=getattr(clone, 'st_file_attributes', 0),
                source_unchanged=True, copy_method='ordinary streamed create-new/write/fsync')


def execute(command, log, env, head):
    if logged_run.tree(REPO) != (head, 0):
        raise ValueError('F3: clean frozen HEAD required before each FAT gate')
    with log.open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(f'HEAD {head}\nWORKTREE_DIRTY 0\nCOMMAND {json.dumps(list(map(str, command)))}\n')
        stream.flush()
        result = subprocess.run(list(map(str, command)), cwd=REPO, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=900)
        stream.write(f'EXIT {result.returncode}\n')
    if result.returncode:
        raise ValueError(f'Gate failed; image/evidence retained: {log}')
    if logged_run.tree(REPO) != (head, 0):
        raise ValueError('F3: tree changed during FAT gate')


def run(args):
    oracle.owned(args.out)
    oracle.local(args.exe)
    oracle.local(args.qemu_img)
    oracle.local(args.pwsh)
    capacity = pool.enforce(args.plan, args.out)
    head, dirty = logged_run.tree(REPO)
    if dirty or args.out.exists():
        raise ValueError('Fresh owned output and clean tree required')
    args.out.mkdir(parents=True)
    env = oracle.environment(args.out)
    result = dict(kind='minios-fat32-small', passed=False, head=head, worktree_dirty=0,
                  program_sha256=oracle.digest(args.exe), capacity_preflight=capacity,
                  physical_disks=False, retained_until_user_acceptance=True, cases=[])
    oracle.save(args.out / 'expected-files.json', expected_fixture())
    for sector in (512, 4096):
        raw = args.out / f'fat32-{sector}.raw'
        with raw.open('xb') as stream:
            stream.truncate(IMAGE_BYTES)
        execute([args.exe, raw, sector, '--image-only', args.out], args.out / f'fixture-{sector}.log', env, head)
        proof = verify(raw, sector)
        oracle.save(args.out / f'python-{sector}.json', proof)
        result['cases'].append(proof)
    raw = args.out / 'fat32-512.raw'
    intermediate = args.out / 'fat32-512-qemu.vhd'
    vhd = args.out / 'fat32-512.vhd'
    execute([args.qemu_img, 'convert', '-f', 'raw', '-O', 'vpc', '-o',
             'subformat=dynamic,force_size=on', raw, intermediate], args.out / 'vhd-create.log', env, head)
    # Both raw fixtures plus both VHD containers and64MiB small-evidence
    # allowance must fit the explicitly coordinated1GiB whole-case budget.
    if 2 * IMAGE_BYTES + 2 * intermediate.stat().st_size + 64 * 1024 * 1024 > 1024**3:
        raise ValueError('Ordinary VHD copy would exceed the1GiB FAT case reservation')
    result['ordinary_vhd_copy'] = normal_copy(intermediate, vhd)
    os.chmod(vhd, stat.S_IREAD)
    execute([args.pwsh, '-NoProfile', '-File', REPO / 'tools/tests/test_minios_fat32_chkdsk.ps1',
             '-Workspace', args.out, '-Vhd', vhd, '-ExpectedImageBytes', IMAGE_BYTES,
             '-ExpectedVhdSha256', oracle.digest(vhd), '-PartitionNumber', 1,
             '-ExpectedPartitionStart', 1024 * 1024, '-ExpectedPartitionBytes', 300 * 1024 * 1024,
             '-ExpectedSectorBytes', 512, '-Out', args.out / 'native-512'],
            args.out / 'native-512.log', env, head)
    native = json.loads((args.out / 'native-512/result.json').read_text(encoding='utf-8'))
    if native.get('passed') is not True or native.get('chkdsk_exit') != 0:
        raise ValueError('Native read-only FAT32 chkdsk gate failed')
    if logged_run.tree(REPO) != (head, 0):
        raise ValueError('F3: tree changed before proof seal')
    result.update(passed=True, native_chkdsk=native,
                  native_4kn='not attempted: ordinary VHD exposes512-byte logical sectors',
                  retained=[dict(path=str(path.relative_to(args.out)), bytes=path.stat().st_size,
                                 sha256=oracle.digest(path)) for path in (raw, args.out / 'fat32-4096.raw', intermediate, vhd)])
    oracle.save(args.out / 'result.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--qemu-img', type=Path, required=True)
    parser.add_argument('--pwsh', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args)))
