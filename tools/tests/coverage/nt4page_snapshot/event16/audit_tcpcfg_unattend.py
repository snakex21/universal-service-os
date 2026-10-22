from pathlib import Path
import importlib.util,json,struct
HERE=Path(__file__).resolve().parent;s=importlib.util.spec_from_file_location('own_tcp_audit',HERE/'audit_tcpcfg_callsite.py');a=importlib.util.module_from_spec(s);s.loader.exec_module(a)
def literal(va):
 data=a.p.get_data(va-a.base,256);end=next((i for i in range(0,len(data)-1,2) if data[i:i+2]==b'\0\0'),None)
 if end is None:raise ValueError('Original literal bound')
 return data[:end].decode('utf-16le')
names=[]
for i in range(9):
 va=struct.unpack('<I',a.p.get_data(0x1c280+4*i,4))[0];names.append(literal(va))
ins=[]
for x in a.md.disasm(a.p.get_data(0x1161c,0x160),a.base+0x1161c):
 val={'rva':hex(x.address-a.base),'instruction':x.mnemonic+' '+x.op_str}
 if x.mnemonic=='call' and x.operands[0].type==a.capstone.x86.X86_OP_MEM and x.operands[0].mem.disp in a.imports:val['public_import']=a.imports[x.operands[0].mem.disp]
 ins.append(val)
result={'source_sha256':a.result['sha256'],'original_unattend_parameter_names':names,'instructions':ins}
(HERE/'original-tcpcfg-unattend-metadata.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(result,indent=2))
