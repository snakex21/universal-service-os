"""Hash-bound NT3.51 NDIS metadata/disassembly audit; never boots a VM.

Only the ISO and short-lived compressed CAB/SZDD inputs touch owned G:
scratch. Expanded Microsoft binaries stay in RAM. Output contains names,
hashes, RVAs and bounded instruction text, never raw binary bytes.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import shutil
import subprocess
import tempfile

import capstone
import pefile
from capstone.x86_const import X86_OP_IMM,X86_OP_MEM

ROOT=Path(__file__).resolve().parents[2]
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
SCRATCH=COLLECTION/'_audit/nt351-ndis-exports'
EXPECTED_NDIS='948d3c6feee3f80b98da5b40a254f7047b044a0bcc9be23739a460d7cfc5ab1b'
SELECTED=('NdisMSetAttributes','NdisMSetAttributesEx','NdisSetTimer','NdisMSetTimer',
          'NdisMSetPeriodicTimer','NdisMInitializeTimer','NdisMCancelTimer',
          'NdisMRegisterMiniport','NdisMQueryAdapterResources','NdisMPciAssignResources',
          'NdisOverrideBusNumber','EthFilterDprIndicateReceive',
          'EthFilterDprIndicateReceiveComplete','NdisMIndicateReceivePacket')
CALLS={'EthFilterDprIndicateReceive','EthFilterDprIndicateReceiveComplete',
       'NdisMRegisterMiniport','NdisMSetAttributes','NdisInitializeWrapper',
       'NdisSetTimer','NdisMInitializeTimer','NdisMCancelTimer'}


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def instructions(binary,export_functions=False,extra_rvas=()):
    pe=pefile.PE(data=binary,fast_load=False)
    if pe.FILE_HEADER.Machine!=0x14c:raise ValueError('Expected original i386 PE')
    base=pe.OPTIONAL_HEADER.ImageBase
    md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_32);md.detail=True;md.skipdata=True
    exports={e.name.decode('ascii'):e.address for e in getattr(pe,'DIRECTORY_ENTRY_EXPORT',()).symbols} if hasattr(pe,'DIRECTORY_ENTRY_EXPORT') else {}
    def record(i):return {'rva':hex(i.address-base),'instruction':i.mnemonic+' '+i.op_str}
    functions={}
    if export_functions or extra_rvas:
        mapped=pe.get_memory_mapped_image()
        selected={n:exports[n] for n in SELECTED if n in exports} if export_functions else {}
        selected.update({'rva_'+hex(rva):rva for rva in extra_rvas})
        for name,rva in selected.items():
            if not 0<=rva<len(mapped):raise ValueError('Selected RVA outside PE')
            decoded=[]
            for instruction in md.disasm(mapped[rva:rva+1024],base+rva):
                decoded.append(record(instruction))
                if instruction.mnemonic.startswith('ret') or len(decoded)>=180:break
            functions[name]={'rva':hex(rva),'instructions':decoded,'scope':'Bounded linear decode, not control-flow proof'}
    iat={i.address:i.name.decode('ascii') for m in getattr(pe,'DIRECTORY_ENTRY_IMPORT',()) for i in m.imports if i.name}
    decoded=[]
    for section in pe.sections:
        if section.Characteristics&0x20000000:
            decoded.extend(md.disasm(section.get_data(),base+section.VirtualAddress))
    def import_name(i):
        if not i.id:return None
        if len(i.operands)==1 and i.operands[0].type==X86_OP_MEM:
            memory=i.operands[0].mem
            if memory.base==0 and memory.index==0:return iat.get(memory.disp)
    thunks={i.address:import_name(i) for i in decoded if i.mnemonic=='jmp' and import_name(i)}
    contexts=[]
    for n,i in enumerate(decoded):
        if i.mnemonic!='call':continue
        name=import_name(i)
        if len(i.operands)==1 and i.operands[0].type==X86_OP_IMM:name=thunks.get(i.operands[0].imm,name)
        if name in CALLS:
            contexts.append({'import':name,'call_rva':hex(i.address-base),
                             'context':[record(item) for item in decoded[max(0,n-20):n+4]]})
    return {'exports_rva':{n:hex(v) for n,v in sorted(exports.items())},
            'import_iat':{hex(address-base):name for address,name in sorted(iat.items())},
            'functions':functions,'import_call_contexts':contexts}


def main(args):
    helper=args.coverage_root.resolve()/'tools/tests/coverage/driver_audit.py'
    spec=importlib.util.spec_from_file_location('original_audit',helper)
    audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
    cases=json.loads(args.plan.read_text(encoding='utf-8'))
    candidates=[c for c in cases if c['system']=='windows-nt-3-51' and c['folder']=='Windows NT 3.51']
    if len(candidates)!=1:raise ValueError('Exactly one NT3.51 Workstation case required')
    case=candidates[0]
    out=args.out.resolve()
    if not out.is_relative_to(ROOT/'artifacts') or out.exists():raise ValueError('Use a new metadata artifact in this worktree')
    if not SCRATCH.resolve().is_relative_to(COLLECTION/'_audit'):raise ValueError('Scratch escaped owned collection audit')
    SCRATCH.mkdir(parents=True,exist_ok=True)
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('Less than 100 GiB free')
    if digest(Path(case['source']))!=case['source_sha256']:raise ValueError('Source archive hash mismatch')
    original_unpack=audit.cab.unpack
    packed=(SCRATCH/'packed').resolve()
    if not packed.is_relative_to(SCRATCH.resolve()):raise ValueError('Packed-input path escaped owned audit')
    audit.cab.unpack=lambda blob,member=None:original_unpack(blob,member,scratch=packed)
    report={'scope':'Static original NT3.51 metadata and bounded disassembly; no ABI/runtime PASS',
            'source_sha256':case['source_sha256'],'member_sha256':case['member_sha256'],'modules':{}}
    extra={}
    for item in args.rva:
        module,rva=item.split(':',1)
        if module not in ('ndis.sys','ne2000.sys','elnk3.sys','dc21x4.sys','e100b.sys'):raise ValueError('Unexpected module for RVA')
        extra.setdefault(module,[]).append(int(rva,0))
    with tempfile.TemporaryDirectory(prefix='original-',dir=SCRATCH) as temporary:
        work=Path(temporary).resolve()
        if not work.is_relative_to(SCRATCH.resolve()):raise ValueError('Temporary path escaped owned audit')
        subprocess.run([str(audit.SEVEN),'e','-y','-o'+str(work),case['source'],case['member']],
                       check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=120)
        iso=work/Path(case['member']).name
        if digest(iso)!=case['member_sha256']:raise ValueError('Original ISO hash mismatch')
        with iso.open('rb') as stream:
            volume=audit.media.ISO(stream)
            for name in ('ndis.sys','ne2000.sys','elnk3.sys','dc21x4.sys','e100b.sys'):
                binary,member=audit.module_from_iso(volume,name)
                if binary is None:report['modules'][name]={'present':False};continue
                sha=hashlib.sha256(binary).hexdigest()
                if name=='ndis.sys' and sha!=EXPECTED_NDIS:raise ValueError('Original NDIS hash differs from prior audit')
                exports,imports=audit.pe(audit.MemoryFile(binary,name))
                report['modules'][name]={'member':member,'sha256':sha,'exports':sorted(exports),
                    'imports':imports,'selected_exports':{item:item in exports for item in SELECTED},
                    'analysis':instructions(binary,name=='ndis.sys',extra.get(name,()))}
    report['temporary_iso_removed']=not work.exists()
    report['expanded_microsoft_binaries_persisted']=False
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'result':'AUDIT_COMPLETE','output':str(out),
        'selected_exports':report['modules']['ndis.sys']['selected_exports'],
        'temporary_iso_removed':report['temporary_iso_removed'],'runtime_pass':False}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('coverage-root','plan','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--rva',action='append',default=[],help='Bounded instruction proof, module:RVA; no raw bytes persisted')
    main(parser.parse_args())
