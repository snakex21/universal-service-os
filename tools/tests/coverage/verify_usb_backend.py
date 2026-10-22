"""Opt-in host regression: real paused QEMU, no Windows or other guest OS.

Reproduce legacy backend deletion, then reuse each production fixture's
named qcow2 node through three completed device_del/device_add cycles.
"""
from pathlib import Path
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
import shutil

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('usb_backend_menu',HERE/'boot_menu.py')
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


async def main(args):
    work=args.work.resolve()
    if work!=args.work.absolute() or not work.is_relative_to(COLLECTION/'_vm'):
        raise ValueError('Use a new exact owned collection VM folder')
    work.mkdir(parents=True,exist_ok=False)
    resources=menu.fixture.check_resources(work,32)
    (work/'preflight.json').write_text(json.dumps(resources,indent=2)+'\n',encoding='utf-8')
    runtime=work/'host-runtime';runtime.mkdir()
    environment=os.environ.copy()
    for name in ('APPDATA','LOCALAPPDATA','TEMP','TMP'):environment[name]=str(runtime)
    disks=menu.aux.create_sticks(work,args.qemu)
    legacy=work/'legacy.qcow2';shutil.copyfile(disks[0],legacy)
    all_disks=[*disks,legacy]
    before={path.name:digest(path) for path in all_disks}
    qmp=menu.Qmp()
    server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
    command=[str(args.qemu),'-no-user-config','-nodefaults','-display','none',
        '-machine','q35','-accel','tcg','-m','32','-smp','1','-S','-nic','none',
        '-device','qemu-xhci,id=xhci',
        '-drive','if=none,id=legacydrive,format=qcow2,file='+str(legacy),
        '-device','usb-storage,id=legacy,bus=xhci.0,drive=legacydrive',
        '-qmp','tcp:127.0.0.1:'+str(server.sockets[0].getsockname()[1])+',server=off']
    for kind,path in zip(('boot','hot'),disks):
        command+=menu.aux.usb_block_arguments(kind,path)
        command+=['-device','usb-storage,id=usability-'+kind+',bus=xhci.0,drive=usability'+kind]
    (work/'command.json').write_text(json.dumps(command,indent=2)+'\n',encoding='utf-8')
    result={'guest_os':None,'guest_usb_pass':False,'host_regression_pass':False}
    with (work/'qemu-stderr.txt').open('wb') as error:
        process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL,stderr=error,env=environment)
        try:
            await asyncio.wait_for(qmp.connected.wait(),30)
            await qmp.command('qmp_capabilities')
            await qmp.delete_device('legacy')
            try:
                await qmp.command('device_add',{'driver':'usb-storage','id':'legacy',
                    'bus':'xhci.0','drive':'legacydrive'})
            except RuntimeError as failure:
                result['legacy_reinsert_error']=str(failure)
            else:raise AssertionError('Legacy negative control did not reproduce backend deletion')
            if "can't find value 'legacydrive'" not in result['legacy_reinsert_error']:
                raise AssertionError('Legacy failed for an unrelated reason')
            for kind in ('boot','hot'):
                for cycle in range(3):
                    await qmp.delete_device('usability-'+kind)
                    await qmp.command('device_add',{'driver':'usb-storage','id':'usability-'+kind,
                        'bus':'xhci.0','drive':'usability'+kind})
                result[kind+'_reinsert_cycles']=3
        finally:
            if process.returncode is None:
                try:await qmp.command('quit')
                except (ConnectionError,RuntimeError):pass
                try:await asyncio.wait_for(process.wait(),30)
                except asyncio.TimeoutError:
                    process.terminate();await process.wait()
            server.close();await server.wait_closed()
            if qmp.writer:
                qmp.writer.close()
                try:await qmp.writer.wait_closed()
                except (ConnectionError,OSError):pass
    after={path.name:digest(path) for path in all_disks}
    result.update(qemu_exit=process.returncode,before_sha256=before,after_sha256=after,
                  images_unchanged=before==after)
    result['host_regression_pass']=process.returncode==0 and before==after
    if result['host_regression_pass']:
        for path in all_disks:
            if path.resolve().parent!=work or path.is_symlink():raise ValueError('Cleanup escaped owned folder')
            path.unlink()
        result['own_images_removed']=[path.name for path in all_disks]
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result),flush=True)
    if not result['host_regression_pass']:raise SystemExit(1)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('qemu','work'):parser.add_argument('--'+name,type=Path,required=True)
    asyncio.run(main(parser.parse_args()))
