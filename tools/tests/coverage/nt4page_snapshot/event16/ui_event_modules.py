"""Paused-event public loader metadata only; no text/EDIT, full paths, or RAM export."""
import re,hashlib,importlib.util
from pathlib import Path
def pointer(value,alignment=4):
 if type(value) is not int or value%alignment or not 0x10000<=value<0x7ffe0000-0x100:raise ValueError('Public metadata pointer boundary')
 return value
class Reader:
 def __init__(self,client):self.client=client;self.words=0
 async def word(self,address):
  pointer(address);self.words+=1
  if self.words>2048:raise ValueError('Public metadata total bound')
  return int.from_bytes(await self.client.word(address,lambda a:a==address),'little')
 async def basename(self,entry):
  shape=await self.word(entry+0x2c);length=shape&65535;maximum=shape>>16;buffer=await self.word(entry+0x30)
  if length%2 or maximum%2 or not 2<=length<=128 or not length<=maximum<=132 or (length+3)//4*4>maximum:raise ValueError('Bounded basename shape')
  pointer(buffer);data=bytearray()
  for offset in range(0,length,4):data.extend((await self.word(buffer+offset)).to_bytes(4,'little'))
  name=bytes(data[:length]).decode('utf-16-le').upper()
  if not re.fullmatch(r'[A-Z0-9_]{1,32}\.(?:DLL|EXE|CPL)',name):raise ValueError('Public basename grammar')
  return name
def original_from_stopped_base(name):
 # Exact public basename comes from one unique loader entry, never an arbitrary path.
 here=Path(__file__).resolve().parent
 def load(leaf,path):
  s=importlib.util.spec_from_file_location(leaf,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
 bank=load('own_original_module_bank',here.parent/'original_nt4_message_bank.py');base=load('own_immutable_base_reader',here.parent/'read_candidate02_setup_metadata.py')
 with bank.a.ISO.open('rb') as f:blob,member=bank.a.audit.module_from_iso(bank.a.audit.media.ISO(f),name.lower())
 if blob is None:raise ValueError('Original public module unavailable')
 fs=base.Fat(base.MappedRead(base.TARGET))
 try:installed,unused=base.debug.file_data(fs,'WINNT/SYSTEM32/'+name,8*1024**2)
 finally:fs.f.close()
 if hashlib.sha256(installed).digest()!=hashlib.sha256(blob).digest():raise ValueError('Original stopped module pin mismatch')
 pe=bank.pefile.PE(data=blob)
 return {'module':name,'image_size':pe.OPTIONAL_HEADER.SizeOfImage,'executable_ranges':[{'start':s.VirtualAddress,'size':s.Misc_VirtualSize} for s in pe.sections if s.Characteristics&0x20000000]}
async def inspect(client,context,manifest,original_resolver=original_from_stopped_base):
 out={'metadata_enum':'LOADER_METADATA_NOT_UNIQUE','ACK_authorized':False,'fs_base_available':'fs_base' in client.regs}
 if 'fs_base' not in client.regs:return out
 read=Reader(client);teb=pointer(await client.register('fs_base'),4096)
 if await read.word(teb+0x18)!=teb:raise ValueError('TEB self boundary')
 peb=pointer(await read.word(teb+0x30),4096);ldr=pointer(await read.word(peb+0xc));head=ldr+0x14;node=await read.word(head);last=await read.word(head+4);previous=head;seen=set();candidates=[]
 for count in range(129):
  if node==head:break
  if count==128 or node in seen:raise ValueError('Loader-list traversal bound')
  pointer(node);seen.add(node)
  if await read.word(node+4)!=previous:raise ValueError('Loader-list backlink boundary')
  entry=node-8;base=await read.word(entry+0x18);size=await read.word(entry+0x20)
  pointer(base,65536)
  if not 4096<=size<=64*1024**2 or size%4096 or base+size>=0x7ffe0000:raise ValueError('Loaded-image boundary')
  if base<=context['caller']<base+size:candidates.append((entry,base,size))
  previous=node;node=await read.word(node)
 if previous!=last:raise ValueError('Loader-list terminal backlink boundary')
 out['modules_checked']=len(seen)
 if len(candidates)!=1:return out
 entry,base,size=candidates[0];name=await read.basename(entry);rva=context['caller']-base
 # Unknown public names are retained in RAM only, never emitted automatically.
 modules=[x for x in manifest['modules'] if x['module']==name and x['image_size']==size and any(e['start']<=rva<e['start']+e['size'] for e in x['executable_ranges'])]
 if not modules:
  try:
   exact=original_resolver(name)
   if exact['module']==name and exact['image_size']==size and any(e['start']<=rva<e['start']+e['size'] for e in exact['executable_ranges']):modules=[exact]
  except (Exception,SystemExit):pass
 if len(modules)!=1:out['metadata_enum']='LOADED_CALLER_NOT_IN_PINNED_EXECUTABLE_MANIFEST';return out
 out.update(metadata_enum='UNIQUE_LOADED_EXECUTABLE_MAPPING',caller_enum='CANDIDATE_UNVERIFIED_CALLSITE',caller_module=name,caller_rva=hex(rva))
 if name=='TCPCFG.DLL' and rva==0x1154f and context['api']=='MessageBoxW':
  adapter_path=Path(__file__).with_name('ui_event_rsp_fp.py');s=importlib.util.spec_from_file_location('own_selected_fp_adapter',adapter_path);adapter=importlib.util.module_from_spec(s);s.loader.exec_module(adapter)
  selected=adapter.Rsp(client.breaks);selected.reader=client.reader;selected.writer=client.writer;await selected.features()
  resource=await tcp_resource(selected,context,base);out['metadata_enum']=resource['resource_enum']+('_'+str(resource['resource_id']) if 'resource_id' in resource else '')
 return out
async def tcp_resource(client,context,base):
 # Exact static helper 11502 has EBP frame and 0x24 byte stack delta at MessageBoxW.
 fp=await client.register('fp')
 if fp!=context['stack']+0x24 or fp%4 or not 0x10000<=fp<0x7ffe0000-8:raise ValueError('Exact original helper-frame boundary')
 value=int.from_bytes(await client.word(fp+4,lambda a:a==fp+4),'little')-base
 ids={0x117e8:0x62ce,0x11862:0x62d0,0x1196a:0x62d1}
 result={'resource_enum':'TCPCFG_HELPER_RETURN_NOT_ALLOWLISTED'}
 if value in ids:result.update(resource_enum='EXACT_ORIGINAL_TCPCFG_STR',resource_id=ids[value])
 return result
