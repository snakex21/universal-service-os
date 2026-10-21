from pathlib import Path
import asyncio
import importlib.util
import io
import unittest

spec=importlib.util.spec_from_file_location('hid_events',Path(__file__).with_name('run_hid_events.py'))
hid=importlib.util.module_from_spec(spec);spec.loader.exec_module(hid)


class HidEventTests(unittest.IsolatedAsyncioTestCase):
    async def test_serial_notification_and_old_record_boundary(self):
        events=hid.SerialEvents();reader=asyncio.StreamReader();log=io.BytesIO()
        consume=asyncio.create_task(events.consume(reader,log))
        reader.feed_data(b'KBD 0000001E d\n')
        self.assertEqual(await events.wait(r'^KBD .* d$'),'KBD 0000001E d')
        boundary=len(events.lines)
        waiting=asyncio.create_task(events.wait(r'^KBD .* d$',after=boundary))
        await asyncio.sleep(0)
        self.assertFalse(waiting.done(),'Cached input from before reconnect cannot satisfy a new action')
        reader.feed_data(b'KBD 00000030 d\n')
        self.assertEqual(await waiting,'KBD 00000030 d')
        reader.feed_eof();await consume

    async def test_closed_serial_does_not_wait_forever(self):
        events=hid.SerialEvents();reader=asyncio.StreamReader();reader.feed_eof()
        await events.consume(reader,io.BytesIO())
        with self.assertRaises(ConnectionError):await events.wait('absent')

    def test_mouse_requires_motion_and_both_button_edges(self):
        self.assertFalse(hid.mouse_verified(['MOU 0 0 00000001','MOU 0 0 00000002']))
        self.assertFalse(hid.mouse_verified(['MOU 17 9 00000001']))
        self.assertTrue(hid.mouse_verified(['MOU 17 9 00000000','MOU 0 0 00000001','MOU 0 0 00000002']))


if __name__=='__main__':unittest.main()
