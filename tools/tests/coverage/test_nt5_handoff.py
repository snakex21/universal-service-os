"""The prepared NT5 target starts only after the guest's real power-off."""
from pathlib import Path
import asyncio
import importlib.util
import unittest

spec=importlib.util.spec_from_file_location('boot_menu',Path(__file__).with_name('boot_menu.py'))
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)


class FakeQmp:
    def __init__(self,guest=True):self.calls=[];self.guest=guest
    async def delete_device(self,name):self.calls.append(('delete',name))
    async def command(self,name,args=None):self.calls.append((name,args))
    def expect_event(self,name):
        self.calls.append(('subscribe',name));self.future=asyncio.get_running_loop().create_future()
        return self.future
    async def key(self,name):
        self.calls.append(('key',name))
        # Firmware can finish power-off before the key command returns.
        self.future.set_result({'event':'SHUTDOWN','data':{'guest':self.guest}})
    def forget_event(self,name,future):self.calls.append(('unsubscribe',name))


class HandoffTests(unittest.IsolatedAsyncioTestCase):
    async def test_safe_unplug_shutdown_then_start_with_boot_stick(self):
        qmp=FakeQmp();await menu.start_nt5_target(qmp,True)
        self.assertEqual([c[0] for c in qmp.calls],
            ['delete','device_add','subscribe','key','system_reset','cont','unsubscribe'])
        self.assertEqual(qmp.calls[0],('delete','coverage-install-stick'))
        self.assertEqual(qmp.calls[1][1]['id'],'usability-boot')

    async def test_no_test_stick_and_no_false_key_acceptance(self):
        qmp=FakeQmp();await menu.start_nt5_target(qmp,False)
        self.assertNotIn('device_add',[c[0] for c in qmp.calls])
        self.assertFalse(menu.capture_permitted(True,False,True))

    async def test_host_shutdown_does_not_start_target(self):
        qmp=FakeQmp(False)
        with self.assertRaisesRegex(RuntimeError,'guest power-off'):
            await menu.start_nt5_target(qmp,False)
        self.assertNotIn('system_reset',[c[0] for c in qmp.calls])
        self.assertEqual(qmp.calls[-1],('unsubscribe','SHUTDOWN'))


if __name__=='__main__':unittest.main()
