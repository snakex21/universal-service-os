#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reviewed-only runner for the one bounded QEMU DISM boot preparation.

Never opens a physical disk or host BCD. The separate firstboot is NOT run.
The VHDX stays deny-write locked while a single bounded overlay is written.
"""
import argparse,asyncio,contextlib,ctypes,hashlib,json,os,re,subprocess,uuid
from pathlib import Path
import diagnostic_boot_guard as guard
import diagnostic_boot_overlay as overlay
import diagnostic_boot_plan as plan
import firstboot_bounds as bounds
import firstboot_output as output
import host_dism_capacity as capacity
import host_dism_vhdx_verify as vhdx
import install_native as native
import logged_run
import qcow_map_readonly as qcow
import tag4_diff as diff
import wim_firmware_case as firmware
import wim_oracle as oracle

REPO=Path(__file__).resolve().parents[2]
CASE='host-dism-538d709d-91fb-4e74-a43b-8a123e253760'
RESUME='resume-7489b026-f807-4100-a120-06d1c2c2d836'
QEMU_SHA='9d930582d0d574bb106d89982c547688e10b8f356192d302cc3d0ae4e8674534'
PROGRAM_SHA='bea7848fb6e4dd56531fca771898c41afddc1c194c6f5936434c2ca37d7bebaf'

def assert_process_limits():
    if os.name!='nt':raise ValueError('Windows controlled diagnostic required')
    k=ctypes.WinDLL('kernel32',use_last_error=True)
    k.GetCurrentProcess.restype=ctypes.c_void_p
    k.GetPriorityClass.argtypes=[ctypes.c_void_p];k.GetPriorityClass.restype=ctypes.c_uint32
    k.GetProcessAffinityMask.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_size_t),ctypes.POINTER(ctypes.c_size_t)]
    k.GetProcessAffinityMask.restype=ctypes.c_int
    proc=k.GetCurrentProcess();mask=ctypes.c_size_t();system=ctypes.c_size_t()
    if k.GetPriorityClass(proc)!=0x4000 or not k.GetProcessAffinityMask(proc,ctypes.byref(mask),ctypes.byref(system)) or mask.value.bit_count()!=2:
        raise ValueError('BelowNormal priority and exactly two allowed host CPUs required')

class Scope:
    caps={'create.out':2*1024**2,'create.err':2*1024**2,'snapshot.out':2*1024**2,'snapshot.err':2*1024**2,
          'debug.stdout':16*1024**2,'qemu.stderr':16*1024**2}
    def __init__(self,root):self.root=root
    def open(self,name,prefix=b''):
        if name not in self.caps:raise ValueError('Unknown bounded output')
        sink=output.Sink(self.root/name,self.caps[name]);sink.write(prefix);return sink

async def run_guest(command,scope,env,prefix,seconds):
    if not 60<=seconds<=900:raise ValueError('Diagnostic runtime bound required')
    failure=asyncio.get_running_loop().create_future()
    with scope.open('debug.stdout',prefix) as out,scope.open('qemu.stderr',prefix) as err:
        child=await asyncio.create_subprocess_exec(*map(str,command),stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,env=env,
            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        tasks=[asyncio.create_task(output.drain(child.stdout,out,failure)),asyncio.create_task(output.drain(child.stderr,err,failure))]
        wait=asyncio.create_task(child.wait())
        try:
            done,_=await asyncio.wait({wait,failure},timeout=seconds,return_when=asyncio.FIRST_COMPLETED)
            if failure.done():raise ValueError(failure.result())
            if wait not in done:raise ValueError('Diagnostic guest timed out')
            await asyncio.wait_for(asyncio.gather(*tasks),15)
            if failure.done():raise ValueError(failure.result())
            return wait.result()
        finally:
            if not wait.done():child.kill()
            await asyncio.wait_for(asyncio.shield(wait),15)
            await asyncio.wait_for(asyncio.gather(*tasks),15)

def capacity_preflight(root,case,job):
    return capacity.preflight(root,Path(job['capacity_plan']),job['capacity_plan_sha256'],case,
                              image_exists=True,growth_bytes=guard.BOOT_BOUND+guard.AUX_BOUND)


def run(job_path,job_sha):
    assert_process_limits()
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError('Clean frozen HEAD required')
    root=oracle.RUNTIME;case=root/'1c7'/CASE;resume=case/RESUME
    job_path=diff.checked_path(root,str(job_path))
    if not re.fullmatch('[0-9a-f]{64}',job_sha):raise ValueError('Exact job SHA required')
    with contextlib.ExitStack() as locks:
        job_stream=locks.enter_context(diff.locked(job_path))
        if diff.digest(job_stream)!=job_sha:raise ValueError('Job SHA differs')
        job=json.load(job_stream)
        if job.get('schema')!='minios-reference-boot-job-v1' or job.get('head')!=head:
            raise ValueError('Exact current job and clean HEAD required')
        if job.get('image_sha256')!=guard.IMAGE_SHA or job.get('program_sha256')!=PROGRAM_SHA:
            raise ValueError('Exact reference image and reviewed EFI required')
        out=Path(job['out']);plan.plan_paths(resume,out)
        if out.exists():raise ValueError('Fresh output required')
        qemu=oracle.local(Path(job['qemu']));qimg=oracle.local(Path(job['qemu_img']));program=oracle.local(Path(job['program']))
        code=oracle.local(Path(job['code']));vars_template=oracle.local(Path(job['vars_template']))
        if qemu.name.lower()!='qemu-system-x86_64.exe' or qimg.name.lower()!='qemu-img.exe' or program.name!='uefi-reference-boot-final.efi':
            raise ValueError('Exact utility names required')
        def pin(path,sha):
            if not re.fullmatch('[0-9a-f]{64}',sha):raise ValueError('Input SHA required')
            stream=locks.enter_context(diff.locked(path))
            if diff.digest(stream)!=sha:raise ValueError('Pinned input differs: '+path.name)
            return stream
        image=case/'install.vhdx';image_file=pin(image,guard.IMAGE_SHA)
        layout=vhdx.check_layout(image_file,32*1024**3,vhdx.real_allocation(image),33*1024**3,include_map=True)
        identity=guard.validate(qcow.Reader(layout['map'],[image_file],32*1024**3),guard.IMAGE_SHA)
        for path,sha in ((qemu,job['qemu_sha256']),(qimg,QEMU_SHA),(program,PROGRAM_SHA),
                         (code,job['code_sha256']),(vars_template,job['vars_sha256'])):pin(path,sha)
        cap=capacity_preflight(root,case,job)
        if max(cap['other_logical_bytes'],cap['other_allocated_bytes'])>1024**3-guard.AUX_BOUND:
            raise ValueError('Insufficient non-overlay auxiliary reservation')
        guard.check_budget(guard.BOOT_BOUND,guard.FIRSTBOOT_BOUND,guard.AUX_BOUND)
        oracle.local(out);out.mkdir()
        scope=Scope(out);prefix=('HEAD='+head+' DIRTY=0\n').encode()
        env=oracle.environment(out)
        # These two receipts describe the actual disk identity and the user's
        # explicit deferral; they do not claim any bcdboot comparison passed.
        layout_data=(json.dumps({'schema':'minios-reference-layout-v1','image_sha256':guard.IMAGE_SHA,**identity},sort_keys=True)+'\n').encode()
        policy_data=(json.dumps({'schema':'minios-reference-bcd-deferred-v1','external_comparison':'deferred','host_bcdboot_used':False},sort_keys=True)+'\n').encode()
        loader=uuid.uuid4();cfg=plan.configuration(hashlib.sha256(layout_data).hexdigest(),hashlib.sha256(policy_data).hexdigest(),loader)
        firmware.api.configure(root,qemu.parent)
        utility=out/'utility.raw';esp=firmware.SmallEsp(utility)
        esp.add('EFI/BOOT/BOOTX64.EFI',program.stat().st_size,firmware.api.blocks(program))
        for name,data in (('USOSBOOT.CFG',cfg),('USOSLAY.RCP',layout_data),('USOSBCD.RCP',policy_data)):esp.add(name,len(data),[data])
        esp.finish()
        if utility.stat().st_size!=plan.UTILITY_BYTES:raise ValueError('Utility RAW size differs')
        entropy=os.urandom(64);(out/'entropy.bin').write_bytes(entropy)
        raw_vars=vars_template.read_bytes()
        if len(raw_vars)>plan.LIMITS['vars.fd']:raise ValueError('Firmware vars bound exceeded')
        (out/'vars.fd').write_bytes(raw_vars)
        target=out/'boot.qcow2'
        asyncio.run(output.execute([qimg,'create','-f','qcow2','-F','vhdx','-b',image,target],scope,'create.out','create.err',env,prefix,60))
        with target.open('rb') as f:overlay.inspect_header(f,target.stat().st_size,image,'vhdx')
        native.empty_wrapper(target)
        asyncio.run(output.execute([qimg,'snapshot','-c','reference-base',target],scope,'snapshot.out','snapshot.err',env,prefix,60))
        envelope=bounds.pad(target,32*1024**3,maximum=guard.BOOT_BOUND)
        with target.open('rb') as f:overlay.inspect_header(f,target.stat().st_size,image,'vhdx')
        command=plan.command(qemu,code,out/'vars.fd',utility,target,out/'entropy.bin')
        rc=asyncio.run(run_guest(command,scope,env,prefix,job.get('timeout_seconds',900)))
        text=(out/'debug.stdout').read_text(encoding='utf-8',errors='replace')
        if diff.digest(image_file)!=guard.IMAGE_SHA:raise ValueError('Reference base changed')
        passed=(rc==33 and 'BOOT_UEFI PASS' in text and 'USOSBOOT FINAL' in text and
                'STACK canary_ok=true' in text and 'USOSPREP PLATFORM' in text and ' FAIL' not in text)
        result={'schema':'minios-reference-boot-preparation-v1','passed':passed,'head':head,'dirty':0,
                'source_image_sha256':guard.IMAGE_SHA,'external_bcd_comparison':'deferred',
                'host_bcdboot_used':False,'physical_disks_opened':False,'qemu_exit':rc,
                'overlay':str(target),'overlay_sha256':oracle.digest(target),'envelope':envelope,
                'identity':identity,'boot_bound':guard.BOOT_BOUND,'firstboot_bound':guard.FIRSTBOOT_BOUND,
                'aux_bound':guard.AUX_BOUND,'first_windows_boot_attempted':False}
        if logged_run.tree(REPO)!=(head,0):raise ValueError('Tree changed during diagnostic')
        data=(json.dumps(result,indent=2)+'\n').encode()
        if len(data)>plan.LIMITS['manifest_and_config']:raise ValueError('Result bound exceeded')
        with (out/'result.json').open('xb') as f:f.write(data)
        if not passed:raise ValueError('Guest preparation did not pass; see retained logs')
        return result

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--job',required=True,type=Path);p.add_argument('--job-sha256',required=True)
    a=p.parse_args();print(json.dumps(run(a.job,a.job_sha256),indent=2))
if __name__=='__main__':main()
