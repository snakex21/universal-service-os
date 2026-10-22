"""Bind future stopped-target collection to the actual qualified own SYS."""
from pathlib import Path
import hashlib,importlib.util,io,os,tarfile,tempfile,unittest

ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('nt351_pinned_collector',Path(__file__).with_name('collect_nt351_success.py'))
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)


class DriverPinTests(unittest.TestCase):
    def test_exact_qualified_binary(self):
        path=Path(os.environ.get('USOSNET351_TEST_DRIVER',ROOT/'tools/nt/usosnet/bin/i386/usosnet351.sys'))
        if not path.is_file():self.skipTest('Explicit own NT351 candidate absent; no actual pin proof')
        data=path.read_bytes()
        self.assertEqual(len(data),17024)
        self.assertEqual(hashlib.sha256(data).hexdigest(),'f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf')
        self.assertEqual(hashlib.sha256(data).hexdigest(),c.DRIVER_SHA256)
        self.assertEqual(len(data),c.DRIVER_BYTES)

    def test_old_candidate_is_still_a_mismatch_and_never_runtime_pass(self):
        parent=ROOT/'artifacts/coverage/nt351-driver-pin-tests';parent.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temporary:
            for label,digest,expected in [('old','dc8827954e6fe75ee8264c7382e87899cc9761890998198c126c7ea8aa5c55b6',False),('qualified',c.DRIVER_SHA256,True)]:
                stream=io.BytesIO();data=(digest+'\n').encode()
                with tarfile.open(fileobj=stream,mode='w:gz') as archive:
                    member=tarfile.TarInfo('DRIVER-READBACK.SHA256');member.size=len(data)
                    archive.addfile(member,io.BytesIO(data))
                result=c.export_evidence(stream.getvalue(),Path(temporary)/label)
                self.assertEqual(result['driver_hash_matches'],expected)
                self.assertFalse(result['installed_runtime_pass'])
                self.assertEqual(result['expected_driver_sha256'],c.DRIVER_SHA256)


if __name__=='__main__':unittest.main()
