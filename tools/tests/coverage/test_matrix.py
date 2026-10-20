"""Prevent inventory, imported symbols or a different image becoming PASS."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('matrix', Path(__file__).with_name('write_matrix.py'))
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


class MeasuredResultTests(unittest.TestCase):
    def test_integrated_media_keeps_old_service_pack_markers(self):
        cases=[(['cdromsp2.tst','cdromsp4.tst'],[5,0,2195,6717],'SP4'),
               (['win51ip.sp2','win51ip.sp3'],[5,1,2600,5657],'SP3'),
               (['cdrom_ip.5','cdrom_sp.tst'],[5,0,2195,1620],'SP1'),
               (['cdrom_ip.5'],[5,0,2195,1],'SP0')]
        for markers,kernel,expected in cases:
            with self.subTest(expected=expected):
                facts=dict(cd_markers=markers,binary_versions={'i386/ntoskrnl.ex_':dict(file_version=kernel)})
                self.assertTrue(matrix.identity(facts)[0].endswith('/ '+expected))

    def test_original_pe_and_locale_fill_missing_optical_arch(self):
        facts = dict(usos=dict(legacy=dict(arch='unknown',locale=1033)),
                     binary_versions={'i386/ntoskrnl.ex_':dict(machine='0x14c',file_version=[3,51,1025,1])})
        self.assertEqual(matrix.identity(facts)[:3],('3.51.1025.1','en-US','x86'))
        facts['binary_versions']['i386/ntoskrnl.ex_']['nt_build_number']=dict(build=1057)
        self.assertEqual(matrix.identity(facts)[0],'3.51.1057 (NtBuildNumber; zasób 3.51.1025.1)')

    def test_same_hash_and_reviewed_desktop_required(self):
        row = dict(sha256='a', result='PASS', stage='desktop', screen='s.png', evidence='result.json')
        self.assertEqual(matrix.measured_result('a',[row])[0], 'QEMU PASS')
        self.assertEqual(matrix.measured_result('b',[row])[0], 'oczekuje')
        for invalid in (dict(row, stage='imports'), dict(row, screen=''), dict(row, result='ASSESS_ENDPOINT')):
            self.assertEqual(matrix.measured_result('a',[invalid])[0], 'oczekuje')

    def test_adapter_error_is_separate_from_windows_failure(self):
        self.assertEqual(matrix.measured_result('a',[dict(sha256='a', result='RUNNER_ERROR', stage='menu')])[:2],
                         ('błąd adaptera testu','menu'))
        self.assertEqual(matrix.measured_result('a',[dict(sha256='a', result='FAIL', stage='Setup')])[:2],
                         ('QEMU FAIL','Setup'))

    def test_successful_retry_preserves_failed_storage_variant(self):
        rows = [dict(sha256='a',result='FAIL',stage='disk selection',target='NVMe'),
                dict(sha256='a',result='PASS',stage='desktop',target='AHCI',screen='s.png',evidence='result.json')]
        self.assertEqual(matrix.measured_result('a',rows)[0],'QEMU PASS')
        self.assertIn('NVMe: FAIL',matrix.variant_notes('a',rows))
        self.assertIn('AHCI: PASS',matrix.variant_notes('a',rows))
        self.assertNotIn('NVMe',matrix.variant_notes('b',rows))


if __name__ == '__main__':
    unittest.main()
