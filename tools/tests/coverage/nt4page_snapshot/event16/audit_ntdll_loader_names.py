from pathlib import Path
import importlib.util,json,hashlib,capstone
HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('own_bank',HERE.parent/'original_nt4_message_bank.py');b=importlib.util.module_from_spec(s);s.loader.exec_module(b)
with b.a.ISO.open('rb') as f:blob,member=b.a.audit.module_from_iso(b.a.audit.media.ISO(f),'ntdll.dll')
p=b.pefile.PE(data=blob);md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_32);md.detail=True
ins=[]
for sec in p.sections:
 if sec.Characteristics&0x20000000:ins.extend(md.disasm(sec.get_data()[:sec.Misc_VirtualSize],sec.VirtualAddress))
groups=[]
for index,x in enumerate(ins):
 if x.mnemonic=='lea' and any(o.type==capstone.x86.X86_OP_MEM and o.mem.disp==0x2c for o in x.operands):
  groups.append([{'rva':hex(z.address),'instruction':z.mnemonic+' '+z.op_str} for z in ins[max(0,index-7):index+9]])
result={'scope':'Original public NTDLL instructions only; no runtime data','source_member':member,'sha256':hashlib.sha256(blob).hexdigest(),'base_name_candidate_instructions':groups}
(HERE/'original-ntdll-loader-basename-metadata.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
if __name__=='__main__':print(json.dumps({'sha256':result['sha256'],'instruction_groups':len(groups)}))
