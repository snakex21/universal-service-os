"""Actual NT35 binary import/ABI and compiled configured-PCI path tests."""
from pathlib import Path
import hashlib,importlib.util,json,os,re,subprocess,tempfile,unittest
import capstone,pefile
ROOT=Path(__file__).resolve().parents[2];DRV=ROOT/'tools/nt/usosnet'
spec=importlib.util.spec_from_file_location('nt351_checks',Path(__file__).with_name('test_usosnet351.py'));prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
CONTRACT=json.loads((Path(__file__).parent/'fixtures/nt35-ndis-contract.json').read_text())
class NT35Binary(prior.BuiltBinary):
 @classmethod
 def setUpClass(cls):
  cls.pe=pefile.PE(str(DRV/'bin/i386/usosnet35.sys'));cls.md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_32);cls.md.detail=True
  cls.base=cls.pe.OPTIONAL_HEADER.ImageBase;cls.iat={i.address:i.name.decode() for m in cls.pe.DIRECTORY_ENTRY_IMPORT for i in m.imports}
  cls.code=[i for section in cls.pe.sections if section.Characteristics&0x20000000 for i in cls.md.disasm(section.get_data(),cls.base+section.VirtualAddress)]
 test_only_original_ndis351_exports=None
 def test_only_original_ndis35_exports(self):
  self.assertEqual(CONTRACT['ndis_sha256'],'fa392210418f6a5977ea8117d49b4d6a0b4cfc7d4fcc436fca2e3defdd6a5543')
  names=set()
  for m in self.pe.DIRECTORY_ENTRY_IMPORT:
   self.assertEqual(m.dll.lower(),b'ndis.sys')
   for i in m.imports:
    self.assertIsNotNone(i.name);name=i.name.decode();self.assertIn(name,CONTRACT['exports']);names.add(name)
  self.assertTrue(names.isdisjoint({'NdisPciAssignResources','NdisMPciAssignResources','NdisMQueryAdapterResources','NdisOverrideBusNumber'}))
  self.assertFalse(any('Timer' in n for n in names))
 def test_351_runtime_binary_unchanged(self):
  self.assertEqual(hashlib.sha256((DRV/'bin/i386/usosnet351.sys').read_bytes()).hexdigest(),'f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf')
class ExactConfiguredPci(unittest.TestCase):
 def test_compiled_actual_function(self):
  source=(DRV/'src/usosnet.c').read_text();body=re.search(r'static BOOLEAN ConfiguredFind35\(PADAPTER A, NDIS_HANDLE Cfg\)\n\{.*?\n\}',source,re.S).group()
  harness=r"""
#include <stdint.h>
#include <string.h>
#define FALSE 0
#define NULL ((void *)0)
#define NdisInterfacePci 5
#define NDIS_STRING_CONST(x) x
typedef uint32_t ULONG; typedef int BOOLEAN;typedef void *NDIS_HANDLE;typedef const char *NDIS_STRING;
typedef struct { void *Handle;ULONG PciBus,PciSlot; } ADAPTER,*PADAPTER;
static ULONG bus,slot,type,id,bytes;static int reads,bad;
static ULONG CfgInt(void *cfg,const char **key,ULONG fallback) {
 (void)fallback;if(cfg!=(void *)2)bad++;
 return !strcmp(*key,"BusNumber")?bus:!strcmp(*key,"UsosPciSlot")?slot:!strcmp(*key,"BusType")?type:0xffffffff;
}
static void UsLog(PADAPTER a,const char *fmt,ULONG b,ULONG s) {(void)a;(void)fmt;if(b!=bus || s!=slot)bad++;}
static ULONG NdisReadPciSlotInformation(void *h,ULONG s,ULONG off,void *data,ULONG n) {
 reads++;if(h!=(void *)1 || s!=slot || off || n!=4)bad++;*(ULONG *)data=id;return bytes;
}
static void *FindChip(ULONG value) {return value==0x10c98086?(void *)1:NULL;}
"""+body+r"""
int main(void){
 ADAPTER a={(void *)1,0,0};unsigned mode;
 for(mode=0;mode<8;mode++){
  bus=0;slot=3;type=5;id=0x10c98086;bytes=4;reads=bad=0;
  if(mode==1)bus=256;if(mode==2)bus=0xffffffff;if(mode==3)slot=256;
  if(mode==4)type=0;if(mode==5)bytes=2;if(mode==6)id=0xdeadbeef;
  if(ConfiguredFind35(&a,mode==7?NULL:(void *)2)!=(mode==0))return 10+mode;
  if(reads!=((mode==0 || mode==5 || mode==6)?1:0) || bad)return 30+mode;
 }
 return 0;
}
"""
  owned=ROOT/'artifacts/nt35-network/host-tests';owned.mkdir(parents=True,exist_ok=True)
  with tempfile.TemporaryDirectory(prefix='configured-',dir=owned) as temp:
   d=Path(temp);c=d/'configured.c';c.write_text(harness);exe=d/'configured.exe'
   env=dict(os.environ,TEMP=str(d),TMP=str(d))
   built=subprocess.run(['C:/msys64/mingw64/bin/gcc.exe','-std=c99','-Wall','-Werror','-Wno-misleading-indentation',str(c),'-o',str(exe)],capture_output=True,text=True,env=env)
   self.assertEqual(built.returncode,0,built.stdout+built.stderr)
   ran=subprocess.run([str(exe)],capture_output=True,text=True,env=env);self.assertEqual(ran.returncode,0,ran.stdout+ran.stderr)
if __name__=='__main__':unittest.main()
