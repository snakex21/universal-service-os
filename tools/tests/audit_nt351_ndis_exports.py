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
import re
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


def control_flow(md,pe,rva,limit=800):
    """Follow direct branches of one routine; calls are recorded, not entered."""
    base=pe.OPTIONAL_HEADER.ImageBase;mapped=pe.get_memory_mapped_image()
    ranges=[(s.VirtualAddress,s.VirtualAddress+max(s.Misc_VirtualSize,s.SizeOfRawData))
            for s in pe.sections if s.Characteristics&0x20000000]
    todo=[base+rva];seen={};truncated=False
    while todo:
        address=todo.pop()
        if not any(a<=address-base<b for a,b in ranges):continue
        for i in md.disasm(mapped[address-base:],address):
            if i.address in seen or not i.id:break
            seen[i.address]={'rva':hex(i.address-base),'instruction':i.mnemonic+' '+i.op_str}
            if len(seen)>=limit:truncated=True;todo.clear();break
            if i.mnemonic.startswith('ret'):break
            if i.mnemonic.startswith(('j','loop')):
                if len(i.operands)==1 and i.operands[0].type==X86_OP_IMM:todo.append(i.operands[0].imm)
                if i.mnemonic=='jmp':break
    return {'entry_rva':hex(rva),'instructions':[seen[k] for k in sorted(seen)],
            'truncated':truncated,'scope':'Direct-branch CFG only; indirect jumps and callees need separate proof'}


def instructions(binary,export_functions=False,extra_rvas=(),call_offsets=(),windows=(),field_offsets=(),immediates=()):
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
    indirect_fields=[]
    field_references=[]
    immediate_references=[]
    for n,i in enumerate(decoded):
        if i.id and any(o.type==X86_OP_IMM and o.imm in immediates for o in i.operands):
            immediate_references.append({'rva':hex(i.address-base),
                'context':[record(item) for item in decoded[max(0,n-14):n+15]]})
        if i.id and any(o.type==X86_OP_MEM and o.mem.disp in field_offsets and
                        md.reg_name(o.mem.base) not in ('','esp','ebp') for o in i.operands):
            field_references.append({'rva':hex(i.address-base),
                'context':[record(item) for item in decoded[max(0,n-14):n+15]]})
        if i.mnemonic!='call':continue
        if (len(i.operands)==1 and i.operands[0].type==X86_OP_MEM and
            i.operands[0].mem.base and i.operands[0].mem.disp in call_offsets):
            indirect_fields.append({'call_rva':hex(i.address-base),'field_offset':hex(i.operands[0].mem.disp),
                'context':[record(item) for item in decoded[max(0,n-14):n+8]]})
        name=import_name(i)
        if len(i.operands)==1 and i.operands[0].type==X86_OP_IMM:name=thunks.get(i.operands[0].imm,name)
        if name in CALLS:
            contexts.append({'import':name,'call_rva':hex(i.address-base),
                             'context':[record(item) for item in decoded[max(0,n-20):n+4]]})
    cfg_rvas=dict(selected) if export_functions or extra_rvas else {}
    cfg={name:control_flow(md,pe,rva) for name,rva in cfg_rvas.items()
         if name=='NdisMRegisterMiniport' or name.startswith('rva_')}
    window_results=[]
    for rva,before,after in windows:
        index=next(n for n,i in enumerate(decoded) if i.address>=base+rva)
        window_results.append({'target_rva':hex(rva),'instructions':[
            record(i) for i in decoded[max(0,index-before):index+after+1]],
            'scope':'Instruction window, not inferred function boundary'})
    return {'exports_rva':{n:hex(v) for n,v in sorted(exports.items())},
            'import_iat':{hex(address-base):name for address,name in sorted(iat.items())},
            'control_flow':cfg,
            'indirect_field_calls':indirect_fields,
            'field_references':field_references,
            'immediate_references':immediate_references,
            'windows':window_results,
            'functions':functions,'import_call_contexts':contexts}


def main(args):
    helper=args.coverage_root.resolve()/'tools/tests/coverage/driver_audit.py'
    spec=importlib.util.spec_from_file_location('original_audit',helper)
    audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
    cases=json.loads(args.plan.read_text(encoding='utf-8'))
    system,folder=(('windows-nt-3-51','Windows NT 3.51') if args.edition=='workstation' else
        ('windows-nt-3-51-server','Windows NT 3.51 Server'))
    candidates=[c for c in cases if c['system']==system and c['folder']==folder]
    if len(candidates)!=1:raise ValueError('Exactly one selected original NT3.51 case required')
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
            'edition':args.edition,'source_sha256':case['source_sha256'],'member_sha256':case['member_sha256'],'modules':{}}
    extra={}
    for item in args.rva:
        module,rva=item.split(':',1)
        if module not in ('ndis.sys','ne2000.sys','elnk3.sys','dc21x4.sys','e100b.sys'):raise ValueError('Unexpected module for RVA')
        extra.setdefault(module,[]).append(int(rva,0))
    windows={}
    for item in args.window:
        module,rva,before,after=item.split(':')
        if module not in ('ndis.sys','dc21x4.sys'):raise ValueError('Unexpected window module')
        before,after=int(before),int(after)
        if not 0<=before<=160 or not 0<=after<=160:raise ValueError('Instruction window too large')
        windows.setdefault(module,[]).append((int(rva,0),before,after))
    with tempfile.TemporaryDirectory(prefix='original-',dir=SCRATCH) as temporary:
        work=Path(temporary).resolve()
        if not work.is_relative_to(SCRATCH.resolve()):raise ValueError('Temporary path escaped owned audit')
        subprocess.run([str(audit.SEVEN),'e','-y','-o'+str(work),case['source'],case['member']],
                       check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=120)
        iso=work/Path(case['member']).name
        if digest(iso)!=case['member_sha256']:raise ValueError('Original ISO hash mismatch')
        with iso.open('rb') as stream:
            volume=audit.media.ISO(stream)
            report['network_inf_members']=[name for name in sorted(volume.entries)
                if name.startswith('i386/') and any(Path(name).name.startswith(prefix)
                    for prefix in ('oemnad','oemnsp','oemnxp','nettcp','ntlanman','unattend','initial'))]
            if args.inf_contract:
                report['inf_contract']={}
                for name in args.inf_contract:
                    if not name.startswith('i386/') or name not in volume.entries:
                        raise ValueError('INF contract must name an exact original i386 member')
                    blob=audit.binary(volume,name)
                    text=blob.decode('cp1252')
                    lines=text.splitlines()
                    matches=[i for i,line in enumerate(lines) if any(re.search(pattern,line,re.I)
                        for pattern in args.inf_pattern)]
                    indices={i for n in matches for i in range(max(0,n-args.inf_context),min(len(lines),n+args.inf_context+1))}
                    if len(indices)>800:raise ValueError('Narrow INF contract patterns: more than800 selected lines')
                    report['inf_contract'][name]={'sha256':hashlib.sha256(blob).hexdigest(),
                        'total_lines':len(lines),'lines':[{'line':i+1,'text':lines[i]} for i in sorted(indices)],
                        'scope':'Bounded contract excerpts only; original expanded file stays in RAM'}
                    if args.loop_patch and name=='i386/oemnadlb.in_':
                        patch=args.loop_patch.resolve()
                        if patch!=ROOT/'tools/nt351_network_setup.sh':raise ValueError('Expected owned NT351 patch function')
                        shell=Path(r'C:\Program Files\Git\bin\sh.exe')
                        changed=subprocess.run([str(shell),'-c',f'. "{patch.as_posix()}"; usos_nt351_loop_inf'],
                            input=blob,capture_output=True,check=True)
                        if changed.stdout.count(b';USOS-NT351-LOOP-AUTO')!=1:raise ValueError('Expected exactly one original INF patch')
                        report['loop_patch_validation']={'source_sha256':hashlib.sha256(blob).hexdigest(),
                            'patched_sha256':hashlib.sha256(changed.stdout).hexdigest(),
                            'original_bytes':len(blob),'patched_bytes':len(changed.stdout),
                            'patch_source_sha256':digest(patch),'process_exit':changed.returncode,
                            'microsoft_bytes_persisted':False,'runtime_pass':False}
            for name in ('ndis.sys','ne2000.sys','elnk3.sys','dc21x4.sys','e100b.sys'):
                binary,member=audit.module_from_iso(volume,name)
                if binary is None:report['modules'][name]={'present':False};continue
                sha=hashlib.sha256(binary).hexdigest()
                if name=='ndis.sys' and sha!=EXPECTED_NDIS:raise ValueError('Original NDIS hash differs from prior audit')
                exports,imports=audit.pe(audit.MemoryFile(binary,name))
                report['modules'][name]={'member':member,'sha256':sha,'exports':sorted(exports),
                    'imports':imports,'selected_exports':{item:item in exports for item in SELECTED},
                    'analysis':instructions(binary,name=='ndis.sys',extra.get(name,()),
                        args.indirect_call_offset if name=='ndis.sys' else (),windows.get(name,()),
                        args.field_offset if name=='ndis.sys' else (),
                        args.immediate if name=='ndis.sys' else ())}
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
    parser.add_argument('--edition',choices=('workstation','server'),default='workstation')
    parser.add_argument('--rva',action='append',default=[],help='Bounded instruction proof, module:RVA; no raw bytes persisted')
    parser.add_argument('--indirect-call-offset',action='append',default=[],type=lambda n:int(n,0),help='NDIS indirect call field to trace from registration dataflow')
    parser.add_argument('--window',action='append',default=[],help='Bounded module:RVA:before:after instruction window')
    parser.add_argument('--field-offset',action='append',default=[],type=lambda n:int(n,0),help='NDIS non-stack field access to follow from verified dataflow')
    parser.add_argument('--immediate',action='append',default=[],type=lambda n:int(n,0),help='NDIS immediate address/value references for verified dataflow')
    parser.add_argument('--inf-contract',action='append',default=[],help='Exact original i386 INF member; bounded contract lines only')
    parser.add_argument('--inf-pattern',action='append',default=[],help='Case-insensitive original INF contract regex')
    parser.add_argument('--inf-context',type=int,choices=range(0,21),default=4)
    parser.add_argument('--loop-patch',type=Path,help='Execute the owned patch against original OEMNADLB in RAM; persist only hashes')
    main(parser.parse_args())
