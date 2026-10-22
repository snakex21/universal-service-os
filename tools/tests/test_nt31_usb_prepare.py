"""Stopped writer, own driver and PS/2 exclusion gates for unchanged COW."""
from pathlib import Path
import copy,importlib.util,unittest
s=importlib.util.spec_from_file_location('usb_prep',Path(__file__).with_name('prepare_nt31_usb_fullmac.py'))
p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
class Gates(unittest.TestCase):
    def setUp(self):
        self.args=[dict(stopped=True),dict(qemu_returncode=0),dict(private_profile=False,folder='Windows NT 3.1'),
            dict(target_sha256=p.BASE_SHA,target_unchanged=True,files={'USNET31.SYS':{'sha256':p.DRIVER_SHA},'USOSUSB.SYS':{'sha256':p.USB_SHA}},
                 services={'i8042prt':{'start':4},'usosusb':{'start':0}})]
    def test_completed_exact_base(self):p.validate(*self.args)
    def test_active_or_private_refused(self):
        for i,key,value in [(0,'stopped',False),(1,'qemu_returncode',None),(2,'private_profile',True)]:
            args=copy.deepcopy(self.args);args[i][key]=value
            with self.assertRaises(ValueError):p.validate(*args)
    def test_changed_driver_or_ps2_refused(self):
        for group,name,key,value in [('files','USNET31.SYS','sha256','wrong'),('services','i8042prt','start',1)]:
            args=copy.deepcopy(self.args);args[3][group][name][key]=value
            with self.assertRaises(ValueError):p.validate(*args)
if __name__=='__main__':unittest.main()
