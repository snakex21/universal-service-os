"""Replace own files only on a new overlay of cleanly completed R24."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,shutil,struct,subprocess,tempfile,warnings
ROOT=Path(__file__).resolve().parents[2]
MATRIX=ROOT.parent/'macierz-windows'
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
TAG='r24b-nt31-image-entry'
BASE=COLLECTION/'_vm/r24-nt31-intel-fullmac/target.qcow2'
BASE_SHA='769e75a2f9f13ba35a9912bb658a55213c7ae756e3c9a45dfc3a0c02dce8ff17'
WORK=COLLECTION/'_vm'/TAG
RUNTIME=ROOT/'artifacts/nt31-fullmac-runtime'
OUT=RUNTIME/'r24b-preparation.json'
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def digest(data):return hashlib.sha256(data).hexdigest()
def main(build):
    if WORK.exists() or OUT.exists():raise FileExistsError('Fresh retry paths required')
    if not build.resolve().is_relative_to(ROOT/'artifacts/nt31-fullmac-build'):raise ValueError('Owned candidate build only')
    if sha(BASE)!=BASE_SHA:raise ValueError('Pinned completed R24 base required')
    stopped=json.loads((RUNTIME/'vm/r24-nt31-intel-fullmac/completed.json').read_text(encoding='utf-8'))
    prior=json.loads((RUNTIME/'vm/r24-nt31-intel-fullmac/result.json').read_text(encoding='utf-8'))
    if stopped.get('stopped') is not True or prior.get('qemu_returncode')!=0:raise ValueError('R24 writer must be completed')
    metadata=json.loads((BASE.parent/'fixture.json').read_text(encoding='utf-8'))
    if metadata.get('private_profile') is not False or metadata.get('folder')!='Windows NT 3.1':raise ValueError('Only explicit keyless NT31')
    old=json.loads((RUNTIME/'r24-preparation.json').read_text(encoding='utf-8'))
    check=load('nt31_retry_candidate',ROOT/'tools/tests/preflight_usosnet31.py');check.check(build)
    manifest=json.loads((build/'build.json').read_text(encoding='utf-8'))
    fat=load('nt31_retry_fat',ROOT.parent/'nt351-net/tools/tests/coverage/prepare_nt351_debug.py')
    reg=load('nt31_retry_regf',MATRIX/'tools/tests/coverage/regf11.py')
    prep=load('nt31_retry_commands',ROOT/'tools/tests/prepare_nt31_fullmac.py')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('100GiB reserve required')
    WORK.mkdir();raw=WORK/'scratch-stopped.raw'
    result=dict(scope='Completed R24 own-file retry only; no new OS install or LAN PASS',tag=TAG,base=str(BASE),base_sha256=BASE_SHA,
        driver_sha256=manifest['sha256'],driver_size=manifest['size'],helper_sha256=manifest['helper_sha256'],
        logger_sha256=old['logger_sha256'],bdf='00:05.0',mac=old['mac'],runtime_pass=False,
        historical_base_assessment=str(RUNTIME/'r24-guest-evaluation.json'),private_profile=False)
    try:
        subprocess.run([str(fat.QIMG),'convert','-f','qcow2','-O','raw',str(BASE),str(raw)],check=True,capture_output=True)
        fs=fat.BoundedFat(raw)
        try:
            protected={name:fat.file_data(fs,'WINNT/SYSTEM32/'+name,8*1024**2)[0] for name in
                ('CONFIG/SYSTEM','DRIVERS/USOSUSB.SYS','DRIVERS/KBDCLASS.SYS','DRIVERS/MOUCLASS.SYS','DRIVERS/NDIS.SYS','DRIVERS/TCPIP.SYS','DRIVERS/STREAMS.SYS','NTOSKRNL.EXE','HAL.DLL','KERNEL32.DLL','ADVAPI32.DLL')}
            modules={leaf.lower():protected[leaf] for leaf in ('NTOSKRNL.EXE','HAL.DLL','KERNEL32.DLL','ADVAPI32.DLL')}
            modules['ndis.sys']=protected['DRIVERS/NDIS.SYS']
            result['actual_installed_import_preflight']={name:prep.imports_against(path.read_bytes(),modules) for name,path in
                [('driver',build/'usosnet31.sys'),('helper',build/'NET31CFG.EXE')]}
            values=reg.Hive11(protected['CONFIG/SYSTEM']).values
            if values['select']['current']!=values['select']['default'] or values['select']['current']!=(4,struct.pack('<I',1)):raise ValueError('Exact current controlset required')
            if values['controlset001\\services\\i8042prt']['start']!=(4,struct.pack('<I',4)):raise ValueError('USB isolation changed')
            own=sorted(k for k in values if k.startswith('controlset001\\services\\usosnet31') and '\\' not in k[len('controlset001\\services\\'):])
            if own!=['controlset001\\services\\usosnet31','controlset001\\services\\usosnet3101']:raise ValueError('Original NCPA singleton identity changed')
            parameters=values['controlset001\\services\\usosnet3101\\parameters']
            for key,value in [('bustype',5),('busnumber',0),('pcibus',0),('pcidevice',5),('pcifunction',0),('debugport',233),('medium',0)]:
                if parameters.get(key)!=(4,struct.pack('<I',value)):raise ValueError('Original own parameter changed '+key)
            for path in ('WINNT/SYSTEM32/DRIVERS/USNET31.SYS','USOS/NET31/USNET31.SYS','N31OEM/USNET31.SYS'):
                if digest(fat.file_data(fs,path,65536)[0])!=old['driver_sha256']:raise ValueError('Old own SYS mismatch')
            if digest(fat.file_data(fs,'USOS/NET31/NET31CFG.EXE',65536)[0])!=old['helper_sha256']:raise ValueError('Old helper changed')
            if digest(fat.file_data(fs,'USOS/NET31/USOSLOG.EXE',1024**2)[0])!=old['logger_sha256']:raise ValueError('Frozen logger changed')
        finally:fs.f.close()
        warnings.filterwarnings('ignore',message='pkg_resources is deprecated as an API.*')
        from pyfatfs.PyFatFS import PyFatFS
        filesystem=PyFatFS(str(raw),offset=32256,preserve_case=False,utc=True)
        changed={};retained={}
        try:
            filesystem.makedir('USOS/NET31/R24BASE')
            for name in ('CFG31.LOG','POST.LOG','NET31.LOG','SVC31.LOG','PING31.LOG'):
                source='USOS/NET31/'+name
                if not filesystem.exists(source):continue
                blob=filesystem.readbytes(source)
                if len(blob)>65536:raise ValueError('Bound historical own text')
                filesystem.writebytes('USOS/NET31/R24BASE/'+name,blob)
                filesystem.remove(source);retained[name]=digest(blob)
            own_sys=(build/'usosnet31.sys').read_bytes()
            replacement={path:own_sys for path in ('WINNT/SYSTEM32/DRIVERS/USNET31.SYS','USOS/NET31/USNET31.SYS','N31OEM/USNET31.SYS')}
            replacement.update({'USOS/NET31/NET31CFG.EXE':(build/'NET31CFG.EXE').read_bytes(),'USOS/NET31/TESTNET.CMD':prep.native_commands()})
            for path,blob in replacement.items():
                if not filesystem.exists(path):raise ValueError('Only existing own files may be replaced')
                # pyfatfs1.1's wb truncation can retain a freed current-cluster
                # cursor on growth. Recreate this exact allowlisted own file.
                filesystem.remove(path)
                filesystem.writebytes(path,blob)
                if filesystem.readbytes(path)!=blob:raise ValueError('Own immediate readback failed')
                changed[path]=digest(blob)
        finally:filesystem.close()
        fs=fat.BoundedFat(raw)
        try:
            for name,before in protected.items():
                if fat.file_data(fs,'WINNT/SYSTEM32/'+name,8*1024**2)[0]!=before:raise ValueError('Protected Microsoft/frozenUSB file changed')
            for path,wanted in changed.items():
                if digest(fat.file_data(fs,path,65536)[0])!=wanted:raise ValueError('Independent changed-file readback failed')
        finally:fs.f.close()
        target=WORK/'target.qcow2'
        subprocess.run([str(fat.QIMG),'convert','-f','raw','-O','qcow2','-B',str(BASE),'-F','qcow2',str(raw),str(target)],check=True,capture_output=True)
        subprocess.run([str(fat.QIMG),'compare','-f','raw','-F','qcow2',str(raw),str(target)],check=True,capture_output=True)
        shutil.copyfile(BASE.parent/'vars.fd',WORK/'vars.fd')
        subprocess.run([str(fat.QIMG),'create','-q','-f','qcow2','-F','qcow2','-b',str(BASE.parent/'stick.qcow2'),str(WORK/'stick.qcow2')],check=True,capture_output=True)
        metadata.update(preparation='R24b own-file-only retry',manifest=str(OUT))
        (WORK/'fixture.json').write_bytes((json.dumps(metadata,indent=2)+'\n').encode('utf-8'))
        result.update(overlay=str(target),overlay_sha256=sha(target),vars_sha256=sha(WORK/'vars.fd'),stick_sha256=sha(WORK/'stick.qcow2'),
            original_archive_sha256=old['original_archive_sha256'],original_iso_sha256=old['original_iso_sha256'],changed_own_files=changed,
            original_logs_retained_in_guest=retained,staged_readback_pass=True,protected_guest_files_unchanged=True,
            base_unchanged=sha(BASE)==BASE_SHA)
        if not result['base_unchanged']:raise ValueError('Readonly R24 base changed')
    finally:
        if raw.exists() and raw.resolve().parent==WORK.resolve():raw.unlink()
    result.update(scratch_raw_removed=True,standalone_microsoft_modules_exported=False)
    OUT.write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));print(json.dumps(result,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True)
    p.add_argument('--tag',choices=('r24b-nt31-image-entry','r24c-nt31-registermac-order'),default=TAG)
    a=p.parse_args();TAG=a.tag;WORK=COLLECTION/'_vm'/TAG
    OUT=RUNTIME/('r24c-preparation.json' if TAG.startswith('r24c-') else 'r24b-preparation.json')
    main(a.build)
