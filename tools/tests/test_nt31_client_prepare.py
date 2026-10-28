"""Cold verification cannot start with the old active-server policy metadata."""
from pathlib import Path
import copy,importlib.util,unittest
s=importlib.util.spec_from_file_location('clientprep',Path(__file__).with_name('prepare_nt31_client.py'))
p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
class PolicyGate(unittest.TestCase):
    def setUp(self):
        self.rb=dict(files={'USNET31.SYS':{'sha256':p.DRIVER},'USOSUSB.SYS':{'sha256':p.USB}},
            services={'i8042prt':{'start':4}},policy_services={'lanmanserver':{'start':4},'browser':{'start':4}})
    def test_exact_completed_policy(self):p.policy_gate(self.rb,True)
    def test_old_server_policy_cannot_be_verification(self):
        self.rb['policy_services']['lanmanserver']['start']=2
        p.policy_gate(self.rb,False)
        with self.assertRaises(ValueError):p.policy_gate(self.rb,True)
    def test_ps2_or_frozen_driver_change_refused(self):
        bad=copy.deepcopy(self.rb);bad['services']['i8042prt']['start']=1
        with self.assertRaises(ValueError):p.policy_gate(bad,False)
        bad=copy.deepcopy(self.rb);bad['files']['USNET31.SYS']['sha256']='wrong'
        with self.assertRaises(ValueError):p.policy_gate(bad,False)
if __name__=='__main__':unittest.main()
