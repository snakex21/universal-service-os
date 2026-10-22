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
COLD_PARENT=COLLECTION/'_vm/nt35-client-apply03/target.qcow2'
COLD_PARENT_SHA='f798b3021c12fec3c56dd652530dc2cd3b1c1dc54a107b1e653eabe7b9e05836'
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
def scm(text,check_only=False):
    if text.count('CLIENT_POLICY_PASS')!=1 or 'CLIENT_POLICY_REFUSED' in text or 'REFUSED_' in text:
        raise ValueError('One successful actual helper completion required')
    found={}
    for match in re.finditer(r'^(Browser|LanmanServer|LanmanWorkstation|Tcpip)\r?\nstate=([0-9A-F]{8})\r?\nstart=([0-9A-F]{8})',text,re.M):
        found[match[1]]=(int(match[2],16),int(match[3],16))
    if found!=STATES:raise ValueError('Actual final SCM states/configuration differ')
    if check_only and 'nativenetexit' in text.casefold():raise ValueError('Cold readonly /check must not repeat native NET stops')
    return {name:dict(state=value[0],start=value[1]) for name,value in found.items()}

def cold_review(path,out,runtime):
    """Bind post-completion operator review; keys_count does not record typed text."""
    path=Path(path).absolute();exact(path)
    if not path.is_relative_to(out) or path.stat().st_size>16384:raise ValueError('Bounded own cold review JSON required')
    review=read(path)
    if review.get('case')!='nt35-client-cold01' or review.get('reviewed_after_completion') is not True:
        raise ValueError('Explicit completed cold operator review required')
    commands=review.get('source_commands',{})
    if set(commands)!={'check','services','ping','shutdown'}:raise ValueError('Four actual native source commands required')
    for command in commands.values():
        if not isinstance(command,str) or not 1<=len(command)<=512 or any(ord(c)<32 for c in command):
            raise ValueError('Bounded source command text required')
        if '/apply' in command.casefold() or '*' in command:raise ValueError('No apply/wildcard application stage in cold check')
    check=commands['check'].casefold().replace('"','')
    services=commands['services'].casefold().replace('"','')
    ping=commands['ping'].casefold().replace('"','')
    if not re.search(r'c:\\usos\\nt3\\clnt35\.exe\s+/check(?:\s|$)',check):raise ValueError('Exact own helper /check command required')
    if not re.search(r'\bnet(?:\.exe)?\s+start\b',services) or not re.search(r'(?<!>)>\s*c:\\usos\\nt3\\net35\.log\b',services):
        raise ValueError('Fresh native NET command must overwrite own NET35.LOG')
    if not re.search(r'\bping(?:\.exe)?\s+-n\s+3\s+10\.0\.2\.2\b',ping) or not re.search(r'(?<!>)>\s*c:\\usos\\nt3\\ping35\.log\b',ping):
        raise ValueError('Fresh native ping must overwrite own PING35.LOG')
    images=review.get('reviewed_images',{})
    if set(images)!={'check','scm','services','ping','safeoff'}:raise ValueError('Actual cold command/result/safeoff images required')
    actions=runtime/'operator-actions.jsonl';exact(actions)
    if actions.stat().st_size>1024*1024:raise ValueError('Bounded completed operator actions required')
    recorded={json.loads(line).get('image') for line in actions.read_text(encoding='utf-8').splitlines() if line}
    hashes={}
    for role,name in images.items():
        if not isinstance(name,str) or not re.fullmatch(r'operator-(?:0[1-9]|[1-9][0-9]|1[01][0-9]|12[0-8])\.png',name) or name not in recorded:
            raise ValueError('Reviewed image must be one completed operator action')
        image=runtime/name;exact(image);hashes[role]=dict(image=name,sha256=sha(image))
    completion=runtime/'policy-done-01.json';exact(completion)
    if completion.stat().st_size>4096:raise ValueError('Bounded own completion required')
    token=read(completion)
    if token.get('completed') is not True or token.get('exit_code')!=0 or token.get('source')!='own GUI helper COM1 completion':
        raise ValueError('Actual cold helper completion0 required')
    return dict(operator_review_sha256=sha(path),source_commands=commands,reviewed_images=hashes,
        operator_actions_sha256=sha(actions),helper_completion_sha256=sha(completion),helper_mode='/check',
        source_commands_basis='Explicit operator review; actions retain image/keys_count, not typed command text')

def main(case='apply03',cold_evidence=None):
    if case not in ('apply03','cold01'):raise ValueError('Only explicit completed apply03/cold01 cases are supported')
    if (case=='cold01')!=(cold_evidence is not None):raise ValueError('Only cold01 requires --cold-evidence after actual completion')
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
    backing=PARENT;backing_hash=PARENT_SHA;review=None
    if case=='cold01':
        backing=COLD_PARENT;backing_hash=COLD_PARENT_SHA;exact(backing)
        apply_out=ROOT/'artifacts/nt35-client/apply03';apply_runtime=ROOT/'artifacts/coverage/vm/nt35-client-apply03'
        observed=read(apply_out/'readback.json')
        if read(apply_out/'evaluation.json').get('policy_apply')!='PASS' or observed.get('target_sha256')!=COLD_PARENT_SHA:
            raise ValueError('Pinned completed apply03 policy proof required')
        if Path(proof.get('base','')).resolve()!=backing or proof.get('base_sha256')!=backing_hash or sha(backing)!=backing_hash:
            raise ValueError('Exact unchanged completed apply03 backing required')
        for flag in ('guest_contents_unchanged','effective_disk_compare_pass','system_unchanged','usb_unchanged','original_usb_parent_unchanged'):
            if proof.get(flag) is not True:raise ValueError('Verified cold preparation required: '+flag)
        if proof.get('original_usb_parent_sha256')!=PARENT_SHA or 'new_client_files' in proof:
            raise ValueError('Unchanged original USB parent and no new-files claim required')
        if meta.get('guest_contents_unchanged') is not True or meta.get('cold_policy_check_only') is not True:
            raise ValueError('Unchanged cold-only fixture required')
        if proof.get('candidate_sha256')!=CANDIDATE or proof.get('usb_sha256')!=USB:
            raise ValueError('Cold preparation candidate pins differ')
        for key,path in (('source_readback_sha256',apply_out/'readback.json'),('source_evaluation_sha256',apply_out/'evaluation.json'),
                         ('source_command_sha256',apply_runtime/'command.json'),('source_import_proof_sha256',apply_out/'preparation.json')):
            if proof.get(key)!=sha(path):raise ValueError('Closed apply source proof changed')
        review=cold_review(cold_evidence,out,runtime)
    target=work/'target.qcow2';raw=work/'client-readback-stopped.raw'
    for path in (work,target,raw,PARENT):exact(path)
    if not work.is_relative_to(COLLECTION/'_vm') or raw.exists():raise ValueError('Fresh exact owned scratch required')
    if sha(PARENT)!=PARENT_SHA:raise ValueError('Completed USB parent changed')
    if shutil.disk_usage(work).free<100*1024**3:raise ValueError('100GiB disk reserve required')
    target_hash=sha(target);helper=load('nt35_client_bounded_fat',Path(__file__).with_name('prepare_nt35_usb_isolated.py'));h=helper.h
    env=dict(os.environ,TEMP=str(work),TMP=str(work),APPDATA=str(work),LOCALAPPDATA=str(work))
    if case=='cold01':
        info=json.loads(subprocess.run([str(h.QIMG),'info','--output=json',str(target)],env=env,check=True,capture_output=True,text=True).stdout)
        actual_backing=info.get('full-backing-filename',info.get('backing-filename',''))
        if not actual_backing or Path(actual_backing).resolve()!=backing:raise ValueError('Actual COW backing differs from pinned apply03')
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
    observed_scm=scm(own['CLNT35.LOG'].decode('utf-8'),check_only=case=='cold01')
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
    if sha(target)!=target_hash or sha(PARENT)!=PARENT_SHA or sha(backing)!=backing_hash:
        raise ValueError('Stopped source or either parent changed during readback')
    if raw.resolve().parent!=work or raw.name!='client-readback-stopped.raw' or not stat.S_ISREG(raw.lstat().st_mode) or raw.lstat().st_file_attributes&0x400:
        raise ValueError('Exact scratch cleanup guard failed')
    raw.unlink()
    texts_out.mkdir(parents=True)
    for name,data in own.items():(texts_out/name).write_bytes(data)
    record=dict(case=tag,stopped=True,qemu_returncode=0,target_sha256=target_hash,
        base_sha256=backing_hash,base_unchanged=True,original_usb_parent_sha256=PARENT_SHA,original_usb_parent_unchanged=True,
        installed_candidate_sha256=CANDIDATE,installed_candidate_bytes=16384,
        usb_sha256=USB,usb_bytes=32128,helper_sha256=HELPER,helper_bytes=5632,
        actual_helper_imports_compatible=True,actual_helper_imports=IMPORTS,source_import_proof_sha256=sha(out/'preparation.json'),
        hive_version=version,current_default=1,service_start=starts,scm_final=observed_scm,
        system_sha256=hashlib.sha256(system).hexdigest(),source_command_sha256=sha(runtime/'command.json'),
        files={name:dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest()) for name,data in own.items()},
        scratch_whole_disk_removed=True,ms_hive_or_binary_exported=False,own_exe_exported=False,
        scope='Only four own text files exported; own helper/SYS/USB hashed and SYSTEM interpreted in RAM')
    if review is not None:record.update(cold_check_no_native_net_exit=True,guest_contents_unchanged_before_boot=True,
        effective_disk_compare_pass=True,operator_evidence=review)
    output.write_bytes((json.dumps(record,indent=2)+'\n').encode('utf-8'))
    image_names=('operator-09.png','operator-11.png','operator-13.png','operator-17.png')
    assessment=dict(case=tag,policy_apply='PASS' if case=='apply03' else 'NOT_RETESTED',
        cold_boot_policy='PASS' if case=='cold01' else 'NOT_TESTED',client_no_sharing='PASS',
        native_service_list_without_browser_server=True,native_ping_replies=3,native_ping_each_below_ms=10,
        scm_final=observed_scm,service_start=starts,helper_sha256=HELPER,installed_candidate_sha256=CANDIDATE,usb_sha256=USB,
        native_safe_shutdown=True,qemu_returncode=0,target_sha256=target_hash,base_unchanged=True,
        reviewed_images=({item['image']:item['sha256'] for item in review['reviewed_images'].values()}
            if review is not None else {name:sha(runtime/name) for name in image_names}),
        usb_hid_retested=False,fresh_setup_retested=False,fresh_auto_policy_retested=False,
        prior_apply01_operator_and_apply02_startup_failures_preserved=True,
        scope='Installed NT35 explicit service policy qualification; no new HID, MSC, fresh Setup or physical PASS')
    if review is not None:assessment.update(operator_evidence=review,helper_mode='/check',cold_check_no_native_net_exit=True)
    evaluation.write_bytes((json.dumps(assessment,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(record,indent=2),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--case',choices=('apply03','cold01'),default='apply03')
    parser.add_argument('--cold-evidence',type=Path,help='Own post-completion operator review JSON, required only for cold01')
    args=parser.parse_args();main(args.case,args.cold_evidence)
