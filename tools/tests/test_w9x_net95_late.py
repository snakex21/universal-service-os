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
  self.out=out
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
  self.assertEqual([x.rstrip('\r') for x in imports],[r'C:\USOS9X\NET\NET95.REG',r'C:\USOS9X\NET\TCP95.REG',r'C:\USOS9X\NET\NETCLN.REG'])
  # The cleanup is queued only after the checks of the network import.
  self.assertLess(s.index('"NetClient\\\\0009"'),s.index('NET\\NETCLN.REG\r\n'))
  self.assertLess(s.index('"NetClient\\\\0009"'),s.index('ECHO complete>'))
  self.assertLess(s.index('ATTRIB.EXE +S +R +H SYSTEM.DAT'),s.index('ECHO complete>'))
  self.assertIn(':RESTORE\r\nC:\\WINDOWS\\COMMAND\\ATTRIB.EXE +S +R +H SYSTEM.DAT',s)
  for name in ['REG95.REG','WIN.COM','SHUTDOWN','APPDATA']:self.assertNotIn(name,s)

 def test_950_default_network_cleanup(self):
  # X470 950 PL (2026-10-25): PnP gave the card NetBEUI + IPX/SPX, two MS
  # clients and the NetWare client; 950 REGEDIT has no /D: setupx DelReg.
  self.create()
  net=self.out/'NET'
  inf=(net/'NETCLEAN.INF').read_bytes();self.assertEqual(inf.count(b'\n'),inf.count(b'\r\n'));self.assertNotIn(b'\r\r',inf)
  text=inf.decode('ascii')
  self.assertIn('Signature="$CHICAGO$"\r\n',text)
  self.assertIn('[DefaultInstall]\r\nAddReg=USOS.NetCleanAdd\r\nDelReg=USOS.NetClean\r\n',text)
  self.assertIn('[USOS.NetCleanAdd]\r\nHKLM,"Software\\Microsoft\\Windows\\CurrentVersion\\Network\\Real Mode Net","transport",,""\r\n',text)
  card='HKLM,"Enum\\PCI\\VEN_8086&DEV_10C9\\BUS_00&DEV_03&FUNC_00\\Bindings",'
  lines=['HKLM,"Enum\\Network\\NETBEUI"','HKLM,"Enum\\Network\\NWLINK"','HKLM,"Enum\\Network\\NWREDIR"',
         'HKLM,"System\\CurrentControlSet\\Services\\VxD\\NWLINK"','HKLM,"System\\CurrentControlSet\\Services\\VxD\\NETBEUI"',
         'HKLM,"System\\CurrentControlSet\\Services\\VxD\\NWREDIR"','HKLM,"System\\CurrentControlSet\\Services\\NWNP32"',
         'HKLM,"System\\CurrentControlSet\\Services\\Winsock\\Parameters","NWREDIR"',
         'HKLM,"System\\CurrentControlSet\\control\\NetworkProvider\\Order","NWNP32"',
         'HKLM,"System\\CurrentControlSet\\control\\ServiceProvider\\Order\\ProviderOrder","NWREDIR"']
  for n in range(9):
   lines+=[f'HKLM,"Enum\\Network\\VREDIR\\000{n}"',f'HKLM,"Enum\\Network\\MSTCP\\000{n}"']
   lines+=[card+f'"{i}\\000{n}"' for i in ('NETBEUI','NWLINK','MSTCP')]
   lines+=[f'HKLM,"Enum\\Network\\MSTCP\\0009\\Bindings","{i}\\000{n}"' for i in ('VREDIR','NWREDIR')]
  for line in lines:self.assertIn(line+'\r\n',text)
  # [USOS.NetClean] is the last section: NET95L.BAT appends class keys.
  self.assertEqual(text.rindex('['),text.index('[USOS.NetClean]'))
  # USOS's own instances (0009) are never removed: no key or value name 0009.
  for line in text.split('\r\n'):
   if line.startswith('HKLM,'):self.assertFalse(line.endswith('\\0009"'),line)
  self.assertNotIn('Class\\',text)
  reg=(net/'NETCLN.REG').read_bytes()
  self.assertTrue(reg.startswith(b'REGEDIT4\r\n'))
  self.assertIn(b'[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce]\r\n'
                b'"USOSNetClean"="rundll.exe setupx.dll,InstallHinfSection DefaultInstall 4 C:\\\\USOS9X\\\\NET\\\\NETCLEAN.INF"\r\n',reg)

 def test_class_keys_by_device_id(self):
  # X470 run 2026-10-27: NetTrans\0000..0003 (NWLINK / NETBEUI twice) and
  # NetClient\0000..0003 (VREDIR / NWREDIR twice) stayed after NETCLEAN.
  _,child=self.create();s=child.decode('ascii')
  clid=(self.out/'NET/NETCLID.BAT').read_bytes();self.assertEqual(clid.count(b'\n'),clid.count(b'\r\n'));self.assertNotIn(b'\r\r',clid)
  c=clid.decode('ascii')
  self.assertIn('REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E USOSNC.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\%1\\%2\r\n',c)
  # Expanded for the longest class / instance, still within the DOS limit.
  self.assertLessEqual(max(len(l.replace('%1','NetClient').replace('%2','0015')) for l in c.split('\r\n')),125)
  self.assertTrue(c.endswith(':END\r\nIF EXIST USOSNC.REG DEL USOSNC.REG > NUL\r\n'))
  self.assertIn('ECHO HKLM,"System\\CurrentControlSet\\Services\\Class\\%1\\%2">> C:\\USOS9X\\NET\\NETCLEAN.INF\r\n',c)
  self.assertLess(c.index("IF NOT EXIST USOSNC.REG GOTO END"),c.index(':DEL'))
  # Emulate FIND on the DeviceID line: the 950 defaults and USOS duplicates
  # go, anything else stays (a third-party component is never removed).
  ids=re.findall(r'FIND\.EXE /I "([A-Z]+)" C:\\USOS9X\\NC\.ID > NUL\r\nIF NOT ERRORLEVEL 1 GOTO DEL',c)
  self.assertEqual(ids,['NWLINK','NETBEUI','NWREDIR','VREDIR','MSTCP'])
  self.assertIn('C:\\WINDOWS\\COMMAND\\FIND.EXE "DeviceID" USOSNC.REG > C:\\USOS9X\\NC.ID\r\n',c)
  def removed(device):return any(i.lower() in f'"DeviceID"="{device}"'.lower() for i in ids)
  for device in ('NWLINK','NETBEUI','NWREDIR','VREDIR','MSTCP','nwlink'):self.assertTrue(removed(device),device)
  for device in ('NDISWAN','DLC','USOSX','IPXODI'):self.assertFalse(removed(device),device)
  # Main batch: NetClient export, both classes scanned, never 0009, before
  # NETCLN.REG queues the cleanup and only after the import checks.
  self.assertIn('IF NOT EXIST C:\\USOS9X\\NET\\NETCLID.BAT GOTO FAIL\r\n',s)
  self.assertIn('IF EXIST C:\\USOS9X\\NL5.REG GOTO FAIL\r\n',s)
  export=s.index('/E C:\\USOS9X\\NL5.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\NetClient\r\n')
  calls=re.findall(r'FIND\.EXE /I "(NetTrans|NetClient)\\(\d{4})\]" C:\\USOS9X\\(NL[35])\.REG > NUL\r\nIF NOT ERRORLEVEL 1 CALL C:\\USOS9X\\NET\\NETCLID\.BAT (\w+) (\d{4})\r\n',s)
  self.assertEqual(len(calls),30)
  for klass,n,nl,k2,n2 in calls:
   self.assertEqual((klass,n),(k2,n2));self.assertEqual(nl,'NL3' if klass=='NetTrans' else 'NL5');self.assertNotEqual(n,'0009')
  for n in ('0000','0003','0008','0010','0015'):
   self.assertIn(f'NETCLID.BAT NetTrans {n}\r\n',s);self.assertIn(f'NETCLID.BAT NetClient {n}\r\n',s)
  self.assertLess(s.index('"NetClient\\\\0009" C:\\USOS9X\\NL4.REG'),export)
  self.assertLess(s.index('NETCLID.BAT NetClient 0015'),s.index('NET\\NETCLN.REG\r\n'))

 def test_original_dos_line_limits_and_complete_unique_labels(self):
  for batch in self.create():
   self.assertEqual(batch.count(b'\n'),batch.count(b'\r\n'))
   self.assertLessEqual(max(map(len,batch.split(b'\r\n'))),125)
   s=batch.decode('ascii');labels=re.findall(r'^:([A-Z0-9]+)\r?$',s,re.M)
   self.assertEqual(len(labels),len(set(labels)))
   self.assertTrue(all(len(label)<=8 for label in labels))
   self.assertFalse(set(re.findall(r'GOTO ([A-Z0-9]+)',s))-set(labels))

if __name__=='__main__':unittest.main()
