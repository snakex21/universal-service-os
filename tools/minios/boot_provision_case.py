#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Closed UEFI boot-files gate; accepted native/bcdboot proofs precede images.

Reads the accepted dynamic VHD only for actual GPT identities/BPB. QEMU uses
a small overlay over the immutable prepared QCOW2; no full disk export, mount,
physical storage API, first Windows boot, cleanup or progress polling.
"""
from __future__ import annotations
import argparse
import asyncio
import contextlib
import json
from pathlib import Path
import re
import secrets
import stat
import struct
import subprocess
import time
import uuid

import bcd_policy
import bcd_compare
import bcdboot_reference as reference
import install_firmware_case as firmware_case
import install_native as native
import logged_run
import wim_firmware_case as firmware
import wim_oracle as oracle
import wim_pool as pool
import bootfiles_bounds as review_bounds
import bootfiles_output as review_scope

REPO = Path(__file__).resolve().parents[2]
MiB = 1024**2
SHA = re.compile(r'^[0-9a-f]{64}$')
HEAD = re.compile(r'^[0-9a-f]{40}$')
MAX_OVERLAY = 128 * MiB
MAX_NEW_BYTES = 208 * MiB


def output_guard(out, arch):
    out = oracle.owned(out)
    scope = oracle.RUNTIME / '1c23' / ('qemu-x64' if arch == 'x86_64' else 'qemu-ia32')
    if arch not in ('x86_64', 'ia32') or out == scope or not out.is_relative_to(scope) or not out.name.startswith('boot-') or out.exists():
        raise ValueError('Fresh boot-* output in the matching reserved QEMU scope required')
    return out


def receipt_fields(prep, proof, layout, ref, compare, pins):
    """Semantics before any image creation; pinned JSON alone is insufficient."""
    if (prep.get('schema') != 'minios-install-firmware-v1' or prep.get('passed') is not True
            or prep.get('qemu_only') is not True or prep.get('dirty') != 0
            or not HEAD.fullmatch(prep.get('head', '')) or prep.get('mode') != 'gpt'
            or prep.get('source_unchanged') is not True or prep.get('base_unchanged') is not True
            or prep.get('returncode') != 33 or type(prep.get('returncode')) is not int
            or prep.get('timed_out') is not False or prep.get('physical_disks_opened') is not False
            or prep.get('guest_completion_wait') is not True):
        raise ValueError('Genuine completed clean firmware preparation PASS required')
    if (proof.get('mode') != 'uefi' or layout.get('style') != 'GPT'
            or proof.get('virtual_bytes') != prep.get('target_bytes')
            or proof.get('source_sha256') != prep.get('target_sha256')):
        raise ValueError('Preparation/native layout or prepared QCOW2 pin differs')
    if bcd_policy.deferred(ref):
        own=dict(compare);own['_actual_sha256']=pins.get('compare')
        bcd_policy.validate(ref,own,pins['native'],pins['ours_bcd'],proof['mode'])
        return
    if (ref.get('schema') != 'minios-bcdboot-reference-v1' or ref.get('passed') is not True
            or ref.get('worktree_dirty') != 0 or ref.get('worktree_dirty_after') != 0
            or not HEAD.fullmatch(ref.get('head', '')) or ref.get('head_after') != ref.get('head')
            or ref.get('native_receipt_sha256') != pins['native']
            or ref.get('bcdboot_exit') != 0 or ref.get('bcdedit_exit') != 0
            or ref.get('physical_disk_touched') is not False
            or ref.get('host_firmware_entry_requested') is not False
            or ref.get('base_sha256_before') != proof.get('vhd_sha256')
            or ref.get('base_sha256_after') != proof.get('vhd_sha256')
            or ref.get('mode') != 'uefi' or ref.get('virtual_bytes') != proof.get('virtual_bytes')
            or ref.get('reference_sha256') != pins['reference_bcd']):
        raise ValueError('Guarded real bcdboot PASS for the exact native base required')
    if (compare.get('status') != 'PASS' or compare.get('core_differences') != {}
            or compare.get('dirty') != 0 or compare.get('after_dirty') != 0
            or not HEAD.fullmatch(compare.get('head', '')) or compare.get('after_head') != compare.get('head')
            or compare.get('source_sha256') != pins['ours_bcd']
            or compare.get('reference_sha256') != pins['reference_bcd']
            or compare.get('bcdboot_receipt_sha256') != pins['reference']
            or compare.get('ours_route') != compare.get('reference_route')):
        raise ValueError('Pinned clean semantic BCD comparison PASS required')


def route_for_layout(route, layout):
    rows = {row['number']: row for row in layout['partitions']}
    disk = uuid.UUID(layout['disk_guid']).bytes_le.hex()
    system = dict(style='GPT', disk_guid_le=disk, partition_guid_le=uuid.UUID(rows[1]['guid']).bytes_le.hex())
    windows = dict(style='GPT', disk_guid_le=disk, partition_guid_le=uuid.UUID(rows[3]['guid']).bytes_le.hex())
    if (route.get('system') != system or route.get('windows') != windows or route.get('osdevice') != windows
            or route.get('manager_path') != '\\efi\\microsoft\\boot\\bootmgfw.efi'
            or route.get('loader_path') != '\\windows\\system32\\winload.efi'
            or route.get('systemroot') != '\\windows' or route.get('winpe') is not False
            or route.get('manager_locale') != route.get('loader_locale')
            or not re.fullmatch(r'[a-z0-9-]{2,32}', route.get('loader_locale', ''))):
        raise ValueError('BCD route differs from actual GPT partitions, loader or locale')


def actual_ids(reader, layout, debug):
    if native.disk_layout(reader, 'uefi') != layout:
        raise ValueError('Actual readonly dynamic VHD GPT differs from accepted layout')
    rows = {row['number']: row for row in layout['partitions']}
    ids = dict(disk_guid=uuid.UUID(layout['disk_guid']).bytes_le.hex(),
               esp_guid=uuid.UUID(rows[1]['guid']).bytes_le.hex(),
               msr_guid=uuid.UUID(rows[2]['guid']).bytes_le.hex(),
               windows_guid=uuid.UUID(rows[3]['guid']).bytes_le.hex())
    for raw in ids.values():
        guid = uuid.UUID(bytes_le=bytes.fromhex(raw))
        if guid.version != 4 or guid.variant != uuid.RFC_4122:
            raise ValueError('Expected original random version4 layout GUIDs')
    reader.seek(rows[3]['start'])
    bpb = reader.read(512)
    if len(bpb) != 512 or bpb[3:11] != b'NTFS    ' or struct.unpack_from('<H', bpb, 11)[0] != 512:
        raise ValueError('Actual Windows NTFS BPB differs')
    ids['ntfs_serial'] = f'{struct.unpack_from("<Q", bpb, 72)[0]:016x}'
    if int(ids['ntfs_serial'], 16) == 0:
        raise ValueError('Actual Windows NTFS serial is missing')
    expression = (r'INSTALL layout_mode=uefi disk_guid=([0-9a-f]{32}) windows_guid=([0-9a-f]{32}) '
                  r'esp_guid=([0-9a-f]{32}) mbr_signature=([0-9a-f]+) windows_start=(\d+) windows_size=(\d+) '
                  r'system_start=(\d+) system_size=(\d+)')
    matches = re.findall(expression, debug)
    if len(matches) != 1:
        raise ValueError('One exact completed installation identity log required')
    disk, windows, esp, signature, ws, wb, ss, sb = matches[0]
    if (disk != ids['disk_guid'] or windows != ids['windows_guid'] or esp != ids['esp_guid']
            or int(signature, 16) == 0 or int(signature, 16) > 0xffffffff
            or (int(ws), int(wb)) != (rows[3]['start'], rows[3]['bytes'])
            or (int(ss), int(sb)) != (rows[1]['start'], rows[1]['bytes'])):
        raise ValueError('Preparation log identity differs from independently read GPT')
    ids['mbr_signature'] = signature
    return ids


def configuration(ids, loader, size, arch, locale, native_sha, compare_sha):
    fields = dict(target_bytes=str(size), **ids, loader_guid=loader.bytes_le.hex(),
                  layout_receipt_sha256=native_sha, bcd_receipt_sha256=compare_sha,
                  layout_gate='pass', bcd_gate='pass', arch='x64' if arch == 'x86_64' else 'ia32', locale=locale)
    result = ('USOSBOOT_QEMU_ONLY_V1\n' + ''.join(f'{key}={value}\n' for key, value in fields.items())).encode('ascii')
    if len(result) > 4096 or loader.version != 4 or loader.variant != uuid.RFC_4122 or loader.bytes_le.hex() in ids.values():
        raise ValueError('Fresh independent bounded boot identity required')
    return result


def accepted(args, locks):
    """Pins and readonly handles live until the QEMU process has completed."""
    pins, streams = {}, {}
    def lock(path, expected=None):
        path = native.regular(oracle.local(path))
        if path not in streams:
            streams[path] = locks.enter_context(oracle.readonly(path))
        if expected is not None:
            if not SHA.fullmatch(expected) or oracle.digest_stream(streams[path]) != expected:
                raise ValueError('Pinned accepted input changed')
            pins[path] = expected
        return path
    values = {}
    for name in ('prep', 'native', 'reference', 'compare'):
        path = oracle.owned(getattr(args, name + '_receipt'))
        expected = getattr(args, name + '_sha256')
        lock(path)
        values[name] = reference.document(path, expected)
        pins[path] = expected
    if not isinstance(values['native'].get('vhd'), str):
        raise ValueError('Complete native receipt with accepted VHD required')
    base = oracle.owned(Path(values['native']['vhd']))
    lock(base)
    proof, layout, native_pins = reference.accepted(args.native_receipt, args.native_sha256)
    for path, pin in native_pins.items():
        if path != base:
            lock(path, pin)
        else:
            pins[path] = pin  # accepted() just hashed it under our readonly lock.
    for name in ('ours_bcd', 'reference_bcd'):
        lock(oracle.owned(getattr(args, name)), getattr(args, name + '_sha256'))
    pin_names = dict(native=args.native_sha256, reference=args.reference_sha256,
                     ours_bcd=args.ours_bcd_sha256, reference_bcd=args.reference_bcd_sha256,compare=args.compare_sha256)
    receipt_fields(values['prep'], proof, layout, values['reference'], values['compare'], pin_names)
    if bcd_policy.deferred(values['reference']):
        bcd_policy.validate_files(values['reference'],values['compare'],args.native_sha256,
            args.ours_bcd_sha256,proof['mode'],args.compare_receipt)
    else:
        job_path = oracle.owned(args.reference_receipt.parent / 'job.json')
        job_sha = values['reference'].get('job_sha256')
        if not isinstance(job_sha, str) or not SHA.fullmatch(job_sha):
            raise ValueError('Pinned guarded bcdboot job required')
        lock(job_path)
        job = reference.document(job_path, job_sha)
        if (job.get('schema') != 'minios-bcdboot-reference-job-v1'
                or job.get('native_receipt') != str(args.native_receipt)
                or job.get('native_receipt_sha256') != args.native_sha256
                or job.get('base') != str(base) or job.get('base_sha256') != proof['vhd_sha256']
                or job.get('layout_sha256') != proof['layout_sha256']
                or job.get('mode') != 'uefi' or job.get('virtual_bytes') != proof['virtual_bytes']):
            raise ValueError('Guarded bcdboot job belongs to another accepted disk')
        pins[job_path] = job_sha
    target = oracle.owned(Path(values['prep']['target']))
    lock(target)
    chain = native.qcow_chain(target, proof['virtual_bytes'])
    expected_chain = {}
    for row in proof['source_backing_chain']:
        relative = Path(row['path'])
        if relative.is_absolute() or relative.drive or '..' in relative.parts or any(c in str(relative) for c in ':,\r\n\0'):
            raise ValueError('Unsafe accepted QCOW2 chain name')
        path = oracle.owned(oracle.RUNTIME / relative)
        if path in expected_chain or len(expected_chain) >= 16:
            raise ValueError('Duplicate or excessive accepted backing chain')
        expected_chain[path] = row['sha256']
    if set(chain) != set(expected_chain) or expected_chain.get(target) != values['prep']['target_sha256']:
        raise ValueError('Prepared QCOW2/backing chain differs from native acceptance')
    for path in chain:
        lock(path, expected_chain[path])
    debug_path = oracle.owned(args.prep_receipt.parent / 'debug.log')
    lock(debug_path)
    if debug_path.stat().st_size > 16 * MiB:
        raise ValueError('Preparation log exceeds bound')
    pins[debug_path] = oracle.digest_stream(streams[debug_path])
    reader = native.DynamicVhd(base, stream=streams[base])
    ids = actual_ids(reader, layout, debug_path.read_text(encoding='utf-8', errors='strict'))
    for name in (('ours_bcd',) if bcd_policy.deferred(values['reference']) else ('ours_bcd','reference_bcd')):
        route = bcd_compare.route(bcd_compare.oracle.independent_read(getattr(args, name)))
        if route != values['compare']['ours_route']:
            raise ValueError('Independently reread BCD differs from accepted semantic proof')
        route_for_layout(route, layout)
    if values['prep']['arch'] != args.arch:
        raise ValueError('Boot executable and accepted installation architecture differ')
    lock(args.program, args.program_sha256)
    return dict(reference_deferred=bcd_policy.deferred(values['reference']),prep=values['prep'], native=proof, layout=layout, ids=ids, target=target,
                locale=values['compare']['ours_route']['loader_locale'], pins=pins, streams=streams)


def guest_acceptance(code, timed_out, text):
    return (type(code) is int and code == 33 and not timed_out and ' FAIL' not in text
            and 'BOOT_UEFI PASS' in text and 'USOSBOOT FINAL' in text
            and 'STACK canary_ok=true' in text and 'USOSPREP PLATFORM' in text)


def capacity_preflight(args):
    # Historical one-case approvals are not reusable program policy.
    if getattr(args, 'approval', None) is not None or getattr(args, 'firstboot_receipt', None) is not None:
        raise ValueError('Historical capacity override is no longer supported')
    return pool.enforce_incremental(args.plan, args.out, MAX_NEW_BYTES, closed_scope=True)


def run(args):
    output_guard(args.out, args.arch)
    for path in (args.program, args.qemu_dir):
        oracle.local(path)
    if not args.program.is_file() or not 64 <= args.memory <= 512 or not 60 <= args.timeout <= 900:
        raise ValueError('Explicit firmware and bounded boot-file VM parameters required')
    head, dirty = logged_run.tree(REPO)
    if dirty:
        raise ValueError('F3: clean frozen HEAD required')
    with contextlib.ExitStack() as locks:
        inputs = accepted(args, locks)  # No output directory/image exists yet.
        capacity = capacity_preflight(args)
        firmware_case.configure_fixture_tools(args.out, args.qemu_dir)
        args.out.mkdir(parents=True)
        env = oracle.environment(args.out)
        scope = review_scope.Scope(args.out)
        loader = uuid.uuid4()
        cfg = configuration(inputs['ids'], loader, inputs['native']['virtual_bytes'], args.arch,
                            inputs['locale'], args.native_sha256, args.compare_sha256)
        receipt_data = {name: path.read_bytes() for name, path in (('USOSLAY.RCP', args.native_receipt), ('USOSBCD.RCP', args.compare_receipt))}
        utility = args.out / 'boot-base.raw'
        esp = firmware.SmallEsp(utility)
        esp.add('EFI/BOOT/' + ('BOOTX64.EFI' if args.arch == 'x86_64' else 'BOOTIA32.EFI'), args.program.stat().st_size, firmware.api.blocks(args.program))
        esp.add('USOSBOOT.CFG', len(cfg), [cfg])
        for name, data in receipt_data.items():
            esp.add(name, len(data), [data])
        esp.finish()
        utility.chmod(stat.S_IREAD)
        scope.save('USOSBOOT.CFG', cfg)
        qemu = args.qemu_dir / 'qemu-system-x86_64.exe'
        if utility.stat().st_size != review_bounds.UTILITY:
            raise ValueError('Bounded 65 MiB utility disk required')
        asyncio.run(review_bounds.create_bounded(qemu, args.out/'target.qcow2', review_bounds.TARGET,
                    inputs['native']['virtual_bytes'], inputs['target'], 'qcow2', env))
        asyncio.run(review_bounds.create_bounded(qemu, args.out/'boot.qcow2', review_bounds.BOOT,
                    review_bounds.UTILITY, utility, 'raw', env))
        utility_lock = locks.enter_context(oracle.readonly(utility))
        utility_sha = oracle.digest_stream(utility_lock)
        entropy = secrets.token_bytes(64)
        scope.save('entropy.bin', entropy)
        scope.save('vars.fd', (args.qemu_dir / 'share/edk2-i386-vars.fd').read_bytes())
        code = args.qemu_dir / ('share/edk2-x86_64-code.fd' if args.arch == 'x86_64' else 'share/edk2-i386-code.fd')
        command = [args.qemu_dir / ('qemu-system-x86_64.exe' if args.arch == 'x86_64' else 'qemu-system-i386.exe'),
                   '-machine', 'q35', '-accel', 'tcg,thread=multi', '-cpu', 'qemu64' if args.arch == 'x86_64' else 'qemu32',
                   '-smp', '1', '-m', str(args.memory), '-nodefaults', '-display', 'none', '-no-reboot', '-nic', 'none',
                   '-drive', f'if=pflash,format=raw,readonly=on,file={code}', '-drive', f'if=pflash,format=raw,file={args.out / "vars.fd"}',
                   '-fw_cfg', f'name=opt/usosprep-entropy,file={args.out / "entropy.bin"}',
                   *review_bounds.nodes(args.out/'boot.qcow2', 'boot', review_bounds.BOOT), '-device', 'ide-hd,drive=boot,bus=ide.0,bootindex=1',
                   *review_bounds.nodes(args.out/'target.qcow2', 'target', review_bounds.TARGET), '-device', 'ide-hd,drive=target,bus=ide.1',
                   '-device', 'VGA', '-serial', 'null', '-debugcon', 'stdio',
                   '-global', 'isa-debugcon.iobase=0xe9', '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04']
        started = time.monotonic()
        timed_out = False
        header = f'HEAD={head} DIRTY={dirty}\n'.encode('ascii')
        returncode = asyncio.run(review_bounds.run_qemu(command, args.out/'debug.log', args.out/'qemu.stderr', env,
                                                       args.timeout, header=header))
        text = (args.out / 'debug.log').read_text(encoding='utf-8', errors='replace')
        passed = guest_acceptance(returncode, timed_out, text)
        unchanged = all(oracle.digest_stream(inputs['streams'][path]) == pin for path, pin in inputs['pins'].items())
        unchanged = unchanged and oracle.digest_stream(utility_lock) == utility_sha
        bounded = (args.out / 'target.qcow2').stat().st_size <= MAX_OVERLAY and (args.out / 'boot.qcow2').stat().st_size <= 8 * MiB
        passed = passed and unchanged and bounded
        memory = firmware_case.memory_evidence(text) if passed else None
        if passed and memory['allocator_peak_including_stack'] > 16 * MiB:
            passed = False
        copied = [dict(path=path, bytes=int(size), sha256=sha) for path, size, sha in re.findall(r'BOOT_FILE path=(.*?) bytes=(\d+) sha256=([0-9a-f]{64})', text)]
        scope.save_json('boot-files.json', copied)
        if passed:
            asyncio.run(review_bounds.snapshot_bounded(qemu, args.out/'target.qcow2', review_bounds.TARGET, env))
        bounded = bounded and (args.out / 'target.qcow2').stat().st_size <= MAX_OVERLAY
        new_bytes = scope.audit()
        passed = passed and bounded and new_bytes + 128 * 1024 <= MAX_NEW_BYTES
        if logged_run.tree(REPO) != (head, 0):
            raise ValueError('F3: tree changed during boot-files gate')
        result = dict(schema='minios-uefi-boot-provision-v1', passed=passed, head=head, dirty=0,
                      arch=args.arch, mode='uefi', target=str(args.out / 'target.qcow2'),
                      target_sha256=oracle.digest(args.out / 'target.qcow2'), source=str(inputs['target']),
                      source_sha256=inputs['prep']['target_sha256'], source_base_unchanged=unchanged,
                      program_sha256=args.program_sha256, native_receipt_sha256=args.native_sha256,
                      reference_receipt_sha256=args.reference_sha256, compare_receipt_sha256=args.compare_sha256,
                      boot_files_manifest_sha256=oracle.digest(args.out / 'boot-files.json'),
                      loader_guid=str(loader), target_overlay_limit=MAX_OVERLAY, overlays_bounded=bounded,
                      retained_new_bytes_before_receipt=new_bytes, new_bytes_budget=MAX_NEW_BYTES,
                      elapsed_seconds=time.monotonic() - started, memory=memory, capacity_preflight=capacity,
                      returncode=returncode, timed_out=timed_out, command=list(map(str, command)),
                      completion_wait=True, progress_polling=False, full_exports=0, native_mount_used=False,
                      host_firmware_entries_changed=False, physical_disks_opened=False, first_windows_boot_attempted=False,
                      immutable_inputs=[dict(path=str(path), sha256=pin) for path, pin in inputs['pins'].items()], deleted=[])
        result['reference_comparison_deferred']=inputs.get('reference_deferred',False)
        scope.save_json('result.json', result)
        scope.audit()
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('prep-receipt', 'native-receipt', 'reference-receipt', 'compare-receipt', 'ours-bcd', 'reference-bcd', 'program', 'qemu-dir', 'plan', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('prep', 'native', 'reference', 'compare', 'ours-bcd', 'reference-bcd', 'program'):
        parser.add_argument('--' + name + '-sha256', required=True)
    parser.add_argument('--arch', choices=('x86_64', 'ia32'), required=True)
    parser.add_argument('--memory', type=int, default=128)
    parser.add_argument('--timeout', type=int, default=300)
    result = run(parser.parse_args())
    print(json.dumps(result))
    raise SystemExit(0 if result['passed'] else 1)
