"""Own bounded GDB event adapter: no text pointers, no bulk registers or RAM export."""
import asyncio,re,xml.etree.ElementTree as ET
class Rsp:
 def __init__(self,breaks):
  self.ready=asyncio.Event();self.reader=None;self.writer=None;self.breaks=set(breaks);self.regs={};self.arch=None
 async def accept(self,reader,writer):
  if self.writer is not None:writer.close();return
  self.reader=reader;self.writer=writer;self.ready.set()
 @staticmethod
 def decode_payload(wire):
  out=bytearray();i=0
  while i<len(wire):
   c=wire[i];i+=1
   if c==125:
    if i==len(wire):raise ValueError('Truncated RSP escape')
    out.append(wire[i]^32);i+=1
   elif c==42:
    if not out or i==len(wire) or not 32<=wire[i]<=126:raise ValueError('Invalid RSP repetition')
    count=wire[i]-29;i+=1
    if count<3 or len(out)+count>65536:raise ValueError('RSP expansion bound')
    out.extend(bytes([out[-1]])*count)
   else:out.append(c)
   if len(out)>65536:raise ValueError('RSP payload bound')
  return bytes(out)
 async def receive(self):
  while True:
   c=await self.reader.readexactly(1)
   if c==b'$':break
   if c not in (b'+',):raise ValueError('Unexpected RSP framing')
  wire=bytearray()
  while True:
   c=await self.reader.readexactly(1)
   if c==b'#':break
   wire.extend(c)
   if len(wire)>65536:raise ValueError('RSP wire bound')
  check=await self.reader.readexactly(2)
  if not re.fullmatch(b'[0-9a-fA-F]{2}',check) or int(check,16)!=(sum(wire)&255):raise ValueError('RSP checksum')
  self.writer.write(b'+');await self.writer.drain();return self.decode_payload(wire)
 def validate(self,command):
  if command in ('qSupported:xmlRegisters=i386','c','s'):return
  if re.fullmatch(r'qXfer:features:read:[a-zA-Z0-9_.-]{1,80}:[0-9a-f]{1,5},1000',command):return
  if re.fullmatch(r'p[0-9a-f]{1,3}',command) and int(command[1:],16) in {r[0] for r in self.regs.values()}:return
  m=re.fullmatch(r'[Zz]1,([0-9a-f]{1,8}),1',command)
  if m and int(m[1],16) in self.breaks:return
  # m is deliberately issued only by the word-policy object below.
  raise ValueError('RSP command not allowlisted')
 async def _send(self,command):
  body=command.encode('ascii');self.writer.write(b'$'+body+b'#'+format(sum(body)&255,'02x').encode('ascii'));await self.writer.drain()
 async def command(self,command):
  self.validate(command);await self._send(command);return await self.receive()
 async def word(self,address,permit):
  if not permit(address):raise ValueError('Four-byte read boundary')
  await self._send('m'+format(address,'x')+',4');result=await self.receive()
  if not re.fullmatch(b'[0-9a-fA-F]{8}',result):raise ValueError('Exact four-byte read failed')
  return bytes.fromhex(result.decode('ascii'))
 async def features(self):
  result=await self.command('qSupported:xmlRegisters=i386')
  if b'qXfer:features:read+' not in result:raise ValueError('Feature XML required')
  documents={};counter=0;seen=set();total=0
  async def get(name):
   nonlocal total
   if name in seen:raise ValueError('Cyclic feature XML')
   seen.add(name);parts=[];offset=0
   while True:
    data=await self.command('qXfer:features:read:'+name+':'+format(offset,'x')+',1000')
    if not data or data[0] not in (109,108):raise ValueError('Feature transport')
    parts.append(data[1:]);offset+=len(data)-1;total+=len(data)-1
    if total>65536 or len(seen)>8:raise ValueError('Feature XML bound')
    if data[0]==108:break
    if len(data)==1:raise ValueError('Empty feature continuation')
   xml=b''.join(parts)
   if b'xi:include' in xml and b'xmlns:xi' not in xml:xml=re.sub(b'<target(?=[ >])',b'<target xmlns:xi="http://www.w3.org/2001/XInclude"',xml,count=1)
   node=ET.fromstring(xml);await visit(node)
  async def visit(node):
   nonlocal counter
   tag=node.tag.split('}')[-1]
   if tag=='include':
    name=node.attrib.get('href','')
    if not re.fullmatch('[a-zA-Z0-9_.-]{1,80}',name):raise ValueError('Feature annex name')
    await get(name);return
   if tag=='architecture':self.arch=node.text
   if tag=='reg':
    number=int(node.attrib.get('regnum',counter));counter=number+1;name=node.attrib.get('name');bits=int(node.attrib.get('bitsize','0'))
    if name in ('rip','eip','rsp','esp','cs','fs_base','ebp','rbp'):
     if bits not in (16,32,64) or number>4095:raise ValueError('Selected register shape')
     self.regs[name]=(number,bits)
   for child in node:await visit(child)
  await get('target.xml')
  if self.arch not in ('i386','i386:x86-64') or not any(n in self.regs for n in ('rip','eip')) or not any(n in self.regs for n in ('rsp','esp')) or 'cs' not in self.regs:raise ValueError('Unsupported x86 feature contract')
 async def register(self,kind):
  name=next((n for n in {'pc':('eip','rip'),'sp':('esp','rsp'),'fp':('ebp','rbp'),'cs':('cs',),'fs_base':('fs_base',)}[kind] if n in self.regs),None)
  if name is None:raise ValueError('Selected register unavailable')
  number,bits=self.regs[name];data=await self.command('p'+format(number,'x'))
  if not re.fullmatch(b'[0-9a-fA-F]{'+str(bits//4).encode('ascii')+b'}',data):raise ValueError('Selected register width')
  return int.from_bytes(bytes.fromhex(data.decode('ascii')),'little')
 async def breakpoint(self,address,insert=True):
  result=await self.command(('Z1,' if insert else 'z1,')+format(address,'x')+',1')
  if result!=b'OK':raise ValueError('Hardware event breakpoint unavailable')
 async def resume(self,step=False):
  result=await self.command('s' if step else 'c')
  if not (result==b'S05' or result.startswith(b'T05') and len(result)<=4096 and all(32<=c<=126 for c in result)):raise ValueError('Unexpected debug stop')
  return result
class WordPolicy:
 def __init__(self,entries,modules,synthetic=False):
  self.entries={x['address']:x for x in entries};self.modules=modules;self.synthetic=synthetic;self._paused_context=None
 def relocated_candidate(self):
  if self._paused_context is None:raise ValueError('No paused event context')
  caller=self._paused_context['caller'];api=self._paused_context['api'];matches=set()
  for module in self.modules:
   for site in module.get('allowlisted_return_sites',[]):
    rva=site['return_rva'];base=caller-rva
    if site['api']==api and (caller&65535)==(rva&65535) and 0x10000<=base<0x7ffe0000-module['image_size'] and not base&65535 and any(x['start']<=rva<x['start']+x['size'] for x in module['executable_ranges']):matches.add((module['module'],rva))
  result={'caller_enum':'RELOCATED_CALLSITE_NOT_UNIQUE','ACK_authorized':False}
  if len(matches)==1:
   name,rva=next(iter(matches));result.update(caller_enum='CANDIDATE_RELOCATED_CALLSITE',caller_module=name,caller_rva=hex(rva))
  return result
 async def event(self,client):
  pc=await client.register('pc')
  if pc not in self.entries:raise ValueError('Stop outside fixed public API')
  api=self.entries[pc];prefix=await client.word(pc,lambda a:a==pc)
  if prefix.hex()!=api['public_prefix_4']:raise ValueError('Original public API prefix mismatch')
  cs=await client.register('cs')
  if not self.synthetic and cs&3!=3:raise ValueError('User mode required')
  stack=await client.register('sp');low,high=(0x7000,0x7c00) if self.synthetic else (0x10000,0x7ffe0000)
  if stack%4 or not low<=stack<high-12:raise ValueError('Exact user stack boundary')
  caller=int.from_bytes(await client.word(stack,lambda a:a==stack),'little');mapped=[];candidates=[]
  # This context is never serialized, printed, or included in an exception.
  self._paused_context={'api':api['api'],'pc':pc,'stack':stack,'caller':caller}
  for module in self.modules:
   rva=caller-module['preferred_base']
   if any(x['start']<=rva<x['start']+x['size'] for x in module['executable_ranges']):
    candidates.append((module['module'],rva))
    if self.synthetic or any(x['return_rva']==rva and x['api']==api['api'] for x in module.get('allowlisted_return_sites',[])):mapped.append((module['module'],rva))
  strength='EXACT_ORIGINAL_API_RETURN_SITE' if len(mapped)==1 else 'CANDIDATE_UNVERIFIED_CALLSITE' if len(candidates)==1 else 'NOT_ALLOWLISTED'
  selected=mapped if len(mapped)==1 else candidates if len(candidates)==1 else []
  result={'api_enum':api['api'],'public_api_prefix_matches':True,'caller_enum':strength,'template_enum':'NOT_READ_FOR_THIS_API'}
  if len(selected)==1:result.update(caller_module=selected[0][0],caller_rva=hex(selected[0][1]))
  if api['numeric_template_argument_offset']==8:
   value=int.from_bytes(await client.word(stack+8,lambda a:a==stack+8),'little')
   if 0<value<65536:result.update(template_enum='NUMERIC_ID',template_id=value)
   else:result['template_enum']='NAMED_OR_POINTER_UNREAD'
  return pc,result
