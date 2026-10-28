"""Transport instrumentation contract, no VM or Windows pixels."""
from pathlib import Path
import importlib.util,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('audit',ROOT/'tools/tests/coverage/usb_input_audit.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Fake:
    def __init__(self):self.calls=[];self.reject=False
    async def command(self,name,args=None):
        self.calls.append((name,args))
        if self.reject:raise RuntimeError('trace rejected')
    async def delete_device(self,device):self.calls.append(('deleted_after_event',device))

class Contract(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        parent=ROOT/'zig-out/usb-audit-tests';parent.mkdir(parents=True,exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=parent);self.addCleanup(self.temp.cleanup)
        self.out=Path(self.temp.name);self.fake=Fake()
        self.audit=m.UsbInputAudit(self.fake,self.out,post_key_boundary=True,positive_control=True)
    async def test_trace_enabled_before_real_removal_and_only_once(self):
        await self.audit.delete_device('coveragekbd');await self.audit.delete_device('coveragepointer')
        self.assertEqual([call[0] for call in self.fake.calls],['trace-event-set-state']*3+['deleted_after_event']*2)
        self.assertEqual([call[1]['name'] for call in self.fake.calls[:3]],list(m.PS2_EVENTS))
    async def test_replug_evidence_is_distinct_and_caller_descriptor_unchanged(self):
        await self.audit.delete_device('coveragekbd')
        descriptor={'driver':'usb-kbd','id':'coveragekbd','bus':'xhci.0'}
        await self.audit.command('device_add',descriptor)
        first=self.fake.calls[-1][1]['pcap']
        await self.audit.delete_device('coveragekbd');await self.audit.command('device_add',descriptor)
        second=self.fake.calls[-1][1]['pcap']
        self.assertNotEqual(first,second);self.assertNotIn('pcap',descriptor)
        self.assertEqual(Path(first).parent,self.out.resolve())
    async def test_unrelated_hotplug_does_not_start_input_audit(self):
        await self.audit.delete_device('usability-hot')
        self.assertFalse(self.audit.started);self.assertEqual(len(self.fake.calls),1)
    async def test_refused_trace_prevents_removal(self):
        self.fake.reject=True
        with self.assertRaises(RuntimeError):await self.audit.delete_device('coveragekbd')
        self.assertFalse(self.audit.started);self.assertEqual(len(self.fake.calls),1)
    async def test_no_reinsert_before_audited_removal(self):
        with self.assertRaises(ValueError):await self.audit.command('device_add',{'id':'coveragekbd'})
        self.assertEqual(self.fake.calls,[])
    async def test_no_overwrite_of_existing_capture(self):
        await self.audit.delete_device('coveragekbd')
        (self.out/'keyboard-after-replug-01.pcap').write_bytes(b'own existing evidence')
        with self.assertRaises(FileExistsError):await self.audit.command('device_add',{'id':'coveragekbd'})
    async def test_missing_proofs_rejected(self):
        for key in ('post_key_boundary','positive_control'):
            args={'post_key_boundary':True,'positive_control':True};args[key]=False
            with self.assertRaises(ValueError):m.UsbInputAudit(self.fake,self.out,**args)

if __name__=='__main__':unittest.main()
