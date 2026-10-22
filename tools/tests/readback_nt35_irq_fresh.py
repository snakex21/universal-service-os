"""After confirmed exit, read own SYS and four service Start DWORDs in RAM.

No hive, OS file, key or arbitrary registry field is written outside the
owned whole-disk image on G. This reader never changes a service or boots VM.
"""
from pathlib import Path
import hashlib,importlib.util,json,os,stat,struct,subprocess
ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'artifacts/coverage/nt35-irq-fresh01'
CASE=ROOT/'artifacts/coverage/vm/nt35-irq-fresh01'
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-fresh01')
DRIVER='d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
NAMES=('Browser','LanmanServer','LanmanWorkstation','Tcpip','RasMan','RasAcd','RemoteAccess')
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def policy_values(values):
    selected={}
    for name in ('current','default'):
        item=values.get('select',{}).get(name)
        if not item or item[0]!=4 or len(item[1])!=4:raise ValueError('Invalid selected control set')
        number=struct.unpack('<I',item[1])[0]
        if not 1<=number<=999:raise ValueError('Invalid control set bound')
        selected[name]=number
    services={}
    for number in sorted(set(selected.values())):
        rows={}
        for service in NAMES:
            node=values.get(f'controlset{number:03d}\\services\\{service.lower()}')
            row=dict(present=node is not None)
            if node is not None:
                for field in ('start','type'):
                    item=node.get(field)
                    if not item or item[0]!=4 or len(item[1])!=4:raise ValueError('Expected bounded service DWORD')
                    row[field]=struct.unpack('<I',item[1])[0]
                if not 0<=row['start']<=4:raise ValueError('Invalid service Start')
            rows[service]=row
        services[str(number)]=rows
    return dict(selected=selected,services=services)
def main():
    result=json.loads((CASE/'result.json').read_text(encoding='utf-8'))
    exit_record=json.loads((HERE/'process-exit.json').read_text(encoding='utf-8'))
    if exit_record.get('returncode')!=0 or result.get('qemu_returncode')!=0 or not (CASE/'cleanup.json').is_file():
        raise ValueError('Confirmed process/QEMU completion required')
    metadata=json.loads((CASE/'fixture.json').read_text(encoding='utf-8'))
    if metadata.get('private_profile') is not False or metadata.get('folder')!='Windows NT 3.5':
        raise ValueError('Exact keyless NT35 scope required')
    output=HERE/'stopped-readback.json';raw=WORK/'fresh-readback-stopped.raw';target=WORK/'target-retained.qcow2'
    if output.exists() or raw.exists():raise FileExistsError('Fresh readback required')
    for path in (WORK,target,raw):
        if path.resolve()!=path or (path.exists() and path.lstat().st_file_attributes&0x400):raise ValueError('Exact non-reparse owned path required')
    if WORK.resolve()!=Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-fresh01'):raise ValueError('Unexpected whole-disk root')
    spec=importlib.util.spec_from_file_location('nt35_fresh_fat',ROOT/'tools/tests/coverage/prepare_nt351_debug.py')
    h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
    target_hash=digest(target)
    env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
    subprocess.run([str(h.QIMG),'convert','-f','qcow2','-O','raw',str(target),str(raw)],env=env,check=True)
    fs=h.BoundedFat(raw)
    native=None
    try:
        if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Exact normal-flow FAT16 layout required')
        own,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet35.sys',16384)
        system,_=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
        try:native,_=h.file_data(fs,'USOS/NT3/FRESHNET.LOG',16384)
        except SystemExit:pass
    finally:fs.f.close()
    if len(own)!=16384 or hashlib.sha256(own).hexdigest()!=DRIVER:raise ValueError('Installed own candidate mismatch')
    version=struct.unpack_from('<II',system,20)
    if system[:4]!=b'regf' or version!=(1,2) or system[4:8]!=system[8:12] or h.hive.checksum(system)!=struct.unpack_from('<I',system,508)[0]:
        raise ValueError('Measured clean REGF1.2 SYSTEM required')
    policy=policy_values(h.hive.read_hive_content(system))
    if digest(target)!=target_hash:raise ValueError('Stopped source changed during readback')
    record=dict(stopped=True,qemu_returncode=0,target_sha256=target_hash,driver_sha256=DRIVER,driver_bytes=16384,
        hive_version=version,system_sha256=hashlib.sha256(system).hexdigest(),policy=policy,
        no_hive_export=True,no_ms_binary_export=True,registry_modified=False,
        scope='Four allowlisted service Start/Type values only; runtime services require native net start evidence')
    if native is not None:
        if b'\0' in native or any(v<32 and v not in (9,10,13) for v in native):raise ValueError('Expected bounded native service text')
        (HERE/'FRESHNET.LOG').write_bytes(native)
        record['native_services_log']=dict(bytes=len(native),sha256=hashlib.sha256(native).hexdigest())
    # Only this new scratch whole disk may be removed; retain the source.
    if raw.resolve().parent!=WORK or raw.name!='fresh-readback-stopped.raw' or not stat.S_ISREG(raw.lstat().st_mode):
        raise ValueError('Unexpected scratch cleanup boundary')
    raw.unlink();record['scratch_whole_disk_removed']=True
    output.write_bytes((json.dumps(record,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(record,indent=2))

if __name__=='__main__':main()
