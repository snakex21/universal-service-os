"""Original NT4 TCPCFG validator in bounded x86 RAM emulation, synthetic inputs.

Needs pefile, unicorn and the original PL CD at USOS_NT4_PL_ISO (or the known
local media path). Expanded Microsoft bytes stay in RAM. A short-lived
compressed input for 7-Zip is kept only in the owned G: collection audit area.
"""
from pathlib import Path
import importlib.util,os,struct,unittest,hashlib,types,tempfile,subprocess
import pefile
from unicorn import Uc,UC_ARCH_X86,UC_MODE_32,UC_HOOK_CODE
from unicorn.x86_const import UC_X86_REG_EAX,UC_X86_REG_ESP,UC_X86_REG_EIP
ROOT=Path(__file__).resolve().parents[2]
EXPECTED='adbda98abbaf38f8272c28c312ffff559f023a8465f68e6f15b1c3cc4d424ad2'
ISO=Path(os.environ.get('USOS_NT4_PL_ISO',r'C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows\Windows NT 4.0\Windows NT 4.0 Workstation PL.iso'))
def expand(data):
 if not data.startswith((b'MSCF',b'SZDD')):raise ValueError('Original compressed-module contract')
 scratch=Path(r'G:\USOS-Kolekcja\_audit\nt4-native-tcpip-test')
 if scratch.resolve()!=scratch:raise ValueError('Exact owned compressed-input boundary')
 scratch.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='input-',dir=scratch) as folder:
  path=Path(folder)/'input.cab';path.write_bytes(data)
  result=subprocess.run([r'C:\Program Files\7-Zip\7z.exe','x','-so',str(path)],capture_output=True,timeout=30,creationflags=subprocess.CREATE_NO_WINDOW)
  if result.returncode or not 64<=len(result.stdout)<=2*1024**2:raise ValueError('Bounded original expansion failed')
  return result.stdout
def original():
 spec=importlib.util.spec_from_file_location('own_original_media',ROOT/'tools/windows_media_facts.py');media=importlib.util.module_from_spec(spec);spec.loader.exec_module(media)
 with ISO.open('rb') as stream:
  volume=media.ISO(stream);blob=expand(volume.read('i386/tcpcfg.dl_'))
 if hashlib.sha256(blob).hexdigest()!=EXPECTED:raise ValueError('Original TCPCFG hash pin')
 p=pefile.PE(data=blob);imports={x.address:entry.dll.decode('ascii')+'!'+x.name.decode('ascii') for entry in p.DIRECTORY_ENTRY_IMPORT for x in entry.imports if x.name}
 return types.SimpleNamespace(base=p.OPTIONAL_HEADER.ImageBase,p=p,blob=blob,imports=imports)
_original=None
def native(value):
 global _original
 if _original is None:_original=original()
 a=_original
 uc=Uc(UC_ARCH_X86,UC_MODE_32);uc.mem_map(a.base,a.p.OPTIONAL_HEADER.SizeOfImage);uc.mem_write(a.base,a.p.get_memory_mapped_image());uc.mem_map(0x100000,0x10000);uc.mem_map(0x200000,0x10000);uc.mem_map(0x300000,0x1000)
 uc.mem_write(0x100000,(value+'\0').encode('utf-16le'));stack=0x208000;uc.mem_write(stack,struct.pack('<II',0x300100,0x100000));uc.reg_write(UC_X86_REG_ESP,stack);context={'next':None,'stopped':False};stubs={}
 for index,name in enumerate(('wcslen','wcscpy','wcstok','wcsspn','_wtoi')):
  sites=[addr for addr,imp in a.imports.items() if imp=='MSVCRT.dll!'+name]
  if len(sites)!=1:raise ValueError('Exact native CRT import contract')
  address=0x300000+16*index;stubs[address]=name;uc.mem_write(sites[0],struct.pack('<I',address))
 def word(address):return struct.unpack('<I',uc.mem_read(address,4))[0]
 def wide(address):
  if not (0x100000<=address<0x110000 or 0x200000<=address<0x210000 or a.base<=address<a.base+a.p.OPTIONAL_HEADER.SizeOfImage):raise ValueError('Synthetic string pointer bound')
  out=[]
  for index in range(32):
   c=struct.unpack('<H',uc.mem_read(address+2*index,2))[0]
   if c==0:return ''.join(out)
   out.append(chr(c))
  raise ValueError('Synthetic string length bound')
 def hook(uc,address,size,unused):
  if address==0x300100:context['stopped']=True;uc.emu_stop();return
  if a.base+0x11562<=address<a.base+0x11629:return
  if address not in stubs:raise ValueError('Execution outside exact native validator and CRT stubs')
  esp=uc.reg_read(UC_X86_REG_ESP);ret=word(esp);p=word(esp+4);name=stubs[address]
  if name=='wcslen':result=len(wide(p))
  elif name=='wcscpy':uc.mem_write(p,(wide(word(esp+8))+'\0').encode('utf-16le'));result=p
  elif name=='wcsspn':
   allowed=wide(word(esp+8));result=0
   for c in wide(p):
    if c not in allowed:break
    result+=1
  elif name=='_wtoi':result=int(wide(p) or '0')
  else:
   if wide(word(esp+8))!='.':raise ValueError('Original delimiter contract')
   cursor=p or context['next'];result=0
   if cursor:
    text=wide(cursor);skip=len(text)-len(text.lstrip('.'));cursor+=2*skip;text=text[skip:]
    if text:
     result=cursor;end=text.find('.')
     if end>=0:uc.mem_write(cursor+2*end,b'\0\0');context['next']=cursor+2*(end+1)
     else:context['next']=None
    else:context['next']=None
  uc.reg_write(UC_X86_REG_EAX,result);uc.reg_write(UC_X86_REG_ESP,esp+4);uc.reg_write(UC_X86_REG_EIP,ret)
 uc.hook_add(UC_HOOK_CODE,hook);uc.emu_start(a.base+0x11562,0x300101,count=10000)
 if not context['stopped']:raise ValueError('Native validator instruction bound')
 return uc.reg_read(UC_X86_REG_EAX)!=0
class NativeValidator(unittest.TestCase):
 def test_old_staging_address_is_rejected(self):self.assertFalse(native('192.0.2.1'))
 def test_new_staging_address_is_accepted(self):self.assertTrue(native('198.51.100.1'))
 def test_every_later_zero_octet_is_rejected(self):
  for value in ('198.0.100.1','198.51.0.1','198.51.100.0'):self.assertFalse(native(value))
 def test_boundaries_and_invalid_syntax(self):
  for value in ('0.1.1.1','224.1.1.1','198.51.100.256','198.51.100','198.x.100.1'):self.assertFalse(native(value))
if __name__=='__main__':unittest.main(verbosity=2)
