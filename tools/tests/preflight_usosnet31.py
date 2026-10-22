"""Check actual NT31 PE/imports, original ABI and compiled callback symbols."""
from pathlib import Path
import argparse,hashlib,json,struct
import pefile
ROOT=Path(__file__).resolve().parents[2]
def coff_symbols(path):
    b=path.read_bytes();_,_,_,table,count,_,_=struct.unpack_from('<HHIIIHH',b)
    strings=table+count*18;names=[];i=0
    while i<count:
        at=table+i*18;raw=b[at:at+8]
        if raw[:4]==b'\0'*4:
            start=strings+struct.unpack_from('<I',raw,4)[0];end=b.index(0,start);name=b[start:end]
        else:name=raw.split(b'\0')[0]
        names.append(name.decode('ascii'));i+=1+b[at+17]
    return set(names)
def check(build):
    build=build.resolve();manifest=json.loads((build/'build.json').read_text(encoding='utf-8'))
    binary=build/'usosnet31.sys';raw=binary.read_bytes()
    assert hashlib.sha256(raw).hexdigest()==manifest['sha256']
    assert manifest['host_policy_pass'] and manifest['host_policy_cases']==52 and manifest['helper_identity_cases']==14
    for rel,sha in manifest['source_sha256'].items():
        assert hashlib.sha256((ROOT/'tools/nt/usosnet'/rel).read_bytes()).hexdigest()==sha,rel
    measured=json.loads((ROOT/'artifacts/nt31-fullmac-contract/lifecycle-06.json').read_text(encoding='utf-8'))
    assert measured['protected_binaries_unchanged'] and measured['temporary_iso_removed']
    pe=pefile.PE(data=raw);oh=pe.OPTIONAL_HEADER
    assert (oh.MajorOperatingSystemVersion,oh.MinorOperatingSystemVersion,oh.MajorSubsystemVersion,oh.MinorSubsystemVersion)==(3,10,3,10)
    # Original NT31 demand-loader772E4 rejects FileAlignment&0x1ff, then
    # requires a power of two and SectionAlignment>=FileAlignment.
    assert oh.FileAlignment>=0x200 and oh.FileAlignment&0x1ff==0 and oh.FileAlignment&(oh.FileAlignment-1)==0
    assert oh.SectionAlignment==0x1000 and oh.SectionAlignment>=oh.FileAlignment
    assert all(section.VirtualAddress%0x1000==0 for section in pe.sections)
    imports={d.dll.decode().lower():[i.name.decode() for i in d.imports] for d in pe.DIRECTORY_ENTRY_IMPORT}
    assert set(imports)=={'ndis.sys','hal.dll','ntoskrnl.exe'}
    for dll,names in imports.items():assert set(names)<=set(measured['modules'][dll]['exports_rva']),dll
    legacy=json.loads((ROOT/'tools/nt/usosnet/src31/legacy_imports.json').read_text(encoding='utf-8'))
    assert set(legacy)<=set(imports['ndis.sys'])
    assert not any(n.startswith('NdisM') and n!='NdisMapIoSpace' for n in imports['ndis.sys'])
    ndis=measured['modules']['ndis.sys']
    for name,cleanup in legacy.items():
        cfg=next(c for c in ndis['direct_cfg'].values() if c['entry_rva']==ndis['exports_rva'][name])
        observed={int(i['instruction'].split()[1],0) if len(i['instruction'].split())>1 else 0 for i in cfg['instructions'] if i['instruction'].startswith('ret')}
        assert observed=={cleanup},(name,cleanup,observed)
    compiled=coff_symbols(build/'src/objfre/i386/usosnet31.obj')
    callbacks={'Open':36,'Close':4,'Send':8,'Transfer':24,'Reset':4,'Request':8,'GlobalQuery':8,'Unload':4,'Add':12,'Remove':4}
    assert {'_'+name+'@'+str(n) for name,n in callbacks.items()}<=compiled
    for path,sha in manifest['protected_binaries'].items():assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==sha,path
    result=dict(scope='Host build/import/ABI/policy only; no Windows runtime PASS',binary_sha256=manifest['sha256'],imports={k:len(v) for k,v in imports.items()},original_cleanup_contracts=len(legacy),compiled_callbacks=len(callbacks),host_policy_cases=52,helper_identity_cases=14,protected_binaries_unchanged=True,runtime_pass=False)
    (build/'preflight.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('build',type=Path);a=p.parse_args();print(json.dumps(check(a.build),indent=2))
