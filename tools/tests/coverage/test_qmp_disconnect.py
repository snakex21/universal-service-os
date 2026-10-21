"""A closed emulator transport must not leave a pending QMP request."""
from pathlib import Path
import asyncio
import importlib.util
import json
import unittest

spec=importlib.util.spec_from_file_location('menu',Path(__file__).with_name('boot_menu.py'))
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)


class ClosedWriter:
    def write(self,data):raise ConnectionResetError('synthetic closed transport')


class DisconnectTests(unittest.IsolatedAsyncioTestCase):
    async def test_device_deleted_event_can_precede_command_reply(self):
        reader=asyncio.StreamReader();reader.feed_data(b'{"QMP":{}}\n')
        class Writer:
            def write(self,data):
                request=json.loads(data)
                event={'event':'DEVICE_DELETED','data':{'device':request['arguments']['id']}}
                reader.feed_data((json.dumps(event)+'\n'+json.dumps({'return':{},'id':request['id']})+'\n').encode())
            async def drain(self):pass
        qmp=menu.Qmp();consumer=asyncio.create_task(qmp.accept(reader,Writer()))
        try:
            await qmp.delete_device('owned-test-stick')
            self.assertEqual(qmp.deleted,{})
            self.assertEqual(qmp.pending,{})
        finally:
            reader.feed_eof();await consumer

    async def test_write_failure_cleans_pending_request(self):
        qmp=menu.Qmp();qmp.connected.set();qmp.writer=ClosedWriter()
        with self.assertRaises(ConnectionResetError):await qmp.command('quit')
        self.assertEqual(qmp.pending,{})


if __name__=='__main__':unittest.main()
