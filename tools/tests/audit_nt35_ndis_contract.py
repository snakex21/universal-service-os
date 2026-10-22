"""Bounded original NT35 miniport bus/timer contract; MS inputs only in RAM."""
from pathlib import Path
import hashlib,importlib.util,json,shutil,struct,subprocess,tempfile
import capstone,pefile
from capstone.x86_const import X86_OP_MEM,X86_OP_IMM
ROOT=Path(__file__).resolve().parents[2]
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
OWN=Path(r'G:\USOS-Kolekcja\_audit\nt35-miniport-bus-contract')
OUT=ROOT/'artifacts/nt35-network/original-bus-contract-04.json'
EXPECTED='fa392210418f6a5977ea8117d49b4d6a0b4cfc7d4fcc436fca2e3defdd6a5543'
SELECTED=('NdisMRegisterMiniport','NdisMSetAttributes','NdisMMapIoSpace','NdisMapIoSpace',
 'NdisMRegisterInterrupt','NdisMAllocateMapRegisters','NdisMAllocateSharedMemory','NdisReadConfiguration',
 'NdisReadPciSlotInformation','NdisWritePciSlotInformation','NdisPciAssignResources',
 'NdisMInitializeTimer','NdisMCancelTimer','NdisMDeregisterInterrupt')
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def digest(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def inspect(binary):
 pe=pefile.PE(data=binary);base=pe.OPTIONAL_HEADER.ImageBase
 md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_32);md.detail=True;md.skipdata=True
 instructions=[i for section in pe.sections if section.Characteristics&0x20000000 for i in md.disasm(section.get_data(),base+section.VirtualAddress)]
 decode=load('own_cfg',ROOT/'tools/tests/audit_nt351_ndis_exports.py')
 exports={e.name.decode():e.address for e in pe.DIRECTORY_ENTRY_EXPORT.symbols if e.name}
 iat={i.address:i.name.decode() for m in pe.DIRECTORY_ENTRY_IMPORT for i in m.imports if i.name}
 def rec(i):return {'rva':hex(i.address-base),'instruction':i.mnemonic+' '+i.op_str}
 def window(n,before=8,after=8):return [rec(i) for i in instructions[max(0,n-before):n+after+1]]
 fields=[];timer=[];callback=[];filter_calls=[]
 for n,i in enumerate(instructions):
  if not i.id:continue
  if any(o.type==X86_OP_MEM and o.mem.disp in (0xd8,0x104,0x108,0x10c) and md.reg_name(o.mem.base) not in ('','esp','ebp') for o in i.operands):fields.append({'at':rec(i),'context':window(n)})
  if i.mnemonic=='call' and i.operands[0].type==X86_OP_MEM:
   op=i.operands[0]
   if op.mem.base==0 and iat.get(op.mem.disp) in ('KeSetTimer','KeCancelTimer','KeRemoveQueueDpc','KeInitializeDpc','HalGetBusDataByOffset','HalTranslateBusAddress'):
    timer.append({'import':iat[op.mem.disp],'context':window(n,14,5)})
   if op.mem.base and op.mem.disp in (0x20,0x2c):callback.append({'at':rec(i),'context':window(n,8,5)})
  if i.mnemonic=='call' and i.operands[0].type==X86_OP_IMM and i.operands[0].imm==base+exports.get('EthCreateFilter',0):filter_calls.append({'at':rec(i),'context':window(n,18,8)})
  if i.mnemonic=='call' and i.operands[0].type==X86_OP_IMM and i.operands[0].imm==base+exports.get('NdisSetTimer',0):timer.append({'import':'internal NdisSetTimer','context':window(n,14,5)})
 if len(fields)>160 or len(timer)>80 or len(callback)>128:raise ValueError('Narrow instruction limits exceeded')
 prologues=[i.address-base for n,i in enumerate(instructions) if n and i.mnemonic=='mov' and i.op_str=='ebp, esp' and instructions[n-1].mnemonic=='push' and instructions[n-1].op_str=='ebp']
 bus_entry=0x9258
 bus_cfg=decode.control_flow(md,pe,bus_entry,limit=3000)
 windows=[]
 for address,before,after in ((0x98e,50,70),(0x8005,55,30),(0x96c0,10,12)):
  at=next(n for n,i in enumerate(instructions) if i.address>=base+address)
  windows.append({'rva':hex(address),'instructions':window(at,before,after)})
 strings={}
 for name in ('BusNumber','BusType','InterfaceType','SlotNumber'):
  needle=(name+'\0').encode('utf-16le');start=0;found=[]
  while True:
   off=binary.find(needle,start)
   if off<0:break
   rva=pe.get_rva_from_offset(off);address=base+rva
   refs=[{'at':rec(i),'context':window(n)} for n,i in enumerate(instructions) if i.id and any(o.type==X86_OP_IMM and o.imm==address for o in i.operands)]
   datarefs=[];at=0
   while True:
    at=binary.find(struct.pack('<I',address),at)
    if at<0:break
    datarefs.append(hex(pe.get_rva_from_offset(at)));at+=4
   found.append({'rva':hex(rva),'code_xrefs':refs,'all_pointer_rvas':datarefs});start=off+len(needle)
  strings[name]=found
 return {'sha256':hashlib.sha256(binary).hexdigest(),'exports':{n:hex(v) for n,v in exports.items()},
  'cfg':{n:decode.control_flow(md,pe,exports[n],limit=800) for n in SELECTED if n in exports},
  'checker_cfg':decode.control_flow(md,pe,0x946,limit=800),'halt_cfg':decode.control_flow(md,pe,0x7f68,limit=800),'eth_create_calls':filter_calls,'diagnostic_windows':windows,'bus_init_entry':hex(bus_entry),'bus_init_cfg':bus_cfg,'attributes_helper':decode.control_flow(md,pe,0x1b34,limit=300),'fields':fields,'bus_strings':strings,
  'kernel_import_contexts':timer,'checker_halt_call_candidates':callback}
def main():
 if OUT.exists():raise FileExistsError('New audit output required')
 if not OWN.resolve().is_relative_to(Path(r'G:\USOS-Kolekcja\_audit').resolve()):raise ValueError('Audit path escaped')
 if shutil.disk_usage(OWN.anchor).free<100*1024**3:raise ValueError('100GiB reserve required')
 OWN.mkdir(parents=True,exist_ok=True);OUT.parent.mkdir(parents=True,exist_ok=True)
 helper=load('original_media',MATRIX/'tools/tests/coverage/driver_audit.py')
 unpack=helper.cab.unpack;helper.cab.unpack=lambda blob,member=None:unpack(blob,member,scratch=OWN/'packed')
 cases=json.loads((MATRIX/'artifacts/coverage/nt3-hid-runtime-plan-r15.json').read_text(encoding='utf-8'))
 case,=[c for c in cases if c['system']=='windows-nt-3-5' and c['folder']=='Windows NT 3.5']
 source=Path(case['source'])
 if digest(source)!=case['source_sha256']:raise ValueError('Original source hash mismatch')
 with tempfile.TemporaryDirectory(prefix='original-',dir=OWN) as temporary:
  work=Path(temporary).resolve();assert work.is_relative_to(OWN.resolve())
  subprocess.run([str(helper.SEVEN),'e','-y','-o'+str(work),str(source),case['member']],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True,timeout=120)
  iso=work/Path(case['member']).name
  if digest(iso)!=case['member_sha256']:raise ValueError('Original ISO hash mismatch')
  with iso.open('rb') as stream:
   blob,member=helper.module_from_iso(helper.media.ISO(stream),'ndis.sys')
   if hashlib.sha256(blob).hexdigest()!=EXPECTED:raise ValueError('Exact NT35 NDIS hash mismatch')
   info=inspect(blob)
 result={'scope':'Static primary original NT35 bus and miniport checker evidence; no runtime/build PASS',
  'source_sha256':case['source_sha256'],'iso_sha256':case['member_sha256'],'script_sha256':digest(Path(__file__)),
  'temporary_iso_removed':not work.exists(),'expanded_ms_binary_exported':False,'ndis':info}
 OUT.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps({'completed':True,'output':str(OUT),'fields':len(info['fields']),'callbacks':len(info['checker_halt_call_candidates'])}))
if __name__=='__main__':main()
