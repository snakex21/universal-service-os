"""Bounded own-policy evidence from completed keyless NT35, never boot VM.

Only five allowlisted own files are read from USOS/NT3. The own EXE is
hashed in RAM; only text is exported. SYSTEM remains in RAM/whole disk G.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,re,shutil,stat,struct,subprocess

ROOT=Path(__file__).resolve().parents[3]
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
PARENT=COLLECTION/'_vm/nt35-irq-usb01/target.qcow2'
PARENT_SHA='92c2aac3c1f1028fe3caeb44b60a7ff8f49df482c7cc2456cb2c75ddc47c819a'
CANDIDATE='d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
USB='2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1'
HELPER='4a927eecb1a6c602f92c0a92c14bd7b56f684238735d36f8218d5bfcb5e3204a'
IMPORTS={'kernel32.dll':14,'advapi32.dll':7}
TEXTS={'CLNT35.LOG':64*1024,'CLNT35.ON':128,'NET35.LOG':16*1024,'PING35.LOG':16*1024}
STATES={'Browser':(1,4),'LanmanServer':(1,4),'LanmanWorkstation':(4,2),'Tcpip':(4,3)}

def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
def read(path):return json.loads(path.read_text(encoding='utf-8'))
def exact(path):
    if not path.is_absolute() or path.resolve()!=path:raise ValueError('Exact absolute non-reparse path required')
    for p in (path,*path.parents):
        if p.exists() and p.lstat().st_file_attributes&0x400:raise ValueError('Reparse path refused')
def dword(values,key,name):
    item=values.get(key,{}).get(name)
    if not item or item[0]!=4 or len(item[1])!=4:raise ValueError('Expected one existing DWORD')
    return struct.unpack('<I',item[1])[0]
def scm(text):
    if text.count('CLIENT_POLICY_PASS')!=1 or 'CLIENT_POLICY_REFUSED' in text or 'REFUSED_' in text:
        raise ValueError('One successful actual helper completion required')
    found={}
    for match in re.finditer(r'^(Browser|LanmanServer|LanmanWorkstation|Tcpip)\r?\nstate=([0-9A-F]{8})\r?\nstart=([0-9A-F]{8})',text,re.M):
        found[match[1]]=(int(match[2],16),int(match[3],16))
    if found!=STATES:raise ValueError('Actual final SCM states/configuration differ')
    return {name:dict(state=value[0],start=value[1]) for name,value in found.items()}

def main(case='apply03'):
    if case!='apply03':raise ValueError('Only completed apply03 is qualified by this reader')
    tag='nt35-client-'+case;work=COLLECTION/'_vm'/tag
    runtime=ROOT/'artifacts/coverage/vm'/tag;out=ROOT/'artifacts/nt35-client'/case
    output=out/'readback.json';evaluation=out/'evaluation.json';texts_out=out/'readback-text'
    if output.exists() or evaluation.exists() or texts_out.exists():raise FileExistsError('Preserve completed readback')
    result=read(runtime/'result.json');done=read(runtime/'completed.json');meta=read(work/'fixture.json')
    if done.get('stopped') is not True or result.get('qemu_returncode')!=0 or result.get('error') is not None:
        raise ValueError('Confirmed completed writer exit0 required')
    if meta.get('private_profile') is not False or meta.get('folder')!='Windows NT 3.5':raise ValueError('Explicit keyless NT35 required')
    proof=read(out/'preparation.json')
    if proof.get('helper_sha256')!=HELPER or proof.get('actual_helper_imports_compatible') is not True or proof.get('actual_helper_imports')!=IMPORTS:
        raise ValueError('Pinned original-module helper import proof required')
    target=work/'target.qcow2';raw=work/'client-readback-stopped.raw'
    for path in (work,target,raw,PARENT):exact(path)
    if not work.is_relative_to(COLLECTION/'_vm') or raw.exists():raise ValueError('Fresh exact owned scratch required')
    if sha(PARENT)!=PARENT_SHA:raise ValueError('Completed USB parent changed')
    if shutil.disk_usage(work).free<100*1024**3:raise ValueError('100GiB disk reserve required')
    target_hash=sha(target);helper=load('nt35_client_bounded_fat',Path(__file__).with_name('prepare_nt35_usb_isolated.py'));h=helper.h
    env=dict(os.environ,TEMP=str(work),TMP=str(work),APPDATA=str(work),LOCALAPPDATA=str(work))
    subprocess.run([str(h.QIMG),'convert','-f','qcow2','-O','raw',str(target),str(raw)],env=env,check=True)
    fs=h.BoundedFat(raw);own={}
    try:
        if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Exact retained FAT16 layout required')
        driver,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet35.sys',16384)
        usb,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosusb.sys',32128)
        system,_=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
        binary,_=h.file_data(fs,'USOS/NT3/CLNT35.EXE',5632)
        for name,bound in TEXTS.items():
            data,_=h.file_data(fs,'USOS/NT3/'+name,bound)
            if b'\0' in data or any(value<32 and value not in (9,10,13) for value in data):raise ValueError('Expected bounded own text')
            data.decode('utf-8',errors='strict');own[name]=data
    finally:fs.f.close()
    for data,size,expected in ((driver,16384,CANDIDATE),(usb,32128,USB),(binary,5632,HELPER)):
        if len(data)!=size or hashlib.sha256(data).hexdigest()!=expected:raise ValueError('Actual installed own binary pin mismatch')
    if own['CLNT35.ON']!=b'USOS NT35 client policy test\r\n':raise ValueError('Adjacent fixture marker differs')
    observed_scm=scm(own['CLNT35.LOG'].decode('utf-8'))
    native={line.strip() for line in own['NET35.LOG'].decode('utf-8').splitlines()}
    if {'Server','Computer Browser','Browser'}&native or not {'Workstation','DHCP Client','The command completed successfully.'}<=native:
        raise ValueError('Native client-only service list differs')
    replies=re.findall(r'Reply from 10\.0\.2\.2: bytes=32 time<10ms TTL=255',own['PING35.LOG'].decode('utf-8'))
    if len(replies)!=3:raise ValueError('Three native ping replies below10ms required')
    values,_,version=helper.read_hive(system)
    if version!=(1,2) or dword(values,'select','current')!=1 or dword(values,'select','default')!=1:
        raise ValueError('Clean measured REGF1.2/CurrentDefault1 required')
    expected_starts={'i8042prt':4,'browser':4,'lanmanserver':4,'lanmanworkstation':2,'tcpip':3}
    starts={name:dword(values,'controlset001\\services\\'+name,'start') for name in expected_starts}
    if starts!=expected_starts:raise ValueError('Stopped policy or USB isolation changed')
    if sha(target)!=target_hash or sha(PARENT)!=PARENT_SHA:raise ValueError('Stopped source or parent changed during readback')
    if raw.resolve().parent!=work or raw.name!='client-readback-stopped.raw' or not stat.S_ISREG(raw.lstat().st_mode) or raw.lstat().st_file_attributes&0x400:
        raise ValueError('Exact scratch cleanup guard failed')
    raw.unlink()
    texts_out.mkdir(parents=True)
    for name,data in own.items():(texts_out/name).write_bytes(data)
    record=dict(case=tag,stopped=True,qemu_returncode=0,target_sha256=target_hash,
        base_sha256=PARENT_SHA,base_unchanged=True,installed_candidate_sha256=CANDIDATE,installed_candidate_bytes=16384,
        usb_sha256=USB,usb_bytes=32128,helper_sha256=HELPER,helper_bytes=5632,
        actual_helper_imports_compatible=True,actual_helper_imports=IMPORTS,source_import_proof_sha256=sha(out/'preparation.json'),
        hive_version=version,current_default=1,service_start=starts,scm_final=observed_scm,
        system_sha256=hashlib.sha256(system).hexdigest(),source_command_sha256=sha(runtime/'command.json'),
        files={name:dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest()) for name,data in own.items()},
        scratch_whole_disk_removed=True,ms_hive_or_binary_exported=False,own_exe_exported=False,
        scope='Only four own text files exported; own helper/SYS/USB hashed and SYSTEM interpreted in RAM')
    output.write_bytes((json.dumps(record,indent=2)+'\n').encode('utf-8'))
    image_names=('operator-09.png','operator-11.png','operator-13.png','operator-17.png')
    assessment=dict(case=tag,policy_apply='PASS',cold_boot_policy='NOT_TESTED',client_no_sharing='PASS',
        native_service_list_without_browser_server=True,native_ping_replies=3,native_ping_each_below_ms=10,
        scm_final=observed_scm,service_start=starts,helper_sha256=HELPER,installed_candidate_sha256=CANDIDATE,usb_sha256=USB,
        native_safe_shutdown=True,qemu_returncode=0,target_sha256=target_hash,base_unchanged=True,
        reviewed_images={name:sha(runtime/name) for name in image_names},
        usb_hid_retested=False,fresh_setup_retested=False,prior_apply01_operator_and_apply02_startup_failures_preserved=True,
        scope='Installed NT35 explicit service policy qualification; no new HID, MSC, fresh Setup or physical PASS')
    evaluation.write_bytes((json.dumps(assessment,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(record,indent=2),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--case',choices=('apply03',),default='apply03')
    main(parser.parse_args().case)
