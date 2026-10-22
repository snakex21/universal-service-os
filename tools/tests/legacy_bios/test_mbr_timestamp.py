"""Build all three real MBRs and execute them after disk-timestamp damage."""
from pathlib import Path
import os,struct,subprocess,unittest
from unicorn import Uc,UC_ARCH_X86,UC_MODE_16,UC_HOOK_CODE,UC_HOOK_INTR
from unicorn.x86_const import UC_X86_REG_AX,UC_X86_REG_BX,UC_X86_REG_CX,UC_X86_REG_DX,UC_X86_REG_SI,UC_X86_REG_EFLAGS

ROOT=Path(__file__).resolve().parents[3]
import sys
sys.path.insert(0,str(ROOT/'tools/tests'))
import depguard
OUT=ROOT/'zig-out/mbr-timestamp'
ZIG=Path(os.environ.get('USOS_ZIG',str(ROOT/'tools/zig/zig.exe')))

def build(name,section):
    depguard.require_zig()
    OUT.mkdir(parents=True,exist_ok=True)
    env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'zig-out/zig-global'))
    elf=OUT/(name+'.elf');binary=OUT/(name+'.bin')
    cmd=[str(ZIG),'cc','-target','x86-freestanding-none','-nostdlib','-nodefaultlibs']
    if name=='stage1':cmd+=['-Wl,-T,'+str(ROOT/'src/platform/bios/boot_sector.ld'),'-Wl,--entry=stage1_start']
    else:cmd+=['-c']
    subprocess.run(cmd+[str(ROOT/('src/platform/bios/'+name+'.S')),'-o',str(elf)],check=True,env=env)
    subprocess.run([str(ZIG),'objcopy','-O','binary','-j',section,str(elf),str(binary)],check=True,env=env)
    return binary.read_bytes()

class MBRTimestamp(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.images={name:build(name,section) for name,section in [('stage1','.text'),('dos_target_mbr','.rodata.dos_mbr'),('dos_source_mbr','.rodata.dos_source_mbr')]}

    def execute(self,name,pattern,fail=False):
        code=bytearray(self.images[name]);self.assertEqual(code[0xda:0xe0],b'\0'*6)
        code=code.ljust(512,b'\0');code[0xda:0xe0]=pattern;struct.pack_into('<I',code,454,2048)
        u=Uc(UC_ARCH_X86,UC_MODE_16);u.mem_map(0,0x200000);u.mem_write(0x7c00,bytes(code));u.reg_write(UC_X86_REG_DX,0x80)
        reads=[];reached=[];halted=[]
        def instruction(uc,address,size,data):
            for start in (0x7cda,0x6da):self.assertFalse(address<start+6 and address+size>start,'timestamp executed')
            if name=='stage1' and address==0x10040:reached.append(address);uc.emu_stop()
            if name!='stage1' and reads and address==0x7c00:reached.append(address);uc.emu_stop()
            if bytes(uc.mem_read(address,1))==b'\xf4':halted.append(address);uc.emu_stop()
        def interrupt(uc,number,data):
            if number==0x10:return
            self.assertEqual(number,0x13);ah=uc.reg_read(UC_X86_REG_AX)>>8
            uc.reg_write(UC_X86_REG_EFLAGS,(uc.reg_read(UC_X86_REG_EFLAGS)&~1)|int(fail))
            if ah==0x41:uc.reg_write(UC_X86_REG_BX,0xaa55);uc.reg_write(UC_X86_REG_CX,1);return
            self.assertEqual(ah,0x42)
            dap=bytes(uc.mem_read(uc.reg_read(UC_X86_REG_SI),16));reads.append(dap)
            if name=='stage1':
                self.assertEqual(struct.unpack_from('<H',dap,2)[0],32);self.assertEqual(struct.unpack_from('<Q',dap,8)[0],64)
            else:
                self.assertEqual(struct.unpack_from('<Q',dap,8)[0],2048 if name=='dos_target_mbr' else 0)
                sector=bytearray(512);sector[0]=0xf4;sector[510:]=b'\x55\xaa';uc.mem_write(0x7c00,bytes(sector))
        u.hook_add(UC_HOOK_CODE,instruction);u.hook_add(UC_HOOK_INTR,interrupt)
        u.emu_start(0x7c00,0x200000,count=10000)
        if fail:self.assertTrue(halted);self.assertFalse(reached)
        else:self.assertEqual(len(reads),1);self.assertEqual(len(reached),1)

    def test_timestamp_is_unused_on_success_and_failure_paths(self):
        for name in self.images:
            for pattern in (b'\0'*6,b'\xff'*6,bytes.fromhex('80 12 34 56 78 9a'),b'\xeb\xfe\xfa\xf4\xcd\x19'):
                for fail in (False,True):
                    with self.subTest(image=name,pattern=pattern.hex(),fail=fail):self.execute(name,pattern,fail)

if __name__=='__main__':unittest.main()
