#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""BIOS boot provisioning on a retained child, after native and real BCD gates.

Only owned virtual files are accepted. No Windows start, native disk mount,
physical storage API, full image export, cleanup or progress polling.
"""
from __future__ import annotations
import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import re
import stat
import struct
import subprocess
import time
import uuid
import zlib

import bcd_policy
import bcd_compare
import bcdboot_reference as reference
import install_firmware_case as common
import install_native as native
import logged_run
import wim_oracle as oracle
import wim_pool as pool

REPO = Path(__file__).resolve().parents[2]
MiB = 1024**2
SHA = re.compile(r'^[0-9a-f]{64}$')
HEAD = re.compile(r'^[0-9a-f]{40}$')
MAX_OVERLAY = 128 * MiB
MAX_NEW_BYTES = 208 * MiB
UTILITY_BYTES = 4 * MiB


def output_guard(out):
    out = oracle.owned(out)
    scope = oracle.RUNTIME / '1c23/qemu-bios'
    if out == scope or not out.is_relative_to(scope) or not out.name.startswith('boot-') or out.exists():
        raise ValueError('Fresh boot-* output in reserved BIOS scope required')
    return out


def receipt_fields(prep, proof, layout, ref, compare, pins):
    if (prep.get('schema') != 'minios-install-firmware-v1' or prep.get('passed') is not True
            or prep.get('qemu_only') is not True or prep.get('dirty') != 0
            or not HEAD.fullmatch(prep.get('head', '')) or prep.get('mode') != 'mbr'
            or prep.get('arch') != 'bios' or prep.get('cpu') not in ('486', 'pentium')
            or prep.get('source_unchanged') is not True or prep.get('base_unchanged') is not True
            or prep.get('source_writes') != 0 or type(prep.get('source_writes')) is not int
            or prep.get('returncode') != 33 or type(prep.get('returncode')) is not int
            or prep.get('timed_out') is not False or prep.get('physical_disks_opened') is not False
            or prep.get('guest_completion_wait') is not True or prep.get('windows_boot_attempted') is not False
            or prep.get('entropy_unchanged') is not True or not SHA.fullmatch(prep.get('entropy_sha256', ''))):
        raise ValueError('Completed clean BIOS preparation with immutable entropy PASS required')
    if (proof.get('mode') != 'bios' or layout.get('style') != 'MBR'
            or proof.get('virtual_bytes') != prep.get('target_bytes')
            or proof.get('source_sha256') != prep.get('target_sha256')):
        raise ValueError('BIOS preparation/native layout or prepared QCOW2 pin differs')
    if bcd_policy.deferred(ref):
        own=dict(compare);own['_actual_sha256']=pins.get('compare')
        bcd_policy.validate(ref,own,pins['native'],pins['ours_bcd'],proof['mode'])
        return
    if (ref.get('schema') != 'minios-bcdboot-reference-v1' or ref.get('passed') is not True
            or ref.get('worktree_dirty') != 0 or ref.get('worktree_dirty_after') != 0
            or not HEAD.fullmatch(ref.get('head', '')) or ref.get('head_after') != ref.get('head')
            or ref.get('native_receipt_sha256') != pins['native']
            or ref.get('bcdboot_exit') != 0 or ref.get('bcdedit_exit') != 0
            or ref.get('physical_disk_touched') is not False or ref.get('host_firmware_entry_requested') is not False
            or ref.get('base_sha256_before') != proof.get('vhd_sha256')
            or ref.get('base_sha256_after') != proof.get('vhd_sha256')
            or ref.get('mode') != 'bios' or ref.get('virtual_bytes') != proof.get('virtual_bytes')
            or ref.get('reference_sha256') != pins['reference_bcd']):
        raise ValueError('Guarded real bcdboot PASS on the exact BIOS native base required')
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
    system = dict(style='MBR', signature=layout['mbr_signature'], byte_offset=rows[1]['start'])
    windows = dict(style='MBR', signature=layout['mbr_signature'], byte_offset=rows[2]['start'])
    if (route.get('system') != system or route.get('windows') != windows or route.get('osdevice') != windows
            or route.get('manager_path') != '\\bootmgr' or route.get('loader_path') != '\\windows\\system32\\winload.exe'
            or route.get('systemroot') != '\\windows' or route.get('winpe') is not False
            or route.get('manager_locale') != route.get('loader_locale')
            or not re.fullmatch(r'[a-z0-9-]{2,32}', route.get('loader_locale', ''))):
        raise ValueError('BCD route differs from actual MBR signature, offsets, loader or locale')


def ids_from_seed(seed):
    """The firmware's exact common Ids.fromSeed64 v2, never new identities."""
    def healthy(data):
        return len(data) == 64 and data not in (bytes(64), b'\xff' * 64) and len(set(struct.unpack('<16I', data))) == 16
    if not healthy(seed):
        raise ValueError('Original healthy 64-byte preparation entropy required')
    tail = b''.join(hashlib.sha256(seed + b'USOSPREP Windows layout identity v2' + bytes([i])).digest() for i in range(2))
    if not healthy(tail):
        raise ValueError('Invalid domain-separated identity expansion')
    def guid(raw):
        data = bytearray(raw); data[7] = (data[7] & 15) | 64; data[8] = (data[8] & 63) | 128
        return data.hex()
    ids = dict(disk_guid=guid(seed[:16]), windows_guid=guid(seed[16:32]), esp_guid=guid(tail[:16]), msr_guid=guid(tail[16:32]),
               mbr_signature=struct.unpack_from('<I', seed, 32)[0], ntfs_serial=struct.unpack_from('<Q', seed, 36)[0])
    guids = [ids[key] for key in ('disk_guid', 'windows_guid', 'esp_guid', 'msr_guid')]
    if len(set(guids)) != 4 or ids['mbr_signature'] in (0, 0xffffffff) or ids['ntfs_serial'] in (0, 2**64-1):
        raise ValueError('Unusable original BIOS identities')
    ids['system_serial'] = int.from_bytes(bytes.fromhex(ids['esp_guid'])[8:16], 'little')
    if ids['system_serial'] == ids['ntfs_serial']:
        ids['system_serial'] ^= 1 << 63
    if ids['system_serial'] in (0, 2**64-1):
        raise ValueError('Unusable system NTFS identity')
    return ids


def actual_ids(reader, layout, debug, seed):
    if native.disk_layout(reader, 'bios') != layout:
        raise ValueError('Actual readonly dynamic VHD MBR differs from accepted layout')
    ids = ids_from_seed(seed)
    rows = {row['number']: row for row in layout['partitions']}
    if layout['mbr_signature'] != ids['mbr_signature']:
        raise ValueError('Original entropy identity differs from MBR signature')
    for number, serial in ((1, ids['system_serial']), (2, ids['ntfs_serial'])):
        part = rows[number]; reader.seek(part['start']); bpb = reader.read(512)
        reader.seek(part['start'] + part['bytes'] - 512); backup = reader.read(512)
        if (len(bpb) != 512 or bpb != backup or bpb[3:11] != b'NTFS    ' or bpb[510:] != b'\x55\xaa'
                or struct.unpack_from('<H', bpb, 11)[0] != 512 or bpb[13] != 8
                or struct.unpack_from('<I', bpb, 28)[0] != part['start'] // 512
                or struct.unpack_from('<Q', bpb, 40)[0] != part['bytes'] // 512 - 1
                or struct.unpack_from('<Q', bpb, 72)[0] != serial):
            raise ValueError('Actual NTFS primary/backup geometry or original serial differs')
    entropy = 'ENTROPY source=fw_cfg_host_csprng bytes=64 expansion=SHA256-domain-v2 qemu_detected=true'
    if debug.splitlines().count(entropy) != 1:
        raise ValueError('Exact preparation entropy source/policy log required')
    system = re.findall(r'INSTALL_SYSTEM NTFS start=(\d+) bytes=(\d+) serial=([0-9a-f]{16}) fresh=true empty=true', debug)
    windows = re.findall(r'^INSTALL_LAYOUT mode=bios windows_start=(\d+) windows_bytes=(\d+) (source_verified_before_target_write|selected_metadata_verified_before_target_write)=true$', debug,re.M)
    if (system != [(str(rows[1]['start']), str(rows[1]['bytes']), f"{ids['system_serial']:016x}")]
            or len(windows)!=1 or windows[0][:2] != (str(rows[2]['start']), str(rows[2]['bytes']))):
        raise ValueError('Preparation layout log differs from independently read MBR/NTFS')
    layout_at=debug.index('INSTALL_LAYOUT mode=bios ')
    if windows[0][2]=='selected_metadata_verified_before_target_write':
        selected=list(re.finditer(r'^WIM_SHA1 SELECTED_STREAMS PASS selected=([1-9][0-9]*) metadata=verified all_applied_streams=verified$',debug,re.M))
        if len(selected)!=1 or not 1<=int(selected[0][1])<=64 or selected[0].start()<layout_at:
            raise ValueError('Selected metadata marker requires completed selected-stream SHA1 gate')
    else:
        all_blobs=list(re.finditer(r'^WIM_SHA1 ALL_BLOBS PASS count=([1-9][0-9]*) before_target_write=true alloc_peak=[0-9]+$',debug,re.M))
        if len(all_blobs)!=1 or all_blobs[0].start()>layout_at:
            raise ValueError('Legacy full-source marker requires completed all-blob SHA1 gate')
    return ids


def configuration(ids, loader, layout, locale, native_sha, compare_sha, native_bytes, compare_bytes, timestamp):
    rows = {row['number']: row for row in layout['partitions']}
    size = layout['image_bytes']
    if (layout.get('style') != 'MBR' or size < 256*MiB or size % MiB or size // 512 > 0xffffffff
            or (rows[1]['start'], rows[1]['bytes'], rows[2]['start'], rows[2]['bytes']) != (MiB, 100*MiB, 101*MiB, size-101*MiB)
            or not 0 < native_bytes <= MiB or not 0 < compare_bytes <= MiB or not 0 < timestamp < 2**64
            or not SHA.fullmatch(native_sha) or not SHA.fullmatch(compare_sha) or native_sha == compare_sha
            or native_sha in ('0'*64, 'f'*64) or compare_sha in ('0'*64, 'f'*64)
            or not re.fullmatch(r'[a-z0-9-]{2,32}', locale)
            or loader.version != 4 or loader.variant != uuid.RFC_4122
            or loader.bytes_le.hex() in ids.values() or ids['mbr_signature'] != layout['mbr_signature']
            or ids['system_serial'] in (0, 2**64-1, ids['ntfs_serial'])):
        raise ValueError('Bounded exact BIOS B1 config with genuine identities and receipt pins required')
    data = bytearray(512); data[:16] = b'USOSPREP BIOS B1'
    struct.pack_into('<IIQII', data, 16, 1, 512, size, ids['mbr_signature'], 512)
    struct.pack_into('<6Q', data, 40, rows[1]['start'], rows[1]['bytes'], rows[2]['start'], rows[2]['bytes'], ids['ntfs_serial'], ids['system_serial'])
    data[88:104] = loader.bytes_le; data[104:136] = bytes.fromhex(native_sha); data[136:168] = bytes.fromhex(compare_sha)
    struct.pack_into('<4I', data, 168, native_bytes, compare_bytes, 1, 1); data[184:188] = bytes((0x80, 0x81, 0, 0))
    struct.pack_into('<Q', data, 192, timestamp); data[200] = len(locale); data[201:201+len(locale)] = locale.encode('ascii')
    for offset, key in ((240,'disk_guid'), (256,'windows_guid'), (272,'esp_guid'), (288,'msr_guid')):
        raw = bytes.fromhex(ids[key])
        if len(raw) != 16 or raw[7] >> 4 != 4 or raw[8] >> 6 != 2:
            raise ValueError('Original normalized layout GUID required')
        data[offset:offset+16] = raw
    struct.pack_into('<I', data, 508, zlib.crc32(data[:508]) & 0xffffffff)
    return bytes(data)


def accepted(args, locks):
    """No output/image until every actual gate, file and independent read agrees."""
    pins, streams = {}, {}
    def lock(path, expected=None):
        path = native.regular(oracle.local(path))
        if path not in streams: streams[path] = locks.enter_context(oracle.readonly(path))
        if expected is not None:
            if not SHA.fullmatch(expected) or oracle.digest_stream(streams[path]) != expected:
                raise ValueError('Pinned accepted input changed')
            pins[path] = expected
        return path
    values = {}
    for name in ('prep','native','reference','compare'):
        path = oracle.owned(getattr(args, name+'_receipt')); expected = getattr(args, name+'_sha256')
        lock(path); values[name] = reference.document(path, expected); pins[path] = expected
    if not isinstance(values['native'].get('vhd'), str):
        raise ValueError('Complete native receipt with accepted VHD required')
    base = oracle.owned(Path(values['native']['vhd'])); lock(base)
    proof, layout, native_pins = reference.accepted(args.native_receipt, args.native_sha256)
    for path, pin in native_pins.items():
        if path != base: lock(path, pin)
        else: pins[path] = pin  # reference.accepted hashed this base under our lock.
    for name in ('ours_bcd','reference_bcd'): lock(oracle.owned(getattr(args,name)), getattr(args,name+'_sha256'))
    receipt_fields(values['prep'], proof, layout, values['reference'], values['compare'],
                   dict(native=args.native_sha256,reference=args.reference_sha256,ours_bcd=args.ours_bcd_sha256,reference_bcd=args.reference_bcd_sha256,compare=args.compare_sha256))
    if bcd_policy.deferred(values['reference']):
        bcd_policy.validate_files(values['reference'],values['compare'],args.native_sha256,
            args.ours_bcd_sha256,proof['mode'],args.compare_receipt)
    else:
        job_path = oracle.owned(args.reference_receipt.parent/'job.json'); lock(job_path)
        job_sha = values['reference'].get('job_sha256',''); job = reference.document(job_path,job_sha)
        if (job.get('schema') != 'minios-bcdboot-reference-job-v1' or job.get('native_receipt') != str(args.native_receipt)
                or job.get('native_receipt_sha256') != args.native_sha256 or job.get('base') != str(base)
                or job.get('base_sha256') != proof['vhd_sha256'] or job.get('layout_sha256') != proof['layout_sha256']
                or job.get('mode') != 'bios' or job.get('virtual_bytes') != proof['virtual_bytes']):
            raise ValueError('Guarded bcdboot job belongs to another BIOS disk')
        pins[job_path] = job_sha
    target = oracle.owned(Path(values['prep']['target'])); lock(target)
    chain = native.qcow_chain(target, proof['virtual_bytes']); expected_chain = {}
    for row in proof['source_backing_chain']:
        relative = Path(row['path'])
        if relative.is_absolute() or relative.drive or '..' in relative.parts or any(c in str(relative) for c in ':,\r\n\0'):
            raise ValueError('Unsafe accepted QCOW2 chain name')
        path = oracle.owned(oracle.RUNTIME/relative)
        if path in expected_chain or len(expected_chain) >= 16: raise ValueError('Duplicate/excessive backing chain')
        expected_chain[path] = row['sha256']
    if set(chain) != set(expected_chain) or expected_chain.get(target) != values['prep']['target_sha256']:
        raise ValueError('Prepared QCOW2 chain differs from native acceptance')
    for path in chain: lock(path,expected_chain[path])
    debug_path = oracle.owned(args.prep_receipt.parent/'debug.log'); lock(debug_path)
    if debug_path.stat().st_size > 16*MiB: raise ValueError('Preparation log exceeds bound')
    pins[debug_path] = oracle.digest_stream(streams[debug_path])
    entropy_path = oracle.owned(args.prep_receipt.parent/'entropy.bin'); lock(entropy_path, values['prep']['entropy_sha256'])
    if entropy_path.stat().st_size != 64: raise ValueError('Exact original entropy64 required')
    reader = native.DynamicVhd(base,stream=streams[base])
    ids = actual_ids(reader,layout,debug_path.read_text(encoding='utf-8',errors='strict'),entropy_path.read_bytes())
    for name in (('ours_bcd',) if bcd_policy.deferred(values['reference']) else ('ours_bcd','reference_bcd')):
        route = bcd_compare.route(bcd_compare.oracle.independent_read(getattr(args,name)))
        if route != values['compare']['ours_route']: raise ValueError('Independent BCD reread differs')
        route_for_layout(route,layout)
    lock(args.program,args.program_sha256)
    return dict(reference_deferred=bcd_policy.deferred(values['reference']),prep=values['prep'],native=proof,layout=layout,ids=ids,target=target,
                locale=values['compare']['ours_route']['loader_locale'],pins=pins,streams=streams)


def guest_command(qemu_dir,out,cpu,memory):
    result = [qemu_dir/'qemu-system-i386.exe','-machine','pc','-accel','tcg,thread=single','-cpu',cpu,'-smp','1','-m',str(memory),
              '-nodefaults','-display','none','-no-reboot','-nic','none']
    for name, unit, order in (('boot',0,1),('target',1,2)):
        result += ['-drive',f'if=none,id={name},format=qcow2,file={out/(name+".qcow2")}',
                   '-device',f'ide-hd,drive={name},bus=ide.0,unit={unit},bootindex={order}']
    return result+['-device','VGA','-serial',f'file:{out/"serial.log"}','-debugcon',f'file:{out/"debug.log"}',
                   '-global','isa-debugcon.iobase=0xe9','-device','isa-debug-exit,iobase=0xf4,iosize=0x04']


def guest_acceptance(code,timed_out,text):
    final = re.findall(r'USOSBOOT FINAL alloc_current=0 alloc_peak=(\d+) target_reads=(\d+) target_writes=(\d+) denied_windows_writes=0;',text)
    return (type(code) is int and code == 33 and timed_out is False and ' FAIL' not in text
            and 'BOOT_BIOS PASS' in text and len(final) == 1 and all(int(n)>0 for n in final[0])
            and 'guard=4096 guard_intact=true' in text and 'HEAP physical_current=0 ' in text)


def memory_evidence(text):
    stack = re.search(r'STACK BIOS reserved=(\d+) high_water=(\d+) guard=4096 guard_intact=true',text)
    heap = re.search(r'HEAP physical_current=0 physical_peak=(\d+) extent_peak=(\d+) reserved=(\d+)',text)
    tracked = re.search(r'USOSBOOT FINAL alloc_current=0 alloc_peak=(\d+)',text)
    if not stack or not heap or not tracked: raise ValueError('Missing BIOS boot stack/heap evidence')
    reserved,high = map(int,stack.groups()); physical,extent,heap_reserved = map(int,heap.groups()); peak = int(tracked[1])
    if not 0 < high <= reserved-4096 or not 0 < peak <= physical <= heap_reserved <= 16*MiB or extent>heap_reserved:
        raise ValueError('Invalid BIOS boot stack/heap measurements')
    return dict(stack_reserved=reserved,stack_high_water=high,allocator_peak=peak,physical_heap_peak=physical,
                physical_extent_peak=extent,heap_reserved=heap_reserved,allocator_peak_including_stack=physical+high,firmware_excluded=True)


def write_utility(program,utility,cfg,native_data,compare_data):
    if program.stat().st_size != UTILITY_BYTES or len(cfg) != 512 or not 0 < len(native_data) <= MiB or not 0 < len(compare_data) <= MiB:
        raise ValueError('Exact4MiB utility and bounded receipts required')
    # The firmware verifies these actual bytes again before target writes.
    if (struct.unpack_from('<II',cfg,168) != (len(native_data),len(compare_data))
            or cfg[104:136] != hashlib.sha256(native_data).digest() or cfg[136:168] != hashlib.sha256(compare_data).digest()):
        raise ValueError('Utility receipt content differs from config')
    with program.open('rb') as source, utility.open('xb') as target:
        while data := source.read(MiB): target.write(data)
    with utility.open('r+b') as target:
        for offset,data in ((512*1024,cfg),(MiB,native_data),(2*MiB,compare_data)): target.seek(offset); target.write(data)
    utility.chmod(stat.S_IREAD)


def run(args):
    output_guard(args.out)
    for path in (args.program,args.qemu_dir): oracle.local(path)
    if (args.arch != 'bios' or args.cpu not in ('486','pentium') or not args.program.is_file()
            or args.program.stat().st_size != UTILITY_BYTES or not 32 <= args.memory <= 256 or not 60 <= args.timeout <= 900):
        raise ValueError('Exact BIOS utility and bounded486/Pentium parameters required')
    for name in ('qemu-system-i386.exe','qemu-img.exe'):
        if not (args.qemu_dir/name).is_file(): raise ValueError('Explicit existing QEMU tools required')
    head,dirty = logged_run.tree(REPO)
    if dirty: raise ValueError('F3 clean frozen HEAD required')
    with contextlib.ExitStack() as locks:
        inputs = accepted(args,locks)  # All actual gates precede output/image creation.
        capacity = pool.enforce_incremental(args.plan,args.out,MAX_NEW_BYTES,closed_scope=True)
        args.out.mkdir(parents=True); env = oracle.environment(args.out)
        loader = uuid.uuid4(); timestamp = time.time_ns()//100 + 116444736000000000
        native_data = args.native_receipt.read_bytes(); compare_data = args.compare_receipt.read_bytes()
        cfg = configuration(inputs['ids'],loader,inputs['layout'],inputs['locale'],args.native_sha256,args.compare_sha256,len(native_data),len(compare_data),timestamp)
        utility = args.out/'boot-base.raw'; write_utility(args.program,utility,cfg,native_data,compare_data)
        (args.out/'boot-config.bin').write_bytes(cfg)
        qemu_img = args.qemu_dir/'qemu-img.exe'
        for name,base,fmt in (('target',inputs['target'],'qcow2'),('boot',utility,'raw')):
            common.execute([qemu_img,'create','-f','qcow2','-F',fmt,'-b',base,args.out/(name+'.qcow2')],args.out/(name+'-overlay.log'),env)
        utility_lock = locks.enter_context(oracle.readonly(utility)); utility_sha = oracle.digest_stream(utility_lock)
        command = guest_command(args.qemu_dir,args.out,args.cpu,args.memory); started = time.monotonic(); timed_out = False
        with (args.out/'qemu.stdout').open('xb') as stdout,(args.out/'qemu.stderr').open('xb') as stderr:
            for stream in (stdout,stderr): stream.write(common.capture_header(head)); stream.flush()
            child = subprocess.Popen(list(map(str,command)),stdout=stdout,stderr=stderr,stdin=subprocess.DEVNULL,env=env,
                                     creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)|getattr(subprocess,'BELOW_NORMAL_PRIORITY_CLASS',0))
            try: code = child.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired: timed_out=True; child.kill(); code=child.wait()
        for name in ('debug.log','serial.log'): common.seal_capture(args.out/name,head)
        text = (args.out/'debug.log').read_text(encoding='utf-8',errors='replace')
        passed = guest_acceptance(code,timed_out,text)
        unchanged = all(oracle.digest_stream(inputs['streams'][path]) == pin for path,pin in inputs['pins'].items()) and oracle.digest_stream(utility_lock) == utility_sha
        bounded = (args.out/'target.qcow2').stat().st_size <= MAX_OVERLAY and (args.out/'boot.qcow2').stat().st_size <= 8*MiB
        passed = passed and unchanged and bounded
        memory = memory_evidence(text) if passed else None
        if memory and memory['allocator_peak_including_stack'] > 16*MiB: passed=False
        copied = [dict(path=path,bytes=int(size),sha256=sha) for path,size,sha in re.findall(r'BOOT_FILE path=(.*?) bytes=(\d+) sha256=([0-9a-f]{64})',text)]
        oracle.save(args.out/'boot-files.json',copied)
        if passed: common.execute([qemu_img,'snapshot','-c','bootfiles',args.out/'target.qcow2'],args.out/'bootfiles-snapshot.log',env)
        bounded = bounded and (args.out/'target.qcow2').stat().st_size <= MAX_OVERLAY
        new_bytes = sum(path.stat().st_size for path in args.out.rglob('*') if path.is_file())
        passed = passed and bounded and new_bytes+128*1024 <= MAX_NEW_BYTES
        if logged_run.tree(REPO) != (head,0): raise ValueError('F3 tree changed during BIOS boot gate')
        result = dict(schema='minios-bios-boot-provision-v1',passed=passed,head=head,dirty=0,arch='bios',mode='bios',cpu=args.cpu,
                      target=str(args.out/'target.qcow2'),target_bytes=inputs['native']['virtual_bytes'],target_sha256=oracle.digest(args.out/'target.qcow2'),
                      source=str(inputs['target']),source_sha256=inputs['prep']['target_sha256'],source_base_unchanged=unchanged,
                      program_sha256=args.program_sha256,native_receipt_sha256=args.native_sha256,reference_receipt_sha256=args.reference_sha256,
                      compare_receipt_sha256=args.compare_sha256,boot_files_manifest_sha256=oracle.digest(args.out/'boot-files.json'),loader_guid=str(loader),
                      target_overlay_limit=MAX_OVERLAY,overlays_bounded=bounded,retained_new_bytes_before_receipt=new_bytes,new_bytes_budget=MAX_NEW_BYTES,
                      elapsed_seconds=time.monotonic()-started,memory=memory,capacity_preflight=capacity,returncode=code,timed_out=timed_out,
                      command=list(map(str,command)),completion_wait=True,progress_polling=False,full_exports=0,native_mount_used=False,
                      host_firmware_entries_changed=False,physical_disks_opened=False,first_windows_boot_attempted=False,
                      original_gate_paths={name:str(getattr(args,name+'_receipt')) for name in ('prep','native','reference','compare')},
                      immutable_inputs=[dict(path=str(path),sha256=pin) for path,pin in inputs['pins'].items()],deleted=[])
        result['reference_comparison_deferred']=inputs.get('reference_deferred',False)
        oracle.save(args.out/'result.json',result)
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('prep-receipt','native-receipt','reference-receipt','compare-receipt','ours-bcd','reference-bcd','program','qemu-dir','plan','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    for name in ('prep','native','reference','compare','ours-bcd','reference-bcd','program'):
        parser.add_argument('--'+name+'-sha256',required=True)
    parser.add_argument('--arch',choices=('bios',),default='bios'); parser.add_argument('--cpu',choices=('486','pentium'),default='486')
    parser.add_argument('--memory',type=int,default=32); parser.add_argument('--timeout',type=int,default=300)
    result=run(parser.parse_args()); print(json.dumps(result)); raise SystemExit(0 if result['passed'] else 1)
