#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit BIOS MiniOS preparation only; never starts installed Windows."""
from __future__ import annotations
import argparse, hashlib, json, re, secrets, stat, struct, subprocess, time, zlib
from pathlib import Path
import install_firmware_case as common
import logged_run
import optical_e2e
import wim_oracle as oracle
import wim_pool as pool

REPO=Path(__file__).resolve().parents[2]
GiB=1024**3


def encode_config(proof,index,target_bytes,token,serial,verify_scope='selected',*,timing=False):
    if (type(index) is not int or index<1 or target_bytes<8*GiB or target_bytes%GiB or
            not re.fullmatch('[0-9a-f]{64}',token) or not 0<serial<2**64 or
            proof['partition_start']<1024**2 or proof['partition_start']%512 or
            proof['partition_bytes']%512 or proof['target_bytes']%512 or
            proof['partition_start']+proof['partition_bytes']>proof['target_bytes'] or
            not 17*2048<=proof['iso_bytes']<=proof['partition_bytes'] or verify_scope not in ('selected','all')):
        raise ValueError('Exact BIOS source/index/target configuration required')
    result=bytearray(512);result[:16]=b'USOSPREP BIOS I1'
    struct.pack_into('<IIQ',result,16,1,512,target_bytes);result[32:96]=token.encode('ascii')
    struct.pack_into('<QQQQ',result,96,proof['target_bytes'],proof['partition_start'],proof['partition_bytes'],serial)
    result[128:132]=bytes((0x80,0x81,0x82,0))
    struct.pack_into('<IIIQ',result,132,index,512,512,proof['iso_bytes'])
    if type(timing) is not bool:raise ValueError('Boolean diagnostic timing required')
    result[152]=int(verify_scope=='all')
    result[153]=int(timing)
    struct.pack_into('<I',result,508,zlib.crc32(result[:508])&0xffffffff)
    return bytes(result)


def guest_acceptance(code,timed_out,text,source_unchanged):
    io=re.search(r'IO source_reads=\d+ source_bytes=\d+ source_writes=(\d+) target_reads=\d+ target_writes=(\d+) target_written_bytes=\d+',text)
    return (type(code) is int and code==33 and not timed_out and source_unchanged is True and io is not None and
            int(io[1])==0 and int(io[2])>0 and 'USOSPREP WIM PASS' in text and 'INSTALL_LAYOUT mode=bios' in text and
            'INSTALL_APPLY PASS mode=bios' in text and
            'USOSPREP INSTALL FINAL current=0 ' in text and 'guard=4096 guard_intact=true' in text and
            'HEAP physical_current=0 ' in text and 'TERMINAL FAIL' not in text)


def memory_evidence(text):
    stack=re.search(r'STACK BIOS reserved=(\d+) high_water=(\d+) guard=4096 guard_intact=true',text)
    heap=re.search(r'HEAP physical_current=0 physical_peak=(\d+) extent_peak=(\d+) reserved=(\d+)',text)
    tracked=re.search(r'USOSPREP INSTALL FINAL current=0 peak=(\d+)',text)
    if not stack or not heap or not tracked:raise ValueError('Missing BIOS stack/heap evidence')
    reserved,high=map(int,stack.groups());physical,extent,heap_reserved=map(int,heap.groups());peak=int(tracked[1])
    if not 0<high<=reserved-4096 or not 0<peak<=physical<=heap_reserved<=16*1024**2 or extent>heap_reserved:
        raise ValueError('Invalid BIOS stack/heap measurements')
    return dict(stack_reserved=reserved,stack_high_water=high,allocator_peak=peak,
                physical_heap_peak=physical,physical_extent_peak=extent,heap_reserved=heap_reserved,firmware_excluded=True)


def guest_command(qemu_dir,out,cpu,memory,accel='tcg',target_format='qcow2'):
    if accel not in ('tcg','whpx') or cpu not in ('486','pentium') or target_format != 'qcow2':
        raise ValueError('Explicit BIOS TCG CPU and preparation accelerator required')
    exe='qemu-system-x86_64.exe' if accel=='whpx' else 'qemu-system-i386.exe'
    args=[qemu_dir/exe,'-machine','pc','-accel','whpx' if accel=='whpx' else 'tcg,thread=single',
          '-cpu','qemu64,-xsave' if accel=='whpx' else cpu,
          '-smp','1','-m',str(memory),'-nodefaults','-display','none','-no-reboot','-nic','none',
          '-fw_cfg',f'name=opt/usosprep-entropy,file={out/"entropy.bin"}']
    # All live drives use checkpointed QCOW2 children. VHD is a single final
    # native-validation export; source RAW remains locked and readonly.
    for name,bus,unit,bootindex in (('boot','ide.0',0,1),('source','ide.0',1,2),('target','ide.1',0,3)):
        fmt=target_format if name=='target' else 'qcow2'
        path=out/(name+'.qcow2')
        args+=['-drive',f'if=none,id={name},format={fmt},file={path}',
               '-device',f'ide-hd,drive={name},bus={bus},unit={unit},bootindex={bootindex}']
    return args+['-device','VGA','-serial',f'file:{out/"serial.log"}','-debugcon',f'file:{out/"debug.log"}',
                 '-global','isa-debugcon.iobase=0xe9','-device','isa-debug-exit,iobase=0xf4,iosize=0x04']


def run(a):
    for path in (a.out,a.source,a.pack_proof,a.plan):oracle.owned(path)
    for path in (a.program,a.qemu_dir):oracle.local(path)
    if (a.out.exists() or not a.out.is_relative_to(oracle.RUNTIME/'1c23/qemu-bios') or
            not a.program.is_file() or a.program.stat().st_size!=1024**2):
        raise ValueError('New reserved BIOS case and exact isolated installer required')
    accel,verify_scope,timeout,memory_mib=common.preparation_settings(a,bios=True)
    target_format=common.selected_target_format(a)
    if (a.cpu not in ('486','pentium') or not 8<=a.target_gib<=64 or
            not re.fullmatch('[0-9a-f]{64}',a.program_sha256)):
        raise ValueError('Explicit bounded BIOS firmware parameters required')
    for name in ('qemu-system-x86_64.exe' if accel=='whpx' else 'qemu-system-i386.exe','qemu-img.exe','qemu-io.exe'):
        if not (a.qemu_dir/name).is_file():raise ValueError('Existing explicit QEMU tools required')
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError('F3 clean tree required')
    capacity=pool.enforce(a.plan,a.out)
    proof=json.loads(a.pack_proof.read_text(encoding='utf8'))
    if proof.get('passed') is not True or proof.get('ntfs_manifest_verified') is not True or Path(proof['target'])!=a.source:
        raise ValueError('Accepted exact ISO-on-NTFS pack receipt required')
    with oracle.readonly(a.source) as locked,oracle.readonly(a.program) as program:
        source_sha=oracle.digest_stream(locked);program_sha=oracle.digest_stream(program)
        if program_sha!=a.program_sha256:raise ValueError('Final BIOS firmware pin differs')
        a.partition_start=proof['partition_start'];a.partition_bytes=proof['partition_bytes']
        expected=optical_e2e.expectations(a,source_sha)
        if source_sha!=proof['target_sha256'] or a.source.stat().st_size!=proof['target_bytes']:
            raise ValueError('Retained readonly source pin differs')
        locked.seek(proof['partition_start']);bpb=locked.read(512)
        if bpb[3:11]!=b'NTFS    ' or struct.unpack_from('<H',bpb,11)[0]!=512:raise ValueError('Source NTFS BPB differs')
        token=secrets.token_hex(32);size=a.target_gib*GiB
        config=encode_config(proof,a.index,size,token,struct.unpack_from('<Q',bpb,72)[0],verify_scope,timing=getattr(a,'timing',False))
        # All independent pins/expectations precede any image creation.
        a.out.mkdir(parents=True);env=oracle.environment(a.out);qemu=a.qemu_dir/'qemu-img.exe'
        boot=a.out/'boot-base.raw';program.seek(0)
        with boot.open('xb') as target:
            while block:=program.read(1024**2):target.write(block)
        with boot.open('r+b') as target:target.seek(1024*512);target.write(config)
        (a.out/'install-config.bin').write_bytes(config)
        marker=b'USOSPREP TARGET v1\n'+token.encode()+b'\n'
        (a.out/'marker.bin').write_bytes(marker.ljust(512,b'\0'))
        target_path,target_base=common.create_preparation_target(a.qemu_dir,a.out,size,env,target_format)
        for name,base,fmt in (('boot',boot,'raw'),('source',a.source,'raw')):
            if name!='source':base.chmod(stat.S_IREAD)
            common.execute([qemu,'create','-f','qcow2','-F',fmt,'-b',base,a.out/(name+'.qcow2')],a.out/(name+'-overlay.log'),env)
        bases={path.name:oracle.digest(path) for path in (boot,target_base)}
        entropy=secrets.token_bytes(64);entropy_path=a.out/'entropy.bin'
        entropy_path.write_bytes(entropy);entropy_path.chmod(stat.S_IREAD)
        entropy_sha=hashlib.sha256(entropy).hexdigest()
        command=guest_command(a.qemu_dir,a.out,a.cpu,memory_mib,accel,target_format)
        started=time.monotonic();timed_out=False
        with (a.out/'qemu.stdout').open('xb') as stdout,(a.out/'qemu.stderr').open('xb') as stderr:
            for stream in (stdout,stderr):stream.write(common.capture_header(head));stream.flush()
            child=subprocess.Popen(list(map(str,command)),stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,env=env,
                                   creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)|getattr(subprocess,'BELOW_NORMAL_PRIORITY_CLASS',0))
            try:code=child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:timed_out=True;child.kill();code=child.wait()
        guest_seconds=time.monotonic()-started
        for name in ('debug.log','serial.log'):common.seal_capture(a.out/name,head)
        debug=a.out/'debug.log'
        text=debug.read_text(encoding='utf8',errors='replace') if debug.is_file() else ''
        source_after=oracle.digest_stream(locked);program_after=oracle.digest_stream(program)
        entropy_after=oracle.digest(entropy_path)
    passed=guest_acceptance(code,timed_out,text,source_sha==source_after)
    bases_ok=all(oracle.digest(a.out/name)==pin for name,pin in bases.items())
    passed=passed and bases_ok and program_sha==program_after and entropy_sha==entropy_after
    prepared=common.seal_prepared_target(a.qemu_dir,a.out,size,env,target_format) if passed else {}
    result_target=a.out/'target.qcow2' if passed else target_path
    measurements=memory_evidence(text) if passed else None
    result=dict(schema='minios-install-firmware-v1',head=head,dirty=0,qemu_only=True,arch='bios',
                cpu='qemu64,-xsave' if accel=='whpx' else a.cpu,accel=accel,verify_scope=verify_scope,timeout_seconds=timeout,mode='mbr',
                target=str(result_target),target_bytes=size,target_sha256=oracle.digest(result_target),target_format=target_format,
                blank_checkpoint=str(target_base),blank_checkpoint_sha256=bases[target_base.name],
                source=str(a.source),source_sha256=source_sha,source_unchanged=source_sha==source_after,
                source_overlay=str(a.out/'source.qcow2'),source_overlay_retained=True,source_writes=0 if passed else None,
                program_sha256=program_sha,base_unchanged=bases_ok,returncode=code,timed_out=timed_out,
                entropy_sha256=entropy_sha,entropy_unchanged=entropy_sha==entropy_after,
                guest_completion_wait=True,elapsed_seconds=guest_seconds,memory_mib=memory_mib,command=list(map(str,command)),
                passed=passed,cleanup_performed=False,physical_disks_opened=False,windows_boot_attempted=False,
                independent_windows_gate_not_yet_run=True,memory=measurements,expected=expected,capacity_preflight=capacity,
                capacity_plan_sha256=oracle.digest(a.plan),**prepared)
    if logged_run.tree(REPO)!=(head,0):raise ValueError('F3 tree changed during BIOS firmware gate')
    oracle.save(a.out/'result.json',result)
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('out','source','pack-proof','program','qemu-dir','plan','expected-tree','expected-security','iso-proof'):
        p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--program-sha256',required=True);p.add_argument('--index',type=int,required=True)
    p.add_argument('--cpu',choices=('486','pentium'),default='486')
    p.add_argument('--accel',choices=('whpx','tcg'),default='tcg');p.add_argument('--verify-scope',choices=('selected','all'),default='selected')
    p.add_argument('--target-format',choices=('qcow2',),default='qcow2')
    p.add_argument('--timing',action='store_true',help='Explicit diagnostic TSC profiling, default off')
    p.add_argument('--target-gib',type=int,default=16);p.add_argument('--memory',type=int,default=None);p.add_argument('--timeout',type=int,default=None)
    a=p.parse_args();r=run(a);print(json.dumps(r));raise SystemExit(0 if r['passed'] else 1)
