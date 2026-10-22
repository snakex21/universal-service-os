"""Real gzip/tar corruption against all four bounded NT evidence exporters."""
from pathlib import Path
import gzip
import importlib.util
import io
import tarfile
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
OUT=HERE.parents[2]/'artifacts/coverage/evidence-archive-tests'


def load(name):
    spec=importlib.util.spec_from_file_location('archive_test_'+name,HERE/(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


COLLECTORS={name:load(name) for name in ('collect_nt4_text','collect_nt4_success','collect_nt35_success','collect_nt351_success')}


def archive(name,data):
    plain=io.BytesIO()
    with tarfile.open(fileobj=plain,mode='w') as tar:
        member=tarfile.TarInfo(name);member.size=len(data);tar.addfile(member,io.BytesIO(data))
    return gzip.compress(plain.getvalue(),mtime=0)


def baseline(name,module):
    if name=='collect_nt4_text':
        text=module.STATE_HEADER+'\n'+''.join(log+'=unavailable\n' for log in module.LOGS)
        return archive('collection-state.txt',text.encode('ascii'))
    if name=='collect_nt4_success':
        text=module.HEADER+'\n'+''.join(log+'=unavailable\n' for log in module.LOGS)+'driver=unavailable\nobserver=unavailable\n'
        return archive('collection-state.txt',text.encode('ascii'))
    return archive(module.FILES[0],b'Own synthetic status\n')


class ArchiveIntegrityTests(unittest.TestCase):
    def setUp(self):
        OUT.mkdir(parents=True,exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=OUT);self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name);self.sequence=0

    def export(self,name,module,payload):
        self.sequence+=1;output=self.directory/(name+'-'+str(self.sequence))
        if name=='collect_nt4_text':output.mkdir()
        exporter=module.export_text if name=='collect_nt4_text' else module.export_evidence
        return exporter,output

    def reject(self,name,module,payload):
        exporter,output=self.export(name,module,payload)
        with self.assertRaises(ValueError):exporter(payload,output)
        self.assertFalse(output.exists() and any(output.iterdir()))

    def test_valid_single_archives_remain_accepted_by_all_exporters(self):
        for name,module in COLLECTORS.items():
            with self.subTest(collector=name):
                payload=baseline(name,module);exporter,output=self.export(name,module,payload)
                result=exporter(payload,output)
                self.assertTrue(result['files']);self.assertTrue(any(output.iterdir()))

    def test_all_exporters_reject_second_gzip_member_before_any_write(self):
        second=archive('unexpected.txt',b'Own synthetic second member')
        for name,module in COLLECTORS.items():
            with self.subTest(collector=name):self.reject(name,module,baseline(name,module)+second)

    def test_all_exporters_reject_second_tar_inside_one_gzip_before_any_write(self):
        second=gzip.decompress(archive('unexpected.txt',b'Own synthetic second tar'))
        for name,module in COLLECTORS.items():
            with self.subTest(collector=name):
                self.reject(name,module,gzip.compress(gzip.decompress(baseline(name,module))+second))

    def test_all_exporters_reject_crc_truncation_and_absent_tar_terminator(self):
        for name,module in COLLECTORS.items():
            payload=baseline(name,module);corrupt=bytearray(payload);corrupt[-8]^=1
            unterminated=gzip.compress(gzip.decompress(payload)[:1024])
            for label,bad in (('CRC',bytes(corrupt)),('gzip EOF',payload[:-1]),('tar EOF',unterminated)):
                with self.subTest(collector=name,failure=label):self.reject(name,module,bad)


if __name__=='__main__':unittest.main()
