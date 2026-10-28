"""USOSV10.COM (INT 10h on a private stack) in Unicorn: the Windows 2.x
WIN.COM situation rebuilt without Microsoft files - code directly below a
small stack, a video BIOS that needs a deep stack - fails without the TSR and
runs with it; registers, flags, nesting and the install/report path."""
from pathlib import Path
import struct
import sys
import unittest
from unicorn import Uc, UcError, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_CODE
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard
from build_win9x_support import build_usosv10

TSR = 0x0800          # resident USOSV10 segment
BIOS = 0xF000         # video BIOS stub F000:1000 (Python semantics + deep stack)
BIOS_IP = 0x1000
APP = 0x3000          # tiny-stack program: code at 0F00h, SP 1000h
REGS = dict(ax=UC_X86_REG_AX, bx=UC_X86_REG_BX, cx=UC_X86_REG_CX, dx=UC_X86_REG_DX,
            si=UC_X86_REG_SI, di=UC_X86_REG_DI, bp=UC_X86_REG_BP, sp=UC_X86_REG_SP,
            ds=UC_X86_REG_DS, es=UC_X86_REG_ES, ss=UC_X86_REG_SS, cs=UC_X86_REG_CS,
            ip=UC_X86_REG_IP, fl=UC_X86_REG_EFLAGS)


def bios_stub(depth):
    """push bp; mov bp,sp; sub sp,depth; fill [bp-depth..bp) with 0F 00
    (SLDT, #UD in real mode) through ES:DI; mov sp,bp; pop bp; iret."""
    return bytes([0x55, 0x89, 0xe5, 0x81, 0xec]) + struct.pack('<H', depth) + bytes([
        0x06, 0x57, 0x51, 0x50,                     # push es, di, cx, ax
        0x8c, 0xd0, 0x8e, 0xc0,                     # mov ax,ss; mov es,ax
        0x8d, 0xbe]) + struct.pack('<h', -depth) + bytes([  # lea di,[bp-depth]
        0xb9]) + struct.pack('<H', (depth - 8) // 2) + bytes([  # mov cx,(depth-8)/2
        0xb8, 0x0f, 0x00, 0xfc, 0xf3, 0xab,         # mov ax,000Fh; cld; rep stosw
        0x58, 0x59, 0x5f, 0x07,                     # pop ax, cx, di, es
        0x89, 0xec, 0x5d, 0xcf])                    # mov sp,bp; pop bp; iret


class Machine:
    def __init__(self, depth=400, clobber=False, nested=False):
        self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        self.u.mem_map(0, 0x110000)
        self.u.mem_write(BIOS * 16 + BIOS_IP, bios_stub(depth))
        self.u.mem_write(BIOS * 16, b'\xcf')
        self.set_ivt(0x10, BIOS, BIOS_IP)
        self.clobber, self.nested = clobber, nested
        self.calls, self.out, self.nest_done = [], b'', False
        self.dos = None

    def r(self, name):
        return self.u.reg_read(REGS[name])

    def w(self, name, value):
        self.u.reg_write(REGS[name], value & 0xffff)

    def set_ivt(self, n, seg, off):
        self.u.mem_write(n * 4, struct.pack('<HH', off, seg))

    def ivt(self, n):
        off, seg = struct.unpack('<HH', self.u.mem_read(n * 4, 4))
        return seg, off

    def deliver(self, n, ret_ip):
        sp = (self.r('sp') - 6) & 0xffff
        fl = self.r('fl') & 0xffff
        self.u.mem_write(self.r('ss') * 16 + sp, struct.pack('<HHH', ret_ip, self.r('cs'), fl))
        self.w('sp', sp)
        self.w('fl', fl & ~0x300)
        seg, off = self.ivt(n)
        self.w('cs', seg)
        self.w('ip', off)

    def video(self):
        """BIOS semantics at F000:1000, before the deep-stack code runs."""
        ax = self.r('ax')
        self.calls.append((ax, self.r('ss'), self.r('sp')))
        if ax >> 8 == 0x0f:
            self.w('ax', 0x5003)
            self.w('bx', self.r('bx') & 0x00ff)
        elif ax >> 8 == 0x03:
            self.w('cx', 0x0607)
            self.w('dx', 0x0510)
        if self.clobber:
            # a BIOS that keeps only what a function returns
            for name in ('cx', 'dx', 'si', 'di', 'bp'):
                if not (ax >> 8 == 0x03 and name in ('cx', 'dx')):
                    self.w(name, 0xdead)
            if ax >> 8 != 0x0f:
                self.w('bx', 0xdead)
            self.w('ds', 0x4444)
            self.w('es', 0x5555)
        self.w('fl', self.r('fl') | 1)      # CF set by the BIOS

    def run(self, limit=200000):
        """Run in blocks; stop at INT n (delivered through the IVT here, as in
        real mode), at F000:1000 (BIOS semantics), HLT and #UD."""
        stop = []

        def intr(uc, n, data):
            stop.append(n)
            uc.emu_stop()

        skip = [False]

        def code(uc, addr, size, data):
            if skip[0]:
                skip[0] = False
            elif addr == BIOS * 16 + BIOS_IP:
                stop.append('bios')
                uc.emu_stop()
        hooks = [self.u.hook_add(UC_HOOK_INTR, intr),
                 self.u.hook_add(UC_HOOK_CODE, code, None, BIOS * 16 + BIOS_IP, BIOS * 16 + BIOS_IP)]
        try:
            steps, bios_pending = 0, False
            while steps < limit:
                cs, ip = self.r('cs'), self.r('ip')
                lin = cs * 16 + ip
                if (cs, ip) == (BIOS, BIOS_IP) and getattr(self, 'resume', None) == self.r('sp'):
                    self.resume, bios_pending = None, True
                if (cs, ip) == (BIOS, BIOS_IP) and not bios_pending:
                    self.video()
                    if self.nested and not self.nest_done:
                        # an interrupt handler issuing INT 10h while the BIOS
                        # runs: a nested INT 10h from inside the BIOS stub
                        self.nest_done, self.resume = True, self.r('sp')
                        self.u.mem_write(0x9000 * 16, b'\xb4\x0f\xcd\x10\xcf')
                        self.deliver_far(0x9000, 0, cs, ip)
                        continue
                    bios_pending = True
                op = bytes(self.u.mem_read(lin, 2))
                if op[0] == 0xf4:
                    return 'hlt'
                if op[0] == 0xcd:
                    if op[1] == 0x21 and self.dos:
                        self.w('ip', ip + 2)
                        res = self.dos()
                        if res:
                            return res
                        continue
                    self.deliver(op[1], ip + 2)
                    continue
                if op == b'\x0f\x00':
                    return 'ud'
                stop.clear()
                skip[0] = lin == BIOS * 16 + BIOS_IP
                try:
                    self.u.emu_start(lin, 0xfffff, count=1000)
                except UcError as e:
                    if stop and stop[0] == 6:
                        return 'ud'
                    return 'error %s' % e
                steps += 1000
                after = self.r('cs') * 16 + self.r('ip')
                if not stop and self.u.mem_read(after - 1, 1)[0] == 0xf4:
                    return 'hlt'
                if stop and stop[0] == 'bios':
                    pass
                elif stop and stop[0] == 6:
                    return 'ud'
                elif stop and stop[0] == 0x21 and self.dos:
                    res = self.dos()
                    if res:
                        return res
                elif stop:
                    # INT n executed by Unicorn: IP is past the instruction
                    self.deliver(stop[0], self.r('ip'))
                bios_pending = False
            return 'limit'
        finally:
            for h in hooks:
                self.u.hook_del(h)

    def deliver_far(self, seg, off, ret_cs, ret_ip):
        sp = (self.r('sp') - 6) & 0xffff
        self.u.mem_write(self.r('ss') * 16 + sp, struct.pack('<HHH', ret_ip, ret_cs, self.r('fl') & 0xffff))
        self.w('sp', sp)
        self.w('cs', seg)
        self.w('ip', off)


class UsosV10(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        depguard.require_zig()
        out = ROOT / 'zig-out/win9x-support-test'
        out.mkdir(parents=True, exist_ok=True)
        cls.com = build_usosv10(out, out).read_bytes()
        cls.sym = cls.symbols(out / 'USOSV10.elf')

    @staticmethod
    def symbols(elf):
        data = elf.read_bytes()
        # ELF32 section headers: find .symtab and its string table
        shoff, = struct.unpack_from('<I', data, 0x20)
        shentsize, shnum = struct.unpack_from('<HH', data, 0x2e)
        secs = [struct.unpack_from('<IIIIIIIIII', data, shoff + i * shentsize) for i in range(shnum)]
        sym = {}
        for s in secs:
            if s[1] == 2:   # SHT_SYMTAB
                strtab = secs[s[6]]
                for i in range(s[5] // 16):
                    name, value = struct.unpack_from('<II', data, s[4] + i * 16)
                    n = data[strtab[4] + name:data.index(b'\0', strtab[4] + name)].decode()
                    if n:
                        sym[n] = value
        return sym

    def resident(self, m):
        m.u.mem_write(TSR * 16 + 0x100, self.com)
        m.u.mem_write(TSR * 16 + self.sym['old10'], struct.pack('<HH', BIOS_IP, BIOS))
        m.set_ivt(0x10, TSR, self.sym['int10'])

    def app(self, m, code=None):
        """Code at APP:0F00 right below the stack (SP=1000h), like WIN.COM's
        0F39h-106Fh: set mode 6, palette, teletype, get mode, then HLT."""
        code = code or bytes([
            0xb8, 0x06, 0x00, 0xcd, 0x10,               # mov ax,6; int 10h
            0xb8, 0x00, 0x10, 0xb7, 0x01, 0xcd, 0x10,   # mov ax,1000h; mov bh,1; int 10h
            0xbb, 0x07, 0x00, 0xb8, 0x41, 0x0e, 0xcd, 0x10,  # mov bx,7; mov ax,0E41h; int 10h
            0xb4, 0x0f, 0xcd, 0x10,                     # mov ah,0Fh; int 10h
            0xf4])
        m.u.mem_write(APP * 16 + 0xf00, code)
        for name, value in dict(cs=APP, ip=0xf00, ss=APP, sp=0x1000, ds=0x1234, es=0xb800,
                                bx=0x0007, cx=0x0023, dx=0x18bf, si=0x0002, di=0x007e, bp=0x1046,
                                fl=0x0202).items():
            m.w(name, value)
        return code

    def test_tiny_stack_breaks_without_tsr(self):
        m = Machine(depth=400)
        code = self.app(m)
        res = m.run()
        self.assertNotEqual(res, 'hlt')
        self.assertNotEqual(bytes(m.u.mem_read(APP * 16 + 0xf00, len(code))), code)

    def test_tiny_stack_with_tsr(self):
        m = Machine(depth=400)
        self.resident(m)
        code = self.app(m)
        self.assertEqual(m.run(), 'hlt')
        self.assertEqual(bytes(m.u.mem_read(APP * 16 + 0xf00, len(code))), code)
        self.assertEqual([c[0] >> 8 for c in m.calls], [0x00, 0x10, 0x0e, 0x0f])
        # the BIOS ran on the TSR's stack, the caller's stack only saw 6+2 bytes
        self.assertTrue(all(c[1] == TSR for c in m.calls))
        self.assertEqual((m.r('ss'), m.r('sp'), m.r('cs')), (APP, 0x1000, APP))
        self.assertEqual(m.r('ax'), 0x5003)
        self.assertEqual(m.r('bx') & 0xff00, 0)     # AH=0Fh: BH from the BIOS

    def test_registers_kept_for_output_free_functions(self):
        m = Machine(depth=64, clobber=True)
        self.resident(m)
        self.app(m, bytes([0xb8, 0x06, 0x00, 0xcd, 0x10, 0xf4]))
        self.assertEqual(m.run(), 'hlt')
        got = {n: m.r(n) for n in ('bx', 'cx', 'dx', 'si', 'di', 'bp', 'ds', 'es')}
        self.assertEqual(got, dict(bx=7, cx=0x23, dx=0x18bf, si=2, di=0x7e, bp=0x1046, ds=0x1234, es=0xb800))
        self.assertTrue(m.r('fl') & 1, 'CF from the BIOS')
        self.assertTrue(m.r('fl') & 0x200, 'IF from the caller')

    def test_outputs_pass_through(self):
        m = Machine(depth=64, clobber=True)
        self.resident(m)
        self.app(m, bytes([0xb4, 0x03, 0xcd, 0x10, 0xf4]))    # AH=03h: CX, DX out
        self.assertEqual(m.run(), 'hlt')
        self.assertEqual((m.r('cx'), m.r('dx')), (0x0607, 0x0510))
        self.assertEqual(m.r('si'), 0xdead)                   # not kept for AH=03h

    def test_nested_call_chains_directly(self):
        m = Machine(depth=64, nested=True)
        self.resident(m)
        self.app(m, bytes([0xb8, 0x06, 0x00, 0xcd, 0x10, 0xf4]))
        self.assertEqual(m.run(), 'hlt')
        self.assertEqual([c[0] >> 8 for c in m.calls], [0x00, 0x0f])
        # the nested call ran on the TSR stack below the outer frame
        self.assertEqual(m.calls[1][1], TSR)
        self.assertLess(m.calls[1][2], m.calls[0][2])
        self.assertEqual(m.u.mem_read(TSR * 16 + self.sym['busy'], 1)[0], 0)
        self.assertEqual(struct.unpack('<H', m.u.mem_read(TSR * 16 + self.sym['ncalls'], 2))[0], 1)

    def run_install(self, m, seg, tail=b''):
        m.u.mem_write(seg * 16 + 0x100, self.com)
        m.u.mem_write(seg * 16 + 0x80, bytes([len(tail)]) + tail + b'\r')
        m.u.mem_write(seg * 16 + 0x2c, struct.pack('<H', 0x0700))
        for name in ('cs', 'ds', 'es', 'ss'):
            m.w(name, seg)
        m.w('ip', 0x100)
        m.w('sp', 0xfffe)
        m.w('fl', 0x0202)
        state = {}

        def dos():
            ah, al = m.r('ax') >> 8, m.r('ax') & 0xff
            if ah == 0x35:
                s, o = m.ivt(al)
                m.w('es', s)
                m.w('bx', o)
            elif ah == 0x25:
                m.set_ivt(al, m.r('ds'), m.r('dx'))
            elif ah == 0x09:
                a = m.r('ds') * 16 + m.r('dx')
                data = bytes(m.u.mem_read(a, 400))
                m.out += data[:data.index(b'$')]
            elif ah == 0x49:
                state['freed'] = m.r('es')
            elif ah == 0x31:
                state['keep'] = m.r('dx')
                return 'tsr'
            elif ah == 0x4c:
                return 'exit'
            return None
        m.dos = dos
        return m.run(), state

    def test_install_and_report(self):
        m = Machine(depth=300)
        res, state = self.run_install(m, 0x2000)
        self.assertEqual(res, 'tsr')
        self.assertEqual(m.ivt(0x10), (0x2000, self.sym['int10']))
        self.assertEqual(state['freed'], 0x0700)
        self.assertEqual(state['keep'], (self.sym['resend'] + 15) >> 4)
        text = m.out.decode('ascii')
        self.assertIn('USOSV10 1.0 resident', text)
        # self-test: AH=0Fh, AH=03h, AX=0083h (mode 3, no clear), AH=01h, AH=02h
        self.assertEqual([c[0] for c in m.calls[:3]][0] >> 8, 0x0f)
        self.assertIn(0x0083, [c[0] for c in m.calls])
        depth = int(text.split('stack use')[1].split('bytes')[0])
        self.assertGreaterEqual(depth, 300)
        self.assertLess(depth, 400)
        self.assertTrue(text.rstrip().endswith('calls     5'), text)
        # a second start reports from the resident copy and exits
        m.out = b''
        res, state = self.run_install(m, 0x5000)
        self.assertEqual(res, 'exit')
        self.assertEqual(m.ivt(0x10), (0x2000, self.sym['int10']))
        self.assertIn('already resident', m.out.decode('ascii'))
        self.assertIn('calls     5', m.out.decode('ascii'))

    def test_wired(self):
        self.assertIn("'USOSV10.COM'", (ROOT / 'tools/build_dos_native_support.py').read_text(encoding='utf-8'))
        self.assertIn('USOSV10.COM', (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8'))
        self.assertIn(r'copy %USRC%\USOSV10.COM C:\DOS /y >nul',
                      (ROOT / 'src/platform/bios/msdos/install.cmd').read_text(encoding='ascii'))


if __name__ == '__main__':
    unittest.main()
