"""Synthetic selected DWORDs through the actual AUTO stopped reader."""
import struct
import unittest

from readback_nt351_client_auto import NAMES, policy_values


class AutoReadback(unittest.TestCase):
    def fixture(self):
        dword = lambda value: (4, struct.pack('<I', value))
        values = {'select': {'current': dword(1), 'default': dword(1)}}
        for name, start, kind in (('Browser',4,32), ('LanmanServer',4,32),
                                  ('LanmanWorkstation',2,32), ('Tcpip',3,1),
                                  ('NDISLoop',2,1), ('usosnt3',4,16)):
            values['controlset001\\services\\'+name.lower()] = {
                'start': dword(start), 'type': dword(kind),
                'unrelated_private_field': (1, b'NEVER EXPORT')}
        values['controlset001\\services\\unrelated'] = {'secret': (1,b'NEVER EXPORT')}
        return values

    def test_only_six_explicit_service_dwords_leave_reader(self):
        result = policy_values(self.fixture())
        self.assertEqual(set(result['services']['1']), set(NAMES))
        self.assertNotIn('NEVER EXPORT', repr(result))
        for value in result['services']['1'].values():
            self.assertEqual(set(value), {'present','start','type'})
        self.assertEqual(result['services']['1']['LanmanServer']['start'],4)
        self.assertEqual(result['services']['1']['usosnt3']['start'],4)

    def test_wrong_registry_type_and_length_refuse(self):
        for malformed in ((1, b'\x04\0\0\0'), (4, b'\x04\0\0')):
            values = self.fixture()
            values['controlset001\\services\\lanmanserver']['start'] = malformed
            with self.assertRaises(ValueError):
                policy_values(values)

    def test_unselected_controlset_and_absent_service_are_explicit(self):
        values = self.fixture()
        del values['controlset001\\services\\browser']
        values['controlset002\\services\\lanmanserver'] = {'start': (4,struct.pack('<I',2))}
        result = policy_values(values)
        self.assertEqual(set(result['services']), {'1'})
        self.assertEqual(result['services']['1']['Browser'], {'present': False})


if __name__ == '__main__':
    unittest.main()
