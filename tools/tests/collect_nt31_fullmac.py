"""Bounded read-only evidence from the completed own R24 whole disk only."""
from pathlib import Path
import hashlib,importlib.util,json,shutil,struct,subprocess,tempfile
import pefile
ROOT=Path(__file__).resolve().parents[2]
MATRIX=ROOT.parent/'macierz-windows'
WORK=Path(r'G:\USOS-Kolekcja\_vm\r24-nt31-intel-fullmac')
RUNTIME=ROOT/'artifacts/nt31-fullmac-runtime'
VM=RUNTIME/'vm/r24-nt31-intel-fullmac'
OUT=RUNTIME/'r24-stopped-readback-02'
LOGS=('CFG31.LOG','POST.LOG','NET31.LOG','SVC31.LOG','PING31.LOG')
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def digest(data):return hashlib.sha256(data).hexdigest()
def own_log(fs,name,reader):
    if name not in LOGS:raise ValueError('Only selected own log names')
    path='USOS/NET31/'+name
    cluster,attr,size=fs.find(path)
    if attr&0x10 or size>64*1024:raise ValueError('Invalid bounded own text log')
    data=reader(fs,path,64*1024)[0] if size else b''
    if b'\0' in data:raise ValueError('Own log is not bounded text')
    return data
def scalar(v):
    kind,data=v
    if kind==4 and len(data)==4:return struct.unpack('<I',data)[0]
    if kind in (1,2,7) and len(data)<=2048 and len(data)%2==0:return data.decode('utf-16-le').rstrip('\0')
    raise ValueError('Unbounded or unexpected selected registry value')
def main():
    if OUT.exists():raise FileExistsError('Completed readback must not be overwritten')
    prep=json.loads((RUNTIME/'r24-preparation.json').read_text(encoding='utf-8'))
    done=json.loads((VM/'completed.json').read_text(encoding='utf-8'))
    result=json.loads((VM/'result.json').read_text(encoding='utf-8'))
    fixture=json.loads((WORK/'fixture.json').read_text(encoding='utf-8'))
    if done.get('stopped') is not True or result.get('qemu_returncode')!=0:raise ValueError('Writer must have completed')
    if fixture.get('private_profile') is not False or fixture.get('folder')!='Windows NT 3.1':raise ValueError('Explicit keyless NT31 required')
    if sha(Path(prep['base']))!=prep['base_sha256']:raise ValueError('Stopped original base changed')
    target=WORK/'target.qcow2';before=sha(target)
    if shutil.disk_usage(WORK).free<100*1024**3:raise ValueError('100GiB reserve required')
    fat=load('nt31_result_fat',ROOT.parent/'nt351-net/tools/tests/coverage/prepare_nt351_debug.py')
    hive=load('nt31_result_hive',MATRIX/'tools/tests/coverage/regf11.py')
    pre=load('nt31_result_preparation',ROOT/'tools/tests/prepare_nt31_fullmac.py')
    OUT.mkdir();scratch=Path(r'G:\USOS-Kolekcja\_audit\nt31-r24-readback');scratch.mkdir(parents=True,exist_ok=True)
    evidence=dict(scope='Completed R24 selected own logs/hash/service readback only; no automatic LAN PASS',target_sha256=before,files={},services={},installed_runtime_pass=False)
    with tempfile.TemporaryDirectory(dir=scratch,prefix='stopped-') as temporary:
        raw=Path(temporary)/'target.raw'
        subprocess.run([str(fat.QIMG),'convert','-f','qcow2','-O','raw',str(target),str(raw)],check=True,capture_output=True)
        fs=fat.BoundedFat(raw)
        try:
            system=fat.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)[0]
            if struct.unpack_from('<II',system,20)!=(1,1):raise ValueError('Actual SYSTEM must remain REGF1.1')
            values=hive.Hive11(system).values
            selected=values['select']['current']
            if selected!=values['select']['default'] or selected!=(4,struct.pack('<I',1)):raise ValueError('Ambiguous current controlset')
            prefix='controlset001\\services\\'
            own_names=sorted(k[len(prefix):] for k in values if k.startswith(prefix+'usosnet31') and '\\' not in k[len(prefix):])
            evidence['own_service_names']=own_names
            allow=('usosnet31','usosnet3101','ndis','tcpip','tcpipsys','streams','afd','netbios','i8042prt','usosusb')
            for service in allow:
                key=prefix+service;rows=values.get(key);record=dict(present=rows is not None);evidence['services'][service]=record
                for name in ('start','type','group','imagepath','dependonservice','dependongroup'):
                    if name in (rows or {}):record[name]=scalar(rows[name])
            for suffix,names in [('usosnet3101\\parameters',('busnumber','bustype','debugport','medium','pcibus','pcidevice','pcifunction')),
                ('usosnet3101\\parameters\\tcpip',('ipaddress','subnetmask')),
                ('tcpip\\parameters',('defaultgateway','nameserver','dnslookuporder'))]:
                rows=values.get(prefix+suffix,{})
                evidence[suffix]={name:scalar(rows[name]) for name in names if name in rows}
            modules={}
            for dll,leaf in [('ntoskrnl.exe','NTOSKRNL.EXE'),('hal.dll','HAL.DLL'),('ndis.sys','DRIVERS/NDIS.SYS'),
                             ('kernel32.dll','KERNEL32.DLL'),('advapi32.dll','ADVAPI32.DLL'),('user32.dll','USER32.DLL'),('gdi32.dll','GDI32.DLL')]:
                modules[dll]=fat.file_data(fs,'WINNT/SYSTEM32/'+leaf,8*1024**2)[0]
            for leaf in ('USNET31.SYS','USOSUSB.SYS','NDIS.SYS','TCPIP.SYS','STREAMS.SYS'):
                try:data=fat.file_data(fs,'WINNT/SYSTEM32/DRIVERS/'+leaf,8*1024**2)[0]
                except SystemExit:evidence['files'][leaf]=dict(present=False);continue
                record=dict(present=True,size=len(data),sha256=digest(data));evidence['files'][leaf]=record
                if leaf=='USNET31.SYS':
                    record['matches_preparation']=digest(data)==prep['driver_sha256']
                    record['actual_installed_imports']=pre.imports_against(data,modules)
                    pe=pefile.PE(data=data)
                    record['pe_version']=[pe.OPTIONAL_HEADER.MajorOperatingSystemVersion,pe.OPTIONAL_HEADER.MinorOperatingSystemVersion,pe.OPTIONAL_HEADER.MajorSubsystemVersion,pe.OPTIONAL_HEADER.MinorSubsystemVersion]
            for name in LOGS:
                try:data=own_log(fs,name,fat.file_data)
                except SystemExit:evidence['files'][name]=dict(present=False);continue
                (OUT/name).write_bytes(data)
                evidence['files'][name]=dict(present=True,size=len(data),sha256=digest(data))
        finally:fs.f.close()
    if sha(target)!=before:raise ValueError('Read-only target changed')
    evidence.update(temporary_raw_removed=not raw.exists(),target_unchanged=True,original_base_unchanged=sha(Path(prep['base']))==prep['base_sha256'],standalone_ms_modules_exported=False)
    (OUT/'readback.json').write_bytes((json.dumps(evidence,indent=2)+'\n').encode('utf-8'));print(json.dumps(evidence,indent=2))
if __name__=='__main__':main()
