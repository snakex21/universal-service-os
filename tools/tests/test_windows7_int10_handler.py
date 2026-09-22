"""Bounded CPU-level regression checks; no firmware, VM, OS or disk image boot."""
from pathlib import Path
import json, struct, unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16
from unicorn.x86_const import *

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'zig-out/windows7-int10-patch'
NEW=(OUT/'handler.bin').read_bytes()
INFO=json.loads((OUT/'manifest.json').read_text())
EFI=(ROOT/'tools/vendor/uefiseven/1.30/UefiSeven.efi').read_bytes()
OLD=EFI[INFO['handler_offset']:INFO['handler_offset']+INFO['original_handler_size']]

def execute(code, ax, bx=0x1234, cx=0x3456):
    cpu=Uc(UC_ARCH_X86, UC_MODE_16)
    cpu.mem_map(0,0x100000)
    cpu.mem_write(0xc0000,code)
    tables=bytes(range(256))+bytes(reversed(range(256)))
    cpu.mem_write(0xc0000,tables)
    regs={UC_X86_REG_CS:0xc000,UC_X86_REG_IP:0x200,UC_X86_REG_SS:0x8000,
          UC_X86_REG_SP:0xffe0,UC_X86_REG_AX:ax,UC_X86_REG_BX:bx,UC_X86_REG_CX:cx,
          UC_X86_REG_DX:0x4567,UC_X86_REG_SI:0x5678,UC_X86_REG_DI:0x20,
          UC_X86_REG_BP:0x6789,UC_X86_REG_DS:0x6000,UC_X86_REG_ES:0x7000,
          UC_X86_REG_EFLAGS:0x602}
    for reg,value in regs.items():cpu.reg_write(reg,value)
    cpu.mem_write(0x8ffe0,struct.pack('<HHH',0x1000,0,0x602))
    cpu.emu_start(0xc0200,0x1000,count=1500)
    return cpu,regs,tables

class Int10Tests(unittest.TestCase):
    def assert_return(self,ax,bx,cx,expected,new_bx=None):
        cpu,regs,tables=execute(NEW,ax,bx,cx)
        self.assertEqual((cpu.reg_read(UC_X86_REG_CS),cpu.reg_read(UC_X86_REG_IP)),(0,0x1000))
        self.assertEqual(cpu.reg_read(UC_X86_REG_SP),0xffe6)
        self.assertEqual(cpu.reg_read(UC_X86_REG_AX),expected)
        self.assertEqual(cpu.reg_read(UC_X86_REG_EFLAGS)&0xffff,0x602)
        for reg in [UC_X86_REG_CX,UC_X86_REG_DX,UC_X86_REG_SI,UC_X86_REG_DI,UC_X86_REG_BP,UC_X86_REG_DS,UC_X86_REG_ES,UC_X86_REG_SS]:
            self.assertEqual(cpu.reg_read(reg),regs[reg])
        self.assertEqual(cpu.reg_read(UC_X86_REG_BX),bx if new_bx is None else new_bx)
        return cpu,tables
    def test_unsupported_requests_return_with_intact_stack(self):
        for ax,bx,cx in [(0x4f99,0,0),(0x4f01,0,0x118),(0x4f02,0x4118,0),(0x0013,0,0),
                         (0x0f00,0,0),(0x4f10,0,0),(0x4f15,0,0),(0x4f02,0x80f1,0),
                         (0x4f02,0x48f1,0),(0x4f01,0,0xffff)]:
            with self.subTest(ax=ax,bx=bx,cx=cx):self.assert_return(ax,bx,cx,0x014f)
    def test_valid_modes_and_preserve_framebuffer_flag(self):
        for bx in [0x40f1,0xc0f1]:self.assert_return(0x4f02,bx,0x3456,0x004f)
        self.assert_return(0x4f03,0x1234,0x3456,0x004f,0x40f1)
        self.assert_return(0x0003,0x1234,0x3456,0x0030)
        self.assert_return(0x0012,0x1234,0x3456,0x0020)
    def test_controller_and_mode_information_copy(self):
        for ax,cx,offset in [(0x4f00,0x3456,0),(0x4f01,0xf1,256),(0x4f01,0x40f1,256)]:
            cpu,tables=self.assert_return(ax,0x1234,cx,0x004f)
            self.assertEqual(cpu.mem_read(0x70020,256),tables[offset:offset+256])
    def test_upstream_reproduces_hangs_for_fixed_inputs(self):
        for ax,bx,cx in [(0x4f99,0,0),(0x4f01,0,0x118),(0x4f02,0xc0f1,0),(0x0013,0,0)]:
            cpu,_,_=execute(OLD,ax,bx,cx)
            self.assertNotEqual((cpu.reg_read(UC_X86_REG_CS),cpu.reg_read(UC_X86_REG_IP)),(0,0x1000))

if __name__=='__main__':unittest.main()
