"""Execute actual pure NT35 metadata parser; never run posthelper on host."""
from pathlib import Path
import os,re,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
class Metadata(unittest.TestCase):
 def test_compiled_parser_real_body(self):
  source=(ROOT/'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8');body=re.search(r'static int net35_decimal\(.*?\n\}',source,re.S).group()
  prefix='#include <stdint.h>\n#include <string.h>\ntypedef uint32_t DWORD;\nstatic int len(const char *s){return (int)strlen(s);}\n'
  main=r'''
int main(void){
 const char *bad[]={"", "bus=256\n", "bus=-1\n", "bus=1x\n", "bus=1\nbus=2\n", "bus=0255\n", "Bus=\n", "slot=3\n"};
 unsigned i;DWORD out=0xdeadbeef;
 if(!net35_decimal("bus=0\r\nslot=35\r\n","bus",&out) || out!=0)return 1;
 if(!net35_decimal("bus=0\r\nslot=35\r\n","slot",&out) || out!=35)return 2;
 if(!net35_decimal("BUS=255\r\n","bus",&out) || out!=255)return 3;
 for(i=0;i<sizeof(bad)/sizeof(bad[0]);i++){
  out=0xdeadbeef;if(net35_decimal(bad[i],"bus",&out) || out!=0xdeadbeef)return 10+i;
 }
 return 0;
}
'''
  parent=ROOT/'artifacts/nt35-network/post-tests';parent.mkdir(parents=True,exist_ok=True)
  with tempfile.TemporaryDirectory(dir=parent) as temp:
   d=Path(temp);c=d/'parser.c';c.write_text(prefix+body+main,encoding='utf-8');exe=d/'parser.exe';env=dict(os.environ,TEMP=str(d),TMP=str(d))
   r=subprocess.run(['C:/msys64/mingw64/bin/gcc.exe','-std=c99','-Wall','-Werror',str(c),'-o',str(exe)],capture_output=True,text=True,env=env);self.assertEqual(r.returncode,0,r.stdout+r.stderr)
   r=subprocess.run([str(exe)],capture_output=True,text=True,env=env);self.assertEqual(r.returncode,0,r.stdout+r.stderr)
 def test_only_nt35_commits_driver_after_verified_binding_and_bus(self):
  source=(ROOT/'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8');body=source[source.index('static int nt35_network(void)'):source.index('static void display_profile(void)')]
  self.assertIn('!meta_len || meta_len>=sizeof meta-1',body);self.assertIn('((version >> 8) & 0xff) != 50)',body)
  self.assertLess(body.index('!net351_has_binding(linkage)'),body.index('CopyFileA('))
  for key in ('BusNumber','UsosPciSlot'):
   self.assertLess(body.index('net351_dword(params,"'+key+'"'),body.index('RegSetValueExA(svc,"ImagePath"'))
if __name__=='__main__':unittest.main()