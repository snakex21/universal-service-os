import copy
import unittest

from readback_nt35_client_auto import native_policy, policy_pass


class EvidenceGuards(unittest.TestCase):
    def policy(self):
        rows={name:dict(present=True,start=start,type=kind) for name,start,kind in (
            ('Browser',4,32),('LanmanServer',4,32),('LanmanWorkstation',2,32),('Tcpip',3,1))}
        return dict(selected=dict(current=1,default=2),services={'1':rows,'2':copy.deepcopy(rows)})

    def test_both_selected_control_sets_required(self):
        policy=self.policy();self.assertTrue(policy_pass(policy))
        policy['services']['2']['LanmanServer']['start']=2
        self.assertFalse(policy_pass(policy))

    def test_optional_browser_and_required_server(self):
        policy=self.policy();policy['services']['1']['Browser']=dict(present=False)
        self.assertTrue(policy_pass(policy))
        policy['services']['1']['LanmanServer']=dict(present=False)
        self.assertFalse(policy_pass(policy))

    def test_workstation_and_tcpip_config_never_inferred(self):
        for name,field,value in (('LanmanWorkstation','start',4),('Tcpip','type',32),('Tcpip','start',0)):
            policy=self.policy();policy['services']['1'][name][field]=value
            self.assertFalse(policy_pass(policy))

    def test_native_enumeration_is_independent_of_registry(self):
        base='These Windows NT services are started:\r\n\r\n   EventLog\r\n   Workstation\r\n%sThe command completed successfully.\r\n'
        self.assertTrue(native_policy(base % '')['no_sharing_running_state'])
        for running in ('   Server\r\n','   Computer Browser\r\n'):
            self.assertFalse(native_policy(base % running)['no_sharing_running_state'])

    def test_incomplete_or_duplicate_native_enumeration_refused(self):
        native='These Windows NT services are started:\n   Workstation\nThe command completed successfully.\n'
        for bad in ('',native+native,native.replace('The command completed successfully.','failed')):
            with self.assertRaises(ValueError):native_policy(bad)


if __name__=='__main__':unittest.main()
