"""Run explicit coverage cases serially, waiting for completion notifications.

Only one case runs at a time. --after names an owned prior test's cleanup
notification; Windows directory-change events block without status polling.
This does not assess endpoint images or promote a marker to desktop PASS.
"""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
FLAT_SYSTEMS={'windows-xp','windows-xp-mce','windows-xp-tablet','windows-2000',
    'windows-2000-server','windows-server-2003','windows-xp-x64','windows-7'}
NESTED_SYSTEMS={'windows-95','windows-98','windows-98-se','windows-me',
    'windows-nt-3-1','windows-nt-3-1-server','windows-nt-3-5','windows-nt-3-5-server',
    'windows-nt-3-51','windows-nt-3-51-server','windows-nt-4','windows-nt-4-server',
    'windows-nt-4-tse','windows-embedded-posready-2009'}


def validate_system(system,nested):
    if system not in (NESTED_SYSTEMS if nested else FLAT_SYSTEMS):
        raise ValueError('System does not match the explicitly reserved one- or two-engine lane')


def after_cleanup(directory):
    directory=directory.resolve()
    if not directory.is_relative_to(ROOT/'artifacts/coverage/vm'):
        raise ValueError('Completion directory must belong to this coverage worktree')
    after_file(directory/'cleanup.json')


def after_file(path,alternatives=()):
    path=path.resolve()
    if not path.is_relative_to(ROOT/'artifacts/coverage'):
        raise ValueError('Completion file must belong to this coverage worktree')
    directory=path.parent
    if any(Path(name).name!=name for name in alternatives):
        raise ValueError('Alternative completion files must be siblings')
    paths=[path,*(directory/name for name in alternatives)]
    watched=directory
    while not watched.is_dir():
        watched=watched.parent
    expected={str(p.relative_to(watched)).casefold():p for p in paths}
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
    kernel.CreateFileW.restype=ctypes.c_void_p
    kernel.ReadDirectoryChangesW.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_int,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32),ctypes.c_void_p,ctypes.c_void_p]
    kernel.CreateEventW.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_wchar_p]
    kernel.CreateEventW.restype=ctypes.c_void_p
    kernel.ResetEvent.argtypes=[ctypes.c_void_p]
    kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_uint32]
    kernel.GetOverlappedResult.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint32),ctypes.c_int]
    kernel.CancelIoEx.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
    kernel.CloseHandle.argtypes=[ctypes.c_void_p]
    class Overlapped(ctypes.Structure):
        _fields_=[('internal',ctypes.c_size_t),('internal_high',ctypes.c_size_t),
                  ('offset',ctypes.c_uint32),('offset_high',ctypes.c_uint32),('event',ctypes.c_void_p)]
    handle=kernel.CreateFileW(str(watched),1,7,None,3,0x42000000,None)
    if handle==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
    event=kernel.CreateEventW(None,True,False,None)
    if not event:kernel.CloseHandle(handle);raise ctypes.WinError(ctypes.get_last_error())
    overlapped=Overlapped();overlapped.event=event
    pending=False
    check_existing=True
    try:
        buffer=ctypes.create_string_buffer(65536)
        while True:
            received=ctypes.c_uint32()
            kernel.ResetEvent(event)
            # FILE_NOTIFY_CHANGE_FILE_NAME: log writes are not progress events.
            if not kernel.ReadDirectoryChangesW(handle,buffer,len(buffer),watched!=directory,1,None,ctypes.byref(overlapped),None) and ctypes.get_last_error()!=997:
                raise ctypes.WinError(ctypes.get_last_error())
            pending=True
            # Arm the subscription first, then handle a completion already
            # on disk. This closes the check/subscribe race.
            if check_existing:
                check_existing=False
                existing=next((p for p in paths if p.is_file()),None)
                if existing:return existing
            if kernel.WaitForSingleObject(event,0xffffffff)!=0:raise ctypes.WinError(ctypes.get_last_error())
            if not kernel.GetOverlappedResult(handle,ctypes.byref(overlapped),ctypes.byref(received),False):
                raise ctypes.WinError(ctypes.get_last_error())
            pending=False
            if not received.value:raise RuntimeError('Completion notification buffer overflow')
            offset=0
            while received.value-offset>=12:
                import struct
                following,action,length=struct.unpack_from('<III',buffer,offset)
                name=buffer.raw[offset+12:offset+12+length].decode('utf-16-le')
                if action in (1,5) and name.casefold() in expected:return expected[name.casefold()]
                if not following:break
                offset+=following
    finally:
        if pending:
            kernel.CancelIoEx(handle,ctypes.byref(overlapped))
            received=ctypes.c_uint32()
            kernel.GetOverlappedResult(handle,ctypes.byref(overlapped),ctypes.byref(received),True)
        kernel.CloseHandle(event);kernel.CloseHandle(handle)


def run(args):
    cases=json.loads(args.plan.read_text(encoding='utf-8'))
    if args.after:after_cleanup(args.after)
    if getattr(args,'after_file',None):after_file(args.after_file)
    for case in cases:
        validate_system(case['system'],args.nested)
        tag=case['tag']
        if not re.fullmatch('[a-z0-9-]+',tag):raise ValueError('Invalid case tag')
        out=ROOT/'artifacts/coverage/vm'/tag
        work=COLLECTION/'_vm'/tag
        inputs=COLLECTION/'_inputs'/tag
        if out.exists() or work.exists() or inputs.exists():raise FileExistsError('Refusing an existing case')
        if shutil.disk_usage(COLLECTION).free<100*1024**3:raise RuntimeError('Less than 100 GiB free')
        outcome=dict(tag=tag,started=time.strftime('%Y-%m-%dT%H:%M:%S%z'),source=case['source'])
        logdir=ROOT/'artifacts/coverage/plan-logs';logdir.mkdir(parents=True,exist_ok=True)
        try:
            source=Path(case['source'])
            if source.drive.upper()=='G:' and not source.resolve().is_relative_to(COLLECTION):
                raise ValueError('G: input outside the authorized collection')
            if case.get('member'):
                inputs.mkdir(parents=True)
                subprocess.run([str(args.seven),'e','-y','-o'+str(inputs),str(source),case['member']],check=True,stdout=subprocess.DEVNULL)
                source=inputs/Path(case['member']).name
                with source.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
                if digest!=case['member_sha256']:raise ValueError('Extracted member hash mismatch')
            service_pack=None
            if case.get('service_pack'):
                sp=case['service_pack']
                sp_source=Path(sp['source'])
                if sp_source.drive.upper()=='G:' and not sp_source.resolve().is_relative_to(COLLECTION):
                    raise ValueError('G: prerequisite outside the authorized collection')
                if sp.get('member'):
                    inputs.mkdir(parents=True,exist_ok=True)
                    subprocess.run([str(args.seven),'e','-y','-o'+str(inputs),str(sp_source),sp['member']],check=True,stdout=subprocess.DEVNULL)
                    service_pack=inputs/Path(sp['member']).name
                else:service_pack=sp_source
                with service_pack.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
                if digest!=sp['sha256']:raise ValueError('Extracted service pack hash mismatch')
            prepare=[sys.executable,'-I','-B',str(HERE/'prepare_stick.py'),'--assets',str(args.assets),'--qemu',str(args.qemu),
                '--iso',str(source),'--folder',case['folder'],'--profile',str(case.get('profile',args.profile)),'--trace-menus','--out',str(work)]
            if case.get('donor'):prepare+=['--donor',case['donor']]
            if service_pack:prepare+=['--legacy-service-pack',str(service_pack)]
            if case.get('boot_floppy'):prepare+=['--boot-floppy',case['boot_floppy']]
            if case.get('nvme_9x'):prepare+=['--nvme-9x']
            if case.get('private_key'):
                prepare+=['--private-key',case['private_key'],'--key-for',case['system']]
                if 'key_index' in case:prepare+=['--key-index',str(case['key_index'])]
            if case.get('legacy_first_logon'):prepare+=['--legacy-first-logon']
            elif case.get('first_logon',not args.nested):prepare+=['--first-logon-observer','--observer-ide']
            boot=[sys.executable,'-I','-B',str(HERE/'boot_menu.py'),'--qemu',str(args.qemu),'--fixture',str(work),
                '--out',str(out),'--seconds',str(case.get('seconds',3600)),'--target-gib',str(case.get('target_gib',8)),
                '--target-bus',case.get('target_bus','ahci'),'--accel',args.accel]
            if case.get('ps2_input',not args.nested):boot+=['--ps2-input']
            if 'boot_seconds' in case:boot+=['--boot-seconds',str(case['boot_seconds'])]
            if case.get('auto_native'):boot+=['--auto-native']
            with (logdir/(tag+'.log')).open('w',encoding='utf-8') as log:
                subprocess.run(prepare,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
                subprocess.run(boot,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
            outcome['result']=json.loads((out/'result.json').read_text(encoding='utf-8'))['result']
        except (OSError,ValueError,subprocess.SubprocessError) as error:
            outcome.update(result='RUNNER_ERROR',error=type(error).__name__)
        finally:
            # Each child has returned; these exact, newly created inputs only.
            if inputs.exists() and inputs.resolve().is_relative_to(COLLECTION/'_inputs'):shutil.rmtree(inputs)
            removed=[]
            for name in ('stick.qcow2','target.qcow2','vars.fd','observer.iso'):
                path=work/name
                if path.exists():path.unlink();removed.append(name)
            outcome['leftover_images_removed']=removed
            out.mkdir(parents=True,exist_ok=True)
            if not (out/'result.json').exists():
                (out/'result.json').write_text(json.dumps(outcome,indent=2)+'\n',encoding='utf-8')
            # A rejected fixture is also terminal. Dependents must not hang
            # because boot_menu never started and could not emit cleanup.
            if not (out/'cleanup.json').exists():
                (out/'cleanup.json').write_text(json.dumps({'runner_cleanup':True,'removed':removed})+'\n',encoding='utf-8')
            (logdir/(tag+'.json')).write_text(json.dumps(outcome,indent=2)+'\n',encoding='utf-8')
        print('CASE_COMPLETE '+tag+' '+outcome['result'],flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('plan','assets','qemu','profile'):parser.add_argument('--'+name,type=Path,required=True)
    dependency=parser.add_mutually_exclusive_group()
    dependency.add_argument('--after',type=Path)
    dependency.add_argument('--after-file',type=Path,help='Wait for an owned terminal plan manifest before reserving this lane')
    parser.add_argument('--seven',type=Path,default=Path(r'C:\Program Files\7-Zip\7z.exe'))
    parser.add_argument('--accel',choices=('tcg','whpx'),default='tcg')
    parser.add_argument('--nested',action='store_true',help='Explicitly reserve two engines for a serial 9x/NT3/NT4/POSReady lane; caller must enforce the global cap')
    run(parser.parse_args())
