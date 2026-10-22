"""NT4-only DHCP mirror policy: discard until the actual first-logon token.

Only the pinned owned virtual igb is mirrored. Before logon and all non-DHCP
frames are drained without storage. No host interface or Setup log is read.
"""
from pathlib import Path
import asyncio
import importlib.util
import json
import struct
import time

spec=importlib.util.spec_from_file_location('nt4_dhcp_base',Path(__file__).with_name('nt351_capture.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
MAC=base.MAC
NETDEV=base.NETDEV
MAX_BYTES=base.MAX_BYTES
MAX_FRAME=base.MAX_FRAME
PCAP_HEADER=base.PCAP_HEADER
POLICY='NT4_DHCP_ONLY_AFTER_ACTUAL_FIRST_LOGON'


def arguments(port):
    if type(port)!=int or not 1<=port<=65535:raise ValueError('Invalid local NT4 mirror port')
    return ['-chardev',f'socket,id=nt4mirror,host=127.0.0.1,port={port},server=off',
        '-object',f'filter-mirror,id=nt4capture,netdev={NETDEV},queue=all,outdev=nt4mirror,vnet_hdr_support=off']


class Capture(base.Capture):
    def __init__(self,path,max_bytes=MAX_BYTES):
        super().__init__(path,max_bytes)
        self.first_logon_observed=False;self.before_logon_frames=0;self.non_dhcp_frames=0

    def mark_prepared_target(self):
        raise ValueError('NT4 DHCP policy requires actual first logon, not preparation')

    def mark_first_logon(self):
        if self.first_logon_observed or self.stored:raise ValueError('Duplicate or late NT4 first-logon boundary')
        self.first_logon_observed=True;self.start_record=1

    async def accept(self,reader,writer):
        if self.accepted:
            writer.close();await writer.wait_closed();return
        self.accepted=True;self.writer=writer;self.task=asyncio.current_task()
        self.connected.set();self.server.close()
        try:
            while True:
                try:header=await reader.readexactly(4)
                except OSError as error:
                    if not base.boundary_reset(error,reader):raise
                    self.boundary_disconnect=dict(type=type(error).__name__,errno=error.errno,
                        winerror=getattr(error,'winerror',None),during_controlled_shutdown=self.shutdown_requested)
                    break
                except asyncio.IncompleteReadError as error:
                    if error.partial:raise ValueError('Truncated NT4 mirror length')
                    break
                size=struct.unpack('!I',header)[0]
                if not 14<=size<=MAX_FRAME:raise ValueError('NT4 mirror frame length outside bound')
                frame=await reader.readexactly(size);self.received+=1
                if not self.first_logon_observed:self.before_logon_frames+=1;continue
                if base.dhcp(frame) is None:self.non_dhcp_frames+=1;continue
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

    async def finish(self,controlled_shutdown=False):
        result=await super().finish(controlled_shutdown=controlled_shutdown)
        result.update(policy=POLICY,first_logon_observed=self.first_logon_observed,
            before_logon_frames=self.before_logon_frames,non_dhcp_frames=self.non_dhcp_frames)
        analysis=result['analysis'];analysis.pop('prepared_target_start_record',None)
        analysis.update(first_logon_observed=self.first_logon_observed,
            scope='Only pinned-MAC DHCP frames received after the actual NT4 first-logon token; separate own guest evidence required')
        if not self.first_logon_observed:analysis['dora_observed']=False
        encoded=json.dumps(result,indent=2)+'\n'
        if len(encoded.encode('utf-8'))>base.MAX_METADATA:raise ValueError('NT4 capture metadata bound')
        self.path.with_suffix('.json').write_text(encoded,encoding='utf-8',newline='\n')
        return result
