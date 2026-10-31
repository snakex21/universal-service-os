#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Small own-data positive smoke through the real firmware install harness.

Retains every artifact. Uses the existing128MiB host pack guard, independent
7-Zip manifest, accepted own wimlib fixture and unchanged firmware case runner.
There are no Windows payloads, native mounts or physical disks in this smoke.
"""
import argparse
import json
from pathlib import Path
import stat
from types import SimpleNamespace

import logged_run
import optical_e2e
import optical_fixtures as fixtures
import optical_oracle
import install_firmware_case
import wim_firmware_case
import wim_oracle as oracle
import wim_pool as pool

REPO = Path(__file__).resolve().parents[2]
MiB = 1024**2


def own_wim_iso(payload):
    """Extend our ISO9660 fixture with one bounded synthetic WIM file."""
    if not 208 <= len(payload) <= 8 * MiB or payload[:8] != b'MSWIM\0\0\0':
        raise ValueError('Bounded explicit own WIM bytes required')
    blocks = max(320, 28 + (len(payload) + 2047) // 2048)
    image = bytearray(fixtures.iso9660())
    image.extend(bytes(blocks * 2048 - len(image)))
    fixtures.both(image, 16 * 2048 + 80, 'I', blocks)
    # Replace the Sources directory and old data; directory self/parent and
    # installation filename follow the same existing self-authored fixture.
    image[25 * 2048:] = bytes(len(image) - 25 * 2048)
    records = (fixtures.iso_record(25, 2048, True, b'\0')
               + fixtures.iso_record(24, 2048, True, b'\1')
               + fixtures.iso_record(28, len(payload), False, b'INSTALL.WIM;1'))
    image[25 * 2048:25 * 2048 + len(records)] = records
    image[28 * 2048:28 * 2048 + len(payload)] = payload
    return bytes(image)


def run(args):
    oracle.owned(args.out)
    oracle.owned(args.fixture)
    if (args.out.exists() or not args.out.is_relative_to(oracle.RUNTIME / '1c23' / 'fixtures')
            or not args.fixture.is_relative_to(oracle.RUNTIME / 'synthetic')):
        raise ValueError('Fresh reserved smoke scope and existing own synthetic fixture required')
    for path in (args.optical, args.firmware, args.qemu_dir, args.sevenzip):
        oracle.local(path)
    head, dirty = logged_run.tree(REPO)
    if dirty:
        raise ValueError('F3: clean frozen smoke HEAD required')
    capacity = pool.enforce(args.plan, args.out)
    fixture, image = wim_firmware_case.selected_fixture(args.fixture, 1)
    if fixture['bytes'] > 8 * MiB:
        raise ValueError('Smoke WIM exceeds the agreed small-image budget')
    args.out.mkdir(parents=True)
    env = oracle.environment(args.out)
    archive = Path(fixture['wim'])
    with oracle.readonly(archive) as stream:
        if oracle.digest_stream(stream) != fixture['sha256']:
            raise ValueError('Own WIM fixture changed')
        stream.seek(0)
        iso = args.out / 'own-install.iso'
        with iso.open('xb') as output:
            output.write(own_wim_iso(stream.read()))
    iso.chmod(stat.S_IREAD)
    with oracle.readonly(iso):
        iso_result = optical_oracle.compare(iso, args.optical, args.sevenzip, args.out / 'iso-oracle')
        if not iso_result['passed']:
            raise ValueError('Own ISO independent7-Zip comparison failed')
        pack = args.out / 'pack'
        pack.mkdir()
        # No smaller-size override of an integration CLI. The host formatter
        # itself explicitly accepts128MiB ordinary images; reuse its existing
        # blank/source proof and independent packed-ISO verification routines.
        raw, base, base_sha = optical_e2e.blank(pack, 128 * MiB, args.qemu_dir / 'qemu-img.exe', env)
        optical_e2e.execute([args.optical, 'pack-ntfs', iso, raw, '--image-only', oracle.RUNTIME],
                            pack / 'program.log', env)
        pack_args = SimpleNamespace(action='pack', out=pack, source=iso, exe=args.optical,
                                    iso_proof=args.out / 'iso-oracle' / 'result.json', plan=args.plan)
        expected = dict(iso_proof_sha256=oracle.digest(pack_args.iso_proof),
                        expected_iso_tree_sha256=oracle.digest(args.out / 'iso-oracle' / 'expected.jsonl'))
        pack_result = optical_e2e.finish_locked(pack_args, head, env, oracle.digest(iso), oracle.digest(args.optical),
                                               raw, base, base_sha, expected)
        oracle.save(pack / 'result.json', pack_result)
    guest_args = SimpleNamespace(out=args.out / 'firmware', source=raw, pack_proof=pack / 'result.json',
                                 program=args.firmware, qemu_dir=args.qemu_dir, plan=args.plan,
                                 arch='x86_64', target_gib=16, memory=128, timeout=900, index=1,
                                 expected_tree=Path(image['tree']), expected_security=Path(image['security']),
                                 iso_proof=args.out / 'iso-oracle' / 'result.json')
    guest = install_firmware_case.run(guest_args)
    retained = [dict(path=str(path.relative_to(args.out)), bytes=path.stat().st_size,
                     sha256=oracle.digest(path)) for path in sorted(args.out.rglob('*')) if path.is_file()]
    total = sum(row['bytes'] for row in retained)
    passed = guest['passed'] and guest['source_unchanged'] and total <= 400 * MiB
    result = dict(schema='minios-install-own-smoke-v1', passed=passed, head=head, worktree_dirty=0,
                  capacity_preflight=capacity, own_generated_data=True, contains_windows_data=False,
                  native_mount_used=False, physical_disks_opened=False, deleted=[],
                  fixture_sha256=oracle.digest(args.fixture), wim_sha256=fixture['sha256'],
                  independent_iso_oracle=iso_result['passed'], ntfs_manifest_verified=pack_result['ntfs_manifest_verified'],
                  guest_receipt_sha256=oracle.digest(guest_args.out / 'result.json'), guest=guest,
                  retained_bytes=total, budget_bytes=400 * MiB, retained=retained)
    if logged_run.tree(REPO) != (head, 0):
        raise ValueError('F3: tree changed during own-data smoke')
    oracle.save(args.out / 'result.json', result)
    if not passed:
        raise ValueError('Positive firmware smoke failed; retained all evidence')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('fixture', 'optical', 'firmware', 'qemu-dir', 'sevenzip', 'out', 'plan'):
        parser.add_argument('--' + name, type=Path, required=True)
    print(json.dumps(run(parser.parse_args())))
