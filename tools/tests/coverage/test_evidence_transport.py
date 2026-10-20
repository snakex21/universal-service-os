"""Keep malformed guest evidence and unexpected payloads out of artifacts."""
from pathlib import Path
import base64
import importlib.util
import io
import tarfile
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('collector',Path(__file__).with_name('collect_guest_logs.py'))
collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)


def archive(name,data):
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as tar:
        member=tarfile.TarInfo(name);member.size=len(data)
        tar.addfile(member,io.BytesIO(data))
    return stream.getvalue()


class EvidenceTests(unittest.TestCase):
    def test_framing_ignores_known_command_echo_but_rejects_corruption(self):
        encoded=base64.b64encode(b'evidence').decode()
        text='COVERAGE_EVIDENCE_BEGIN\n/tmp/export/nt4 # base64 /tmp/evidence.tgz\n'+encoded+'\nCOVERAGE_EVIDENCE_END\n'
        self.assertEqual(collector.decode_transport(text),b'evidence')
        with self.assertRaises(ValueError):collector.decode_transport(text.replace(encoded,'!'+encoded))

    def test_only_valid_screen_is_persisted(self):
        scratch=Path(__file__).resolve().parents[3]/'artifacts/coverage/evidence-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            root=Path(temporary)
            self.assertEqual(collector.export_evidence(archive('run-1/screen.ppm',b'P6\n1 1\n255\n\xff\0\0'),root),[str(Path('run-1/screen.png'))])
            collector.export_evidence(archive('run-2/screen.ppm',b'broken'),root)
            self.assertTrue((root/'run-2/screen.invalid.json').exists())
            self.assertFalse((root/'run-2/screen.ppm').exists())
            collector.export_evidence(archive('run-2/qemu.log',b'\0binary'),root)
            self.assertFalse((root/'run-2/qemu.log').exists())

    def test_rejects_traversal_and_non_log_payload(self):
        scratch=Path(__file__).resolve().parents[3]/'artifacts/coverage/evidence-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            for name in ('../qemu.log','run-1/driver.sys'):
                with self.assertRaises(ValueError):collector.export_evidence(archive(name,b'text'),Path(temporary))


if __name__=='__main__':unittest.main()
