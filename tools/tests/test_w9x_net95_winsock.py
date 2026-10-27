"""Host contract for 950 TCP/IP global registration, separate from binding."""
from pathlib import Path
import re,shutil,sys,unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh,scratch
from test_w9x_reg95 import ANSWER_95,REG95
from test_w9x_net95_files import osr2_setup_folder
ROOT=Path(__file__).resolve().parents[2]

class TcpGlobals(unittest.TestCase):
 def create(self,version='4 0 0 950',network=True):
  tmp=scratch('tcp95-');self.addCleanup(shutil.rmtree,tmp,ignore_errors=True)
  out=tmp/'USOS9X';(out/'NET').mkdir(parents=True)
  inf=tmp/'MSBATCH.INF';inf.write_bytes(ANSWER_95.encode('ascii'))
  net=out/'NET/NET95.REG'
  body='REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_8086&DEV_10C9\\BUS_00&DEV_03&FUNC_00]\r\n"Driver"="Net\\\\0009"\r\n'
  if network:net.write_bytes(body.encode('ascii'))
  src=osr2_setup_folder(tmp).as_posix() if version not in ('4 0 0 950','') else ''
  rc,so,err=sh(f'. "{REG95}"\nw9x_reg95_write "{out.as_posix()}" "{inf.as_posix()}" "" "" "{net.as_posix() if network else ""}" "{version}" "" "{src}"\n')
  self.assertEqual(rc,0,so+err)
  if network:self.assertEqual(net.read_bytes(),body.encode('ascii'))
  tcp=out/'NET/TCP95.REG'
  return tcp.read_bytes() if tcp.exists() else None,(out/'REG95.REG').read_bytes()

 def test_exact_scope_keeps_other_versions_and_no_network_unchanged(self):
  self.assertIsNotNone(self.create()[0])
  for v,n in [('',True),('4 0 0 950',False),('4 0 0 1111',False)]:
   tcp,merged=self.create(v,n);self.assertIsNone(tcp)
   self.assertNotIn(b'Ancillary Function Driver for Winsock',merged)
  # OSR2: the same companion, imported late by NET95L.BAT, not merged.
  for v in ('4 0 0 1068','4 0 0 1111'):
   tcp,merged=self.create(v);self.assertEqual(tcp,self.create()[0])
   self.assertNotIn(b'Ancillary Function Driver for Winsock',merged)

 def test_ip_socket_helper_and_provider_are_registered(self):
  tcp,_=self.create();s=tcp.decode('ascii')
  self.assertIn('"Ancillary Function Driver for Winsock"="afvxd.vxd"',s)
  self.assertIn('"MSTCP Helper for Winsock"="wshtcp.vxd"',s)
  self.assertIn('"MaxSockAddrLength"=hex:10,00,00,00',s)
  self.assertIn('"MinSockAddrLength"=hex:10,00,00,00',s)
  self.assertIn('"HelperDllName"="%windir%\\\\system\\\\wsock32.dll"',s)
  self.assertIn('Services\\Winsock\\Parameters]\r\n"MSTCP"=""',s)
  self.assertIn('ServiceProvider\\Order\\ProviderOrder]\r\n"MSTCP"=""',s)

 def test_resolver_order_and_rpc_match_original_950_contract(self):
  tcp,_=self.create();s=tcp.decode('ascii')
  for name,value in [('LocalPriority','f3,01'),('HostsPriority','f4,01'),('DnsPriority','d0,07'),('NetbtPriority','d1,07')]:
   self.assertIn(f'"{name}"=hex:{value},00,00',s)
  self.assertIn('"ProviderPath"="%windir%\\\\system\\\\wsock32.dll"',s)
  self.assertIn('"ncacn_ip_tcp"="rpcltc3.dll"',s)
  self.assertIn('"ncacn_ip_tcp"="rpclts3.dll"',s)

 def test_companion_is_in_merged_import_before_trailing_comments(self):
  tcp,merged=self.create()
  self.assertIn(tcp.split(b'REGEDIT4\r\n',1)[1],merged)
  self.assertEqual(merged.count(b'REGEDIT4'),1)
  self.assertLess(merged.index(b'HelperDllName'),merged.index(b'; USOS: not converted'))

 def test_globals_have_no_adapters_addresses_or_extra_components(self):
  tcp,_=self.create();s=tcp.decode('ascii')
  self.assertEqual(tcp.count(b'\n'),tcp.count(b'\r\n'))
  self.assertEqual(len(re.findall(r'^".*"=',s,re.M)),16)
  self.assertTrue(all(k.startswith('HKEY_LOCAL_MACHINE\\') for k in re.findall(r'^\[(.*)\]',s,re.M)))
  for unwanted in ('Enum\\','Class\\Net','IPAddress','EnableDNS','DialUp','VSERVER','NWLINK','NETBEUI','APPDATA'):
   self.assertNotIn(unwanted,s)

if __name__=='__main__':unittest.main()
