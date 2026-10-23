"""Answer-derived Windows95 VNETSUP identity, limited to the 950 NET95 path."""
from pathlib import Path
import shutil,sys,unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh,scratch
from test_w9x_reg95 import ANSWER_95,REG95
ROOT=Path(__file__).resolve().parents[2]
NET=(ROOT/'tools/network_setup.sh').as_posix()

class Identity(unittest.TestCase):
 def create(self,extra='',version='4 0 0 950',net=True):
  folder=scratch('netidentity-');self.addCleanup(shutil.rmtree,folder,ignore_errors=True)
  target=folder/'USOS9X';(target/'NET').mkdir(parents=True)
  answer=folder/'ANSWER.INF';answer.write_bytes((ANSWER_95+'\n'+extra).encode('ascii'))
  registry=target/'NET/NET95.REG'
  script=f'. "{NET}"\n. "{REG95}"\n'
  if net:script+=f"usos_net_w95_reg 'PCI\\VEN_8086&DEV_10C9' 'BUS_00&DEV_03&FUNC_00' '82576' USOSNET82576.ndi 03 > '{registry.as_posix()}'\n"
  script+=f"w9x_reg95_write '{target.as_posix()}' '{answer.as_posix()}' '' '' '{registry.as_posix() if net else ''}' '{version}'\n"
  rc,out,err=sh(script,{});self.assertEqual(rc,0,out+err)
  data=(target/'REG95.REG').read_bytes();self.assertEqual(data.count(b'\n'),data.count(b'\r\n'))
  return data.decode('ascii')
 def test_uses_answer_values_and_strings(self):
  text=self.create('[Network]\nComputerName="%host%"\nWorkgroup="CUSTOMGROUP"\nDescription="Lab, One; Two"\n[Strings]\nhost="CUSTOM-PC"\n')
  self.assertIn('[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\VxD\\VNETSUP]',text)
  for line in ('"ComputerName"="CUSTOM-PC"','"Workgroup"="CUSTOMGROUP"','"Comment"="Lab, One; Two"'):self.assertIn(line,text)
 def test_only_static_950_path_seeds_identity(self):
  answer='[Network]\nComputerName="CUSTOM-PC"\nWorkgroup="CUSTOMGROUP"\n'
  for version,net in [('4 0 0 1068',True),('4 0 0 1111',True),('',True),('4 0 0 950',False)]:
   self.assertNotIn('VNETSUP',self.create(answer,version,net),(version,net))
 def test_no_missing_or_empty_identity_defaults(self):
  self.assertNotIn('VNETSUP',self.create())
  text=self.create('[Network]\nComputerName=""\nWorkgroup=\nDescription=""\n')
  self.assertNotIn('"ComputerName"=',text);self.assertNotIn('"Workgroup"=',text);self.assertIn('"Comment"=""',text)
 def test_quoted_description_preserves_safe_registry_escaping(self):
  text=self.create('[Network]\nComputerName="CUSTOM-PC"\nWorkgroup="CUSTOMGROUP"\nDescription="Owner ""quoted""\\lab" ; outside comment\n')
  self.assertIn(r'"Comment"="Owner \"quoted\"\\lab"',text);self.assertNotIn('outside comment',text)
 def test_other_sections_do_not_supply_identity(self):
  text=self.create('[Unrelated]\nComputerName="WRONG-PC"\nWorkgroup="WRONGGROUP"\n')
  self.assertNotIn('VNETSUP',text);self.assertNotIn('WRONG-PC',text);self.assertNotIn('WRONGGROUP',text)
 def test_comments_and_keys_are_case_insensitive(self):
  text=self.create('[nEtWoRk]\n  cOmPuTeRnAmE = "CUSTOM-PC" ; trailing\n  wOrKgRoUp = CUSTOMGROUP\n')
  self.assertIn('"ComputerName"="CUSTOM-PC"',text);self.assertIn('"Workgroup"="CUSTOMGROUP"',text)

if __name__=='__main__':unittest.main()
