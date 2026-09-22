"""Execute the real-mode hook against a BIOS surrogate; no real disks."""
from pathlib import Path
import os,struct,subprocess,sys,unittest
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'zig-out/int13-python'))
from unicorn import Uc,UC_ARCH_X86,UC_MODE_16,UC_HOOK_CODE
from unicorn.x86_const import *
OUT=ROOT/'zig-out/windows-disk-order'

def build():
 OUT.mkdir(exist_ok=True)
 env=os.environ.copy();env['ZIG_GLOBAL_CACHE_DIR']=str(ROOT/'tools/cache/zig-global');env['ZIG_LOCAL_CACHE_DIR']=str(OUT/'cache')
 zig=str(ROOT/'tools/zig/zig.exe')
 subprocess.run([zig,'cc','-target','x86-freestanding-none','-mcpu=i386','-c',str(ROOT/'src/platform/bios/windows_disk_order.S'),'-o',str(OUT/'hook.o')],env=env,check=True)
 subprocess.run([zig,'objcopy','-O','binary','-j','.rodata.windows_disk_order',str(OUT/'hook.o'),str(OUT/'hook.bin')],env=env,check=True)
 return (OUT/'hook.bin').read_bytes()

class DiskOrder(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.blob=build();assert len(cls.blob)==512
 def vm(self,boot=0x80,count=2):
  u=Uc(UC_ARCH_X86,UC_MODE_16);u.mem_map(0,0x100000)
  blob=bytearray(self.blob);blob[0x1fa]=boot;struct.pack_into('<H',blob,0x1fc,0x300)
  u.mem_write(0x90400,bytes(blob));u.mem_write(0x90300,b'\xf4')
  u.mem_write(0x475,bytes([count]));u.mem_write(0x4c,struct.pack('<HH',0,0xf000))
  u.reg_write(UC_X86_REG_CS,0x9000);u.reg_write(UC_X86_REG_DS,0x9000);u.reg_write(UC_X86_REG_ES,0x9000)
  u.reg_write(UC_X86_REG_SS,0x8000);u.reg_write(UC_X86_REG_SP,0xf000)
  trace=[]
  tracehook=u.hook_add(UC_HOOK_CODE,lambda uc,a,s,d:trace.append((hex(a),bytes(uc.mem_read(a,s)).hex())))
  try:u.emu_start(0x90400,0x90300,count=10000)
  except Exception:
   print(trace[-12:]);raise
  u.hook_del(tracehook)
  self.assertEqual(u.reg_read(UC_X86_REG_DS),0x9000)
  self.assertEqual(u.reg_read(UC_X86_REG_ES),0x9000)
  self.assertEqual(u.reg_read(UC_X86_REG_CS),0x9000)
  self.assertEqual(u.reg_read(UC_X86_REG_SP),0xf000)
  for interrupt in (0x10,0x15,0x16,0x1a):
   self.assertEqual(bytes(u.mem_read(interrupt*4,4)),bytes(4),'Production must not install BIOS diagnostic wrappers')
  return u
 def call(self,u,drive,fn,carry=False):
  calls=[]
  def firmware(uc,address,size,data):
   if address!=0xf0000:return
   calls.append((uc.reg_read(UC_X86_REG_DX)&255,uc.reg_read(UC_X86_REG_AX)>>8))
   if fn==8:uc.reg_write(UC_X86_REG_DX,0xfe03)
   if fn==0x15:uc.reg_write(UC_X86_REG_DX,0x1234)
   sp=uc.reg_read(UC_X86_REG_SP);ss=uc.reg_read(UC_X86_REG_SS)*16
   flags=struct.unpack('<H',uc.mem_read(ss+sp+4,2))[0]
   uc.mem_write(ss+sp+4,struct.pack('<H',(flags&~1)|int(carry)))
  hook=u.hook_add(UC_HOOK_CODE,firmware);u.mem_write(0xf0000,b'\xcf')
  vector=struct.unpack('<HH',u.mem_read(0x4c,4))
  u.reg_write(UC_X86_REG_CS,vector[1]);u.reg_write(UC_X86_REG_SS,0x8000);u.reg_write(UC_X86_REG_SP,0xeffa)
  u.mem_write(0x8effa,struct.pack('<HHH',0,0x7000,0x202))
  u.reg_write(UC_X86_REG_AX,fn<<8);u.reg_write(UC_X86_REG_DX,drive)
  u.emu_start(vector[1]*16+vector[0],0x70000,count=10000)
  u.hook_del(hook)
  self.assertEqual(u.reg_read(UC_X86_REG_SP),0xf000)
  self.assertEqual(u.reg_read(UC_X86_REG_EFLAGS)&0x201,0x200|int(carry))
  return calls,u.reg_read(UC_X86_REG_DX)
 def test_two_drives_swap_without_changing_returned_drive(self):
  u=self.vm()
  for drive,want in [(0x80,0x81),(0x81,0x80),(0x82,0x82),(0,0),(0xe0,0xe0)]:
   calls,dx=self.call(u,drive,0x42);self.assertEqual(calls,[(want,0x42)]);self.assertEqual(dx,drive)
 def test_three_drives_preserve_internal_order(self):
  u=self.vm(count=3)
  for drive,want in [(0x80,0x81),(0x81,0x82),(0x82,0x80),(0x83,0x83)]:
   self.assertEqual(self.call(u,drive,0x48)[0],[(want,0x48)])
 def test_geometry_size_and_error_results_are_preserved(self):
  u=self.vm()
  self.assertEqual(self.call(u,0x80,8)[1],0xfe03)
  self.assertEqual(self.call(u,0x80,0x15)[1],0x1234)
  self.call(u,0x80,0x42,True)
 def test_nonleading_usb_and_invalid_counts_do_not_install_hook(self):
  for boot,count in [(0x81,2),(0x82,3),(0x80,1),(0x80,0),(0x80,17)]:
   u=self.vm(boot,count);self.assertEqual(bytes(u.mem_read(0x4c,4)),struct.pack('<HH',0,0xf000))

if __name__=='__main__':unittest.main()
