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

    def test_observed_r16_cursor_query_and_truncated_end_echo(self):
        payload=archive('./collection-state.txt',b'Sanitized state only\n')
        encoded=base64.b64encode(payload).decode()
        text=('COVERAGE_EVIDENCE_BEGIN\n/tmp/export/nt4 # \x1b[6nbase64 /tmp/evidence.tgz\n'+
              '\n'.join(encoded[i:i+76] for i in range(0,len(encoded),76))+
              '\nVERAGE_E/tmp/export/nt4 # echo COVERAGE_EVIDENCE_END\nCOVERAGE_EVIDENCE_END\n')
        self.assertEqual(collector.decode_transport(text),payload)

    def test_second_encoded_archive_after_padding_is_rejected(self):
        payload=archive('collection-state.txt',b'state\n')
        while len(payload)%3==0:payload+=b'\0'
        encoded=base64.b64encode(payload).decode()
        second=base64.b64encode(archive('post.txt',b'other archive\n')).decode()
        text='COVERAGE_EVIDENCE_BEGIN\n'+encoded+'\n'+second+'\nCOVERAGE_EVIDENCE_END\n'
        with self.assertRaises(ValueError):collector.decode_transport(text)

    def test_unknown_prompt_suffix_and_duplicate_frames_are_rejected(self):
        encoded=base64.b64encode(b'evidence').decode()
        frame='COVERAGE_EVIDENCE_BEGIN\n'+encoded+'\nCOVERAGE_EVIDENCE_END\n'
        for text in (frame+frame,frame.replace(encoded,'/tmp/export/nt4 # unknown\n'+encoded),
                     frame.replace(encoded,encoded+'\nMOTD unexpected'),
                     frame.replace(encoded,'VERAGE_E/tmp/export/nt4 # echo COVERAGE_EVIDENCE_END\n'+encoded)):
            with self.assertRaises(ValueError):collector.decode_transport(text)

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
