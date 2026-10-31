"""Execute the NT 3.1 text-mode key answerer (MBR sector 5, "K3").

NT 3.1 text-mode Setup (SETUPAPP.EXE inside SETUPLDR) has no answer file and
reads its keys through BIOS INT 16h.  On the native path (no install VM) the
NT 3.x MBR's quiesce code loads sector 5 into the second half of the
reserved 1 KiB when bit 2 of the hook options byte is set and points INT 16h
at it; the answerer returns ENTER for the express-path pages the VM runner
answered (nt31_vm_tick) and resets the machine on the final page.  Whole MBR
and the handler itself in Unicorn; the page texts are SETUPAPP's own strings.
"""
from pathlib import Path
import struct
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INSN, UC_HOOK_CODE
from unicorn.x86_const import (UC_X86_REG_AX, UC_X86_REG_CS, UC_X86_REG_IP, UC_X86_REG_SP, UC_X86_REG_SS,
                               UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_FLAGS, UC_X86_INS_OUT, UC_X86_INS_IN)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_nt3_mbr_quiesce as q

OPT_KEYS31 = 4
HOOK_SEG = 639 * 64          # INT 12h top after the MBR's 1 KiB


def build_keys():
    q.build()
    elf = q.OUT / 'nt3-e820-mbr.elf'
    import os, subprocess
    env = os.environ.copy()
    env['ZIG_GLOBAL_CACHE_DIR'] = str(q.base.ROOT / 'tools/cache/zig-global')
    out = q.OUT / 'keys.bin'
    subprocess.run([str(q.base.ROOT / 'tools/zig/zig.exe'), 'objcopy', '-O', 'binary', '-j', '.keys', str(elf), str(out)],
                   env=env, check=True)
    return out.read_bytes()


def screen(text):
    page = bytearray(4000)
    for i in range(2000):
        page[2 * i] = 0x20
        page[2 * i + 1] = 0x1F
    for i, c in enumerate(text.encode('ascii')[:2000]):
        page[2 * i] = c
    return bytes(page)


class Handler:
    """keys.bin at HOOK_SEG:0200, a BIOS INT 16h stub without keys."""
    STUB = 0xF0100

    def __init__(self, keys):
        u = self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        u.mem_write((HOOK_SEG << 4) + 0x200, keys)
        # old INT 16h: AH=01h/11h -> ZF=1 (no key); anything else: AX=0FFFFh
        u.mem_write(self.STUB, bytes([0x80, 0xFC, 0x01, 0x74, 0x0A, 0x80, 0xFC, 0x11, 0x74, 0x05,
                                      0xB8, 0xFF, 0xFF, 0xCF, 0x90,
                                      0x55, 0x89, 0xE5, 0x80, 0x4E, 0x06, 0x40, 0x5D, 0xCF]))
        old = keys.index(b'\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00', keys.index(b'Choose the location'))
        # k_old16 follows the table's final 0 byte: string NUL + table NUL
        self.old16 = (HOOK_SEG << 4) + 0x200 + old + 2
        u.mem_write(self.old16, struct.pack('<HH', 0x0100, 0xF000))
        u.mem_write(0x16 * 4, struct.pack('<HH', 0x0200, HOOK_SEG))
        u.mem_write(0x500, b'\xCD\x16\xF4')       # int 16h ; hlt
        self.outs = []
        u.hook_add(UC_HOOK_INSN, self.out, None, 1, 0, UC_X86_INS_OUT)
        u.hook_add(UC_HOOK_INSN, lambda *a: 0, None, 1, 0, UC_X86_INS_IN)

    def out(self, uc, port, size, value, user):
        self.outs.append((port, value))
        if port == 0x64:
            uc.emu_stop()

    def call(self, ah, page):
        u = self.u
        u.mem_write(0xB8000, page)
        u.reg_write(UC_X86_REG_SS, 0)
        # INT 16h by hand (Unicorn raises INT as an exception): FLAGS, CS, IP
        # of the return to 0000:0502 on the stack, then the vector.
        u.mem_write(0x7000 - 6, struct.pack('<HHH', 0x0502, 0x0000, 0x0202))
        u.reg_write(UC_X86_REG_SP, 0x7000 - 6)
        u.reg_write(UC_X86_REG_DS, 0x1234)
        u.reg_write(UC_X86_REG_ES, 0x2345)
        u.reg_write(UC_X86_REG_AX, ah << 8)
        u.reg_write(UC_X86_REG_FLAGS, 0x0002)
        u.reg_write(UC_X86_REG_CS, HOOK_SEG)
        u.emu_start((HOOK_SEG << 4) + 0x200, 0x502, count=3_000_000)
        flags = u.reg_read(UC_X86_REG_FLAGS)
        return u.reg_read(UC_X86_REG_AX), bool(flags & 0x40)


class Nt3MbrKeys(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = build_keys()
        assert len(cls.keys) == 512 and cls.keys[510:] == b'K3', len(cls.keys)
        cls.mbr, cls.hook, cls.quiesce = q.build()

    def boot(self, options, with_keys=True):
        m = q.PciMachine(self.mbr, self.hook, self.quiesce, q.x470_pci(), options)
        if with_keys:
            m.disk[5] = self.keys
        m.run(count=2_000_000)
        return m

    def test_quiesce_code_hooks_int16_with_the_option_bit(self):
        m = self.boot(q.OPT_QUIESCE | OPT_KEYS31)
        self.assertEqual(struct.unpack('<HH', m.u.mem_read(0x16 * 4, 4)), (0x0200, HOOK_SEG))
        self.assertEqual(bytes(m.u.mem_read((HOOK_SEG << 4) + 0x3FE, 2)), b'K3')
        # The NIC quiesce still ran.
        self.assertEqual(self.cmd(m, 0x25, 0, 0), 0x0402)

    def cmd(self, m, b, d, f):
        return m.pci[q.bdf(b, d, f)][4] & 0xFFFF

    def test_no_option_bit_or_no_sector_leaves_int16(self):
        for opt, keys in ((q.OPT_QUIESCE, True), (q.OPT_QUIESCE | OPT_KEYS31, False)):
            m = self.boot(opt, keys)
            self.assertNotEqual(struct.unpack('<HH', m.u.mem_read(0x16 * 4, 4))[1], HOOK_SEG, (opt, keys))

    def test_express_pages_get_enter_once(self):
        h = Handler(self.keys)
        pages = ['Welcome to Setup.', '   Express Setup (recommended)',
                 'Please select the partition where you would like to install Windows NT.  C:  FAT',
                 'Please select a file system option below.',
                 'Setup installs Windows NT files onto your hard disk. Choose the location']
        for text in pages:
            self.assertEqual(h.call(0x00, screen(text)), (0x1C0D, False), text)   # read: ENTER
            ax, zf = h.call(0x01, screen(text))                                     # same page again: nothing
            self.assertTrue(zf, text)
        # peek first (ENTER waiting), then the read takes it
        h2 = Handler(self.keys)
        self.assertEqual(h2.call(0x11, screen('Welcome to Setup.')), (0x1C0D, False))
        self.assertEqual(h2.call(0x10, screen('Welcome to Setup.'))[0], 0x1C0D)
        self.assertTrue(h2.call(0x11, screen('Welcome to Setup.'))[1])

    def test_unknown_and_error_pages_get_nothing(self):
        h = Handler(self.keys)
        for text in ('Setup was unable to load the file.', 'Please select a file system for C: from the list below.',
                     'This version of Setup requires a CD-ROM drive.  Press CTRL+ALT+DELETE to restart your computer.', ''):
            self.assertTrue(h.call(0x01, screen(text))[1], text)
        self.assertEqual(h.outs, [])
        # other functions pass through unchanged
        self.assertEqual(h.call(0x02, screen('Welcome to Setup.'))[0], 0xFFFF)

    def test_text_on_the_last_cells_and_off_the_page(self):
        h = Handler(self.keys)
        page = bytearray(screen(''))
        word = b'Welcome to Setup.'
        for i, c in enumerate(word):
            page[4000 - 2 * len(word) + 2 * i] = c
        self.assertEqual(h.call(0x00, bytes(page))[0], 0x1C0D)
        h = Handler(self.keys)
        cut = bytearray(screen(''))
        for i, c in enumerate(word[:-1]):
            cut[4000 - 2 * (len(word) - 1) + 2 * i] = c
        self.assertTrue(h.call(0x01, bytes(cut))[1])

    def test_final_page_resets(self):
        h = Handler(self.keys)
        h.call(0x01, screen('Setup has successfully configured your computer for Windows NT.   '
                            'Press CTRL+ALT+DELETE to restart your computer.'))
        self.assertEqual(h.outs, [(0xCF9, 0x02), (0xCF9, 0x06), (0x64, 0xFE)])


if __name__ == '__main__':
    unittest.main()
