"""One own-helper overlay, then an unchanged cold-boot overlay for client policy."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,shutil,subprocess,warnings
ROOT=Path(__file__).resolve().parents[2]
G=Path(r'G:\USOS-Kolekcja').resolve()
RUNTIME=ROOT/'artifacts/nt31-fullmac-runtime'
DRIVER='b49f2445a2e48dbf75b50f426ccc1cef09943a84e779d351747d4cbc8df27a8d'
USB='f5373eb3bf829d585651bc0da7ea5b1ca9b0cf2b20a1fe74ccb5054955f3ef05'
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def policy_gate(rb,verify):
    if rb['files']['USNET31.SYS']['sha256']!=DRIVER or rb['files']['USOSUSB.SYS']['sha256']!=USB:raise ValueError('Frozen own SYS required')
    if rb['services']['i8042prt'].get('start')!=4:raise ValueError('Input isolation changed')
    if verify:
        for name in ('lanmanserver','browser'):
            if rb.get('policy_services',{}).get(name,{}).get('start')!=4:raise ValueError('Completed client-policy apply required')
def main():
    p=argparse.ArgumentParser();p.add_argument('--phase',choices=('apply','verify'),required=True);p.add_argument('--helper-build',type=Path);p.add_argument('--base-sha256',required=True);a=p.parse_args()
    verify=a.phase=='verify';tag='r24f-nt31-client-coldboot' if verify else 'r24e-nt31-client-policy';parent='r24e-nt31-client-policy' if verify else 'r24d-nt31-usb-fullmac'
    base=G/'_vm'/parent/'target.qcow2';work=G/'_vm'/tag;out=RUNTIME/(tag.split('-')[0]+'-preparation.json');prior=RUNTIME/'vm'/parent
    if work.exists() or out.exists():raise FileExistsError('Fresh own output only')
    if not re.fullmatch('[a-f0-9]{64}',a.base_sha256) or sha(base)!=a.base_sha256:raise ValueError('Explicit stopped-base pin required')
    if read(prior/'completed.json').get('stopped') is not True or read(prior/'result.json').get('qemu_returncode')!=0:raise ValueError('Writer must be completed')
    fixture=read(base.parent/'fixture.json')
    if fixture.get('private_profile') is not False or fixture.get('folder')!='Windows NT 3.1':raise ValueError('Keyless NT31 only')
    rb=read(RUNTIME/(parent.split('-')[0]+'-stopped-readback/readback.json'))
    if rb['target_sha256']!=a.base_sha256:raise ValueError('Actual stopped evidence required')
    policy_gate(rb,verify);old=read(RUNTIME/(parent.split('-')[0]+'-preparation.json'))
    if shutil.disk_usage(G).free<100*1024**3:raise ValueError('100GiB reserve required')
    fat=load('clientfat',ROOT.parent/'nt351-net/tools/tests/coverage/prepare_nt351_debug.py')
    prep=load('clientpre',ROOT/'tools/tests/prepare_nt31_fullmac.py')
    helper=None;manifest=None
    if not verify:
        build=a.helper_build.resolve() if a.helper_build else None
        if build is None or not build.is_relative_to(ROOT/'artifacts/nt31-client-policy'):raise ValueError('Owned helper build required')
        manifest=read(build/'build.json');helper=(build/'NET31CFG.EXE').read_bytes()
        if hashlib.sha256(helper).hexdigest()!=manifest['helper_sha256'] or not manifest['actual_policy_contract_pass']:raise ValueError('Helper manifest mismatch')
    work.mkdir();raw=work/'scratch-stopped.raw';changed={};imports=None
    try:
        if verify:
            subprocess.run([str(fat.QIMG),'create','-q','-f','qcow2','-F','qcow2','-b',str(base),str(work/'target.qcow2')],check=True,capture_output=True)
            subprocess.run([str(fat.QIMG),'compare','-f','qcow2','-F','qcow2',str(base),str(work/'target.qcow2')],check=True,capture_output=True)
        else:
            subprocess.run([str(fat.QIMG),'convert','-f','qcow2','-O','raw',str(base),str(raw)],check=True,capture_output=True)
            fs=fat.BoundedFat(raw)
            try:
                protected={n:fat.file_data(fs,'WINNT/SYSTEM32/'+n,8*1024**2)[0] for n in ('CONFIG/SYSTEM','DRIVERS/USNET31.SYS','DRIVERS/USOSUSB.SYS','DRIVERS/KBDCLASS.SYS','DRIVERS/MOUCLASS.SYS','DRIVERS/NDIS.SYS','DRIVERS/TCPIP.SYS','DRIVERS/STREAMS.SYS','NTOSKRNL.EXE','HAL.DLL','KERNEL32.DLL','ADVAPI32.DLL')}
                imports=prep.imports_against(helper,{'kernel32.dll':protected['KERNEL32.DLL'],'advapi32.dll':protected['ADVAPI32.DLL']})
                previous=fat.file_data(fs,'USOS/NET31/NET31CFG.EXE',65536)[0]
                if hashlib.sha256(previous).hexdigest()!=old['helper_sha256']:raise ValueError('Existing helper mismatch')
            finally:fs.f.close()
            warnings.filterwarnings('ignore',message='pkg_resources is deprecated as an API.*')
            from pyfatfs.PyFatFS import PyFatFS
            f=PyFatFS(str(raw),offset=32256,preserve_case=False,utc=True)
            try:f.remove('USOS/NET31/NET31CFG.EXE');f.writebytes('USOS/NET31/NET31CFG.EXE',helper)
            finally:f.close()
            fs=fat.BoundedFat(raw)
            try:
                for n,data in protected.items():
                    if fat.file_data(fs,'WINNT/SYSTEM32/'+n,8*1024**2)[0]!=data:raise ValueError('Protected file changed')
                if fat.file_data(fs,'USOS/NET31/NET31CFG.EXE',65536)[0]!=helper:raise ValueError('Independent helper readback failed')
            finally:fs.f.close()
            subprocess.run([str(fat.QIMG),'convert','-f','raw','-O','qcow2','-B',str(base),'-F','qcow2',str(raw),str(work/'target.qcow2')],check=True,capture_output=True)
            subprocess.run([str(fat.QIMG),'compare','-f','raw','-F','qcow2',str(raw),str(work/'target.qcow2')],check=True,capture_output=True)
            changed['USOS/NET31/NET31CFG.EXE']=manifest['helper_sha256']
        shutil.copyfile(base.parent/'vars.fd',work/'vars.fd')
        subprocess.run([str(fat.QIMG),'create','-q','-f','qcow2','-F','qcow2','-b',str(base.parent/'stick.qcow2'),str(work/'stick.qcow2')],check=True,capture_output=True)
        fixture.update(preparation='Scoped NT31 client service policy '+a.phase,manifest=str(out));(work/'fixture.json').write_bytes((json.dumps(fixture,indent=2)+'\n').encode('utf-8'))
        result=dict(scope='Stopped overlay client-policy '+a.phase+' only; no SYS/network/NCPA changes',tag=tag,base=str(base),base_sha256=a.base_sha256,
            overlay=str(work/'target.qcow2'),overlay_sha256=sha(work/'target.qcow2'),vars_sha256=sha(work/'vars.fd'),stick_sha256=sha(work/'stick.qcow2'),
            driver_sha256=DRIVER,driver_size=16384,helper_sha256=manifest['helper_sha256'] if manifest else old['helper_sha256'],logger_sha256=old['logger_sha256'],
            original_archive_sha256=old['original_archive_sha256'],original_iso_sha256=old['original_iso_sha256'],bdf=old['bdf'],mac=old['mac'],
            runtime_pass=False,private_profile=False,staged_readback_pass=True,changed_own_files=changed,actual_installed_helper_imports=imports,base_unchanged=sha(base)==a.base_sha256)
        if not result['base_unchanged']:raise ValueError('Readonly base changed')
    finally:
        if raw.exists():raw.unlink()
    result['scratch_raw_removed']=not raw.exists();out.write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
