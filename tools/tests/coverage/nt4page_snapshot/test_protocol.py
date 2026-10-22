from pathlib import Path
import importlib.util,json,unittest
HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('own_page_protocol',HERE/'protocol.py');p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
MANIFEST=json.loads((HERE/'public_manifest.json').read_text(encoding='utf-8'))
def frame():return b'NT4PAGE BEGIN\r\nNT4PAGE MATCH SYSSETUP STR 1 STATIC\r\n'+b''.join(('NT4PAGE '+n+'=NO\r\n').encode('ascii') for n in sorted(p.BOOLS))+b'NT4PAGE END\r\n'
class ClosedProtocol(unittest.TestCase):
 def test_actual_manifest_fragmented_complete_frame(self):
  q=p.Protocol(MANIFEST);result=[]
  for byte in frame():result.extend(q.feed(bytes([byte])))
  self.assertEqual(len(result),1);self.assertEqual(result[0]['matches'][0]['id'],1);q.eof()
 def test_unknown_public_id_rejected(self):
  q=p.Protocol(MANIFEST)
  with self.assertRaises(ValueError):q.feed(b'NT4PAGE BEGIN\nNT4PAGE MATCH SYSSETUP STR 999999 STATIC\n')
 def test_edit_role_and_arbitrary_data_rejected(self):
  for data in (b'NT4PAGE BEGIN\nNT4PAGE MATCH SYSSETUP STR 1 EDIT\n',b'NT4PAGE BEGIN\nSYNTHETIC PRIVATE DATA\n',b'NT4PAGE UNKNOWN=SYNTHETIC\n'):
   with self.assertRaises(ValueError):p.Protocol(MANIFEST).feed(data)
 def test_truncation_missing_flags_and_duplicate_rejected(self):
  q=p.Protocol(MANIFEST);q.feed(frame()[:-2])
  with self.assertRaises(ValueError):q.eof()
  for data in (b'NT4PAGE BEGIN\nNT4PAGE END\n',b'NT4PAGE BEGIN\nNT4PAGE OK_PRESENT=YES\nNT4PAGE OK_PRESENT=NO\n'):
   with self.assertRaises(ValueError):p.Protocol(MANIFEST).feed(data)
 def test_nonprotocol_noise_is_not_exported(self):
  q=p.Protocol(MANIFEST);self.assertEqual(q.feed(b'OWN SYNTHETIC NONPROTOCOL\n'),[]);self.assertEqual(q.discarded_lines,1)
 def test_traversal_module_and_slot_bounds(self):
  for data in (b'NT4PAGE BEGIN\nNT4PAGE DIALOG ../SYSSETUP 102 0 TITLE\n',b'NT4PAGE BEGIN\nNT4PAGE DIALOG SYSSETUP 102 999 STATIC\n'):
   with self.assertRaises(ValueError):p.Protocol(MANIFEST).feed(data)
 def test_diagnostic_fragment_stays_separate_from_whole_matches(self):
  data=frame().replace(b'NT4PAGE BEGIN\r\n',b'NT4PAGE BEGIN\r\nNT4PAGE FRAGMENT KERNEL32 MSG 1010 STATIC\r\n');q=p.Protocol(MANIFEST);events=q.feed(data);self.assertEqual(events[0]['fragments'][0]['id'],1010);self.assertFalse(any(x['id']==1010 for x in events[0]['matches']));q.eof()
 def test_oracle_flags_must_be_explicit_and_known(self):
  for data in (frame().replace(b'NT4PAGE ORACLE_MESSAGE1010_READ=NO\r\n',b''),frame().replace(b'ORACLE_MESSAGE1010_READ=NO',b'ORACLE_UNKNOWN1010=NO')):
   with self.assertRaises(ValueError):p.Protocol(MANIFEST).feed(data)
 def test_known_original_named_dialog_is_allowlisted(self):
  data=frame().replace(b'NT4PAGE BEGIN\r\n',b'NT4PAGE BEGIN\r\nNT4PAGE DIALOGNAME SETUPDLL CRITERR 1 STATIC\r\n');q=p.Protocol(MANIFEST);result=q.feed(data);self.assertEqual(result[0]['named_dialogs'][0]['name'],'CRITERR');q.eof()
 def test_unknown_named_or_path_or_edit_rejected(self):
  for item in (b'SETUPDLL UNKNOWN',b'SETUPDLL ../CRITERR',b'PRIVATE CRITERR'):
   with self.assertRaises(ValueError):p.Protocol(MANIFEST).feed(b'NT4PAGE BEGIN\nNT4PAGE DIALOGNAME '+item+b' 1 STATIC\n')
  with self.assertRaises(ValueError):p.Protocol(MANIFEST).feed(b'NT4PAGE BEGIN\nNT4PAGE DIALOGNAME SETUPDLL CRITERR 1 EDIT\n')
if __name__=='__main__':unittest.main(verbosity=2)
