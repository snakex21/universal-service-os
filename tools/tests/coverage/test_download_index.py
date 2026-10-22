"""Adding Windows 95 media must preserve the prior verified collection."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('download',Path(__file__).with_name('download_media.py'))
download=importlib.util.module_from_spec(spec);spec.loader.exec_module(download)


class IndexTests(unittest.TestCase):
    def test_new_batch_preserves_existing_verified_entries(self):
        old=dict(relative='Windows/XP.iso',sha256='original',status='downloaded and verified')
        new=dict(relative='Windows/95.7z',sha256='new',status='downloaded and verified')
        failed_retry=dict(relative=old['relative'],status='not downloaded',error='already exists')
        result={row['relative']:row for row in download.merge_manifest([old],[new,failed_retry])}
        self.assertEqual(result[old['relative']],old)
        self.assertEqual(result[new['relative']],new)


if __name__=='__main__':unittest.main()
