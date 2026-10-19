"""USOSMOUS.DRV wheel path, run in Unicorn (real mode stands in for the
Windows protected-mode selectors): the built NE driver is loaded with its
relocations, KERNEL / SYSTEM imports and INT 2Fh / DPMI INT 31h 0300h are
small stubs, the BIOS answers like CSMWrap with patch 0016 (IntelliMouse
knock: C204h BH=3) or like an older CSMWrap (BH=0AAh). Checks Inquire's
msExists (4Bh = wheel for 98 / Me USER), the knock order, and the events
the poll timer sends to USER's procedure: AX=0800h, DX = -wheel * 120 after
the movement/button events, nothing for a ring without wheel bytes; and
the USOSWHEELINFO record (ordinal 8, read by USOSDBG.EXE): knock answer,
knock error code (step << 12 | 100h | AH), knocks and wheel calls.
"""
from pathlib import Path
import struct
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_CODE
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_win3_usb_keyboard import build_mouse_driver  # noqa: E402

CODE_SEG, DATA_SEG, STUB_SEG, SHARED_SEG, STACK_SEG = 0x1000, 0x2000, 0x6000, 0x3000, 0x5000
RET = 0x7000                         # linear stop address (0000:7000)
MOUSEINFO_SEG = 0x4000
KERNEL = {175: 'AllocSelector', 187: 'SetSelectorBase', 189: 'SetSelectorLimit', 3: 'GetVersion',
          127: 'GetPrivateProfileInt', 47: 'GetModuleHandle', 50: 'GetProcAddress', 74: 'OpenFile'}
POPS = {'AllocSelector': 2, 'SetSelectorBase': 6, 'SetSelectorLimit': 6, 'GetVersion': 0,
        'GetPrivateProfileInt': 14, 'GetModuleHandle': 4, 'GetProcAddress': 6, 'OpenFile': 10,
        'CreateSystemTimer': 6, 'KillSystemTimer': 2, 'EventProc': 0}
# Shared block (usoskey.S version 4)
MHEAD, MTAIL, MALIVE, MSTATE, MCB, MRING = 396, 397, 398, 399, 400, 420
SHARED_OFF = 0x0103


def load_ne(data: bytes):
    ne = struct.unpack_from('<H', data, 0x3c)[0]
    nseg = struct.unpack_from('<H', data, ne + 0x1c)[0]
    segtab = ne + struct.unpack_from('<H', data, ne + 0x22)[0]
    shift = struct.unpack_from('<H', data, ne + 0x32)[0] or 9
    segs = []
    for i in range(nseg):
        so, sl, fl, mn = struct.unpack_from('<HHHH', data, segtab + 8 * i)
        segs.append((so << shift, sl or 0x10000, fl, mn))
    names, i = {}, ne + struct.unpack_from('<H', data, ne + 0x26)[0]
    while data[i]:
        n = data[i]
        names[data[i + 1:i + 1 + n].decode()] = struct.unpack_from('<H', data, i + 1 + n)[0]
        i += n + 3
    ents, p, ordn = {}, ne + struct.unpack_from('<H', data, ne + 0x04)[0], 1
    end = p + struct.unpack_from('<H', data, ne + 0x06)[0]
    while p < end:
        cnt, ind = data[p], data[p + 1]
        p += 2
        if cnt == 0:
            break
        for _ in range(cnt):
            if ind == 0:
                ordn += 1
                continue
            if ind == 0xff:
                _, _, seg, off = struct.unpack_from('<BHBH', data, p)
                p += 6
            else:
                _, off = struct.unpack_from('<BH', data, p)
                seg = ind
                p += 3
            ents[ordn] = (seg, off)
            ordn += 1
    return segs, names, ents


class Emu:
    def __init__(self, drv: bytes, dos_version: int, bios_id: int, bridge=True, fail=None):
        self.u = u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        self.dos_version, self.bios_id, self.bridge = dos_version, bios_id, bridge
        self.fail = fail                     # (AX, BX, AH): that BIOS call fails with CF and AH
        self.bios_calls, self.events, self.timer_proc = [], [], None
        segs, self.names, self.ents = load_ne(drv)
        bases = [CODE_SEG, DATA_SEG]
        self.stubs = {}
        for name in POPS:
            off = 0x10 * (len(self.stubs) + 1)
            self.stubs[name] = off
            u.mem_write(STUB_SEG * 16 + off, bytes([0xCA]) + struct.pack('<H', POPS[name]) if POPS[name]
                        else b'\xcb')                     # retf n / retf
        for idx, (so, sl, fl, mn) in enumerate(segs):
            image = bytearray(drv[so:so + sl] if so else b'')
            image += bytes(max(mn, sl) - len(image))
            if fl & 0x100:                                # relocations follow the segment data
                p = so + sl
                for k in range(struct.unpack_from('<H', drv, p)[0]):
                    src, flags, off, a, b = struct.unpack_from('<BBHHH', drv, p + 2 + 8 * k)
                    kind = flags & 3
                    if kind == 0:
                        tseg, toff = bases[a - 1], b
                    elif kind == 1:
                        assert a == 1, 'KERNEL only'
                        tseg, toff = STUB_SEG, self.stubs[KERNEL[b]]
                    else:
                        raise AssertionError('unexpected relocation %r' % (flags,))
                    while True:
                        nxt = struct.unpack_from('<H', image, off)[0]
                        if src == 3:
                            struct.pack_into('<HH', image, off, toff, tseg)
                        elif src == 2:
                            struct.pack_into('<H', image, off, tseg)
                        elif src == 5:
                            struct.pack_into('<H', image, off, toff)
                        else:
                            raise AssertionError('relocation source %d' % src)
                        if flags & 4 or nxt == 0xFFFF:
                            break
                        off = nxt
            u.mem_write(bases[idx] * 16, bytes(image))
        u.mem_write(SHARED_SEG * 16 + SHARED_OFF, b'USKY\x04\x00')
        u.mem_write(SHARED_SEG * 16 + SHARED_OFF + MCB, struct.pack('<H', 0x0400))
        u.hook_add(UC_HOOK_INTR, self.on_int)
        u.hook_add(UC_HOOK_CODE, self.on_stub, begin=STUB_SEG * 16, end=STUB_SEG * 16 + 0x400)

    # ---------------------------------------------------------------- stubs
    def arg(self, n):
        sp = self.u.reg_read(UC_X86_REG_SP)
        return struct.unpack_from('<H', self.u.mem_read(STACK_SEG * 16 + sp + 4 + 2 * n, 2))[0]

    def on_stub(self, u, address, size, _):
        name = next(k for k, v in self.stubs.items() if STUB_SEG * 16 + v == address)
        ax = dx = None
        if name == 'AllocSelector':
            ax = SHARED_SEG                      # the "selector" is the real-mode segment
        elif name in ('SetSelectorBase', 'SetSelectorLimit'):
            ax = self.arg(2)
        elif name == 'GetVersion':
            ax, dx = 0x5F03, self.dos_version
        elif name == 'GetPrivateProfileInt':
            ax = self.arg(2)                     # nDefault: no SYSTEM.INI entries
        elif name == 'GetModuleHandle':
            ax = 0x0042
        elif name == 'GetProcAddress':
            ordinal = self.arg(0)
            ax, dx = self.stubs['CreateSystemTimer' if ordinal == 2 else 'KillSystemTimer'], STUB_SEG
        elif name == 'OpenFile':
            ax = 0xFFFF                          # no NOMOUSE.TXT
        elif name == 'CreateSystemTimer':
            self.timer_proc = (self.arg(1), self.arg(0))   # FARPROC seg, off
            ax = 1
        elif name == 'KillSystemTimer':
            ax = 1
        elif name == 'EventProc':
            r = [u.reg_read(x) for x in (UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_CX, UC_X86_REG_DX)]
            self.events.append(tuple(r))
        if ax is not None:
            u.reg_write(UC_X86_REG_AX, ax)
        if dx is not None:
            u.reg_write(UC_X86_REG_DX, dx)

    def on_int(self, u, intno, _):
        if intno == 0x2F:
            if self.bridge and u.reg_read(UC_X86_REG_AX) == 0xD700:
                u.reg_write(UC_X86_REG_AX, 0xD7FF)
                u.reg_write(UC_X86_REG_BX, SHARED_SEG)
                u.reg_write(UC_X86_REG_CX, SHARED_OFF)
                u.reg_write(UC_X86_REG_DX, 0x554B)
            return
        assert intno == 0x31 and u.reg_read(UC_X86_REG_AX) == 0x0300 and u.reg_read(UC_X86_REG_BX) == 0x15, intno
        rm = u.reg_read(UC_X86_REG_ES) * 16 + u.reg_read(UC_X86_REG_DI)
        regs = bytearray(u.mem_read(rm, 0x32))
        eax, = struct.unpack_from('<I', regs, 0x1C)
        ebx, = struct.unpack_from('<I', regs, 0x10)
        ax, bx = eax & 0xFFFF, ebx & 0xFFFF
        self.bios_calls.append((ax, bx))
        flags = struct.unpack_from('<H', regs, 0x20)[0] & ~1
        if self.fail and (ax, bx) == self.fail[:2]:
            flags |= 1
            struct.pack_into('<I', regs, 0x1C, (eax & 0xFFFF00FF) | (self.fail[2] << 8))
        elif ax == 0xC204:
            struct.pack_into('<I', regs, 0x10, (ebx & 0xFFFF00FF) | (self.bios_id << 8))
        struct.pack_into('<H', regs, 0x20, flags)
        u.mem_write(rm, bytes(regs))
        u.reg_write(UC_X86_REG_EFLAGS, u.reg_read(UC_X86_REG_EFLAGS) & ~1)

    # ---------------------------------------------------------------- calls
    def far_call(self, seg, off, words=()):
        u = self.u
        sp = 0xF000
        frame = b''.join(struct.pack('<H', w) for w in words)   # stack order above the return address
        frame = struct.pack('<HH', RET, 0) + frame
        sp -= len(frame)
        u.mem_write(STACK_SEG * 16 + sp, frame)
        u.reg_write(UC_X86_REG_SS, STACK_SEG)
        u.reg_write(UC_X86_REG_SP, sp)
        u.reg_write(UC_X86_REG_DS, 0x0BAD)
        u.reg_write(UC_X86_REG_ES, 0x0BAD)
        u.reg_write(UC_X86_REG_CS, seg)
        u.emu_start(seg * 16 + off, RET, count=200000)
        assert (u.reg_read(UC_X86_REG_CS), u.reg_read(UC_X86_REG_IP)) == (0, RET)
        return u.reg_read(UC_X86_REG_AX)

    def wheel_info(self):
        self.export('USOSWHEELINFO')
        seg, off = self.u.reg_read(UC_X86_REG_DX), self.u.reg_read(UC_X86_REG_AX)
        assert seg == DATA_SEG, hex(seg)
        return struct.unpack_from('<BBBBHHHhh', bytes(self.u.mem_read(seg * 16 + off, 14)))

    def export(self, name, words=()):
        seg, off = self.ents[self.names[name]]
        return self.far_call((CODE_SEG, DATA_SEG)[seg - 1], off, words)

    def shared(self, off, size=1):
        return bytes(self.u.mem_read(SHARED_SEG * 16 + SHARED_OFF + off, size))

    def push_packets(self, packets):
        head = self.shared(MHEAD)[0]
        for p in packets:
            self.u.mem_write(SHARED_SEG * 16 + SHARED_OFF + MRING + 4 * head, bytes(p))
            head = (head + 1) & 31
        self.u.mem_write(SHARED_SEG * 16 + SHARED_OFF + MHEAD, bytes([head]))

    def poll(self):
        seg, off = self.timer_proc
        self.far_call(seg, off)


class WheelEmu(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = ROOT / 'zig-out/win3-usb-mouse-wheel-test'
        work.mkdir(parents=True, exist_ok=True)
        cls.drv = build_mouse_driver(work, work).read_bytes()

    def start(self, dos_version, bios_id, bridge=True):
        e = Emu(self.drv, dos_version, bios_id, bridge)
        info = e.export('INQUIRE', (0, MOUSEINFO_SEG))        # MOUSEINFO FAR * (offset, segment)
        exists = e.u.mem_read(MOUSEINFO_SEG * 16, 1)[0]
        self.assertEqual(info, 16)
        e.export('ENABLE', (e.stubs['EventProc'], STUB_SEG))
        return e, exists

    def test_98se_wheel_bios(self):
        e, exists = self.start(0x070A, 3)
        self.assertEqual(exists, 0x4B)                        # SM_MOUSEWHEELPRESENT for 98 USER
        self.assertIsNotNone(e.timer_proc)
        calls = [c[0] for c in e.bios_calls]
        on = len(calls) - 1 - calls[::-1].index(0xC205)       # bios_on: C205h, knock, C204h, C207h, C200h
        self.assertEqual(e.bios_calls[on:], [(0xC205, 0x0300), (0xC202, 0x0600), (0xC202, 0x0500), (0xC202, 0x0400),
                                             (0xC204, 0), (0xC207, 0x0400), (0xC200, 0x0100)])
        self.assertEqual(e.shared(MSTATE)[0], 1)
        e.u.mem_write(SHARED_SEG * 16 + SHARED_OFF + MALIVE, b'\x12')
        # move right 8 (scaled 1/2), then two notches up (IntelliMouse -2), one with the left button down
        e.push_packets([(0x08, 8, 0, 0), (0x08, 0, 0, 0xFF), (0x09, 0, 0, 0xFF)])
        e.poll()
        self.assertEqual(e.events, [(0x0003, 4, 0, 3), (0x0800, 0, 0, 240)])
        e.events.clear()
        e.push_packets([(0x08, 0, 0, 0x03)])                  # three notches down
        e.poll()
        self.assertEqual(e.events, [(0x0004, 0, 0, 3), (0x0800, 0, 0, (-360) & 0xFFFF)])
        e.events.clear()
        e.push_packets([(0x08, 2, 0, 0)])
        e.poll()
        self.assertEqual(e.events, [(0x0001, 1, 0, 3)])       # no wheel byte, no wheel event

    def test_older_csmwrap_no_wheel(self):
        # an older CSMWrap answers the knock with 0AAh and passes Z = 0
        e, exists = self.start(0x070A, 0xAA)
        self.assertEqual(exists, 1)
        e.u.mem_write(SHARED_SEG * 16 + SHARED_OFF + MALIVE, b'\x12')
        e.push_packets([(0x08, 0, 0, 0x00)])
        e.poll()
        self.assertEqual(e.events, [])

    def test_wheel_in_z_without_the_knock(self):
        # v4 / CSMWrap usos15 (patch 0020): the device ID was reset by another
        # INT 15h client (C204h answers 0), the wheel still comes in the Z word
        e, exists = self.start(0x070A, 0)
        self.assertEqual(exists, 1)
        e.u.mem_write(SHARED_SEG * 16 + SHARED_OFF + MALIVE, b'\x12')
        e.push_packets([(0x08, 0, 0, 0xFF), (0x08, 0, 0, 0xFF)])
        e.poll()
        self.assertEqual(e.events, [(0x0800, 0, 0, 240)])
        e.events.clear()
        e.push_packets([(0x08, 2, 0, 0)])
        e.poll()
        self.assertEqual(e.events, [(0x0001, 1, 0, 3)])       # no wheel byte, no wheel event
        # the knock answered with ID 0 was sent once more (probe + bios_on: 2 x 2)
        self.assertEqual(e.wheel_info()[:6], (2, 2, 0, 0, 0, 4))
        calls = [c[0] for c in e.bios_calls]
        on = len(calls) - 1 - calls[::-1].index(0xC205)
        knock = [(0xC202, 0x0600), (0xC202, 0x0500), (0xC202, 0x0400), (0xC204, 0)]
        self.assertEqual(e.bios_calls[on:], [(0xC205, 0x0300)] + knock + knock + [(0xC207, 0x0400), (0xC200, 0x0100)])

    def test_win95_and_win3_never_knock(self):
        for dos in (0x0700, 0x0616):
            e, exists = self.start(dos, 3)
            self.assertEqual(exists, 1)
            self.assertNotIn(0xC202, [c[0] for c in e.bios_calls])
            e.u.mem_write(SHARED_SEG * 16 + SHARED_OFF + MALIVE, b'\x12')
            e.push_packets([(0x08, 0, 0, 0xFF)])
            e.poll()
            self.assertEqual(e.events, [])

    def test_wheel_info(self):
        # version, pref (2 = wanted), wheel, knock ID, knock error, knocks, wheel calls, last sum,
        # notch count (version 2: up positive, USOSKEY.DRV's wheel scrolling)
        e, _ = self.start(0x070A, 3)
        self.assertEqual(e.wheel_info(), (2, 2, 1, 3, 0, 2, 0, 0, 0))   # probe + bios_on: two knocks
        e.u.mem_write(SHARED_SEG * 16 + SHARED_OFF + MALIVE, b'\x12')
        e.push_packets([(0x08, 0, 0, 0xFF), (0x08, 0, 0, 0xFF)])
        e.poll()
        self.assertEqual(e.wheel_info()[8], 2)                          # two notches up
        e.push_packets([(0x08, 0, 0, 0x03)])
        e.poll()
        self.assertEqual(e.wheel_info(), (2, 2, 1, 3, 0, 2, 2, 3, -1))  # last sum: three notches down
        calls = len(e.bios_calls)
        e.wheel_info()
        self.assertEqual(len(e.bios_calls), calls)                     # read only: no BIOS call
        # older CSMWrap: the knock is answered with 0AAh, and sent once more (v4)
        e, _ = self.start(0x070A, 0xAA)
        self.assertEqual(e.wheel_info(), (2, 2, 0, 0xAA, 0, 4, 0, 0, 0))
        # Windows 95: not wanted, no knock
        e, _ = self.start(0x0700, 3)
        self.assertEqual(e.wheel_info()[:6], (2, 1, 0, 0xFF, 0, 0))
        # the second sample rate refused (AH=03h) / C204h refused (AH=86h)
        e = Emu(self.drv, 0x070A, 3, fail=(0xC202, 0x0500, 0x03))
        e.export('INQUIRE', (0, MOUSEINFO_SEG))
        e.export('ENABLE', (e.stubs['EventProc'], STUB_SEG))
        self.assertEqual(e.wheel_info()[:6], (2, 2, 0, 0xFF, 0x2103, 2))
        e = Emu(self.drv, 0x070A, 3, fail=(0xC204, 0, 0x86))
        e.export('INQUIRE', (0, MOUSEINFO_SEG))
        e.export('ENABLE', (e.stubs['EventProc'], STUB_SEG))
        self.assertEqual(e.wheel_info()[:6], (2, 2, 0, 0xFF, 0x4186, 2))

    def test_me_inquire_without_bridge_is_static(self):
        e = Emu(self.drv, 0x0800, 3, bridge=False)
        e.export('INQUIRE', (0, MOUSEINFO_SEG))
        self.assertEqual(e.u.mem_read(MOUSEINFO_SEG * 16, 1)[0], 0x4B)
        self.assertEqual(e.bios_calls, [])                    # no BIOS call before USOSATTACH


if __name__ == '__main__':
    unittest.main()
