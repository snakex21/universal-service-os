from pathlib import Path
import importlib.util
import io
import subprocess
import tarfile
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('nt4_text',Path(__file__).with_name('collect_nt4_text.py'))
collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
spec=importlib.util.spec_from_file_location('aux',Path(__file__).with_name('usability_aux.py'))
aux=importlib.util.module_from_spec(spec);spec.loader.exec_module(aux)


def archive(name,data):
    out=io.BytesIO()
    with tarfile.open(fileobj=out,mode='w:gz') as tar:
        entry=tarfile.TarInfo(name);entry.size=len(data);tar.addfile(entry,io.BytesIO(data))
    return out.getvalue()


class NativeTextTests(unittest.TestCase):
    def test_unanswered_product_key_form_stops_before_windows(self):
        with self.assertRaisesRegex(RuntimeError,'Windows has not started'):
            aux.reject_unanswered_usos_form('[UI_SCREEN] form Enter the Windows NT 4.0 product key')
        aux.reject_unanswered_usos_form('[UI_SCREEN] list Windows NT 4.0')

    def test_guest_pipeline_removes_keys_before_transport(self):
        key='12345-OEM-1234567-12345'
        data=('Setup error\nProductId='+key+'\nAAAAA-BBBBB-CCCCC-DDDDD-EEEEE\n').encode()
        script=collector.SANITIZER
        env=__import__('os').environ.copy();env['PATH']=r'C:\Program Files\Git\usr\bin;'+env.get('PATH','')
        result=subprocess.run([r'C:\Program Files\Git\usr\bin\sh.exe','-c',script],input=data,capture_output=True,env=env,check=True)
        self.assertNotIn(key.encode(),result.stdout)
        self.assertNotIn(b'AAAAA-',result.stdout)
        self.assertIn(b'Setup error',result.stdout)

    def test_rejects_unredacted_text_and_any_non_log_payload(self):
        scratch=Path(__file__).resolve().parents[3]/'artifacts/coverage/nt4-text-tests'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            directory=Path(temporary)
            for name,data in [('screen.ppm',b'pixels'),('WINNT.SIF',b'answer'),('../setuplog.txt',b'bad'),('setuplog.txt',b'12345-OEM-1234567-12345')]:
                with self.assertRaises(ValueError):collector.export_text(archive(name,data),directory)
            self.assertEqual(list(directory.iterdir()),[])
            self.assertEqual(collector.export_text(archive('setuplog.txt',b'Setup error [number omitted]\n'),directory),['setuplog.txt'])


if __name__=='__main__':unittest.main()
