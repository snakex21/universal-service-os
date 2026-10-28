#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One first Windows boot on an overlay, gated by immutable real boot proofs.

Transport completion is PENDING_REVIEW, never an automatic OOBE/specialize PASS.
Only closed-image mapping and four bounded Panther logs are inspected afterward.
"""
import argparse
import asyncio
import contextlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid
import os

import firstboot_bounds as bounds
import firstboot_output as output

import bcd_policy
import bcd_compare
import bcdboot_reference as reference
import firstboot_logs
import firstboot_qmp
import install_firmware_case as commands
import install_native as native
import logged_run
import qcow_map_readonly
import wim_oracle as oracle
import wim_pool as pool

REPO=Path(__file__).resolve().parents[2]
MiB=1024**2
MAX_NEW_BYTES=2*1024**3
SHA=re.compile(r'^[0-9a-f]{64}$')
HEAD=re.compile(r'^[0-9a-f]{40}$')


def output_guard(out, arch):
    out=oracle.owned(out)
    scope=oracle.RUNTIME/'1c23'/dict(x86_64='qemu-x64',ia32='qemu-ia32',bios='qemu-bios').get(arch,'invalid')
    if arch not in ('x86_64','ia32','bios') or out==scope or not out.is_relative_to(scope) or not out.name.startswith('firstboot-') or out.exists():
        raise ValueError('Fresh firstboot-* output in the exact architecture reservation required')
    return out


def boot_fields(boot, arch):
    mode='bios' if arch=='bios' else 'uefi'
    if (boot.get('schema')!=f'minios-{mode}-boot-provision-v1' or boot.get('passed') is not True
        or boot.get('arch')!=arch or boot.get('mode')!=mode or boot.get('dirty')!=0
        or not HEAD.fullmatch(boot.get('head','')) or type(boot.get('returncode')) is not int or boot['returncode']!=33
        or boot.get('timed_out') is not False or boot.get('completion_wait') is not True
        or boot.get('source_base_unchanged') is not True or boot.get('overlays_bounded') is not True
        or boot.get('first_windows_boot_attempted') is not False or boot.get('physical_disks_opened') is not False
        or boot.get('host_firmware_entries_changed') is not False):
        raise ValueError('Completed clean boot-provision PASS for the exact architecture required')
    for field in ('target_sha256','source_sha256','native_receipt_sha256','reference_receipt_sha256','compare_receipt_sha256','boot_files_manifest_sha256'):
        if not SHA.fullmatch(boot.get(field,'')):
            raise ValueError('Complete immutable proof pins required')
    rows=boot.get('immutable_inputs')
    if not isinstance(rows,list) or not 1<=len(rows)<=128:
        raise ValueError('Bounded immutable input chain required')


def route_layout(route, layout):
    rows={row['number']:row for row in layout['partitions']}
    if layout['mode']=='uefi':
        def device(number):
            return dict(style='GPT',disk_guid_le=uuid.UUID(layout['disk_guid']).bytes_le.hex(),
                        partition_guid_le=uuid.UUID(rows[number]['guid']).bytes_le.hex())
        manager,loader='\\efi\\microsoft\\boot\\bootmgfw.efi','\\windows\\system32\\winload.efi'
    else:
        def device(number):
            return dict(style='MBR',signature=layout['mbr_signature'],byte_offset=rows[number]['start'])
        manager,loader='\\bootmgr','\\windows\\system32\\winload.exe'
    if (route.get('system')!=device(layout['system_number']) or route.get('windows')!=device(layout['windows_number'])
        or route.get('osdevice')!=device(layout['windows_number']) or route.get('manager_path')!=manager
        or route.get('loader_path')!=loader or route.get('systemroot')!='\\windows' or route.get('winpe') is not False
        or route.get('manager_locale')!=route.get('loader_locale') or not re.fullmatch('[a-z0-9-]{2,32}',route.get('loader_locale',''))):
        raise ValueError('BCD route differs from the actual native-accepted disk')


def immutable_input(path, sha, boot=None):
    """Images stay in the owned pool; one pinned build artifact is read-only."""
    path=oracle.local(Path(path))
    if path.is_relative_to(oracle.RUNTIME):
        return native.regular(oracle.owned(path))
    # The boot-provision producer also pins the firmware used to copy files.
    # It lives in zig-out, not in the image pool, and is never a VM disk.
    if (boot is None or sha!=boot.get('program_sha256')
        or not path.is_relative_to(REPO/'zig-out') or path.suffix.lower() not in ('.efi','.bin')
        or not 0<path.stat().st_size<=16*MiB):
        raise ValueError('Only the exact pinned MiniOS build artifact may be outside the image pool')
    return native.regular(path)


def resume_fields(previous, boot_sha, arch, *, interrupted=False):
    """A closed, bounded endpoint is a checkpoint, not an OOBE assertion."""
    if (previous.get('schema')!='minios-windows-firstboot-v1'
        or previous.get('dirty')!=0
        or not HEAD.fullmatch(previous.get('head','')) or previous.get('arch')!=arch
        or previous.get('boot_receipt_sha256')!=boot_sha
        or previous.get('immutable_base_unchanged') is not True
        or previous.get('within_budget') is not True
        or previous.get('physical_disks_opened') is not False
        or not SHA.fullmatch(previous.get('target_sha256',''))):
        raise ValueError('A closed bounded checkpoint for the same boot proof is required')
    qmp=previous.get('qmp',{})
    if interrupted is True:
        # Explicit recovery of a forcibly terminated run. Never relabel it PASS.
        # accepted() must additionally run a read-only qcow consistency check.
        if (previous.get('status')!='EVIDENCE_FAILURE' or qmp.get('returncode') not in (-1,4294967295)
            or not str(qmp.get('transport_error','')).startswith('QMP closed:')
            or qmp.get('block_io_error') is not None or qmp.get('unexpected_stop') is not None
            or any(e.get('event')=='BLOCK_IO_ERROR' for e in qmp.get('events',[]))):
            raise ValueError('Only an explicitly interrupted transport failure is recoverable')
    elif interrupted is not False or (previous.get('status')!='PENDING_REVIEW'
            or qmp.get('returncode')!=0 or qmp.get('endpoint_reason')!='fixed_deadline'):
        raise ValueError('A closed bounded checkpoint for the same boot proof is required')


def check_interrupted_checkpoint(qemu_img, target):
    """No repair flag: parent is also held through a deny-write/delete handle."""
    run=subprocess.run([str(qemu_img),'check','--output=json','-f','qcow2',str(target)],
        stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120,
        creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    if run.returncode!=0 or len(run.stdout)>MiB or len(run.stderr)>MiB:
        raise ValueError('Read-only interrupted QCOW2 check failed; no repair attempted')
    check=json.loads(run.stdout)
    if (check.get('format')!='qcow2' or check.get('filename')!=str(target)
        or type(check.get('check-errors')) is not int or check['check-errors']!=0
        or any(check.get(key,0)!=0 for key in ('corruptions','leaks'))):
        raise ValueError('Interrupted QCOW2 has errors; no repair attempted')
    return dict(read_only=True,repair_attempted=False,returncode=run.returncode,check=check)


def accepted(args, locks):
    """Lock/hash every immutable input and revalidate real child acceptance."""
    if getattr(args,'recover_interrupted',False) and getattr(args,'resume_receipt',None) is None:
        raise ValueError('Interrupted recovery requires a pinned resume receipt')
    streams,pins={},{}
    def pin(path,sha,boot=None):
        path=immutable_input(path,sha,boot)
        if not isinstance(sha,str) or not SHA.fullmatch(sha):
            raise ValueError('Exact SHA256 required')
        if path in pins:
            if pins[path]!=sha:raise ValueError('Conflicting immutable pin')
            return path
        streams[path]=locks.enter_context(oracle.readonly(path))
        if oracle.digest_stream(streams[path])!=sha:raise ValueError('Immutable proof or image changed')
        pins[path]=sha
        return path
    path=pin(args.boot_receipt,args.boot_sha256)
    boot=reference.document(path,args.boot_sha256)
    boot_fields(boot,args.arch)
    for row in boot['immutable_inputs']:
        if not isinstance(row,dict) or set(row)!={'path','sha256'}:
            raise ValueError('Exact immutable input row required')
        original=immutable_input(row['path'],row['sha256'],boot)
        if original in pins:raise ValueError('Repeated immutable input path')
        pin(original,row['sha256'],boot)
    def document_sha(sha):
        matches=[path for path,value in pins.items() if value==sha]
        if len(matches)!=1:raise ValueError('One exact pinned child receipt required')
        return matches[0],reference.document(matches[0],sha)
    native_path,proof=document_sha(boot['native_receipt_sha256'])
    proof,layout,native_pins=reference.accepted(native_path,boot['native_receipt_sha256'])
    if any(pins.get(path)!=sha for path,sha in native_pins.items()):
        raise ValueError('Native acceptance child is absent from immutable proof chain')
    if proof['mode']!=boot['mode'] or proof['source_sha256']!=boot['source_sha256']:
        raise ValueError('Native acceptance belongs to another disk/mode')
    ref_path,ref=document_sha(boot['reference_receipt_sha256'])
    _,compare=document_sha(boot['compare_receipt_sha256'])
    if bcd_policy.deferred(ref):
        if boot.get('reference_comparison_deferred') is not True:
            raise ValueError('Boot receipt must explicitly disclose comparison deferral')
        own_matches=[path for path,sha in pins.items() if sha==compare.get('source_sha256')]
        if len(own_matches)!=1:raise ValueError('Pinned own BCD required')
        bcd_policy.validate_files(ref,compare,boot['native_receipt_sha256'],compare['source_sha256'],
            proof['mode'],document_sha(boot['compare_receipt_sha256'])[0])
        route=bcd_compare.route(bcd_compare.oracle.independent_read(own_matches[0]))
        if route!=compare['ours_route']:raise ValueError('Reread own BCD changed')
        route_layout(route,layout)
    else:
        if (ref.get('schema')!='minios-bcdboot-reference-v1' or ref.get('passed') is not True
            or ref.get('worktree_dirty')!=0 or ref.get('worktree_dirty_after')!=0
            or not HEAD.fullmatch(ref.get('head','')) or ref.get('head_after')!=ref.get('head')
            or ref.get('native_receipt_sha256')!=boot['native_receipt_sha256']
            or ref.get('bcdboot_exit')!=0 or ref.get('bcdedit_exit')!=0
            or ref.get('physical_disk_touched') is not False or ref.get('host_firmware_entry_requested') is not False
            or ref.get('base_sha256_before')!=proof['vhd_sha256'] or ref.get('base_sha256_after')!=proof['vhd_sha256']
            or ref.get('mode')!=proof['mode'] or ref.get('virtual_bytes')!=proof['virtual_bytes']
            or compare.get('status')!='PASS' or compare.get('core_differences')!={}
            or compare.get('dirty')!=0 or compare.get('after_dirty')!=0 or not HEAD.fullmatch(compare.get('head',''))
            or compare.get('head')!=compare.get('after_head') or compare.get('ours_route')!=compare.get('reference_route')
            or compare.get('bcdboot_receipt_sha256')!=boot['reference_receipt_sha256']
            or compare.get('reference_sha256')!=ref.get('reference_sha256')):
            raise ValueError('Actual guarded bcdboot and semantic comparison PASS required')
        job_path=ref_path.parent/'job.json'
        if pins.get(job_path)!=ref.get('job_sha256'):raise ValueError('Immutable guarded bcdboot job required')
        job=reference.document(job_path,ref['job_sha256'])
        if (job.get('schema')!='minios-bcdboot-reference-job-v1' or job.get('native_receipt_sha256')!=boot['native_receipt_sha256']
            or job.get('base_sha256')!=proof['vhd_sha256'] or job.get('layout_sha256')!=proof['layout_sha256']
            or job.get('mode')!=proof['mode'] or job.get('virtual_bytes')!=proof['virtual_bytes']):
            raise ValueError('Reference bcdboot job layout differs')
        for name in ('source_sha256','reference_sha256'):
            matches=[path for path,sha in pins.items() if sha==compare.get(name)]
            if len(matches)!=1:raise ValueError('Pinned BCD stores required')
            route=bcd_compare.route(bcd_compare.oracle.independent_read(matches[0]))
            if route!=compare['ours_route']:raise ValueError('Reread BCD changed')
            route_layout(route,layout)
    source=oracle.owned(Path(boot['source']))
    if pins.get(source)!=boot['source_sha256']:raise ValueError('Original prepared QCOW2 pin missing')
    target=pin(boot['target'],boot['target_sha256'])
    if target.parent!=args.boot_receipt.parent or target.suffix!='.qcow2' or target==source:
        raise ValueError('Fresh provisioned QCOW2 distinct from prepared source required')
    chain=native.qcow_chain(target,proof['virtual_bytes'])
    if chain[0]!=target or source not in chain[1:] or any(path not in pins for path in chain):
        raise ValueError('Full provisioned image backing chain must be immutable')
    manifest=target.parent/'boot-files.json'
    pin(manifest,boot['boot_files_manifest_sha256'])
    resumed=None; recovery_check=None
    if getattr(args,'resume_receipt',None) is not None:
        previous_path=pin(args.resume_receipt,args.resume_sha256)
        previous=reference.document(previous_path,args.resume_sha256)
        interrupted=getattr(args,'recover_interrupted',False)
        resume_fields(previous,args.boot_sha256,args.arch,interrupted=interrupted)
        previous_target=oracle.owned(Path(previous['target']))
        if (previous_target!=previous_path.parent/'windows.qcow2'
            or not previous_path.parent.name.startswith('firstboot-')
            or previous_path.parent.parent!=target.parent.parent):
            raise ValueError('Resume disk must be the exact prior architecture checkpoint')
        rows=previous.get('logs',{}).get('chain')
        if not isinstance(rows,list) or not 2<=len(rows)<=32:
            raise ValueError('Closed independent resume chain required')
        expected=[]
        for row in rows:
            if not isinstance(row,dict) or set(row)!={'path','sha256'}:
                raise ValueError('Exact resume chain row required')
            expected.append(pin(row['path'],row['sha256']))
        actual=native.qcow_chain(previous_target,proof['virtual_bytes'])
        if (actual!=expected or actual[0]!=previous_target or target not in actual[1:]
            or pins[previous_target]!=previous['target_sha256']):
            raise ValueError('Resume overlay or its immutable ancestors changed')
        if interrupted:
            recovery_check=check_interrupted_checkpoint(args.qemu_dir/'qemu-img.exe',previous_target)
        target=previous_target
        resumed=args.resume_sha256
    return dict(boot=boot,native=proof,layout=layout,target=target,pins=pins,streams=streams,
                resumed_checkpoint_sha256=resumed,interrupted_checkpoint_check=recovery_check)


def command_for(args, out):
    """AHCI on all paths; reboots remain enabled for specialize/OOBE."""
    x64=args.arch=='x86_64'
    accelerator=getattr(args,'accelerator','tcg')
    if accelerator not in ('tcg','whpx') or (accelerator=='whpx' and not x64):
        raise ValueError('WHPX diagnostic is supported only for x86_64')
    irqchip=getattr(args,'whpx_irqchip','default')
    cpu_name=getattr(args,'whpx_cpu','qemu64-no-xsave')
    cpus={'qemu64-no-xsave':'qemu64,-xsave','qemu64':'qemu64','max-no-xsave-avx-avx2-avx512f':'max,-xsave,-avx,-avx2,-avx512f'}
    if irqchip not in ('default','off') or cpu_name not in cpus:
        raise ValueError('Explicit bounded WHPX CPU/irqchip choice required')
    accel='whpx'+(',kernel-irqchip=off' if irqchip=='off' else '')
    command=[args.qemu_dir/('qemu-system-x86_64.exe' if x64 else 'qemu-system-i386.exe'),
             '-machine',('q35' if args.arch!='bios' else 'pc')+('' if os.name=='nt' else ',dump-guest-core=off'),'-accel',accel if accelerator=='whpx' else 'tcg,thread=multi',
             '-cpu',cpus[cpu_name] if accelerator=='whpx' else ('max' if x64 else 'qemu32'),'-m','4096' if x64 else '2048','-smp','2',
             '-nodefaults','-display','none','-nic','none','-monitor','none',
             '-device','ich9-ahci,id=win-ahci',
             *bounds.blockdev_arguments(out/'windows.qcow2'),
             '-device','ide-hd,drive=windows,bus=win-ahci.0,bootindex=1,werror=stop,rerror=stop',
             '-device','VGA','-device','usb-ehci,id=ehci','-device','usb-kbd,bus=ehci.0',
             '-device','usb-tablet,bus=ehci.0','-serial','stdio']
    # Optional controlled diagnostic: QEMU's restricted user backend permits
    # DHCP but routes no guest IP packets to the host or outside. No explicit
    # forwarding is configured. The default remains the original no-NIC run.
    isolated_nic = getattr(args, 'isolated_nic', False)
    if type(isolated_nic) is not bool:
        raise ValueError('Explicit boolean isolated NIC selection required')
    if isolated_nic:
        command.extend(['-netdev','user,id=isolated,restrict=on',
                        '-device','e1000e,netdev=isolated'])
    if args.arch!='bios':
        code=args.qemu_dir/('share/edk2-x86_64-code.fd' if x64 else 'share/edk2-i386-code.fd')
        command.extend(['-drive',f'if=pflash,format=raw,readonly=on,file={code}',
                        '-blockdev',json.dumps(dict(driver='file',**{'node-name':'vars-file'},filename=str(out/'vars.fd'))),
                        '-blockdev',json.dumps(dict(driver='raw',**{'node-name':'vars-limit'},file='vars-file',offset=0,size=(out/'vars.fd').stat().st_size)),
                        '-machine','pflash1=vars-limit'])
    else:
        command.extend(['-bios',str(args.qemu_dir/'share/bios-256k.bin')])
    return command


def logs_after_exit(qemu_img, target, inputs, out, env, scope):
    """No QEMU remains alive. Deny-write all chain files before mapping."""
    with contextlib.ExitStack() as locks:
        chain=native.qcow_chain(target,inputs['native']['virtual_bytes'])
        if chain[1:]!=native.qcow_chain(inputs['target'],inputs['native']['virtual_bytes']):
            raise ValueError('Closed firstboot overlay changed backing identity')
        files=[locks.enter_context(oracle.readonly(path)) for path in chain]
        target_sha=oracle.digest_stream(files[0])
        for path,file in zip(chain[1:],files[1:]):
            if oracle.digest_stream(file)!=inputs['pins'].get(path):raise ValueError('Immutable backing file changed')
        command=list(map(str,[qemu_img,'map','-f','qcow2','--output=json',target]))
        head,dirty=logged_run.tree(REPO)
        if dirty:raise ValueError('Clean closed-image map capture required')
        scope.save('qcow-map-command.json',dict(head=head,dirty=dirty,command=command,
                    child_completed_before_map=True,read_only=True))
        asyncio.run(output.execute(command,scope,'qcow-map.json','qcow-map.stderr',env))
        if logged_run.tree(REPO)!=(head,0):raise ValueError('Closed-image map failed or tree changed')
        map_path=out/'qcow-map.json'
        if map_path.stat().st_size>32*MiB:raise ValueError('QCOW map evidence exceeds bound')
        rows=json.loads(map_path.read_text(encoding='utf-8'))
        for row in rows:
            if row.get('data') and not row.get('zero') and 'filename' in row:
                depth=row.get('depth')
                if type(depth) is not int or not 0<=depth<len(chain) or Path(row['filename'])!=chain[depth]:
                    raise ValueError('QEMU map filename differs from independently parsed depth')
        reader=qcow_map_readonly.Reader(rows,files,inputs['native']['virtual_bytes'])
        if native.disk_layout(reader,inputs['native']['mode'])!=inputs['layout']:
            raise ValueError('Windows changed the accepted partition table')
        number=inputs['layout']['windows_number']
        partition=next(row for row in inputs['layout']['partitions'] if row['number']==number)
        result=firstboot_logs.collect(reader,partition,out/'panther')
        result.update(target_sha256=target_sha,read_only=True,full_exports=0,host_mount_used=False,
                      map_sha256=oracle.digest(map_path),chain=[dict(path=str(p),sha256=oracle.digest_stream(f)) for p,f in zip(chain,files)])
        scope.save('panther-result.json',result)
        return result


def run(args):
    output_guard(args.out,args.arch)
    oracle.local(args.qemu_dir)
    if type(args.endpoint_seconds) is not int or not 60<=args.endpoint_seconds<=10800:
        raise ValueError('Single fixed60..10800second endpoint required')
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError('F3: clean frozen HEAD required')
    with contextlib.ExitStack() as locks:
        inputs=accepted(args,locks)  # All real acceptance precedes output creation.
        capacity=pool.enforce_incremental(args.plan,args.out,MAX_NEW_BYTES,closed_scope=True)
        args.out.mkdir(parents=True)
        scope=output.Scope(args.out)
        # These tools need no temporary files. Do not offer an unbounded temp sink.
        env=os.environ.copy()
        env.update({key:str(args.out/'disabled-temp') for key in ('TEMP','TMP','APPDATA','LOCALAPPDATA','HOME','USERPROFILE')})
        qemu_img=args.qemu_dir/'qemu-img.exe'
        # Creation is deterministic small metadata; only the freshly created
        # QCOW is then extended into a sparse fixed envelope before QEMU opens it.
        async def prepare():
            await output.execute([qemu_img,'create','-f','qcow2','-F','qcow2','-b',inputs['target'],args.out/'windows.qcow2'],
                scope,'overlay-create.log','base-snapshot.log',env,commands.capture_header(head))
            # Both prepare tools share the bounded pair of logs, avoiding append bypass.
        asyncio.run(prepare())
        # Snapshot command output is bounded in memory and copied to the envelope receipt.
        snap=subprocess.run(list(map(str,[qemu_img,'snapshot','-c','firstboot-base',args.out/'windows.qcow2'])),
            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=env,timeout=60,
            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if snap.returncode:raise ValueError('Firstboot base snapshot failed')
        envelope=bounds.pad(args.out/'windows.qcow2',inputs['native']['virtual_bytes'])
        scope.save('envelope.json',envelope)
        if args.arch!='bios':
            data=oracle.local(args.qemu_dir/'share/edk2-i386-vars.fd').read_bytes()
            with scope.open('vars.fd') as stream:stream.write(data)
        start=time.monotonic()
        seconds=args.lifetime.guest_seconds(args.endpoint_seconds) if hasattr(args,'lifetime') else args.endpoint_seconds
        evidence=asyncio.run(firstboot_qmp.endpoint(command_for(args,args.out),args.out,env,seconds,
            scope,commands.capture_header(head),wake_screen=getattr(args,'wake_screen',False)))
        log_result=None
        try:
            log_result=logs_after_exit(qemu_img,args.out/'windows.qcow2',inputs,args.out,env,scope)
        except Exception as error:
            evidence['offline_log_error']=str(error)
        unchanged=all(oracle.digest_stream(inputs['streams'][path])==sha for path,sha in inputs['pins'].items())
        retained=scope.audit()
        bounded=retained+output.LIMITS['result.json']<=MAX_NEW_BYTES
        if logged_run.tree(REPO)!=(head,0):raise ValueError('F3: tree changed during firstboot evidence')
        transport=(evidence.get('returncode')==0 and evidence.get('screenshot_created') is True
                   and 'transport_error' not in evidence and log_result is not None and unchanged and bounded)
        result=dict(schema='minios-windows-firstboot-v1',status='PENDING_REVIEW' if transport else 'EVIDENCE_FAILURE',
                    windows_gate_passed=False,visual_review_required=True,critical_setup_errors_review_required=True,
                    head=head,dirty=0,arch=args.arch,mode=inputs['native']['mode'],first_windows_boot_attempted=True,
                    reference_comparison_deferred=inputs['boot'].get('reference_comparison_deferred',False),
                    boot_receipt_sha256=args.boot_sha256,immutable_base_unchanged=unchanged,
                    resumed_checkpoint_sha256=inputs.get('resumed_checkpoint_sha256'),
                    interrupted_checkpoint_check=inputs.get('interrupted_checkpoint_check'),
                    elapsed_seconds=time.monotonic()-start,qmp=evidence,logs=log_result,
                    target=str(args.out/'windows.qcow2'),target_sha256=oracle.digest(args.out/'windows.qcow2'),
                    retained_new_bytes=retained,new_bytes_budget=MAX_NEW_BYTES,within_budget=bounded,
                    capacity_preflight=capacity,physical_disks_opened=False,host_firmware_entries_changed=False,
                    native_mount_used=False,full_exports=0,deleted=[])
        scope.save('result.json',result)
        scope.audit()
        return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('boot-receipt','qemu-dir','plan','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--boot-sha256',required=True)
    parser.add_argument('--arch',choices=('x86_64','ia32','bios'),required=True)
    parser.add_argument('--accelerator',choices=('tcg','whpx'),default='tcg',
                        help='WHPX is an opt-in x86_64 diagnostic; TCG remains the default')
    parser.add_argument('--endpoint-seconds',type=int,default=600)
    parser.add_argument('--isolated-nic',action='store_true',
                        help='Attach an isolated virtual NIC; no guest traffic is routed outside')
    parser.add_argument('--wake-screen',action='store_true',
                        help='Press/release Shift once at the fixed endpoint before the final screenshot')
    parser.add_argument('--total-seconds',type=int,default=10800)
    parser.add_argument('--resume-receipt',type=Path)
    parser.add_argument('--resume-sha256')
    parser.add_argument('--recover-interrupted',action='store_true',
                        help='Explicit interrupted checkpoint recovery after a read-only QCOW2 check')
    parser.add_argument('--whpx-irqchip',choices=('default','off'),default='default')
    parser.add_argument('--whpx-cpu',choices=('qemu64-no-xsave','qemu64','max-no-xsave-avx-avx2-avx512f'),default='qemu64-no-xsave')
    args=parser.parse_args()
    if (args.resume_receipt is None)!=(args.resume_sha256 is None):
        parser.error('--resume-receipt and --resume-sha256 must be used together')
    if args.recover_interrupted and args.resume_receipt is None:
        parser.error('--recover-interrupted requires a pinned resume receipt')
    output_guard(args.out,args.arch)
    from firstboot_lifetime import Lifetime
    lifetime=Lifetime(args.total_seconds,args.out)
    args.lifetime=lifetime
    try:result=run(args)
    finally:lifetime.close()
    print(json.dumps(result))
    raise SystemExit(0 if result['status']=='PENDING_REVIEW' else 1)
