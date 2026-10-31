#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pre-write, EOF, error-race and whole-operation firstboot regressions."""
import asyncio
import json
from pathlib import Path
import struct
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from unittest.mock import AsyncMock

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import firstboot_bounds as b
import firstboot_output as o
import firstboot_qmp as q


class Limits(unittest.TestCase):
    def setUp(self):
        root=Path(__file__).resolve().parents[2]/'runtime';root.mkdir(exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=root);self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)

    def test_disjoint_scope_covers_container_and_every_auxiliary(self):
        self.assertEqual(o.LIMITS['windows.qcow2'],b.CONTAINER_BYTES)
        self.assertLessEqual(sum(o.LIMITS.values())+o.PANTHER_LIMIT,b.SCOPE_BYTES)
        self.assertEqual(b.CONTAINER_BYTES+b.AUXILIARY_RESERVATION,b.SCOPE_BYTES)
        for name,limit in o.LIMITS.items():
            if name=='windows.qcow2':continue
            # Same pre-write boundary for all sinks, including headers/error JSON.
            with self.subTest(name=name),o.Sink(self.root/(name+'.tiny'),3) as sink:
                sink.write(b'123')
                with self.assertRaises(ValueError):sink.write(b'4')
                self.assertEqual(sink.written,3)

    def test_no_unexpected_or_oversized_retained_files(self):
        scope=o.Scope(self.root);scope.save('failure.json',{'reason':'fixture'})
        self.assertGreater(scope.audit(),0)
        (self.root/'escape.log').write_bytes(b'x')
        with self.assertRaises(ValueError):scope.audit()

    def test_envelope_rejects_external_data_or_bad_geometry(self):
        h=bytearray(104);h[:4]=b'QFI\xfb'
        struct.pack_into('>I',h,4,3);struct.pack_into('>I',h,20,16)
        struct.pack_into('>Q',h,24,32*1024**3)
        self.assertEqual(b.header_limits(h,196608,b.CONTAINER_BYTES,32*1024**3),65536)
        for offset,value in [(72,4),(24,99)]:
            bad=bytearray(h);struct.pack_into('>Q',bad,offset,value)
            with self.assertRaises(ValueError):b.header_limits(bad,196608,b.CONTAINER_BYTES,32*1024**3)

    def test_graph_forces_every_write_through_fixed_raw(self):
        graph=[json.loads(x) for x in b.blockdev_arguments('fixture.qcow2')[1::2]]
        self.assertEqual(graph[1]['size'],b.CONTAINER_BYTES)
        self.assertEqual(graph[2]['file'],graph[1]['node-name'])
        self.assertEqual(graph[1]['file'],graph[0]['node-name'])

    def test_windows_reset_is_only_clean_after_own_ack_exit_zero_and_host_quit(self):
        client=SimpleNamespace(failure='reset',failure_code=64,
            events=[dict(event='SHUTDOWN',data=dict(reason='host-qmp-quit'))])
        self.assertTrue(q.clean_quit_close(client,True,0))
        self.assertFalse(q.clean_quit_close(client,False,0))
        self.assertFalse(q.clean_quit_close(client,True,1))
        client.events=[];self.assertFalse(q.clean_quit_close(client,True,0))
        client.events=[dict(event='SHUTDOWN',data=dict(reason='host-qmp-quit'))]
        client.failure_code=None;self.assertFalse(q.clean_quit_close(client,True,0))


class EventTests(unittest.IsolatedAsyncioTestCase):
    async def test_display_wake_is_one_modifier_release_pair_without_progress_queries(self):
        client=SimpleNamespace(command=AsyncMock())
        with patch.object(q.asyncio,'sleep',new=AsyncMock()) as pause:
            await q.wake_display(client)
        client.command.assert_awaited_once_with('input-send-event',events=[
            dict(type='key',data=dict(down=True,key=dict(type='qcode',data='shift'))),
            dict(type='key',data=dict(down=False,key=dict(type='qcode',data='shift')))])
        pause.assert_awaited_once_with(2)

    async def test_eof_bad_json_and_all_io_errors_wake_without_deadline(self):
        for payload in (b'',b'bad\n',b'{"event":"BLOCK_IO_ERROR","data":{"action":"stop","nospace":false}}\n',
                        b'{"event":"SHUTDOWN"}\n{"event":"BLOCK_IO_ERROR"}\n'):
            reader=asyncio.StreamReader()
            class Writer:
                def close(self):pass
                async def wait_closed(self):pass
            client=q.Qmp(reader,Writer());client.pump=asyncio.create_task(client.receive())
            reader.feed_data(payload);reader.feed_eof()
            result=await asyncio.wait_for(client.closed,1)
            self.assertIn(result['reason'],('eof','error'))
            if b'BLOCK_IO_ERROR' in payload:self.assertTrue(client.io_error.done())
            await client.close()

    async def test_flood_drains_both_streams_and_refuses_before_write(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'runtime') as temp:
            root=Path(temp);scope=o.Scope(root)
            code='import os,threading; t=threading.Thread(target=lambda:os.write(2,b"e"*1048576));t.start();os.write(1,b"o"*1048576);t.join()'
            with patch.dict(o.LIMITS,{'qemu.stdout':128,'qemu.stderr':128}):
                with self.assertRaises(ValueError):
                    await asyncio.wait_for(o.execute([sys.executable,'-c',code],scope,'qemu.stdout','qemu.stderr',None),5)
            self.assertLessEqual((root/'qemu.stdout').stat().st_size,128)
            self.assertLessEqual((root/'qemu.stderr').stat().st_size,128)

    async def test_10800_endpoint_validation_and_immediate_qmp_eof(self):
        # The fake QEMU remains alive after dropping QMP. An EOF must kill it,
        # not sleep for the requested three hours.
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'runtime') as temp:
            peers=[];tasks=[]
            class Process:
                def __init__(self):
                    self.done=asyncio.get_running_loop().create_future()
                    self.stdout=asyncio.StreamReader();self.stderr=asyncio.StreamReader();self.killed=False
                async def wait(self):return await self.done
                def kill(self):
                    self.killed=True
                    if not self.done.done():self.done.set_result(-9)
                    self.stdout.feed_eof();self.stderr.feed_eof()
            process=Process()
            async def peer(port):
                reader,writer=await asyncio.open_connection('127.0.0.1',port);peers.append(writer)
                writer.write(b'{"QMP":{}}\n');await writer.drain()
                request=json.loads(await reader.readline())
                writer.write(json.dumps({'id':request['id'],'return':{}}).encode()+b'\n');await writer.drain()
                writer.close();await writer.wait_closed()
            async def create(*command,**kwargs):
                port=int(command[command.index('-qmp')+1].rsplit(':',1)[1])
                tasks.append(asyncio.create_task(peer(port)));return process
            start=time.monotonic()
            with patch.object(q.asyncio,'create_subprocess_exec',side_effect=create):
                result=await asyncio.wait_for(q.endpoint(['fixture'],Path(temp),{},10800),3)
            await asyncio.gather(*tasks)
            self.assertLess(time.monotonic()-start,3);self.assertTrue(process.killed)
            self.assertIn('QMP closed',result['transport_error']);self.assertFalse(result['windows_gate_passed'])


if __name__=='__main__':unittest.main()
