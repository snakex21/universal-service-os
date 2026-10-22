"""Completed fresh target only: bounded service DWORDs and own file hashes.

Original SYSTEM/DLL bytes remain in RAM or owned whole disk on G; no keys,
account values or arbitrary registry fields are exported. No host registry.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TAG = 'nt35-client-auto-fresh01'
HERE = ROOT/'artifacts/coverage'/TAG
CASE = ROOT/'artifacts/coverage/vm'/TAG
WORK = Path(r'G:\USOS-Kolekcja\_vm')/TAG
DRIVER = 'd94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
POST = '87cb43259878583758269b979c8e59411d69366ce5d58ec949a51638786d449f'


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def policy_pass(policy):
    selected=policy.get('selected',{})
    if set(selected)!={'current','default'} or any(type(v) is not int or not 1<=v<=999 for v in selected.values()):return False
    if set(policy.get('services',{}))!={str(v) for v in selected.values()}:return False
    for rows in policy['services'].values():
        for name in ('Browser','LanmanServer'):
            value=rows[name]
            if not value['present']:
                if name=='Browser':continue
                return False
            if value.get('start')!=4 or value.get('type')!=32:return False
        if rows['LanmanWorkstation']!={'present':True,'start':2,'type':32}:return False
        if rows['Tcpip']!={'present':True,'start':3,'type':1}:return False
    return True


def native_policy(native):
    """One initial readonly NET service enumeration, not a status-file claim."""
    text=native.replace('\r\n','\n')
    sections=re.findall(r'These Windows NT services are started:\n(.*?)The command completed successfully\.',text,re.S)
    if len(sections)!=1:raise ValueError('One complete native service enumeration required')
    names=re.findall(r'^   ([^\n]+)$',sections[0],re.M)
    return dict(running_services=names,workstation_running='Workstation' in names,
        server_running='Server' in names,browser_running='Computer Browser' in names,
        no_sharing_running_state='Workstation' in names and 'Server' not in names and 'Computer Browser' not in names)


def main():
    result=json.loads((CASE/'result.json').read_text(encoding='utf-8'))
    process=json.loads((HERE/'process-exit.json').read_text(encoding='utf-8'))
    fixture=json.loads((CASE/'fixture.json').read_text(encoding='utf-8'))
    if result.get('qemu_returncode')!=0 or process.get('returncode')!=0 or not (CASE/'cleanup.json').is_file():
        raise ValueError('Actual parent/QEMU exit and cleanup required')
    if fixture.get('private_profile') is not False or fixture.get('folder')!='Windows NT 3.5':
        raise ValueError('Exact keyless NT35 Workstation scope required')
    output=HERE/'stopped-readback.json'
    raw=WORK/'client-auto-stopped.raw';target=WORK/'target-retained.qcow2'
    if output.exists() or raw.exists():raise FileExistsError('Fresh stopped readback only')
    for p in (WORK,target,raw):
        if p.resolve()!=p or (p.exists() and p.lstat().st_file_attributes&0x400):raise ValueError('Literal non-reparse owned path required')
    target_hash=digest(target)
    h=load('client_auto_fat',ROOT/'tools/tests/coverage/prepare_nt351_debug.py')
    old=load('client_auto_policy_reader',ROOT/'tools/tests/readback_nt35_irq_fresh.py')
    env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
    subprocess.run([str(h.QIMG),'convert','-f','qcow2','-O','raw',str(target),str(raw)],env=env,check=True)
    own_files={}
    try:
        fs=h.BoundedFat(raw)
        try:
            if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Normal FAT16 layout required')
            driver,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet35.sys',16384)
            post,_=h.file_data(fs,'USOS/NT3/USOSNT3.EXE',30208)
            system,_=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
            for leaf in ('CLNT35.REQ','CLNT35.LOG','CLNT35.ERR','C35NET.LOG'):
                try:data,_=h.file_data(fs,'USOS/NT3/'+leaf,16384)
                except SystemExit:
                    own_files[leaf]=dict(present=False);continue
                if b'\0' in data or any(x<32 and x not in (9,10,13) for x in data):raise ValueError('Bounded own ASCII text expected')
                own_files[leaf]=dict(present=True,bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
                (HERE/leaf).write_bytes(data)
        finally:fs.f.close()
        if len(driver)!=16384 or hashlib.sha256(driver).hexdigest()!=DRIVER:raise ValueError('Actual installed d94 SYS mismatch')
        if len(post)!=30208 or hashlib.sha256(post).hexdigest()!=POST:raise ValueError('Actual installed POST mismatch')
        version=struct.unpack_from('<II',system,20)
        if system[:4]!=b'regf' or version!=(1,2) or system[4:8]!=system[8:12] or h.hive.checksum(system)!=struct.unpack_from('<I',system,508)[0]:
            raise ValueError('Clean measured SYSTEM1.2 required')
        policy=old.policy_values(h.hive.read_hive_content(system))
        if digest(target)!=target_hash:raise ValueError('Stopped target changed during readonly probe')
        record=dict(stopped=True,qemu_returncode=0,process_returncode=0,target=str(target),target_sha256=target_hash,
            driver_sha256=DRIVER,driver_bytes=16384,post_sha256=POST,post_bytes=30208,
            hive_version=list(version),system_sha256=hashlib.sha256(system).hexdigest(),policy=policy,
            client_configuration_disabled_readback=policy_pass(policy),own_files=own_files,
            registry_modified=False,no_ms_binary_or_hive_export=True,
            scope='Selected service Start/Type only; native running-state proof is separate')
    finally:
        if raw.resolve().parent!=WORK or raw.name!='client-auto-stopped.raw':raise ValueError('Exact scratch cleanup boundary required')
        if raw.exists():raw.unlink()
    record['scratch_whole_disk_removed']=True
    output.write_bytes((json.dumps(record,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(record,indent=2))


if __name__=='__main__':main()
