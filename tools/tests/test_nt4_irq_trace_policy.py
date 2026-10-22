from pathlib import Path
import importlib.util,json,unittest
p=Path(__file__).parent/'coverage/nt4page_snapshot/installed03/irq08_trace.py';s=importlib.util.spec_from_file_location('own_nt4_irq08_trace_test',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class PassiveIRQ(unittest.TestCase):
 def fixture(self,irq=10):return [{'bus':0,'devices':[{'bus':0,'slot':3,'function':0,'irq':irq,'irq_pin':1,'id':{'vendor':0x8086,'device':0x10c9}}]}]
 def test_actual_irq_selection_and_ambiguous_or_missing_rejected(self):
  self.assertEqual(m.selected_pci_irq(self.fixture())['irq'],10)
  for value in (self.fixture()+self.fixture(),self.fixture(0),[]):
   with self.assertRaises(ValueError):m.selected_pci_irq(value)
 def test_no_irq11_assumption_and_no_pit_spam(self):
  f=m.Filter();self.assertIsNone(f.event('pic_interrupt irq 10 intno 58',1));f.select(self.fixture())
  self.assertIsNone(f.event('pic_interrupt irq 11 intno 59',2));self.assertIsNone(f.event('pic_set_irq master 1 irq 0 level 1',3))
  self.assertIsNotNone(f.event('pic_set_irq master 0 irq 2 level 1',4));self.assertIsNotNone(f.event('pic_interrupt irq 10 intno 58',5))
  with self.assertRaises(ValueError):f.select(self.fixture())
 def test_actual_trace_shapes_need_full_post_logon_chain(self):
  lines=['OWN_ACTUAL_FIRST_LOGON_BOUNDARY','e1000e_irq_set Setting interrupt register 0xd0: 0x0 --> 0xdc','e1000e_irq_legacy_notify IRQ line state: 1','pic_interrupt irq 10 intno 58','e1000e_irq_icr_clear_nonmsix_icr_read Clearing ICR bits on read']
  records=[{'monotonic_ns':i,'line':v} for i,v in enumerate(lines)]
  self.assertTrue(m.assess(records,10)['irq_delivery_observed'])
  self.assertFalse(m.assess(records,11)['irq_delivery_observed']);self.assertFalse(m.assess(records[:-1],10)['irq_delivery_observed']);self.assertFalse(m.assess(records,10,1)['irq_delivery_observed'])
 def test_line_and_total_caps_count_drop(self):
  f=m.Filter();self.assertIsNone(f.event('x'*2049,1));self.assertEqual(f.dropped,1)
  f.bytes=m.MAX_BYTES;self.assertIsNone(f.event('e1000e_irq_legacy_notify IRQ line state: 1',2));self.assertEqual(f.dropped,2)
if __name__=='__main__':unittest.main()
