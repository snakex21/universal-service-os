#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One bounded reference firstboot. Result is evidence, never an OOBE PASS."""
import argparse, asyncio, contextlib, json, os, re, shutil, subprocess, time
from pathlib import Path
import diagnostic_boot_guard as guard
import diagnostic_boot_overlay as overlay
import diagnostic_boot_runner as boot
import diagnostic_firstboot_map as maps
import firstboot_bounds as bounds
import firstboot_logs as logs
import firstboot_output as output
import firstboot_qmp as qmp
import host_dism_capacity as capacity
import host_dism_vhdx_verify as vhdx
import install_native as native
import logged_run
import qcow_map_readonly as qcow
import tag4_collector as collector
import tag4_diff as diff
import wim_oracle as oracle

MIB=1024**2
BASE_SHA=guard.IMAGE_SHA
BOOT_SHA='db7f2cfc94cb180baa8d3c6fc06e120f46d554d3d4a640b38ae72e894069eb57'
QEMU_SHA='47d57a6072e0bb3bd98f87926eb129eb1736dfe818c67b3b81ef7ce4edd0b3cd'
CODE_SHA='33090cc07675baa5190d9f1e84bf5176b33bcbfa9bacac522961150cdb6dbb2a'
VARS_SHA='5d2ac383371b408398accee7ec27c8c09ea5b74a0de0ceea6513388b15be5d1e'

def aux_usage(folder):
    total=0
    for path in folder.rglob('*'):
        info=path.lstat()
        if path.is_symlink() or getattr(info,'st_file_attributes',0)&0x400:raise ValueError('Reparse point in preparation evidence')
        if path.is_dir():continue
        if not path.is_file() or info.st_nlink!=1:raise ValueError('Invalid preparation evidence')
        if path.name!='boot.qcow2':total+=info.st_size
    return total

def validate_budget(used,limits):
    if type(used) is not int or used<0:raise ValueError('Invalid auxiliary usage')
    reserve=sum(v for k,v in limits.items() if k!='windows.qcow2')+output.PANTHER_LIMIT
    if used+reserve>guard.AUX_BOUND:raise ValueError('Shared auxiliary bound exceeded')
    guard.check_budget(guard.BOOT_BOUND,guard.FIRSTBOOT_BOUND,guard.AUX_BOUND)
    return reserve

def receipt_ok(data,boot_path):
    if (data.get('schema')!='minios-reference-boot-preparation-v1' or data.get('passed') is not True or
        data.get('source_image_sha256')!=BASE_SHA or data.get('overlay_sha256')!=BOOT_SHA or
        Path(data.get('overlay',''))!=boot_path or data.get('qemu_exit')!=33 or
        data.get('first_windows_boot_attempted') is not False or data.get('external_bcd_comparison')!='deferred'):
        raise ValueError('Exact successful boot preparation required')

def command(qemu,code,out):
    var=out/'vars.fd'
    return [qemu,'-machine','q35','-accel','tcg,thread=multi','-cpu','max','-m','4096','-smp','2',
       '-nodefaults','-display','none','-nic','none','-monitor','none','-device','ich9-ahci,id=win-ahci',
       *bounds.blockdev_arguments(out/'windows.qcow2',maximum=guard.FIRSTBOOT_BOUND),
       '-device','ide-hd,drive=windows,bus=win-ahci.0,bootindex=1,werror=stop,rerror=stop',
       '-device','VGA','-device','usb-ehci,id=ehci','-device','usb-kbd,bus=ehci.0',
       '-device','usb-tablet,bus=ehci.0','-serial','stdio',
       '-drive',f'if=pflash,format=raw,readonly=on,file={code}',
       '-blockdev',json.dumps({'driver':'file','node-name':'vars-file','filename':str(var)}),
       '-blockdev',json.dumps({'driver':'raw','node-name':'vars-limit','file':'vars-file','offset':0,'size':var.stat().st_size}),
       '-machine','pflash1=vars-limit']

def capacity_preflight(root,case,job,reserve):
    return capacity.preflight(root,Path(job['capacity_plan']),job['capacity_plan_sha256'],case,
                              image_exists=True,growth_bytes=guard.FIRSTBOOT_BOUND+reserve)


def run(job_path,job_sha,lifetime):
    boot.assert_process_limits()
    head,dirty=logged_run.tree(boot.REPO)
    if dirty:raise ValueError('Clean HEAD required')
    root=oracle.RUNTIME;case=root/'1c7'/boot.CASE;resume=case/boot.RESUME
    with contextlib.ExitStack() as locks:
        def pin(path,sha):
            path=oracle.local(Path(path));f=locks.enter_context(diff.locked(path))
            if diff.digest(f)!=sha:raise ValueError('Pinned file differs: '+path.name)
            return f
        job=pin(diff.checked_path(root,str(job_path)),job_sha);config=json.load(job)
        if config.get('schema')!='minios-reference-firstboot-job-v1' or config.get('head')!=head:
            raise ValueError('Pinned clean HEAD job required')
        prepared=resume/'diag-boot-a3a6eb8e-0675-4f3c-aaa2-39e94abead71';parent=prepared/'boot.qcow2'
        image=case/'install.vhdx';out=Path(config['out'])
        if out.parent!=resume or not re.fullmatch(r'diag-firstboot-[0-9a-f-]{36}',out.name) or out.exists():
            raise ValueError('Fresh exact diagnostic output required')
        imgf=pin(image,BASE_SHA);parentf=pin(parent,BOOT_SHA)
        if parent.stat().st_size!=guard.BOOT_BOUND:raise ValueError('Preparation overlay envelope differs')
        overlay.inspect_header(parentf,parent.stat().st_size,image,'vhdx')
        result=pin(prepared/'result.json',config['preparation_sha256']);receipt_ok(json.load(result),parent)
        layout=vhdx.check_layout(imgf,32*1024**3,vhdx.real_allocation(image),33*1024**3,include_map=True)
        guard.validate(qcow.Reader(layout['map'],[imgf],32*1024**3),BASE_SHA)
        qemu=Path(config['qemu']);qimg=Path(config['qemu_img']);code=Path(config['code']);var=Path(config['vars_template'])
        if qemu.name.lower()!='qemu-system-x86_64.exe' or qimg.name.lower()!='qemu-img.exe':
            raise ValueError('Expected explicitly pinned QEMU utilities')
        for path,sha in ((qemu,QEMU_SHA),(qimg,boot.QEMU_SHA),(code,CODE_SHA),(var,VARS_SHA)):pin(path,sha)
        used=aux_usage(prepared);reserve=validate_budget(used,output.LIMITS)
        cap=capacity_preflight(root,case,config,reserve)
        if max(cap['other_logical_bytes'],cap['other_allocated_bytes'])+guard.FIRSTBOOT_BOUND+reserve>3*1024**3:
            raise ValueError('Remaining case capacity insufficient')
        oracle.local(out);out.mkdir();scope=output.Scope(out)
        output.LIMITS['windows.qcow2']=guard.FIRSTBOOT_BOUND
        output.SCOPE_LIMIT=guard.FIRSTBOOT_BOUND+reserve
        env=oracle.environment(out);header=('HEAD='+head+' DIRTY=0\n').encode()
        evidence=None;start=time.monotonic();target=out/'windows.qcow2'
        try:
            asyncio.run(output.execute([qimg,'create','-f','qcow2','-F','qcow2','-b',parent,target],scope,
                       'overlay-create.log','base-snapshot.log',env,header))
            with target.open('rb') as f:overlay.inspect_header(f,target.stat().st_size,parent,'qcow2')
            native.empty_wrapper(target)
            subprocess.run([str(qimg),'snapshot','-c','firstboot-base',str(target)],check=True,timeout=60,
                           stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            envelope=bounds.pad(target,32*1024**3,maximum=guard.FIRSTBOOT_BOUND)
            with target.open('rb') as f:overlay.inspect_header(f,target.stat().st_size,parent,'qcow2')
            scope.save('envelope.json',envelope)
            with scope.open('vars.fd') as f:f.write(var.read_bytes())
            evidence=asyncio.run(qmp.endpoint(command(qemu,code,out),out,env,lifetime.guest_seconds(10800),scope,header))
            with target.open('rb') as f:overlay.inspect_header(f,target.stat().st_size,parent,'qcow2')
            with diff.locked(target) as targetf:
                scope.save('qcow-map-command.json',{'head':head,'dirty':0,'read_only':True,'child_completed_before_map':True})
                asyncio.run(output.execute([qimg,'map','-f','qcow2','--output=json',target],scope,'qcow-map.json','qcow-map.stderr',env))
                rows=json.loads((out/'qcow-map.json').read_text(encoding='utf-8'))
                for row in rows:
                    if 'filename' in row:
                        depth=row.get('depth')
                        if type(depth) is not int or depth not in (0,1,2) or Path(row['filename'])!=[target,parent,image][depth]:
                            raise ValueError('Unexpected map backing filename')
                reader=qcow.Reader(maps.materialize(rows,layout['map'],32*1024**3),[targetf,parentf,imgf],32*1024**3)
                part=collector.gpt_partition(reader,guard.WINDOWS,allow_windows_mbr_sentinel=True)
                if part['disk_guid']!=guard.DISK or part['start']!=289406976 or part['bytes']!=34069282816:
                    raise ValueError('Guest partition identity changed')
                panther=logs.collect(reader,part,out/'panther');scope.save('panther-result.json',panther)
                target_sha=diff.digest(targetf)
            if diff.digest(imgf)!=BASE_SHA or diff.digest(parentf)!=BOOT_SHA:raise ValueError('Immutable parent changed')
            if logged_run.tree(boot.REPO)!=(head,0):raise ValueError('Tree changed during run')
            report={'schema':'minios-reference-firstboot-v1','status':'INCONCLUSIVE' if evidence.get('transport_error') else 'PENDING_REVIEW',
                    'head':head,'dirty':0,'qmp':evidence,'elapsed_seconds':time.monotonic()-start,
                    'target_sha256':target_sha,'base_sha256':BASE_SHA,'boot_sha256':BOOT_SHA,'panther':panther,
                    'capacity':cap,'preparation_auxiliary_bytes':used,'firstboot_auxiliary_reservation':reserve,
                    'oobe_or_specialize_pass':False,'physical_disks_opened':False,'host_bcd_modified':False}
            scope.save('result.json',report);scope.audit();return report
        except Exception as error:
            try:scope.save('failure.json',{'head':head,'dirty':0,'error':str(error),'qmp':evidence,'status':'INCONCLUSIVE'})
            except Exception:pass
            raise

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--job',required=True,type=Path);p.add_argument('--job-sha256',required=True)
    a=p.parse_args()
    # Entire operation, not just the guest: timeout also bounds evidence work.
    with diff.locked(diff.checked_path(oracle.RUNTIME,str(a.job))) as job:
        if diff.digest(job)!=a.job_sha256:raise ValueError('Pinned job required')
        cfg=json.load(job)
    from firstboot_lifetime import Lifetime
    lifetime=Lifetime(10800,Path(cfg['out']))
    try:print(json.dumps(run(a.job,a.job_sha256,lifetime)))
    finally:lifetime.close()
