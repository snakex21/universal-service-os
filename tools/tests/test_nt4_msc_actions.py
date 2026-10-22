"""Exercise one-shot serial completion ordering and pre-action input refusal."""
from pathlib import Path
import asyncio,importlib.util,io,json,unittest
s=importlib.util.spec_from_file_location('nt4_msc_actions',Path(__file__).with_name('coverage')/'boot_nt4_msc.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Actions(unittest.TestCase):
 def test_refuses_transport_truncation_and_wrong_device(self):
  for a in ({'usb':'format'},{'usb':'insert','expect_msc':'HOT','keys':['ret']},{'keys':['ret;quit']},{'hid':{'device':'keyboard','state':'remove'}},{'finish':True,'usb':'remove'}):
   with self.assertRaises(ValueError):m.parse_action(json.dumps(a))
  line=json.dumps({'keys':['ret']});self.assertEqual(m.parse_action(line+' '*(450-len(line)))['keys'],['ret'])
  with self.assertRaises(ValueError):m.parse_action(line+' '*(451-len(line)))
 def test_actual_stage_future_cannot_consume_stale_token(self):
  async def exercise():
   c=m.Completions()
   with self.assertRaises(RuntimeError):c.line(b'USOS_MSC4_DONE=HOT:0\r')
   future=c.arm('HOT');c.line(b'Unrelated line');self.assertFalse(future.done())
   c.line(b'USOS_MSC4_DONE=HOT:3\r');self.assertEqual(await future,3)
   with self.assertRaises(ValueError):c.arm('HOT')
   with self.assertRaises(RuntimeError):c.line(b'USOS_MSC4_DONE=HOT:0\r')
  asyncio.run(exercise())
 def test_firmware_prefix_then_framed_native_completion(self):
  async def exercise():
   c=m.Completions();future=c.arm('STARTUP');reader=asyncio.StreamReader()
   # Actual completed03 prefix had no newline before the helper wrote.
   reader.feed_data(b'DSsDSsDSsDSs\r\nUSOS_MSC4_DONE=STARTUP:0\r\n');reader.feed_eof()
   process=type('Process',(),{'stdout':reader})();serial=io.BytesIO()
   await m.consume(process,serial,c);self.assertEqual(await future,0)
   self.assertTrue(serial.getvalue().startswith(b'DSsDSs'))
  asyncio.run(exercise())
if __name__=='__main__':unittest.main()
