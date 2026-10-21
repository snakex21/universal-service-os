"""Bounded, passive QEMU filter-mirror receiver for one owned igb netdev.

Frames use QEMU's big-endian u32 length prefix, no vnet header. Only localhost
is listened on; no host interface is captured. A full file is still drained.
"""
import asyncio
import hashlib
import ipaddress
import json
import struct
import time

MAC='52:54:00:55:53:01'
NETDEV='usabilitynet'
MAX_BYTES=8*1024**2
MAX_FRAME=65535
MAX_METADATA=64*1024
PCAP_HEADER=struct.pack('<IHHIIII',0xa1b2c3d4,2,4,0,0,MAX_FRAME,1)


def arguments(port):
    if type(port)!=int or not 1<=port<=65535:raise ValueError('Invalid local capture port')
    return ['-chardev',f'socket,id=nt351mirror,host=127.0.0.1,port={port},server=off',
        '-object',f'filter-mirror,id=nt351capture,netdev={NETDEV},queue=all,outdev=nt351mirror,vnet_hdr_support=off']


def checksum(data):
    if len(data)%2:data+=b'\0'
    value=sum(struct.unpack('!'+str(len(data)//2)+'H',data))
    while value>>16:value=(value&65535)+(value>>16)
    return (~value)&65535


def dhcp(frame):
    """Strict direct Ethernet/IPv4 DHCP for the pinned six-byte client MAC."""
    mac=bytes.fromhex(MAC.replace(':',''))
    if len(frame)<14+20+8+240 or frame[12:14]!=b'\x08\x00':return None
    ip=frame[14:];ihl=(ip[0]&15)*4
    if ip[0]>>4!=4 or ihl<20 or len(ip)<ihl+8 or ip[9]!=17:return None
    length=struct.unpack_from('!H',ip,2)[0]
    if not ihl+8<=length<=len(ip) or struct.unpack_from('!H',ip,6)[0]&0x3fff:return None
    if checksum(ip[:ihl]):return None
    udp=ip[ihl:length];src,dst,size,check=struct.unpack_from('!HHHH',udp)
    if size!=len(udp) or (src,dst) not in ((68,67),(67,68)):return None
    if check and checksum(ip[12:20]+bytes((0,17))+struct.pack('!H',size)+udp):return None
    data=udp[8:]
    if len(data)<240 or data[1:3]!=b'\x01\x06' or data[28:34]!=mac or data[236:240]!=b'\x63\x82\x53\x63':return None
    client=src==68
    if data[0]!=(1 if client else 2) or data[3] or data[24:28]!=b'\0'*4:return None
    if client and frame[6:12]!=mac:return None
    if not client and frame[:6] not in (mac,b'\xff'*6):return None
    opts={};i=240;ended=False
    while i<len(data):
        code=data[i];i+=1
        if code==0:continue
        if code==255:ended=True;break
        if i>=len(data):return None
        n=data[i];i+=1
        if i+n>len(data) or code in opts:return None
        opts[code]=data[i:i+n];i+=n
    if not ended or len(opts.get(53,b''))!=1 or 52 in opts:return None
    kind=opts[53][0]
    if kind not in ((1,3) if client else (2,5)):return None
    def address(option):
        value=opts.get(option)
        return str(ipaddress.IPv4Address(value)) if value is not None and len(value)==4 else None
    def addresses(option):
        value=opts.get(option,b'')
        if not value or len(value)%4:return []
        return [str(ipaddress.IPv4Address(value[n:n+4])) for n in range(0,len(value),4)]
    lease=opts.get(51,b'')
    return dict(kind=kind,xid=struct.unpack_from('!I',data,4)[0],
        yiaddr=str(ipaddress.IPv4Address(data[16:20])),server=address(54),requested=address(50),
        lease_seconds=struct.unpack('!I',lease)[0] if len(lease)==4 else 0,
        routers=addresses(3),dns=addresses(6))


def analyze_pcap(data,start_record=None):
    if len(data)>MAX_BYTES or data[:24]!=PCAP_HEADER:raise ValueError('Invalid bounded Ethernet PCAP')
    states={};proofs=[];offset=24;record=0
    while offset<len(data):
        if offset+16>len(data):raise ValueError('Truncated PCAP record header')
        _,micros,size,original=struct.unpack_from('<IIII',data,offset);offset+=16;record+=1
        if size!=original or size>MAX_FRAME or micros>=1000000 or offset+size>len(data):raise ValueError('Invalid PCAP record')
        frame=data[offset:offset+size];offset+=size
        if start_record is None or record<start_record:continue
        packet=dhcp(frame)
        if packet is None:continue
        xid=packet['xid'];kind=packet['kind'];state=states.get(xid)
        if kind==1:
            if state is None:
                if len(states)>=64:continue  # Bounded metadata as well as file bytes.
                states[xid]=dict(stage=1,records=[record])
        elif kind==2 and state and state['stage']==1 and packet['server'] and packet['yiaddr']!='0.0.0.0':
            state.update(stage=2,offer=packet,records=state['records']+[record])
        elif kind==3 and state and state['stage']==2:
            if packet['requested']==state['offer']['yiaddr'] and packet['server']==state['offer']['server']:
                state.update(stage=3,records=state['records']+[record])
        elif kind==5 and state and state['stage']==3:
            offer=state['offer']
            if packet['server']==offer['server'] and packet['yiaddr']==offer['yiaddr'] and packet['lease_seconds']>0:
                if len(proofs)<8:
                    proofs.append(dict(xid=f'{xid:08x}',mac=MAC,address=packet['yiaddr'],server=packet['server'],
                        lease_seconds=packet['lease_seconds'],routers=packet['routers'],dns=packet['dns'],
                        records=state['records']+[record]))
                state['stage']=4
    return dict(dora_observed=bool(proofs),exchanges=proofs,records=record,
        prepared_target_start_record=start_record,installed_runtime_pass=False,
        icmp_pass=False,dns_pass=False,
        scope='Pinned VM netdev exchange after requested prepared-target start; guest/OS attribution requires guest evidence')


class Capture:
    def __init__(self,path,max_bytes=MAX_BYTES):
        if type(max_bytes)!=int or not 24<=max_bytes<=MAX_BYTES:raise ValueError('Invalid hard capture byte cap')
        self.path=path;self.limit=max_bytes;self.file=None;self.server=None
        self.writer=None;self.task=None;self.accepted=False
        self.received=0;self.stored=0;self.bytes=24;self.discarded=0
        self.start_record=None;self.capped=False;self.error=None;self.finished=False
        self.connected=asyncio.Event()

    async def start(self):
        self.file=self.path.open('xb');self.file.write(PCAP_HEADER)
        try:self.server=await asyncio.start_server(self.accept,'127.0.0.1',0)
        except BaseException:self.file.close();raise
        return self.server.sockets[0].getsockname()[1]

    def mark_prepared_target(self):
        if self.start_record is not None:raise ValueError('Duplicate prepared-target boundary')
        self.start_record=self.stored+1

    async def accept(self,reader,writer):
        if self.accepted:
            writer.close();await writer.wait_closed();return
        self.accepted=True;self.writer=writer;self.task=asyncio.current_task()
        self.connected.set()
        self.server.close()  # Exactly the first local connection; no reconnect.
        try:
            while True:
                try:header=await reader.readexactly(4)
                except asyncio.IncompleteReadError as error:
                    if error.partial:raise ValueError('Truncated mirror length')
                    break
                size=struct.unpack('!I',header)[0]
                if not 14<=size<=MAX_FRAME:raise ValueError('Mirror frame length outside bound')
                frame=await reader.readexactly(size);self.received+=1
                if self.capped or self.bytes+16+size>self.limit:
                    self.capped=True;self.discarded+=1;continue
                stamp=time.time_ns();sec,nano=divmod(stamp,10**9)
                self.file.write(struct.pack('<IIII',sec,nano//1000,size,size)+frame)
                self.bytes+=16+size;self.stored+=1
        except (OSError,ValueError,asyncio.IncompleteReadError) as error:
            self.error=type(error).__name__+': '+str(error)
        finally:
            writer.close()
            try:await writer.wait_closed()
            except OSError:pass

    async def finish(self):
        """Called only after QEMU termination, never to observe VM progress."""
        if self.finished:raise ValueError('Capture already finished')
        self.finished=True
        self.server.close();await self.server.wait_closed()
        if self.task:
            try:await asyncio.wait_for(asyncio.shield(self.task),5)
            except asyncio.TimeoutError:
                self.error='Mirror did not close after QEMU exit'
                self.writer.close();self.task.cancel()
                await asyncio.gather(self.task,return_exceptions=True)
        self.file.close()
        data=self.path.read_bytes()
        result=dict(path=self.path.name,mac=MAC,netdev=NETDEV,hard_byte_cap=self.limit,
            stored_bytes=len(data),stored_frames=self.stored,received_frames=self.received,
            discarded_frames=self.discarded,capped=self.capped,connected=self.accepted,error=self.error,
            sha256=hashlib.sha256(data).hexdigest(),analysis=analyze_pcap(data,self.start_record))
        if self.error or not self.accepted:result['analysis']['dora_observed']=False
        encoded=json.dumps(result,indent=2)+'\n'
        if len(encoded.encode('utf-8'))>MAX_METADATA:raise ValueError('Capture metadata byte cap exceeded')
        self.path.with_suffix('.json').write_text(encoded,encoding='utf-8',newline='\n')
        return result
