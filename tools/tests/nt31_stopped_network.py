"""Read only selected network presence from stopped owned R19c; no hive export."""
from pathlib import Path
import hashlib,importlib.util,json,shutil,struct,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
MATRIX=ROOT.parent/'macierz-windows'
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
BASE=COLLECTION/'_vm/r19c-nt31-usb-isolation/target.qcow2'
PIN='d736f6509fba4780e73a74ab7164dd4bfe7a1e6664ba1f0cfbc80c9e6169f644'
OUT=ROOT/'artifacts/nt31-fullmac-contract/r19c-stopped-network.json'
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def main():
    if OUT.exists():raise FileExistsError('Completed measurement already exists')
    if sha(BASE)!=PIN:raise ValueError('Stopped own base changed')
    done=json.loads((MATRIX/'artifacts/coverage/vm/r19c-nt31-usb-isolation/completed.json').read_text(encoding='utf-8'))
    if done.get('stopped') is not True:raise ValueError('No completed writer confirmation')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('100GiB reserve required')
    helper=load('nt31_owned_fat',ROOT.parent/'nt351-net/tools/tests/coverage/prepare_nt351_debug.py')
    hive=load('nt31_regf11',MATRIX/'tools/tests/coverage/regf11.py')
    scratch=COLLECTION/'_audit/nt31-stopped-network';scratch.mkdir(parents=True,exist_ok=True)
    result=dict(scope='Stopped target presence only; no runtime LAN PASS',base=str(BASE),base_sha256=PIN,files={},services={})
    with tempfile.TemporaryDirectory(dir=scratch,prefix='read-') as temporary:
        raw=Path(temporary)/'stopped.raw'
        subprocess.run([str(helper.QIMG),'convert','-f','qcow2','-O','raw',str(BASE),str(raw)],check=True,capture_output=True)
        fs=helper.BoundedFat(raw)
        try:
            original,_=helper.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
            version=struct.unpack_from('<II',original,20)
            if version!=(1,1):raise ValueError('Expected actual REGF1.1')
            values=hive.Hive11(original).values
            selected=values['select']['current']
            if selected!=values['select']['default'] or selected[0]!=4:raise ValueError('Ambiguous controlset')
            current=struct.unpack('<I',selected[1])[0];result.update(hive_version=list(version),current_controlset=current)
            for leaf in ('NDIS.SYS','TCPIP.SYS','NE2000.SYS','NETBT.SYS','AFD.SYS','TDI.SYS','USOSUSB.SYS','NETBIOS.SYS','STREAMS.SYS'):
                try:data,_=helper.file_data(fs,'WINNT/SYSTEM32/DRIVERS/'+leaf,4*1024**2)
                except SystemExit:result['files'][leaf]={'present':False};continue
                result['files'][leaf]={'present':True,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
            for leaf in ('PING.EXE','IPCONFIG.EXE','WSOCK32.DLL','NTOSKRNL.EXE','HAL.DLL'):
                try:data,_=helper.file_data(fs,'WINNT/SYSTEM32/'+leaf,8*1024**2)
                except SystemExit:result['files'][leaf]={'present':False};continue
                result['files'][leaf]={'present':True,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
            for service in ('ndis','tcpip','ne2000','netbt','afd','tdi','netbios','streams','i8042prt','usosusb'):
                key=f'controlset{current:03d}\\services\\{service}';rows=values.get(key)
                record={'present':rows is not None};result['services'][service]=record
                for name in ('start','type','group','dependonservice','dependongroup','imagepath'):
                    v=(rows or {}).get(name)
                    if v and v[0]==4 and len(v[1])==4:record[name]=struct.unpack('<I',v[1])[0]
                    elif v and v[0] in (1,2,7):record[name]=v[1].decode('utf-16-le').rstrip('\0')
        finally:fs.f.close()
    if sha(BASE)!=PIN:raise ValueError('Readonly base changed')
    result.update(temporary_raw_removed=not raw.exists(),expanded_microsoft_files_persisted=False,runtime_pass=False)
    OUT.write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
