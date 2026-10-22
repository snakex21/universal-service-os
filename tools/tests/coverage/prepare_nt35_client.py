"""Add only the owned client helper/marker to a stopped NT35 overlay."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import warnings
import pefile
import re

ROOT=Path(__file__).resolve().parents[3]
PRIOR=ROOT.parent/'nt35-irq'
BASE=Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-usb01')
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt35-client-apply01')
SOURCE=PRIOR/'artifacts/coverage/vm/nt35-irq-usb01'
OUT=ROOT/'artifacts/nt35-client/apply'
BUILD=ROOT/'artifacts/nt35-client/build02'
BASE_SHA='92c2aac3c1f1028fe3caeb44b60a7ff8f49df482c7cc2456cb2c75ddc47c819a'
DRIVER='d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
USB='2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1'
ADDED=('USOS/NT3/CLNT35.EXE','USOS/NT3/CLNT35.ON')

def sha(p):
    with p.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def read(p):return json.loads(p.read_text('utf-8'))
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
def inventory(raw):
    from pyfatfs.PyFatFS import PyFatFS
    f=PyFatFS(str(raw),offset=32256,preserve_case=False,utc=True,read_only=True)
    result={}
    try:
        for name in f.walk.files():
            with f.openbin(name,'r') as stream:result[name.strip('/').casefold()]=hashlib.file_digest(stream,'sha256').hexdigest()
    finally:f.close()
    return result
def imports(raw,modules):
    own=pefile.PE(data=raw,fast_load=False);result={}
    if own.OPTIONAL_HEADER.Subsystem!=2:raise ValueError('GUI helper required')
    for desc in own.DIRECTORY_ENTRY_IMPORT:
        name=desc.dll.decode('ascii').lower()
        if name not in modules:raise ValueError('Unexpected helper DLL')
        original=pefile.PE(data=modules[name],fast_load=False)
        exports={x.name for x in original.DIRECTORY_ENTRY_EXPORT.symbols if x.name}
        if any(not x.name or x.name not in exports for x in desc.imports):raise ValueError('Unavailable original NT35 import')
        result[name]=len(desc.imports)
    return result

def main(tag=None):
    global WORK,OUT
    if tag is not None:
        if not re.fullmatch(r'nt35-client-apply[0-9]{2}',tag):raise ValueError('Fixed owned apply tag required')
        WORK=Path(r'G:\USOS-Kolekcja\_vm')/tag
        OUT=ROOT/'artifacts/nt35-client'/tag.removeprefix('nt35-client-')
    if WORK.exists() or OUT.exists():raise ValueError('Fresh owned preparation only')
    if read(SOURCE/'completed.json').get('stopped') is not True or read(SOURCE/'result.json').get('qemu_returncode')!=0:raise ValueError('Writer exit required')
    meta=read(BASE/'fixture.json')
    if meta.get('private_profile') is not False or meta.get('folder')!='Windows NT 3.5':raise ValueError('Keyless NT35 only')
    if sha(BASE/'target.qcow2')!=BASE_SHA:raise ValueError('Pinned stopped parent changed')
    build=read(BUILD/'build.json');helper=(BUILD/'CLNT35.EXE').read_bytes()
    if hashlib.sha256(helper).hexdigest()!=build['sha256'] or not build['actual_policy_contract_pass']:raise ValueError('Helper build mismatch')
    if shutil.disk_usage(WORK.parent).free<100*1024**3:raise ValueError('100GiB reserve required')
    fat=load('client35_boundedfat',ROOT/'tools/tests/coverage/prepare_nt35_usb_isolated.py');h=fat.h
    qimg=h.QIMG;WORK.mkdir();OUT.mkdir(parents=True)
    raw=WORK/'prepare-whole.raw'
    env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
    subprocess.run([str(qimg),'convert','-f','qcow2','-O','raw',str(BASE/'target.qcow2'),str(raw)],env=env,check=True)
    fs=h.BoundedFat(raw)
    try:
        if fs.fat32 or fs.base!=32256:raise ValueError('Exact FAT16 layout required')
        original={name:h.file_data(fs,'WINNT/SYSTEM32/'+name,4*1024**2)[0] for name in ('KERNEL32.DLL','ADVAPI32.DLL','CONFIG/SYSTEM','DRIVERS/usosnet35.sys','DRIVERS/usosusb.sys')}
        if hashlib.sha256(original['DRIVERS/usosnet35.sys']).hexdigest()!=DRIVER or hashlib.sha256(original['DRIVERS/usosusb.sys']).hexdigest()!=USB:raise ValueError('Frozen drivers mismatch')
        actual_imports=imports(helper,{'kernel32.dll':original['KERNEL32.DLL'],'advapi32.dll':original['ADVAPI32.DLL']})
    finally:fs.f.close()
    values,_,version=fat.read_hive(original['CONFIG/SYSTEM'])
    import struct
    if version!=(1,2) or values['controlset001\\services\\i8042prt']['start']!=(4,struct.pack('<I',4)):raise ValueError('Existing input isolation required')
    warnings.filterwarnings('ignore',message='pkg_resources is deprecated as an API.*')
    before=inventory(raw)
    if any(name.casefold() in before for name in ADDED):raise ValueError('Fresh helper names required')
    from pyfatfs.PyFatFS import PyFatFS
    f=PyFatFS(str(raw),offset=32256,preserve_case=False,utc=True)
    try:
        f.writebytes(ADDED[0],helper);f.writebytes(ADDED[1],b'USOS NT35 client policy test\r\n')
    finally:f.close()
    after=inventory(raw)
    if set(after)-set(before)!={x.casefold() for x in ADDED} or any(after.get(name)!=digest for name,digest in before.items()):raise ValueError('Unrelated installed file changed')
    fs=h.BoundedFat(raw)
    try:
        if h.file_data(fs,ADDED[0],65536)[0]!=helper:raise ValueError('Independent helper readback failed')
        if h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)[0]!=original['CONFIG/SYSTEM']:raise ValueError('SYSTEM changed')
    finally:fs.f.close()
    target=WORK/'target.qcow2'
    subprocess.run([str(qimg),'convert','-f','raw','-O','qcow2','-B',str(BASE/'target.qcow2'),'-F','qcow2',str(raw),str(target)],env=env,check=True)
    subprocess.run([str(qimg),'compare','-f','raw','-F','qcow2',str(raw),str(target)],env=env,check=True,capture_output=True)
    if sha(BASE/'target.qcow2')!=BASE_SHA:raise ValueError('Readonly parent changed')
    if raw.resolve().parent!=WORK.resolve() or raw.name!='prepare-whole.raw':raise ValueError('Wrong cleanup path')
    raw.unlink()
    meta.update(stopped_parent=str(BASE/'target.qcow2'),diagnostic_only=True,preparation='Own client helper/marker only; service policy not yet applied')
    (WORK/'fixture.json').write_text(json.dumps(meta,indent=2))
    proof=dict(base_sha256=BASE_SHA,base_unchanged=True,overlay_sha256=sha(target),system_unchanged=True,usb_unchanged=True,
        candidate_sha256=DRIVER,i8042prt_start=4,raw_overlay_qemu_compare_pass=True,new_client_files=list(ADDED),
        original_files_unchanged=True,original_file_count=len(before),original_inventory_sha256=hashlib.sha256(json.dumps(before,sort_keys=True).encode()).hexdigest(),
        actual_helper_imports_compatible=True,actual_helper_imports=actual_imports,helper_sha256=build['sha256'],source_command_sha256=sha(SOURCE/'command.json'),
        system_sha256=hashlib.sha256(original['CONFIG/SYSTEM']).hexdigest(),usb_sha256=USB,standalone_ms_exported=False,whole_disk_scratch_removed=True,
        runtime_pass=False,scope='Only own GUI helper and marker added; original installed files byte-identical')
    (OUT/'preparation.json').write_text(json.dumps(proof,indent=2)+'\n')
    print(json.dumps(proof,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--tag',default='nt35-client-apply02')
    main(parser.parse_args().tag)
