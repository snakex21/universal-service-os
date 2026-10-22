"""Execute the NT4 fork's real registry fallback C with synthetic read-only APIs."""
from pathlib import Path
import importlib.util,os,re,shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'tools/nt4/usoslog/src'
s=importlib.util.spec_from_file_location('own_logger_network_shim',ROOT/'tools/tests/usability/test_logger_network.py');base=importlib.util.module_from_spec(s);s.loader.exec_module(base)
class GlobalDNS(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  scratch=ROOT/'artifacts/nt4-logger-global-dns-host';scratch.mkdir(parents=True,exist_ok=True)
  cls.tmp=tempfile.TemporaryDirectory(dir=scratch);cls.addClassCleanup(cls.tmp.cleanup);work=Path(cls.tmp.name)
  source=(SRC/'usoslog.c').read_text(encoding='utf-8');ip=re.search(r'static DWORD ip_addr\([^\n]+\)\n\{.*?\n\}',source,re.S).group()
  mock=base.MOCKS.replace('if(strstr(p,"Tcpip\\\\Linkage"))', 'if(!strcmp(p,"System\\\\CurrentControlSet\\\\Services\\\\Tcpip\\\\Parameters")) { *out=(HKEY)3;return 0; }\n    if(strstr(p,"Tcpip\\\\Linkage"))')
  marker='    *type=REG_MULTI_SZ;'
  replacement=r'''
    if(k==(HKEY)3) {
        *type=REG_SZ;
        if(!strcmp(n,"NameServer")) s=!strcmp(mode,"config-global-static")?"10.0.2.4":"";
        else if(!strcmp(n,"DhcpNameServer")) {
            s="10.0.2.3";
            if(!strcmp(mode,"config-global-type")) *type=REG_BINARY;
            if(!strcmp(mode,"config-global-large")) { *size=4096;return 0; }
            if(!strcmp(mode,"config-global-multi")) { *type=REG_MULTI_SZ;s="10.0.2.3\0" "1.1.1.1\0";length=sizeof("10.0.2.3\0" "1.1.1.1\0"); }
        } else return ERROR_FILE_NOT_FOUND;
        if(!length)length=(DWORD)strlen(s)+1;
        if(*size<length)return ERROR_MORE_DATA;
        memcpy(out,s,length);*size=length;return 0;
    }
    if(k==(HKEY)2 && !strcmp(n,"NameServer") && !strcmp(mode,"config-global-adapter")) {
        const char chosen[]="10.0.2.8";*type=REG_SZ;memcpy(out,chosen,sizeof(chosen));*size=sizeof(chosen);return 0;
    }
    if(k==(HKEY)2 && (!strcmp(n,"NameServer")||!strcmp(n,"DhcpNameServer")))return ERROR_FILE_NOT_FOUND;
    *type=REG_MULTI_SZ;'''
  if mock.count(marker)!=1:raise ValueError('Exact synthetic query insertion point')
  mock=mock.replace(marker,replacement).replace('nt_tcpip_config();ipstr(addr,gateway);','nt_tcpip_config();ipstr(addr,dns_cfg[0]);printf("DNS_FIRST=%s\\n",addr);ipstr(addr,gateway);')
  c=work/'global.c';c.write_text(base.SHIM+ip+'\n#include "usoslog_net.h"\n'+mock,encoding='utf-8')
  cls.exe=work/'global.exe';cc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
  subprocess.run([cc,'-std=c99','-Wall','-Wextra','-I',str(SRC),str(c),'-o',str(cls.exe)],check=True,capture_output=True,env=dict(os.environ,TEMP=str(work),TMP=str(work)))
 def case(self,mode):return subprocess.run([str(self.exe),mode],check=True,capture_output=True,text=True).stdout
 def test_actual_nt4_global_dhcp_location(self):
  out=self.case('config-global-dhcp');self.assertIn('DNS_FIRST=10.0.2.3',out);self.assertIn('dns_count=1',out)
 def test_static_global_and_existing_adapter_precedence(self):
  self.assertIn('DNS_FIRST=10.0.2.4',self.case('config-global-static'))
  self.assertIn('DNS_FIRST=10.0.2.8',self.case('config-global-adapter'))
 def test_multi_sz_and_wrong_type_or_oversize(self):
  self.assertIn('dns_count=2',self.case('config-global-multi'))
  for mode in ('config-global-type','config-global-large'):
   with self.subTest(mode=mode):self.assertIn('dns_count=0',self.case(mode))
if __name__=='__main__':unittest.main()
