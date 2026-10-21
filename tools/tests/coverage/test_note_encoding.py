"""Read/write assessment metadata as UTF-8; recover only own text fields."""
from pathlib import Path
import importlib.util
import json
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('repair',Path(__file__).with_name('repair_notes.py'))
notes=importlib.util.module_from_spec(spec);spec.loader.exec_module(notes)


class EncodingTests(unittest.TestCase):
    def test_one_or_multiple_wrong_windows_decodes(self):
        text='Narzędziowy przepływ źródła, ustawienia i język'
        broken=text.encode('utf-8').decode('cp1250')
        self.assertEqual(notes.repair(broken),text)
        broken=broken.encode('utf-8').decode('cp1250')
        self.assertEqual(notes.repair(broken),text)
        self.assertEqual(notes.repair('Poprawny język; '+broken),'Poprawny język; '+text)
    def test_valid_unicode_is_preserved(self):
        for text in ('źródło, przepływ, użytkownik','Windows 95','日本語','Ärger'):
            self.assertEqual(notes.repair(text),text)
    def test_only_own_human_fields_can_change(self):
        scratch=Path(__file__).resolve().parents[3]/'artifacts/coverage/encoding-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            path=Path(folder)/'results.json';broken='źródło'.encode('utf-8').decode('cp1250')
            row=dict(reason=broken,path=broken,sha256='unchanged',result='INCOMPLETE')
            path.write_text(json.dumps([row],ensure_ascii=False),encoding='utf-8')
            notes.main(path);result=json.loads(path.read_text(encoding='utf-8'))[0]
            self.assertEqual(result,dict(row,reason='źródło'))


if __name__=='__main__':unittest.main()
