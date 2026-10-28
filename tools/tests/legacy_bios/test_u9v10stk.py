"""U9V10STK.COM (INT 10h on a private stack for 9x SETUP.EXE) in Unicorn.

The Windows 95 RTM SETUP.EXE situation rebuilt without Microsoft files: a
caller on a 128-byte stack (SS:SP = 3000:0080, the whole segment filled with
CCh) calls INT 10h AX=0003h / AX=1100h, the "old" handler
(u9v10stk_fake10.S, linked at F000:1000) burns 1.5 KiB of stack, nests one
INT 10h (AX=1A00h) for AX=1100h and returns either IRET-style or RETF 2
(live flags). Checked: install (INT 21h 35h/25h/49h/31h, environment freed,
signature at 0103h), the old handler sees the caller's registers and FLAGS
on the private stack with IF=0, the nested call chains on that stack, the
outputs and arithmetic flags come back, IF/TF/DF stay the caller's, and the
caller's stack differs only in the CPU's own 6-byte INT frame.
Hardware: X470 + RX 560 under CSMWrap, 95 RTM native phase 1 PASS with this
TSR (2026-10-26, Kingston B261026-170810 + hotpatched target).
"""
from pathlib import Path
import os
import random
import subprocess
import sys
import unittest

try:
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR
    from unicorn.x86_const import (UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_CX, UC_X86_REG_DX,
                                   UC_X86_REG_SI, UC_X86_REG_DI, UC_X86_REG_BP, UC_X86_REG_SP,
                                   UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS, UC_X86_REG_CS,
                                   UC_X86_REG_IP, UC_X86_REG_EFLAGS)
except ImportError:  # pragma: no cover
    Uc = None

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard  # noqa: E402
from build_win9x_support import build_u9v10stk  # noqa: E402

HERE = Path(__file__).resolve().parent
SEG, OLDSEG, CSEG, SSEG = 0x1000, 0xF000, 0x2000, 0x3000


def build_fake(work: Path) -> bytes:
    zig = str(depguard.require_zig())
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    ld = work / 'fake10.ld'
    ld.write_text('ENTRY(_start)\nSECTIONS { . = 0x1000; .text : { *(.text) } '
                  '/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) } }\n', encoding='ascii')
    obj, elf, out = work / 'fake10.o', work / 'fake10.elf', work / 'fake10.bin'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(HERE / 'u9v10stk_fake10.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ld), str(obj), '-o', str(elf)],
                   env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(out)], env=env, check=True)
    return out.read_bytes()


@unittest.skipIf(Uc is None, 'unicorn not installed')
class U9V10Stk(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        depguard.require_zig()
        work = ROOT / 'zig-out/u9v10stk-test'
        work.mkdir(parents=True, exist_ok=True)
        cls.com = build_u9v10stk(work, work).read_bytes()
        cls.fake = build_fake(work)

    def setUp(self):
        self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        self.u.mem_map(0, 0x110000)
        self.R = dict(ax=UC_X86_REG_AX, bx=UC_X86_REG_BX, cx=UC_X86_REG_CX, dx=UC_X86_REG_DX,
                      si=UC_X86_REG_SI, di=UC_X86_REG_DI, bp=UC_X86_REG_BP, sp=UC_X86_REG_SP,
                      ds=UC_X86_REG_DS, es=UC_X86_REG_ES, ss=UC_X86_REG_SS, cs=UC_X86_REG_CS,
                      ip=UC_X86_REG_IP, fl=UC_X86_REG_EFLAGS)
        self.vec, self.st, self.phase = {}, {'resident': None, 'free_env': None, 'msg': None}, 'init'
        self.u.hook_add(UC_HOOK_INTR, self.intr)

    def rd(self, r):
        return self.u.reg_read(self.R[r]) & 0xffff

    def wr(self, r, v):
        self.u.reg_write(self.R[r], v)

    def w16(self, a):
        return int.from_bytes(self.u.mem_read(a, 2), 'little')

    def intr(self, uc, n, _):
        rd, wr = self.rd, self.wr
        if self.phase == 'init':
            assert n == 0x21, n
            ah, al = rd('ax') >> 8, rd('ax') & 0xff
            if ah == 0x35:
                assert al == 0x10
                wr('bx', 0x1000)
                wr('es', OLDSEG)
            elif ah == 0x25:
                self.vec[al] = (rd('ds'), rd('dx'))
            elif ah == 0x09:
                m = bytes(uc.mem_read(rd('ds') * 16 + rd('dx'), 100))
                self.st['msg'] = m[:m.index(b'$')]
            elif ah == 0x49:
                self.st['free_env'] = rd('es')
            elif ah == 0x31:
                self.st['resident'] = rd('dx')
                uc.emu_stop()
            else:
                raise AssertionError(hex(ah))
            return
        # real-mode INT n through the IVT (IP already points past the INT)
        assert n == 0x10, n
        sp = (rd('sp') - 6) & 0xffff
        uc.mem_write(rd('ss') * 16 + sp, rd('ip').to_bytes(2, 'little') + rd('cs').to_bytes(2, 'little')
                     + rd('fl').to_bytes(2, 'little'))
        wr('sp', sp)
        wr('fl', rd('fl') & ~0x300)
        wr('cs', self.w16(0x42))
        wr('ip', self.w16(0x40))

    def install(self):
        u = self.u
        u.mem_write(SEG * 16 + 0x100, self.com)
        u.mem_write(SEG * 16 + 0x2c, (0x2500).to_bytes(2, 'little'))
        u.mem_write(OLDSEG * 16 + 0x1000, self.fake)
        u.mem_write(OLDSEG * 16 + 0x26, (0x6000).to_bytes(2, 'little'))  # ES the fake returns
        u.mem_write(CSEG * 16, b'\xcd\x10\xf4')  # caller: int 10h / hlt
        for r in ('ss', 'ds', 'es', 'cs'):
            self.wr(r, SEG)
        self.wr('sp', 0xfffe)
        u.emu_start(SEG * 16 + 0x100, 0, count=100000)
        self.phase = 'run'
        u.mem_write(0x40, self.vec[0x10][1].to_bytes(2, 'little') + SEG.to_bytes(2, 'little'))
        img = bytes(u.mem_read(SEG * 16, 0x10000))
        # stktop = the immediate of "mov sp, imm16" (BC xx xx) in the handler
        self.stktop = int.from_bytes(img[img.index(b'\xbc', 0x110) + 1:][:2], 'little')
        self.stkbase = self.stktop - 2048
        return img

    def test_install(self):
        img = self.install()
        self.assertEqual(sorted(self.vec), [0x10])
        self.assertEqual(self.vec[0x10][0], SEG)
        self.assertEqual(self.st['free_env'], 0x2500)
        self.assertEqual(self.w16(SEG * 16 + 0x2c), 0)
        self.assertEqual(img[0x103:0x10b], b'U9V10STK')
        self.assertIn(b'U9V10STK 1.0 resident', self.st['msg'])
        self.assertEqual(self.stkbase % 16, 0)
        self.assertGreaterEqual(self.st['resident'] * 16, self.stktop)
        self.assertEqual(img[self.stkbase:self.stktop], b'\x5a' * 2048)
        # resident part: under 2.5 KiB (stack included)
        self.assertLess(self.st['resident'] * 16, 0x100 + 2560)

    def call(self, ax, dx, cflags):
        u, rd, wr = self.u, self.rd, self.wr
        rnd = random.Random(ax * 7 + dx * 3 + cflags)
        regs = dict(ax=ax, bx=rnd.getrandbits(16), cx=rnd.getrandbits(16), dx=dx,
                    si=rnd.getrandbits(16), di=rnd.getrandbits(16), bp=rnd.getrandbits(16),
                    ds=0x4000, es=0x4100)
        # SETUP.EXE-like 128-byte stack, the whole segment pattern-filled
        u.mem_write(SSEG * 16, bytes([0xcc]) * 0x10000)
        u.mem_write(OLDSEG * 16, bytes(0x26))
        for k, x in regs.items():
            wr(k, x)
        wr('ss', SSEG)
        wr('sp', 0x80)
        wr('fl', cflags)
        wr('cs', CSEG)
        u.emu_start(CSEG * 16, CSEG * 16 + 2, count=50000)
        self.assertEqual((rd('cs'), rd('ip')), (CSEG, 2))
        f = lambda o: self.w16(OLDSEG * 16 + o)  # noqa: E731
        got_in = dict(ax=f(6), bx=f(8), cx=f(10), dx=f(12), si=f(14), di=f(16), bp=f(18), ds=f(20), es=f(22))
        self.assertEqual(got_in, regs)
        self.assertEqual(f(0) & 0x200, 0, 'old handler entered with IF=1')
        self.assertEqual(f(2), SEG, 'old handler not on the private stack')
        self.assertTrue(self.stkbase <= f(4) < self.stktop, hex(f(4)))
        self.assertEqual(f(0x18) & 0xfd5, cflags & 0xfd5, 'FLAGS in the old handler frame')
        if ax == 0x1100:
            self.assertEqual(u.mem_read(OLDSEG * 16 + 0x24, 1)[0], 1)
            self.assertEqual(u.mem_read(OLDSEG * 16 + 0x1e, 1)[0], 0x1a)
            self.assertEqual(f(0x22), SEG)
            self.assertTrue(self.stkbase <= f(0x20) < f(4), 'nested call not on the private stack')
        want = dict(ax=ax ^ 0x5555, bx=(regs['bx'] + 1) & 0xffff, cx=~regs['cx'] & 0xffff,
                    dx=0x5555 if dx == 1 else 0x4444, si=0x1111, di=0x2222, bp=0x3333,
                    ds=OLDSEG, es=0x6000, ss=SSEG, sp=0x80)
        self.assertEqual({k: rd(k) for k in want}, want)
        fl = rd('fl')
        arith = 0x0881 if dx == 1 else ((cflags & 0x08d5) | 0x41) & ~0x80
        self.assertEqual(fl & 0x08d5, arith, hex(fl))
        self.assertEqual(fl & 0x0700, cflags & 0x0700, 'IF/TF/DF not the caller\'s')
        s = bytes(u.mem_read(SSEG * 16, 0x10000))
        bad = [i for i in range(0x10000) if s[i] != 0xcc and not 0x7a <= i < 0x80]
        self.assertFalse(bad, 'caller stack touched')
        self.assertEqual(u.mem_read(SEG * 16 + self.com.index(b'U9V10STK') + 0x100 + 18, 1)[0], 0,
                         'busy flag not cleared')

    def test_mode_set_and_font_load_on_a_128_byte_stack(self):
        self.install()
        for ax in (0x0003, 0x1100):
            for dx in (0, 1):
                for cflags in (0x0002, 0x0202, 0x0603, 0x08c7 | 0x200, 0x0400 | 0x0002):
                    with self.subTest(ax=hex(ax), dx=dx, flags=hex(cflags)):
                        self.call(ax, dx, cflags)
        used = 2048 - next(i for i, b in enumerate(self.u.mem_read(SEG * 16 + self.stkbase, 2048)) if b != 0x5a)
        self.assertGreater(used, 1536)

    def test_wired(self):
        install = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='latin-1').splitlines()
        load = install.index(r'IF EXIST %U9T%\U9V10STK.COM %U9T%\U9V10STK.COM')
        setup = install.index(r'C:\%U9SRC%\SETUP.EXE C:\%U9SRC%\MSBATCH.INF %U9SW%')
        self.assertLess(load, setup)
        self.assertFalse([l for l in install[load + 1:setup] if not l.startswith(('ECHO', 'C:', 'CD'))])
        resume = [l for l in install if l.endswith(r'>>C:\USOS9X\RESUME.BAT')]
        stk = resume.index(r'ECHO IF EXIST C:\USOS9X\U9V10STK.COM C:\USOS9X\U9V10STK.COM>>C:\USOS9X\RESUME.BAT')
        self.assertTrue(resume[stk + 1].startswith(r'ECHO C:\%U9SRC%\SETUP.EXE'))
        self.assertIn('`EFI/USOS/dos-native/win9x/U9V10STK.COM`',
                      (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8'))
        import build_win9x_support
        self.assertIn('U9V10STK.COM', build_win9x_support.STAGED)


if __name__ == '__main__':
    unittest.main()
