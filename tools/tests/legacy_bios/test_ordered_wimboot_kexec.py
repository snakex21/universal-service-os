"""Run the combined real-mode entry and its two INT13 hooks; no real disks."""
from pathlib import Path
import struct,sys,unittest
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools'))
sys.path.insert(0,str(ROOT/'zig-out/int13-python'))
from wimboot_kexec import make_ordered_kexec_wimboot,build_disk_order,build_kexec_bridge,build_kexec_cpu_reset
from test_windows_disk_order import DiskOrder
from unicorn import Uc,UC_ARCH_X86,UC_MODE_16,UC_HOOK_INTR,UC_HOOK_CODE
from unicorn.x86_const import *

class OrderedEntry(unittest.TestCase):
    call=DiskOrder.call
    @classmethod
    def setUpClass(cls):
        cls.original=(ROOT/'tools/vendor/wimboot/2.9.0/wimboot').read_bytes()
        cls.image=make_ordered_kexec_wimboot(
            cls.original,
            build_disk_order(ROOT,ROOT/'zig-out/ordered-kexec-tests'),
            build_kexec_bridge(ROOT,ROOT/'zig-out/ordered-kexec-tests'),
            build_kexec_cpu_reset(ROOT,ROOT/'zig-out/ordered-kexec-tests'),
        )
    def vm(self,boot=0x80,count=2,ram_only=True):
        u=Uc(UC_ARCH_X86,UC_MODE_16);u.mem_map(0,0x100000)
        image=bytearray(self.image[:0xa00]);image[0x5fa]=boot
        if not ram_only:
            image[0x706]=0
        # Linux bzImage boot_params consumed by the INT15/e820 bridge.
        image[0x1e8]=2
        struct.pack_into('<QQI',image,0x2d0,0x00000000,0x0009f000,1)
        struct.pack_into('<QQI',image,0x2e4,0x00100000,0x1ff00000,1)
        continuation=struct.unpack_from('<H',image,0x5fc)[0]
        u.mem_write(0x90000,bytes(image));u.mem_write(0x475,bytes([count]))
        u.mem_write(0x4c,struct.pack('<HH',0,0xf000))
        for reg,val in ((UC_X86_REG_CS,0x9000),(UC_X86_REG_DS,0x9000),(UC_X86_REG_ES,0x9000),(UC_X86_REG_SS,0x8000),(UC_X86_REG_SP,0xf000)):
            u.reg_write(reg,val)
        interrupts=[]
        u.hook_add(UC_HOOK_INTR,lambda uc,n,data:interrupts.append(n))
        u.emu_start(0x90600,0x90000+continuation,count=20000)
        self.assertEqual(u.reg_read(UC_X86_REG_IP),continuation)
        self.assertEqual(interrupts,[0x10])
        self.assertEqual(u.reg_read(UC_X86_REG_SP),0xf000)
        self.assertEqual(u.reg_read(UC_X86_REG_DS),0x9000)
        self.assertEqual(u.reg_read(UC_X86_REG_ES),0x9000)
        return u
    def test_combined_entry_rotates_disks_and_preserves_read_errors(self):
        u=self.vm(ram_only=False)
        self.assertEqual(bytes(u.mem_read(0x4c,4)),struct.pack('<HH',0x500,0x2000))
        self.assertEqual(bytes(u.mem_read(0x205f0,4)),struct.pack('<HH',0x800,0x2000))
        self.assertEqual(bytes(u.mem_read(0x208f0,4)),struct.pack('<HH',0,0xf000))
        for drive,want in ((0x80,0x81),(0x81,0x80),(0x82,0x82)):
            calls,dx=self.call(u,drive,0x42)
            self.assertEqual(calls,[(want,0x42)]);self.assertEqual(dx,drive)
        self.call(u,0x80,0x42,True)
    def test_geometry_uses_bda_count_without_firmware_probe(self):
        u=self.vm(count=3,ram_only=False)
        for drive in (0x80,0x81,0x82):
            calls,dx=self.call(u,drive,8)
            self.assertEqual(calls,[]);self.assertEqual(dx,0xfe03)
        self.assertEqual(self.call(u,0x83,8,True)[0],[])
    def test_nonleading_usb_does_not_rotate_and_edd_size_is_preserved(self):
        u=self.vm(boot=0x81,ram_only=False)
        self.assertEqual(self.call(u,0x80,0x42)[0],[(0x80,0x42)])
        self.assertEqual(self.call(u,0x80,0x15)[1],0x1234)
    def test_vendor_payload_unchanged_and_runtime_blocks_do_not_overlap(self):
        self.assertEqual(self.image[0xa00:],self.original[0xa00:])
        entry=0x202+self.original[0x201]
        allowed={entry+2,entry+3}|set(range(0x400,0xa00))
        self.assertTrue(all(a==b or i in allowed for i,(a,b) in enumerate(zip(self.original,self.image))))
        bridge=build_kexec_bridge(ROOT,ROOT/'zig-out/ordered-kexec-tests')
        cpu_reset=build_kexec_cpu_reset(ROOT,ROOT/'zig-out/ordered-kexec-tests')
        with self.assertRaises(ValueError):make_ordered_kexec_wimboot(bytes(76064),bytes(512),bridge,cpu_reset)

    def test_entry_resets_linux_control_state_before_firmware_handoff(self):
        cpu_reset=build_kexec_cpu_reset(ROOT,ROOT/'zig-out/ordered-kexec-tests')
        self.assertEqual(self.image[0x720:0x760],cpu_reset)
        # mov cr4,eax; mov cr3,eax; mov ecx,MSR_EFER; wrmsr; clts
        self.assertIn(bytes.fromhex('0f22e00f22d8'),cpu_reset)
        self.assertIn(bytes.fromhex('66b9800000c0'),cpu_reset)
        self.assertIn(bytes.fromhex('0f300f06'),cpu_reset)
        # Entry calls the reset stub before the PIC/PIT sequence.
        call_at=self.image.index(b'\xe8',0x600,0x620)
        rel=struct.unpack_from('<h',self.image,call_at+1)[0]
        self.assertEqual(call_at+3+rel,0x720)

    def test_kexec_bridge_installs_int15_and_hides_post_linux_firmware_disks(self):
        u=self.vm(count=2)
        self.assertEqual(bytes(u.mem_read(0x54,4)),struct.pack('<HH',0x960,0x2000))
        self.assertEqual(bytes(u.mem_read(0x20700,4)),struct.pack('<HH',0,0))
        self.assertEqual(bytes(u.mem_read(0x20704,2)),struct.pack('<H',0x9000))
        self.assertEqual(bytes(u.mem_read(0x475,1)),b'\x00')
        self.assertEqual(self.image[0x706],1)

    def test_kexec_bridge_serves_linux_e820_without_firmware_interrupt(self):
        u=self.vm(count=2)
        u.mem_write(0x70000,b'\x00'*64)
        u.reg_write(UC_X86_REG_ES,0x7000)
        u.reg_write(UC_X86_REG_DI,0)
        u.reg_write(UC_X86_REG_EAX,0xe820)
        u.reg_write(UC_X86_REG_EBX,0)
        u.reg_write(UC_X86_REG_ECX,24)
        u.reg_write(UC_X86_REG_EDX,0x534d4150)
        # Create the same IRET frame a real INT 15h invocation would create.
        sp=0xefe0
        u.reg_write(UC_X86_REG_SS,0x8000);u.reg_write(UC_X86_REG_SP,sp)
        u.mem_write(0x80000+sp,struct.pack('<HHH',0x1234,0x5678,0x0201))
        u.reg_write(UC_X86_REG_CS,0x2000);u.reg_write(UC_X86_REG_IP,0x960)
        u.emu_start(0x20960,0x5678*16+0x1234,count=1000)
        self.assertEqual(bytes(u.mem_read(0x70000,20)),struct.pack('<QQI',0,0x9f000,1))
        self.assertEqual(u.reg_read(UC_X86_REG_EAX),0x534d4150)
        self.assertEqual(u.reg_read(UC_X86_REG_EBX),1)
        self.assertEqual(u.reg_read(UC_X86_REG_ECX),20)

    def test_kexec_bridge_fails_all_non_e820_int15_without_firmware_call(self):
        for ax in (0xc000,0xc100,0xe801,0x2401,0x5300):
            with self.subTest(ax=hex(ax)):
                u=self.vm(count=2)
                calls=[]
                # Original firmware INT15 points at F000:0000 in the VM.  If
                # the bridge chains there, record it; no non-E820 service may
                # re-enter firmware after Linux/kexec on this direct path.
                def firmware(uc,address,size,data):
                    if address==0xf0000:
                        calls.append(ax)
                hook=u.hook_add(UC_HOOK_CODE,firmware)
                u.mem_write(0xf0000,b'\xcf')
                sp=0xefe0
                u.reg_write(UC_X86_REG_SS,0x8000);u.reg_write(UC_X86_REG_SP,sp)
                u.mem_write(0x80000+sp,struct.pack('<HHH',0x1234,0x5678,0x0200))
                u.reg_write(UC_X86_REG_EAX,ax)
                u.reg_write(UC_X86_REG_CS,0x2000);u.reg_write(UC_X86_REG_IP,0x960)
                u.emu_start(0x20960,0x5678*16+0x1234,count=1000)
                u.hook_del(hook)
                self.assertEqual(calls,[])
                self.assertEqual(u.reg_read(UC_X86_REG_EFLAGS)&1,1)
                self.assertEqual((u.reg_read(UC_X86_REG_EAX)>>8)&0xff,0x86)

if __name__=='__main__':unittest.main()
