from pathlib import Path
import importlib.util
import io
import base64
import gzip
import os
import subprocess
import tarfile
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('nt4_text',Path(__file__).with_name('collect_nt4_text.py'))
collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
spec=importlib.util.spec_from_file_location('aux',Path(__file__).with_name('usability_aux.py'))
aux=importlib.util.module_from_spec(spec);spec.loader.exec_module(aux)


OUT=Path(__file__).resolve().parents[3]/'artifacts/coverage/nt4-text-tests'
SH=r'C:\Program Files\Git\usr\bin\sh.exe'


def archive_entries(entries):
    out=io.BytesIO()
    with tarfile.open(fileobj=out,mode='w:gz') as tar:
        for name,data in entries:
            entry=name if isinstance(name,tarfile.TarInfo) else tarfile.TarInfo(name)
            entry.size=len(data);tar.addfile(entry,io.BytesIO(data) if entry.isfile() else None)
    return out.getvalue()


def archive(name,data):return archive_entries([(name,data)])


def state(changes=None):
    statuses=dict.fromkeys(collector.LOGS,'unavailable')
    statuses.update(changes or {})
    return (collector.STATE_HEADER+'\n'+''.join(name+'='+value+'\n' for name,value in statuses.items())).encode('ascii')


def bundle(entries=(),changes=None,prefix=''):
    return archive_entries([(prefix+'collection-state.txt',state(changes)),*entries])


class NativeTextTests(unittest.TestCase):
    def setUp(self):
        OUT.mkdir(parents=True,exist_ok=True)
        self.temporary=tempfile.TemporaryDirectory(dir=OUT)
        self.addCleanup(self.temporary.cleanup)
        self.directory=Path(self.temporary.name)

    def test_canonical_transport_cannot_hide_a_second_gzip_archive(self):
        payload=bundle()+archive('unexpected.txt',b'Own synthetic second archive')
        encoded=base64.b64encode(payload).decode('ascii')
        decoded=collector.transport.decode_transport('COVERAGE_EVIDENCE_BEGIN\n'+encoded+'\nCOVERAGE_EVIDENCE_END\n')
        self.assertEqual(decoded,payload)  # Valid one-frame canonical base64.
        with self.assertRaisesRegex(ValueError,'gzip'):
            collector.export_text(decoded,self.directory)
        self.assertEqual(list(self.directory.iterdir()),[])

    def test_second_tar_and_nonzero_trailer_inside_one_gzip_are_rejected(self):
        plain=gzip.decompress(bundle())
        for trailer in (gzip.decompress(archive('unexpected.txt',b'Own synthetic second tar')),b'X'+bytes(511)):
            with self.subTest(trailer_bytes=len(trailer)),self.assertRaisesRegex(ValueError,'tar'):
                collector.export_text(gzip.compress(plain+trailer),self.directory)
            self.assertEqual(list(self.directory.iterdir()),[])

    def test_truncated_gzip_crc_failure_and_absent_tar_terminator_save_nothing(self):
        payload=bundle();corrupt=bytearray(payload);corrupt[-8]^=1
        # The first state-only member occupies one header and one data block.
        unterminated=gzip.compress(gzip.decompress(payload)[:1024])
        for bad in (payload[:-1],bytes(corrupt),unterminated):
            with self.subTest(payload_bytes=len(bad)),self.assertRaises(ValueError):
                collector.export_text(bad,self.directory)
            self.assertEqual(list(self.directory.iterdir()),[])

    def test_compressed_expansion_is_bounded_before_tar_or_output(self):
        payload=gzip.compress(bytes(collector.MAX_ARCHIVE_PLAIN+1))
        with self.assertRaisesRegex(ValueError,'bounded.*gzip'):
            collector.export_text(payload,self.directory)
        self.assertEqual(list(self.directory.iterdir()),[])

    def test_unanswered_product_key_form_stops_before_windows(self):
        with self.assertRaisesRegex(RuntimeError,'Windows has not started'):
            aux.reject_unanswered_usos_form('[UI_SCREEN] form Enter the Windows NT 4.0 product key')
        aux.reject_unanswered_usos_form('[UI_SCREEN] list Windows NT 4.0')

    def test_guest_pipeline_removes_keys_before_transport(self):
        key='12345-OEM-1234567-12345'
        data=('Setup error\nProductId='+key+'\nAAAAA-BBBBB-CCCCC-DDDDD-EEEEE\n').encode()
        script=collector.SANITIZER
        env=os.environ.copy();env['PATH']=r'C:\Program Files\Git\usr\bin;'+env.get('PATH','')
        result=subprocess.run([SH,'-c',script],input=data,capture_output=True,env=env,check=True)
        self.assertNotIn(key.encode(),result.stdout)
        self.assertNotIn(b'AAAAA-',result.stdout)
        self.assertIn(b'Setup error',result.stdout)

    def test_rejects_unredacted_text_and_any_non_log_payload(self):
        for name,data in [('screen.ppm',b'pixels'),('WINNT.SIF',b'answer'),('../setuplog.txt',b'bad'),
                          ('setuplog.txt',b'12345-OEM-1234567-12345'),('setuplog.txt',b'bad\x1bcontrol')]:
            with self.subTest(name=name,data=data),self.assertRaises(ValueError):
                collector.export_text(bundle([(name,data)]),self.directory)
            self.assertEqual(list(self.directory.iterdir()),[])

    def test_real_busybox_prefix_and_state_only_are_not_native_logs(self):
        evidence=collector.export_text(bundle(prefix='./'),self.directory)
        self.assertEqual(evidence['files'],['collection-state.txt'])
        self.assertEqual(evidence['actual_native_logs'],[])
        self.assertFalse(evidence['native_logs_read'])
        self.assertEqual(evidence['evidence_result'],'no-native-text-exported')
        self.assertEqual(set(evidence['log_status'].values()),{'unavailable'})

    def test_only_nonempty_exported_log_counts_as_native_text(self):
        evidence=collector.export_text(bundle([('./setuplog.txt',b'Setup error [number omitted]\n'),
            ('./post.txt',b'')],{'setuplog.txt':'exported','post.txt':'empty'},prefix='./'),self.directory)
        self.assertEqual(evidence['actual_native_logs'],['setuplog.txt'])
        self.assertTrue(evidence['native_logs_read'])
        self.assertEqual(evidence['evidence_result'],'native-text-exported')

    def test_paths_links_and_normalized_duplicates_are_rejected(self):
        link=tarfile.TarInfo('setuplog.txt');link.type=tarfile.SYMTYPE;link.linkname='WINNT.SIF'
        bad=[[(name,b'bad')] for name in ('../setuplog.txt','/setuplog.txt','././setuplog.txt',
            'dir/setuplog.txt',r'.\setuplog.txt','C:/setuplog.txt')]
        bad += [[(link,b'')],[('collection-state.txt',state())]]
        for entries in bad:
            with self.subTest(entries=entries),self.assertRaises(ValueError):
                collector.export_text(bundle(entries,prefix='./'),self.directory)
            self.assertEqual(list(self.directory.iterdir()),[])

    def test_status_names_values_duplicates_and_missing_records_are_rejected(self):
        valid=state().decode('ascii')
        invalid=[valid.replace('setuplog.txt=unavailable','WINNT.SIF=exported'),
            valid.replace('setuplog.txt=unavailable','../setuplog.txt=exported'),
            valid.replace('setuplog.txt=unavailable','setuplog.txt=missing'),
            valid+'setuplog.txt=exported\n',
            valid.replace('setuplog.txt=unavailable\n','')]
        for text in invalid:
            with self.subTest(text=text),self.assertRaises(ValueError):
                collector.export_text(archive('./collection-state.txt',text.encode('ascii')),self.directory)
            self.assertEqual(list(self.directory.iterdir()),[])

    def test_inconsistent_or_absent_status_never_saves_a_partial_archive(self):
        cases=[archive('./setuplog.txt',b'Setup text\n'),bundle(changes={'setuplog.txt':'exported'}),
            bundle([('setuplog.txt',b'')],{'setuplog.txt':'exported'}),
            bundle([('setuplog.txt',b'Setup text\n')],{'setuplog.txt':'empty'}),
            bundle([('setuplog.txt',b'Setup text\n')])]
        for payload in cases:
            with self.subTest(payload_size=len(payload)),self.assertRaises(ValueError):
                collector.export_text(payload,self.directory)
            self.assertEqual(list(self.directory.iterdir()),[])

    def run_guest_reader(self,data,failed=False):
        raw=self.directory/'raw';raw.mkdir()
        exported=self.directory/'export';exported.mkdir()
        source=self.directory/'source';source.write_bytes(data)
        (exported/'collection-state.txt').write_text(collector.STATE_HEADER+'\n',encoding='utf-8')
        reader=collector.READLOG.replace('/tmp/raw',raw.as_posix()).replace('/tmp/export/nt4',exported.as_posix())
        reader=reader.replace('SANITIZE',collector.SANITIZER)
        # A failed mcopy deliberately leaves partial raw data; the real guest
        # function must discard it and report only unavailable.
        mock='mcopy() { for target do :; done; cp "'+source.as_posix()+'" "$target"; return '+('1' if failed else '0')+'; }\n'
        calls='\n'.join('readlog /ignored '+name for name in collector.LOGS)
        env=dict(os.environ,PATH=r'C:\Program Files\Git\usr\bin;'+os.environ.get('PATH',''))
        subprocess.run([SH,'-c','set -e\n'+mock+reader+'\n'+calls],check=True,capture_output=True,env=env)
        self.assertEqual(list(raw.iterdir()),[])
        payload=archive_entries([('./'+path.name,path.read_bytes()) for path in exported.iterdir()])
        destination=self.directory/'host';destination.mkdir()
        return collector.export_text(payload,destination)

    def test_failed_read_with_partial_bytes_does_not_claim_file_absence_or_native_logs(self):
        evidence=self.run_guest_reader(b'12345-OEM-1234567-12345',failed=True)
        self.assertEqual(set(evidence['log_status'].values()),{'unavailable'})
        self.assertFalse(evidence['native_logs_read'])
        self.assertEqual(evidence['files'],['collection-state.txt'])

    def test_successful_empty_read_has_explicit_empty_status(self):
        evidence=self.run_guest_reader(b'')
        self.assertEqual(set(evidence['log_status'].values()),{'empty'})
        self.assertFalse(evidence['native_logs_read'])

    def test_oversized_read_has_explicit_too_large_status(self):
        evidence=self.run_guest_reader(bytes(2*1024**2+1))
        self.assertEqual(set(evidence['log_status'].values()),{'too-large'})
        self.assertFalse(evidence['native_logs_read'])

    def test_redaction_expansion_cannot_exceed_the_host_evidence_limit(self):
        evidence=self.run_guest_reader(b'123\n'*(256*1024))
        self.assertEqual(set(evidence['log_status'].values()),{'too-large'})
        self.assertFalse(evidence['native_logs_read'])

    def test_actual_guest_reader_exports_only_sanitized_native_text(self):
        evidence=self.run_guest_reader(b'Setup step\n12345-OEM-1234567-12345\n')
        self.assertEqual(set(evidence['log_status'].values()),{'exported'})
        self.assertEqual(evidence['actual_native_logs'],list(collector.LOGS))
        for name in collector.LOGS:
            text=(self.directory/'host'/name).read_text(encoding='utf-8')
            self.assertIn('Setup step',text)
            self.assertNotIn('12345',text)


if __name__=='__main__':unittest.main()
