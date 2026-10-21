"""A closed emulator transport must not leave a pending QMP request."""
from pathlib import Path
import asyncio
import importlib.util
import unittest

spec=importlib.util.spec_from_file_location('menu',Path(__file__).with_name('boot_menu.py'))
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)


class ClosedWriter:
    def write(self,data):raise ConnectionResetError('synthetic closed transport')


class DisconnectTests(unittest.IsolatedAsyncioTestCase):
    async def test_write_failure_cleans_pending_request(self):
        qmp=menu.Qmp();qmp.connected.set();qmp.writer=ClosedWriter()
        with self.assertRaises(ConnectionResetError):await qmp.command('quit')
        self.assertEqual(qmp.pending,{})


if __name__=='__main__':unittest.main()
