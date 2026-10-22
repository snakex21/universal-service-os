"""Exercise actual newc layer reader used for strict overlay cache."""
from pathlib import Path
import importlib.util,stat,sys,unittest
ROOT=Path(__file__).resolve().parents[2]
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);sys.modules[name]=m;spec.loader.exec_module(m);return m
cache=load('nt35_cache',ROOT/'tools/tests/build_nt35_fixture_cache.py')
cpio=load('nt35_cpio',ROOT/'tools/build_micro_linux.py')
class Layers(unittest.TestCase):
 def test_last_script_wins_and_unrelated_features_remain(self):
  a={'usr/lib/usos/script.sh':cpio.Entry('usr/lib/usos/script.sh',stat.S_IFREG|0o755,b'old')}
  b={'usr/lib/usos/script.sh':cpio.Entry('usr/lib/usos/script.sh',stat.S_IFREG|0o755,b'current'),
     'usr/lib/usos/nt4-storage.sh':cpio.Entry('usr/lib/usos/nt4-storage.sh',stat.S_IFREG|0o755,b'retained')}
  entries,count=cache.effective_newc(cpio.newc(a)+b'\0'*12+cpio.newc(b))
  self.assertEqual(count,2);self.assertEqual(entries['usr/lib/usos/script.sh'].data,b'current');self.assertEqual(entries['usr/lib/usos/nt4-storage.sh'].data,b'retained')
 def test_invalid_or_truncated_layer_is_refused(self):
  a=cpio.newc({'own':cpio.Entry('own',stat.S_IFREG|0o644,b'own')})
  for bad in (b'',b'bad',a[:-10],a+b'bad'):
   with self.assertRaises(ValueError):cache.effective_newc(bad)
if __name__=='__main__':unittest.main()