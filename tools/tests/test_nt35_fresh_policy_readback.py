import importlib.util,struct,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('fresh_policy',Path(__file__).with_name('readback_nt35_irq_fresh.py'))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
def d(v):return (4,struct.pack('<I',v))
class BoundedPolicy(unittest.TestCase):
    def test_only_selected_allowlisted_start_and_type_leave_reader(self):
        values={'select':{'current':d(1),'default':d(1)},'private':{'secret':(1,b'not exported')}}
        for name in b.NAMES:values['controlset001\\services\\'+name.lower()]={'start':d(2),'type':d(16),'private':(1,b'not exported')}
        out=b.policy_values(values)
        self.assertEqual(out['selected'],{'current':1,'default':1})
        self.assertEqual(set(out['services']['1']),set(b.NAMES))
        for row in out['services']['1'].values():self.assertEqual(row,{'present':True,'start':2,'type':16})
    def test_absent_services_remain_explicitly_absent(self):
        out=b.policy_values({'select':{'current':d(1),'default':d(2)}})
        self.assertEqual(set(out['services']),{'1','2'})
        self.assertTrue(all(row=={'present':False} for nodes in out['services'].values() for row in nodes.values()))
    def test_invalid_type_or_controlset_fails_closed(self):
        for item in ((1,b'bad'),d(0),d(1000)):
            with self.subTest(item=item),self.assertRaises(ValueError):b.policy_values({'select':{'current':item,'default':d(1)}})

if __name__=='__main__':unittest.main()
