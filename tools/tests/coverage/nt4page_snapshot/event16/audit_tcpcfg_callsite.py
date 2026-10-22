from pathlib import Path
import importlib.util,json,hashlib,capstone
HERE=Path(__file__).resolve().parent;s=importlib.util.spec_from_file_location('own_bank',HERE.parent/'original_nt4_message_bank.py');b=importlib.util.module_from_spec(s);s.loader.exec_module(b)
with b.a.ISO.open('rb') as f:blob,member=b.a.audit.module_from_iso(b.a.audit.media.ISO(f),'tcpcfg.dll')
p=b.pefile.PE(data=blob);md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_32);md.detail=True;base=p.OPTIONAL_HEADER.ImageBase
imports={x.address:entry.dll.decode('ascii')+'!'+x.name.decode('ascii') for entry in p.DIRECTORY_ENTRY_IMPORT for x in entry.imports if x.name}
groups=[]
allins=[]
for sec in p.sections:
 if sec.Characteristics&0x20000000:
  md.skipdata=True;allins.extend(md.disasm(sec.get_data()[:sec.Misc_VirtualSize],base+sec.VirtualAddress));md.skipdata=False
sites=[]
for x in allins:
 if x.id and x.mnemonic=='call' and x.operands and x.operands[0].type==capstone.x86.X86_OP_IMM and x.operands[0].imm==base+0x11502:sites.append(x.address-base)
for start,size in [(0x11470,0x150)]+[(max(0x1000,x-0x90),0xc0) for x in sites]:
 ins=[]
 for x in md.disasm(p.get_data(start,size),base+start):
  value={'rva':hex(x.address-base),'instruction':x.mnemonic+' '+x.op_str}
  if x.mnemonic in ('call','jmp') and x.operands and x.operands[0].type==capstone.x86.X86_OP_MEM and x.operands[0].mem.disp in imports:value['public_import']=imports[x.operands[0].mem.disp]
  ins.append(value)
 groups.append(ins)
result={'scope':'Original TCPCFG public code only, no runtime text or parameters','source_member':member,'sha256':hashlib.sha256(blob).hexdigest(),'preferred_base':hex(base),'helper_call_sites':[hex(x) for x in sites],'functions':groups}
(HERE/'original-tcpcfg-callsite-metadata.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
if __name__=='__main__':print(json.dumps({'sha256':result['sha256'],'helper_call_sites':result['helper_call_sites'],'caller_functions':groups[1:]},indent=2))
