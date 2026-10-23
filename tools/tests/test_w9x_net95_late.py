"""Post-Setup boundary and interrupted-import guards for the 950 DOS hook."""
from pathlib import Path
import re,shutil,sys,unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh,scratch
from test_w9x_reg95 import ANSWER_95,REG95

class LateNetwork(unittest.TestCase):
 def create(self,version='4 0 0 950',network=True):
  tmp=scratch('netlate-');self.addCleanup(shutil.rmtree,tmp,ignore_errors=True)
  out=tmp/'USOS9X';(out/'NET').mkdir(parents=True);inf=tmp/'MSBATCH.INF';inf.write_bytes(ANSWER_95.encode('ascii'))
  net=out/'NET/NET95.REG'
  if network:net.write_bytes(b'REGEDIT4\r\n[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_8086&DEV_10C9\\BUS_00&DEV_03&FUNC_00]\r\n"Driver"="Net\\\\0009"\r\n')
  rc,so,err=sh(f'. "{REG95}"\nw9x_reg95_write "{out.as_posix()}" "{inf.as_posix()}" "" "" "{net.as_posix() if network else ""}" "{version}"\n')
  self.assertEqual(rc,0,so+err)
  child=out/'NET/NET95L.BAT'
  return (out/'REG95.BAT').read_bytes(),child.read_bytes() if child.exists() else None

 def test_scope_and_call_precedes_early_done_marker(self):
  parent,child=self.create();self.assertIsNotNone(child)
  self.assertLess(parent.index(b'CALL C:\\USOS9X\\NET\\NET95L.BAT'),parent.index(b'IF EXIST C:\\USOS9X\\REG95.OK GOTO END'))
  for v,n in [('4 0 0 1111',True),('4 0 0 1068',True),('',True),('4 0 0 950',False)]:
   parent,child=self.create(v,n);self.assertIsNone(child);self.assertNotIn(b'NET95L',parent)

 def test_setup_presence_withholds_import_and_journal_creation(self):
  _,child=self.create();s=child.decode('ascii')
  boundary=s.index('IF NOT ERRORLEVEL 1 GOTO PENDING')
  self.assertLess(s.index('IF NOT EXIST C:\\USOS9X\\REG95.OK GOTO END'),boundary)
  self.assertLess(s.index('"\\RunOnce]"'),boundary)
  self.assertLess(s.index('"\\RunOnce\\Setup]"'),boundary)
  self.assertLess(boundary,s.index('ECHO run>'))
  self.assertLess(boundary,s.index('ATTRIB.EXE -S -R -H'))
  self.assertLess(boundary,s.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:'))

 def test_incomplete_journal_is_not_treated_as_success(self):
  parent,child=self.create();s=child.decode('ascii')
  self.assertLess(s.index('NLATE.ERR GOTO FAIL'),s.index('NLATE.OK GOTO END'))
  self.assertLess(s.index('NLATE.RUN GOTO FAIL'),s.index('NLATE.OK GOTO END'))
  self.assertIn(b'NLATE.ERR GOTO PREPERR',parent);self.assertIn(b'NLATE.RUN GOTO PREPERR',parent)
  # Fail-soft: logged on the target disk, then Windows starts (no PAUSE loop).
  self.assertNotIn(b'PAUSE',parent)
  self.assertIn(b'>> C:\\USOS9X\\USOSLOG.TXT\r\n:END',parent.split(b':PREPERR\r\n')[1])

 def test_only_network_files_imported_once_then_verified_and_restored(self):
  _,child=self.create();s=child.decode('ascii')
  imports=re.findall(r'^REGEDIT /L:SYSTEM.DAT /R:USER.DAT (?!/E)(.*)\r?$',s,re.M)
  self.assertEqual([x.rstrip('\r') for x in imports],[r'C:\USOS9X\NET\NET95.REG',r'C:\USOS9X\NET\TCP95.REG'])
  self.assertLess(s.index('"NetClient\\\\0009"'),s.index('ECHO complete>'))
  self.assertLess(s.index('ATTRIB.EXE +S +R +H SYSTEM.DAT'),s.index('ECHO complete>'))
  self.assertIn(':RESTORE\r\nC:\\WINDOWS\\COMMAND\\ATTRIB.EXE +S +R +H SYSTEM.DAT',s)
  for name in ['REG95.REG','WIN.COM','SHUTDOWN','APPDATA']:self.assertNotIn(name,s)

 def test_original_dos_line_limits_and_complete_unique_labels(self):
  for batch in self.create():
   self.assertEqual(batch.count(b'\n'),batch.count(b'\r\n'))
   self.assertLessEqual(max(map(len,batch.split(b'\r\n'))),125)
   s=batch.decode('ascii');labels=re.findall(r'^:([A-Z0-9]+)\r?$',s,re.M)
   self.assertEqual(len(labels),len(set(labels)))
   self.assertTrue(all(len(label)<=8 for label in labels))
   self.assertFalse(set(re.findall(r'GOTO ([A-Z0-9]+)',s))-set(labels))

if __name__=='__main__':unittest.main()
