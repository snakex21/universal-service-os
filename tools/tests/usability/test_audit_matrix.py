"""Evidence boundaries in the per-image USB/LAN audit."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('audit',Path(__file__).with_name('audit_matrix.py'))
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)


def row(path,route,arch='x86'):
    return [path,'unknown',arch,route,'QEMU PASS','desktop','reviewed','X470 PASS']


class EvidenceTests(unittest.TestCase):
    def test_desktop_does_not_imply_usb_or_network(self):
        usb,net=audit.capability(row('Windows XP\\XP SP3.iso','windows-xp'))
        self.assertIn('brak potwierdzenia MSC',usb)
        self.assertNotIn('QEMU PASS',net)

    def test_nt4_unmerged_build_is_not_runtime_pass(self):
        usb,net=audit.capability(row('Windows NT 4.0\\Workstation PL.iso','windows-nt-4'))
        self.assertIn('feat/nt4-usb-sticks',usb)
        self.assertIn('oczekują',usb)
        self.assertNotIn('PASS',usb+net)

    def test_9x_family_pass_is_not_transferred_to_other_source(self):
        usb,net=audit.capability(row('Windows 98\\Windows 98 SE EN Upgrade.iso','windows-98-se'))
        self.assertTrue(usb.startswith('brak osobnego testu'))
        self.assertIn('nie zmierzono',net)

    def test_hid_reconnection_is_a_separate_measurement(self):
        self.assertTrue(audit.hid_test('X470 PASS pendrive').startswith('brak pomiaru'))
        self.assertEqual(audit.hid_test('nie dotyczy: update'),'nie dotyczy')

    def test_upstream_win7_hid_evidence_is_only_a_family_binding(self):
        pl=row('Windows 7\\SP1 PL x86.iso','windows-7','pl-PL / x86');pl[1]='6.1.7601 / SP1'
        self.assertIn('X470 PASS rodziny',audit.hid_test('USB',pl))
        self.assertIn('brak powiązania z hashem',audit.hid_test('USB',pl))
        en=list(pl);en[2]='en-US / x86'
        self.assertTrue(audit.hid_test('USB',en).startswith('brak pomiaru'))

    def test_nt3_storage_remains_after_1_0(self):
        usb,net=audit.capability(row('Windows NT 3.51\\Workstation.iso','windows-nt-3-51'))
        self.assertIn('po 1.0',usb)
        self.assertIn('NDIS 3',net)

    def test_fresh_nt351_lan_keeps_diagnostic_usb_and_storage_separate(self):
        exact=[*audit.NT351_R18F_ROW,'unused','unused','unused','unused']
        usb,net=audit.capability(exact)
        self.assertNotIn('PASS',usb)
        self.assertIn('QEMU PASS R22',net)
        self.assertIn('świeży normalny USOS',net)
        self.assertIn('około2s',net)
        self.assertIn('QEMU PASS R18f',audit.hid_test(usb,exact))
        self.assertIn('i8042prt Start4',audit.hid_test(usb,exact))

    def test_nt351_result_does_not_spread_to_other_media_editions_or_architecture(self):
        for index,value in ((0,'Windows NT 3.51\\Other.iso'),(1,'3.51 SP5'),
                            (2,'en-US / x64'),(3,'windows-nt-3-51-server / nt3-x86-qemu-csmwrap')):
            changed=list(audit.NT351_R18F_ROW)
            changed[index]=value
            usb,net=audit.capability(changed)
            self.assertNotIn('QEMU PASS',usb+net+audit.hid_test(usb,changed))

    def test_nt31_static_tcpip_capability_is_not_an_intel_network_pass(self):
        usb,net=audit.capability(row('Windows NT 3.1\\WKS.iso','windows-nt-3-1'))
        self.assertIn('DHCP nie dotyczy',net)
        self.assertIn('full-MAC',net)
        self.assertNotIn('PASS',usb+net)

    def test_nt31_completed_hid_does_not_qualify_storage_or_intel(self):
        exact=list(audit.NT31_R19C_ROW)
        usb,net=audit.capability(exact)
        self.assertNotIn('PASS',usb+net)
        self.assertIn('QEMU PASS R19c',audit.hid_test(usb,exact))
        self.assertIn('i8042prt Start4',audit.hid_test(usb,exact))

    def test_nt31_result_does_not_spread_to_other_media_or_server(self):
        for index,value in ((0,'Windows NT 3.1\\Other.iso'),(1,'3.10 SP3'),
                            (2,'en-US / x86'),(3,'windows-nt-3-1-server / nt3-x86-qemu-csmwrap')):
            changed=list(audit.NT31_R19C_ROW);changed[index]=value
            usb,net=audit.capability(changed)
            self.assertNotIn('QEMU PASS',usb+net+audit.hid_test(usb,changed))

    def test_nt35_fresh_lan_and_overlay_hid_keep_storage_and_latency_limits(self):
        exact=list(audit.NT35_R20_ROW)
        usb,net=audit.capability(exact)
        self.assertNotIn('PASS',usb)
        self.assertIn('QEMU PASS R20',net)
        self.assertIn('pierwszy ping2/3',net)
        self.assertIn('około2s',net)
        self.assertIn('QEMU PASS R20b',audit.hid_test(usb,exact))

    def test_nt35_pass_never_spreads_to_server_or_nt351(self):
        for index,value in ((0,'Windows NT 3.5\\Server.iso'),(1,'3.50.807 SP3'),(2,'pl-PL / x86'),
                            (3,'windows-nt-3-5-server / nt3-x86-qemu-csmwrap'),(3,'windows-nt-3-51 / nt3-x86-qemu-csmwrap')):
            changed=list(audit.NT35_R20_ROW);changed[index]=value
            usb,net=audit.capability(changed)
            self.assertNotIn('QEMU PASS',usb+net+audit.hid_test(usb,changed))


if __name__=='__main__':unittest.main()
