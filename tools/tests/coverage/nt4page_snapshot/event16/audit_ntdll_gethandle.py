from pathlib import Path
import importlib.util,json
HERE=Path(__file__).resolve().parent;s=importlib.util.spec_from_file_location('own_loader_audit',HERE/'audit_ntdll_loader_names.py');a=importlib.util.module_from_spec(s);s.loader.exec_module(a)
groups=[]
for start,size in ((0x3ae8,0x200),):
 groups.append([{'rva':hex(x.address),'instruction':x.mnemonic+' '+x.op_str} for x in a.md.disasm(a.p.get_data(start,size),start)])
result={'scope':'Original public LdrGetDllHandle code, no guest data','sha256':a.result['sha256'],'functions':groups}
(HERE/'original-ntdll-gethandle-metadata.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(result,indent=2))
