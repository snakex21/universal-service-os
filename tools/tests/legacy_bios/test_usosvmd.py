"""USOSVMD.VXD v2 - the Windows 9x VMOUSE mouse minidriver that gives MS-DOS
boxes an Int 33h mouse (docs/dos-mouse-2026-10-18.md). Checks:

  * the shared-block offsets the VxD hard-codes match usoskey.S (version 4);
  * the built file is a valid LE VxD with the USOSVMD DDB (SDK 4.0, v2) and
    makes exactly the documented VMM / VMOUSE service calls;
  * emulated at ring 0 (Unicorn, 32-bit):
      - Device_Init claims VMOUSE's mouse data only when VMOUSE has none
        (otherwise "observer": never posts), allocates the V86 callback,
        and does nothing without VMOUSE;
      - the V86 callback (what SeaBIOS far-calls for INT 15h C207h) reads
        the packet from the stack of WHATEVER VM was current through that
        VM's high linear mapping, counts calls from DOS VMs, queues for
        VMOUSE and copies into the system VM's shared ring through the
        system VM's mapping (the Me callback hazard fix: no V86 code in
        private memory is run);
      - drain posts to VMOUSE (b1=0x20, b2=0x08, b3=0x10, X as read, Y
        negated, overflow skipped); a later VMOUSE type change stops posting;
      - PM API: attach (block checked), status, status-block copy;
  * USOSMOUS.DRV / USOSKEY.DRV source contracts for the VMOUSE mode.
"""
from pathlib import Path
import re
import struct
import sys
import unittest

from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_INTR
from unicorn.x86_const import (UC_X86_REG_EIP, UC_X86_REG_ESP, UC_X86_REG_EAX,
                               UC_X86_REG_EBX, UC_X86_REG_ESI, UC_X86_REG_EDI,
                               UC_X86_REG_EDX, UC_X86_REG_EFLAGS)

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_win3_usb_keyboard import build_vxd, ne_imported_modules, build_mouse_driver, build_tsr, write_tsr_header

# Shared-block mouse-field offsets as the VxD hard-codes them (usoskey.S v4).
OFF = dict(MHEAD=396, MTAIL=397, MALIVE=398, MCBOFS=400, MRING=420)
BASE = 0x10000                      # LE object load base


def le_image(path: Path):
    """Return (flat bytes of object 1 with internal fixups applied, symbol
    map). Enough of the LE format for a single-object preload VxD."""
    d = path.read_bytes()
    le = struct.unpack_from('<I', d, 0x3c)[0]
    assert d[le:le + 2] == b'LE'
    g = lambda o: struct.unpack_from('<I', d, le + o)[0]
    pagesz, npages = g(0x28), g(0x14)
    objtab, pmap = g(0x40), g(0x48)
    fpt, frt, datapg = le + g(0x68), le + g(0x6c), g(0x80)
    vs, base, fl, pidx, pcnt, _ = struct.unpack_from('<IIIIII', d, le + objtab)
    buf = bytearray(vs + pagesz)
    for p in range(pcnt):
        pg = pidx + p
        off = datapg + (pg - 1) * pagesz
        sz = g(0x2c) if pg == npages else pagesz
        buf[p * pagesz:p * pagesz + sz] = d[off:off + sz]
    # internal fixups
    for p in range(pcnt):
        a, b = struct.unpack_from('<II', d, fpt + 4 * (pidx + p - 1))
        r, end = frt + a, frt + b
        while r < end:
            src, flags = d[r], d[r + 1]; r += 2
            so = struct.unpack_from('<h', d, r)[0]; r += 2
            tobj = d[r]; r += 1
            st = src & 0xf
            if st == 7:
                toff = struct.unpack_from('<H', d, r)[0]; r += 2
                struct.pack_into('<I', buf, p * pagesz + so, BASE + toff)
            else:
                raise AssertionError('unexpected fixup type %d' % st)
    return bytes(buf[:vs])


def vxd_calls(code: bytes):
    out = []
    i = 0
    while i < len(code) - 5:
        if code[i] == 0xcd and code[i + 1] == 0x20:
            v = struct.unpack_from('<I', code, i + 2)[0]
            out.append((v >> 16, v & 0x7fff))
            i += 6
        else:
            i += 1
    return out


def sym_map(work: Path):
    m = {}
    for line in (work / 'usosvmd.map').read_text(errors='replace').splitlines():
        g = re.match(r'\s*0001:([0-9a-fA-F]{8})\*?\s+(\w+)', line)
        if g:
            m[g.group(2)] = BASE + int(g.group(1), 16)
    return m



# status block field offsets (usosvmd.asm, `status`)
ST = dict(mode=3, type_init=6, type_now=7, cb=8, sb=12, callbacks=16, foreign=20, posted=24,
          own_drop=28, shared_put=32, shared_drop=36, last_vm=40, last_pkt=44, err=48,
          changes=50, ticks=52, attach=56, sys_vm=58)
OWN_HEAD, OWN_TAIL, OWN_RING = 64, 65, 68
SYSCB, DOSCB = 0x50000, 0x50100      # fake VM control blocks
SYS_HIGH, DOS_HIGH = 0x400000, 0x600000   # their CB_High_Linear
CRS = 0x58000                        # Client_Reg_Struc
BLK_SEG, BLK_OFF = 0x2230, 0x0104    # the shared block in the system VM
CB_ADDR = 0xFD6224F7


class Vxd:
    """The built VxD in Unicorn at ring 0 (flat 32-bit). VxD service calls
    (INT 20h + dword) go to `svc`; every call is logged in `calls`."""

    def __init__(self, img, sym, vmd_version=0x0400, mouse_type=0, alloc_ok=True):
        self.sym = sym
        self.u = u = Uc(UC_ARCH_X86, UC_MODE_32)
        u.mem_map(0, 0x800000)
        u.mem_write(BASE, img)
        u.mem_write(SYSCB + 4, struct.pack('<I', SYS_HIGH))
        u.mem_write(DOSCB + 4, struct.pack('<I', DOS_HIGH))
        self.vmd_version, self.mouse_type, self.alloc_ok = vmd_version, mouse_type, alloc_ok
        self.calls, self.posts, self.set_data = [], [], []
        self.map_flat = 0
        u.hook_add(UC_HOOK_INTR, self.on_intr)

    def on_intr(self, uc, n, data):
        eip = uc.reg_read(UC_X86_REG_EIP)
        v = struct.unpack_from('<I', bytes(uc.mem_read(eip, 4)), 0)[0]
        dev, svc = v >> 16, v & 0x7fff
        self.calls.append((dev, svc))
        fl = uc.reg_read(UC_X86_REG_EFLAGS) & ~1
        r = lambda x: uc.reg_read(x)
        if (dev, svc) == (1, 0x03):                 # Get_Sys_VM_Handle
            uc.reg_write(UC_X86_REG_EBX, SYSCB)
        elif (dev, svc) == (0xc, 0x00):             # VMD_Get_Version
            if self.vmd_version is None:
                uc.reg_write(UC_X86_REG_EAX, 0)
                fl |= 1
            else:
                uc.reg_write(UC_X86_REG_EAX, self.vmd_version)
        elif (dev, svc) == (0xc, 0x07):             # VMD_Get_Mouse_Data: AH = type
            uc.reg_write(UC_X86_REG_EAX, (r(UC_X86_REG_EAX) & 0xFFFF00FF) | (self.mouse_type << 8))
        elif (dev, svc) == (0xc, 0x06):             # VMD_Set_Mouse_Data
            self.set_data.append((r(UC_X86_REG_EAX) & 0xFFFF, r(UC_X86_REG_EDX) & 0xFFFF))
            self.mouse_type = (r(UC_X86_REG_EAX) >> 8) & 0xFF
        elif (dev, svc) == (1, 0x0B):               # Allocate_V86_Call_Back
            self.alloc_esi = r(UC_X86_REG_ESI)
            if self.alloc_ok:
                uc.reg_write(UC_X86_REG_EAX, CB_ADDR)
            else:
                fl |= 1
        elif (dev, svc) == (0xc, 0x03):             # VMD_Post_Pointer_Message
            self.posts.append((r(UC_X86_REG_EAX) & 0xff, r(UC_X86_REG_ESI), r(UC_X86_REG_EDI), r(UC_X86_REG_EDX)))
        elif (dev, svc) == (1, 0x1C):               # Map_Flat
            self.map_ax = r(UC_X86_REG_EAX) & 0xFFFF
            uc.reg_write(UC_X86_REG_EAX, self.map_flat)
        uc.reg_write(UC_X86_REG_EFLAGS, fl)
        uc.reg_write(UC_X86_REG_EIP, eip + 4)

    def run(self, name, **regs):
        u = self.u
        RET = 0x7f0000
        u.mem_write(RET, b'\xf4')
        u.reg_write(UC_X86_REG_ESP, 0x780000)
        u.mem_write(0x780000, struct.pack('<I', RET))
        for k, v in regs.items():
            u.reg_write(getattr(sys.modules['unicorn.x86_const'], 'UC_X86_REG_' + k.upper()), v)
        u.emu_start(self.sym[name], RET, count=500000)
        return u.reg_read(UC_X86_REG_EAX)

    def st(self, field, size=1):
        b = bytes(self.u.mem_read(self.sym['status'] + (ST[field] if isinstance(field, str) else field), size))
        return int.from_bytes(b, 'little')

    def set_st(self, field, value, size=1):
        self.u.mem_write(self.sym['status'] + (ST[field] if isinstance(field, str) else field),
                         value.to_bytes(size, 'little'))

    # the shared block in the system VM's memory
    def blk(self):
        return SYS_HIGH + BLK_SEG * 16 + BLK_OFF

    def make_block(self, magic=b'USKY', version=4):
        self.u.mem_write(self.blk(), magic + struct.pack('<H', version))

    def client(self, **words):
        """Client_Reg_Struc at CRS; words are written as dwords at their offsets."""
        offs = dict(eax=0x1C, ebx=0x10, ecx=0x18, edx=0x14, edi=0x00, eflags=0x2C, esp=0x30, ss=0x34, es=0x38)
        for k, v in words.items():
            self.u.mem_write(CRS + offs[k], struct.pack('<I', v))

    def client_word(self, off):
        return struct.unpack_from('<H', bytes(self.u.mem_read(CRS + off, 2)))[0]

    def bios_call(self, vm_cb, high, status, dx, dy, z, ss=0x1500, sp=0x03E0):
        """SeaBIOS far-called the callback in VM vm_cb: after VMM's simulated
        far return SS:SP points at Z, Y, X, status."""
        self.u.mem_write(high + ss * 16 + sp, struct.pack('<HHHH', z, dy, dx, status))
        self.client(ss=ss, esp=sp)
        self.run('v86_cb', ebx=vm_cb, ebp=CRS, edx=0)


class UsosVmd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = ROOT / 'zig-out/win3-usb-mouse-test'
        work.mkdir(parents=True, exist_ok=True)
        cls.work = work
        cls.vxd = build_vxd(work, work)
        cls.img = le_image(cls.vxd)
        cls.sym = sym_map(work)

    # --- offsets match the TSR ---------------------------------------------
    def test_shared_offsets_match_usoskey_S(self):
        s = (ROOT / 'src/platform/bios/msdos/usoskey.S').read_text()
        sizes = {'.byte': 1, '.word': 2, '.long': 4}

        def dir_size(d, arg):
            if d == '.space':
                return int(arg.split(',')[0], 0)
            if d in ('.ascii', '.asciz', '.string'):
                lit = re.search(r'"((?:[^"\\]|\\.)*)"', arg).group(1)
                n = len(re.sub(r'\\.', 'x', lit))
                return n + (1 if d != '.ascii' else 0)
            return sizes[d]

        # Walk from the `shared:` label, summing every data directive (an
        # optional label may share the line) and recording each label's byte
        # offset from `shared`.
        off, cur, seen = {}, 0, False
        datare = re.compile(r'(\.byte|\.word|\.long|\.space|\.ascii|\.asciz|\.string)\s+(.*)')
        for line in s.splitlines():
            line = line.split('/*')[0].strip()
            if line.startswith('shared:'):
                seen = True
            if not seen:
                continue
            lab = re.match(r'(\w+):', line)
            if lab:
                off[lab.group(1)] = cur
                line = line[lab.end():].strip()
            m = datare.match(line)
            if m:
                cur += dir_size(m.group(1), m.group(2))
            if 'mring' in off and cur > off['mring'] + 128:
                break
        got = {k: off[name] for k, name in
               (('MHEAD', 'mhead'), ('MTAIL', 'mtail'), ('MALIVE', 'malive'),
    ('MCBOFS', 'mcbofs'), ('MRING', 'mring'))}
        self.assertEqual(got, OFF)
        # and the .asm actually uses them
        asm = (ROOT / 'src/platform/win9x/usosvmd.asm').read_text()
        for name, val in OFF.items():
            self.assertRegex(asm, r'OFF_%s\s+equ\s+%d\b' % (name, val))


    # --- LE / DDB / service set --------------------------------------------
    def test_valid_le_vxd_and_ddb(self):
        d = self.vxd.read_bytes()
        le = struct.unpack_from('<I', d, 0x3c)[0]
        self.assertEqual(d[le:le + 2], b'LE')
        b = self.img
        i = b.find(b'USOSVMD ')
        ddb = i - 12
        self.assertEqual(struct.unpack_from('<H', b, ddb + 4)[0], 0x400)      # SDK 4.0
        self.assertEqual(b[ddb + 8], 2)                                       # version 2
        self.assertEqual(struct.unpack_from('<I', b, ddb + 20)[0], 0x80000000)  # init order undefined
        self.assertEqual(struct.unpack_from('<I', b, ddb + 32)[0], self.sym['USOSVMD_PM_API'])

    def test_service_calls(self):
        # exactly the documented services: VMM Get_Sys_VM_Handle,
        # Allocate_V86_Call_Back, Map_Flat, Set_Global_Time_Out; VMOUSE
        # Get_Version, Post_Pointer_Message, Set_Mouse_Data, Get_Mouse_Data
        self.assertEqual(set(vxd_calls(self.img)),
                         {(1, 0x03), (1, 0x0B), (1, 0x1C), (1, 0x3C),
                          (0xc, 0x00), (0xc, 0x03), (0xc, 0x06), (0xc, 0x07)})

    # --- Device_Init ---------------------------------------------------------
    def test_device_init_claims_an_empty_vmouse(self):
        v = Vxd(self.img, self.sym, mouse_type=0)
        v.run('dev_init_proc')
        self.assertEqual(v.set_data, [(0x0200, 0x0300)])      # serial type, no IRQ, 3 buttons, port 0
        self.assertEqual(v.st('mode'), 1)                     # minidriver
        self.assertEqual(v.alloc_esi, self.sym['v86_cb'])
        self.assertEqual(v.st('cb', 4), CB_ADDR)
        self.assertEqual(v.st('sys_vm', 4), SYSCB)
        self.assertEqual(v.st('type_init'), 0)
        self.assertEqual(v.st('err', 2), 0)

    def test_device_init_leaves_another_mouse_alone(self):
        v = Vxd(self.img, self.sym, mouse_type=4)             # VMOUSE's own PS/2 mouse
        v.run('dev_init_proc')
        self.assertEqual(v.set_data, [])
        self.assertEqual(v.st('mode'), 2)                     # observer
        self.assertEqual(v.st('err', 2), 0x0002)
        self.assertEqual(v.st('cb', 4), CB_ADDR)

    def test_device_init_without_vmouse(self):
        v = Vxd(self.img, self.sym, vmd_version=None)
        v.run('dev_init_proc')
        self.assertEqual(v.st('mode'), 0)
        self.assertEqual(v.st('err', 2), 0x0040)
        self.assertNotIn((1, 0x0B), v.calls)                  # no callback, nothing to feed
        self.assertNotIn((0xc, 0x07), v.calls)

    def test_device_init_callback_failure(self):
        v = Vxd(self.img, self.sym, alloc_ok=False)
        v.run('dev_init_proc')
        self.assertEqual(v.st('cb', 4), 0)
        self.assertEqual(v.st('err', 2), 0x0001)

    def ready(self, mouse_type=0, attach=True):
        v = Vxd(self.img, self.sym, mouse_type=mouse_type)
        v.run('dev_init_proc')
        v.run('check_type')
        if attach:
            v.make_block()
            v.client(ebx=BLK_SEG, ecx=BLK_OFF)
            self.assertEqual(v.run('api_attach', ebp=CRS), 1)
        return v

    # --- the V86 callback (the hazard fix) ------------------------------------
    def test_callback_reads_the_current_vms_stack(self):
        v = self.ready()
        self.assertEqual(v.st('sb', 4), v.blk())
        # a DOS VM was current when SeaBIOS called: read through ITS mapping
        v.bios_call(DOSCB, DOS_HIGH, 0x09, 5, 3, 0xFF)
        self.assertEqual(v.st('callbacks', 4), 1)
        self.assertEqual(v.st('foreign', 4), 1)
        self.assertEqual(v.st('last_vm', 4), DOSCB)
        self.assertEqual(v.st('last_pkt', 4), int.from_bytes(bytes([0x09, 5, 3, 0xFF]), 'little'))
        # own ring (posted later) ...
        self.assertEqual(v.st(OWN_HEAD), 1)
        self.assertEqual(v.st(OWN_RING, 4), int.from_bytes(bytes([0x09, 5, 3, 0xFF]), 'little'))
        # ... and the system VM's shared ring, written through the SYSTEM VM's
        # high linear mapping whatever VM is current (wheel for USOSMOUS)
        b = v.blk()
        mem = lambda o, n=1: bytes(v.u.mem_read(b + o, n))
        self.assertEqual(mem(OFF['MHEAD'])[0], 1)
        self.assertEqual(mem(OFF['MRING'], 4), bytes([0x09, 5, 3, 0xFF]))
        self.assertEqual(struct.unpack('<I', mem(408, 4))[0], 1)       # mpackets
        self.assertEqual(mem(412, 4), bytes([0x09, 5, 3, 0xFF]))        # mlast
        self.assertEqual(v.st('shared_put', 4), 1)
        # from the system VM: not foreign
        v.bios_call(SYSCB, SYS_HIGH, 0x08, 1, 0, 0)
        self.assertEqual(v.st('foreign', 4), 1)
        self.assertEqual(v.st('callbacks', 4), 2)

    def test_shared_ring_full_is_counted(self):
        v = self.ready()
        b = v.blk()
        v.u.mem_write(b + OFF['MHEAD'], bytes([5]))
        v.u.mem_write(b + OFF['MTAIL'], bytes([6]))                     # full
        v.bios_call(SYSCB, SYS_HIGH, 0x08, 1, 0, 0)
        self.assertEqual(bytes(v.u.mem_read(b + OFF['MHEAD'], 1))[0], 5)
        self.assertEqual(v.st('shared_drop', 4), 1)
        self.assertEqual(struct.unpack('<H', bytes(v.u.mem_read(b + 402, 2)))[0], 1)   # mdropped
        self.assertEqual(v.st('err', 2) & 0x20, 0x20)

    def post_one(self, status, dx, dy):
        v = self.ready()
        v.bios_call(SYSCB, SYS_HIGH, status, dx, dy, 0)
        v.run('drain')
        return v

    @staticmethod
    def s32(x):
        return x - 0x100000000 if x >= 0x80000000 else x

    def test_drain_moves_and_buttons(self):
        v = self.post_one(0x01, 5, 3)                          # left, dx +5, dy +3 (PS/2 up)
        self.assertEqual(len(v.posts), 1)
        al, esi, edi, edx = v.posts[0]
        self.assertEqual(al, 0x20)                             # b1
        self.assertEqual(self.s32(esi), 5)
        self.assertEqual(self.s32(edi), -3)                    # down-positive
        self.assertEqual(edx, self.sym['status'] + OWN_RING + 256 + 0)   # mi_inst follows the ring
        self.assertEqual(v.st(OWN_TAIL), 1)
        self.assertEqual(v.st('posted', 4), 1)

    def test_drain_sign_and_button_map(self):
        v = self.post_one(0x06 | 0x10 | 0x20, 0xFE, 0xFD)
        al, esi, edi, _ = v.posts[0]
        self.assertEqual(al, 0x08 | 0x10)                      # b2 | b3
        self.assertEqual(self.s32(esi), -2)
        self.assertEqual(self.s32(edi), 3)

    def test_drain_skips_overflow(self):
        v = self.ready()
        v.bios_call(SYSCB, SYS_HIGH, 0x40, 9, 9, 0)
        v.bios_call(SYSCB, SYS_HIGH, 0x00, 1, 0, 0)
        v.run('drain')
        self.assertEqual(len(v.posts), 1)
        self.assertEqual(self.s32(v.posts[0][1]), 1)
        self.assertEqual(v.st(OWN_TAIL), 2)

    def test_observer_never_posts(self):
        v = self.ready(mouse_type=4)
        v.bios_call(SYSCB, SYS_HIGH, 0x01, 5, 3, 0)
        v.run('drain')
        self.assertEqual(v.posts, [])
        self.assertEqual(v.st(OWN_HEAD), 0)                    # not even queued
        self.assertEqual(v.st('shared_put', 4), 1)             # the shared ring still gets it

    def test_type_change_switches_to_observer(self):
        v = self.ready()
        v.bios_call(SYSCB, SYS_HIGH, 0x01, 5, 3, 0)            # queued as minidriver
        v.mouse_type = 4                                       # VMOUSE's own PS/2 code took the mouse
        v.run('check_type')
        self.assertEqual(v.st('mode'), 2)
        self.assertEqual(v.st('type_now'), 4)
        self.assertEqual(v.st('changes', 2), 1)
        self.assertEqual(v.st('err', 2) & 0x08, 0x08)
        v.run('drain')
        self.assertEqual(v.posts, [])                          # the queued packet is dropped

    def test_callback_without_attach_counts_only(self):
        v = self.ready(attach=False)
        v.bios_call(SYSCB, SYS_HIGH, 0x01, 5, 3, 0)
        self.assertEqual(v.st('callbacks', 4), 1)
        self.assertEqual(v.st('shared_put', 4), 0)

    # --- PM API ----------------------------------------------------------------
    def test_attach_rejects_a_bad_block(self):
        v = self.ready(attach=False)
        v.make_block(magic=b'XXXX')
        v.client(ebx=BLK_SEG, ecx=BLK_OFF)
        self.assertEqual(v.run('api_attach', ebp=CRS), 0)
        self.assertEqual(v.st('sb', 4), 0)
        self.assertEqual(v.st('err', 2) & 0x04, 0x04)
        v.make_block(version=3)                                # no mouse ring
        self.assertEqual(v.run('api_attach', ebp=CRS), 0)

    def test_pm_api_attach_status_and_copy(self):
        v = self.ready(attach=False)
        v.make_block()
        v.client(eax=1, ebx=BLK_SEG, ecx=BLK_OFF, eflags=0x202)
        v.run('USOSVMD_PM_API', ebp=CRS)
        self.assertEqual(v.client_word(0x1C), 0x5655)
        self.assertEqual((v.client_word(0x10), v.client_word(0x18)), (CB_ADDR >> 16, CB_ADDR & 0xFFFF))
        self.assertEqual(v.client_word(0x14), 1)               # mode minidriver
        self.assertEqual(v.client_word(0x2C) & 1, 0)           # CF clear
        v.client(eax=0)
        v.run('USOSVMD_PM_API', ebp=CRS)
        self.assertEqual((v.client_word(0x1C), v.client_word(0x10), v.client_word(0x14)), (0x5655, 0x0200, 1))
        v.map_flat = 0x700000
        v.client(eax=2)
        v.run('USOSVMD_PM_API', ebp=CRS)
        self.assertEqual(v.map_ax, 0x3800)                     # Client_ES : Client_DI
        self.assertEqual(v.client_word(0x18), 64)
        self.assertEqual(bytes(v.u.mem_read(0x700000, 4)), b'UV\x02\x01')
        v.client(eax=7)
        v.run('USOSVMD_PM_API', ebp=CRS)
        self.assertEqual(v.client_word(0x2C) & 1, 1)           # unknown function: CF set

    # --- the companion driver changes --------------------------------------
    def test_usosmous_vmouse_mode_and_imports(self):
        work = self.work
        com = build_tsr(work, work)
        write_tsr_header(com, work / 'usoskey.elf', work)
        drv = build_mouse_driver(work, work).read_bytes()
        self.assertEqual(ne_imported_modules(drv), ['KERNEL'])
        c = (ROOT / 'src/platform/win3/usosmous.c').read_text()
        self.assertIn('USOSVMD.ON', c)
        self.assertIn('VMDAPI_SET_MOUSE_EVENT_CB', c)
        self.assertRegex(c, r'VMD_DEVICE_ID\s+0x000C')
        # C207h: the VxD's callback in VMOUSE mode, the mcb only otherwise
        self.assertIn('if (vmdmode) r = bios15(0xC207, LOWORD(vinfo.vxd_cb), HIWORD(vinfo.vxd_cb));', c)
        self.assertIn('if (vmdmode) continue;', c)             # poll: wheel only
        self.assertIn('if (vmdmode) return;', c)               # USOSPAUSE: nothing to guard

    def test_usoskey_guard_asks_usosmous(self):
        k = (ROOT / 'src/platform/win3/usoskey.c').read_text()
        self.assertIn('mouse_export("USOSVMDMODE")', k)
        self.assertNotIn('USOSVMD.ON', k)                      # the flag alone is not enough
        self.assertRegex(k, r'mouse_guard\s*=\s*!usosvmd_on\(\)')


if __name__ == '__main__':
    unittest.main()
