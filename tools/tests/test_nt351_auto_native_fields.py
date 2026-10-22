"""Native IPCONFIG separators vary; labels and values must remain exact."""
import unittest
from assess_nt351_client_auto import native_field


class NativeFields(unittest.TestCase):
    def test_actual_dotted_and_tabbed_field_formats(self):
        self.assertTrue(native_field('\tDNS Servers . . . . . . . . : 10.0.2.3\r\n',
                                     'DNS Servers','10.0.2.3'))
        self.assertTrue(native_field(' DHCP Enabled. . . :\tYes\r\n','DHCP Enabled','Yes'))

    def test_wrong_or_prefix_values_and_unrelated_labels_refuse(self):
        for line in ('DNS Servers . . : 10.0.2.30\n','Other DNS Servers . : 10.0.2.3\n',
                     'DNS Servers . . : 10.0.2.3 extra\n','DNS ServersX: 10.0.2.3\n'):
            self.assertFalse(native_field(line,'DNS Servers','10.0.2.3'))


if __name__ == '__main__':
    unittest.main()
