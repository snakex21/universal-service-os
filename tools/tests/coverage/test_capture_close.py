"""Real localhost FIN/RST at frame boundaries; partial frames always fail closed."""
from pathlib import Path
import asyncio
import importlib.util
import os
import socket
import struct
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
def load(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
base=load('nt351_capture');nt4=load('nt4_capture');fixtures=load('test_nt4_success')
TMP=ROOT/'artifacts/coverage/capture-close-host';TMP.mkdir(parents=True,exist_ok=True)


class CaptureClose(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):self.temp=tempfile.TemporaryDirectory(dir=TMP);self.directory=Path(self.temp.name);self.count=0
    async def asyncTearDown(self):self.temp.cleanup()
    async def connection(self,cls,raw=False):
        self.count+=1;capture=cls(self.directory/(str(self.count)+'.pcap'));port=await capture.start()
        if raw:
            writer=socket.socket(socket.AF_INET,socket.SOCK_STREAM);writer.settimeout(2);writer.connect(('127.0.0.1',port))
        else:reader,writer=await asyncio.open_connection('127.0.0.1',port)
        await capture.connected.wait()
        if cls is nt4.Capture:capture.mark_first_logon()
        else:capture.mark_prepared_target()
        return capture,writer
    async def send_dora(self,writer):
        frames=[fixtures.packet(n) for n in (1,2,3,5)]
        wire=b''.join(struct.pack('!I',len(f))+f for f in frames)
        if isinstance(writer,socket.socket):writer.sendall(wire)
        else:writer.write(wire);await writer.drain()
        await asyncio.sleep(.05)  # One concrete localhost write delivery, no VM/progress polling.
    def reset(self,writer):
        linger=struct.pack('HH' if os.name=='nt' else 'ii',1,0)
        # A raw socket avoids asyncio.abort() calling shutdown() first, which
        # turns this into FIN on Windows despite SO_LINGER(1,0).
        writer.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,linger)
        writer.close()
    async def test_normal_fin_after_complete_frames_is_clean_for_both_policies(self):
        for cls in (base.Capture,nt4.Capture):
            capture,writer=await self.connection(cls);await self.send_dora(writer)
            writer.close();await writer.wait_closed();result=await capture.finish()
            self.assertIsNone(result['error']);self.assertTrue(result['analysis']['dora_observed'])
            self.assertFalse(result['controlled_boundary_reset_accepted'])
    async def test_real_controlled_rst_between_frames_preserves_complete_dora(self):
        for cls in (base.Capture,nt4.Capture):
            capture,writer=await self.connection(cls,raw=True);await self.send_dora(writer)
            capture.begin_controlled_shutdown();self.reset(writer)
            result=await capture.finish(controlled_shutdown=True)
            self.assertIsNone(result['error']);self.assertTrue(result['analysis']['dora_observed'])
            self.assertTrue(result['controlled_boundary_reset_accepted']);self.assertTrue(result['boundary_disconnect']['during_controlled_shutdown'])
    async def test_reset_before_shutdown_cannot_be_blessed_retroactively(self):
        capture,writer=await self.connection(nt4.Capture,raw=True);await self.send_dora(writer);self.reset(writer)
        await asyncio.wait_for(asyncio.shield(capture.task),2)
        capture.begin_controlled_shutdown();result=await capture.finish(controlled_shutdown=True)
        self.assertIsNotNone(result['error']);self.assertFalse(result['analysis']['dora_observed'])
        self.assertFalse(result['controlled_boundary_reset_accepted']);self.assertFalse(result['boundary_disconnect']['during_controlled_shutdown'])
    async def test_partial_header_or_payload_is_fatal_even_under_controlled_close(self):
        for cls in (base.Capture,nt4.Capture):
            for partial in (b'\0\0',struct.pack('!I',100)+b'partial body'):
                for rst in (False,True):
                    capture,writer=await self.connection(cls,raw=rst);await self.send_dora(writer)
                    if rst:writer.sendall(partial)
                    else:writer.write(partial);await writer.drain()
                    await asyncio.sleep(.05);capture.begin_controlled_shutdown()
                    if rst:self.reset(writer)
                    else:writer.close();await writer.wait_closed()
                    result=await capture.finish(controlled_shutdown=True)
                    self.assertIsNotNone(result['error']);self.assertFalse(result['analysis']['dora_observed'])
                    self.assertFalse(result['controlled_boundary_reset_accepted'])
    async def test_winerror64_requires_empty_concrete_streamreader_buffer(self):
        empty=asyncio.StreamReader();partial=asyncio.StreamReader();partial.feed_data(b'\0\0')
        error=OSError(64,'The specified network name is no longer available')
        self.assertTrue(base.boundary_reset(error,empty));self.assertFalse(base.boundary_reset(error,partial))
        self.assertFalse(base.boundary_reset(OSError(13,'denied'),empty));self.assertFalse(base.boundary_reset(error,object()))
    def test_runner_marks_before_quit_and_checks_success_after_process_exit(self):
        code=(HERE/'boot_menu.py').read_text(encoding='utf-8')
        self.assertLess(code.index('network_capture.begin_controlled_shutdown()'),code.index("await asyncio.wait_for(qmp.command('quit'),3)"))
        self.assertIn("controlled_shutdown=shutdown_method=='QMP quit' and process.returncode==0",code)


if __name__=='__main__':unittest.main()
