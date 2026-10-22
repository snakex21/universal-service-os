"""Actual private351 collector transform; no guest or source-profile reads."""
import ast
import unittest

from prepare_nt351_client_auto_run import policy_collector


class CollectorNames(unittest.TestCase):
    SOURCE = "FILES=('NET351.STATUS','NET351.ON','USABILITY.TXT','POST.LOG','USOSNET351.SHA256')\nMAX_TOTAL=5*MAX_FILE+4096\n"

    def test_exact351_request_status_error_and_native_names(self):
        actual = policy_collector(self.SOURCE)
        files = ast.literal_eval(ast.parse(actual).body[0].value)
        self.assertEqual(files, ('NET351.STATUS','NET351.ON','USABILITY.TXT','POST.LOG',
                                'USOSNET351.SHA256','CLNT351.REQ','CLNT351.LOG','CLNT351.ERR','C351NET.LOG'))
        self.assertNotIn('CLNT3511',actual)
        self.assertIn('MAX_TOTAL=9*MAX_FILE+4096',actual)

    def test_duplicate_changed_wrong_version_or_already_typo_refuse(self):
        for source in (self.SOURCE+self.SOURCE, self.SOURCE.replace('NET351','NET35'),
                       self.SOURCE.replace('5*MAX_FILE','6*MAX_FILE'),
                       self.SOURCE+'# CLNT3511.REQ\n'):
            with self.assertRaises(ValueError):
                policy_collector(source)

    def test_unrelated_source_preserved_exactly(self):
        prefix='# exact unrelated privacy/transport guard\n'
        suffix='PRIVATE_PROFILE_REFUSED=True\n'
        changed=policy_collector(prefix+self.SOURCE+suffix)
        self.assertTrue(changed.startswith(prefix))
        self.assertTrue(changed.endswith(suffix))


if __name__ == '__main__':
    unittest.main()
