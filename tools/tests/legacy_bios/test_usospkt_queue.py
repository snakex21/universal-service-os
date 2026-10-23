"""USOSPKT.COM queue mode: the second interface for a protected-mode client
(Windows 3.1 DLL) that cannot take a far-call upcall - INT 2Fh AX=5553h
("US"), the shared block (header, 16 x 2048 RX, 4 x 1536 TX, text log) and
the polling protocol. Two layers:

* the source contract - the multiplex number, the subfunctions, the block
  constants and the "no DOS call from the ISR" rule, plus the untouched
  packet-driver entry (INT 60h, "PKT DRVR" at offset 3);
* the built driver in Unicorn: query, ATTACH (once), GET_STATE, TX_KICK,
  RX frames landing in the ring instead of an upcall, the drop counter, the
  log ring, RELEASE going back to upcalls and everything else passed on to
  the previous INT 2Fh handler. Hardware bring-up is out of scope (see
  docs/ds-usospkt-queue-2026-10-23.md).
"""
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard

try:
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INSN
    from unicorn.x86_const import *
except ImportError:                                   # pragma: no cover
    Uc = None

SOURCE = ROOT / 'src/platform/bios/msdos/usospkt.S'
TSR = 0x1000          # resident segment (PSP)
APP = 0x3000          # caller: buffer at 0400h, receiver at 0100h
STUB = 0xF000         # previous handler = IRET
IOBASE = 0xC000
TDT0, RDT0, RCTL = 0xE018, 0xC018, 0x0100
MAC = bytes.fromhex('525400123456')

# the block as usospkt.S lays it out
Q_HDR, Q_SIZE = 128, 39712
Q_RXBUF, Q_RXSTR, Q_RXCNT = 128, 2056, 16
Q_TXBUF, Q_TXSTR, Q_TXCNT = 0x8100, 1544, 4
Q_LOGOFF, Q_LOGSZ = 0x9920, 512
Q_FLAGS, Q_RXHEAD, Q_RXTAIL, Q_RXSTRIDE = 8, 12, 14, 18
Q_TXHEAD, Q_TXTAIL, Q_TXSTRIDE = 24, 26, 30
Q_RXDROP, Q_TXBUSY, Q_TXDONE, Q_TXERR = 36, 40, 44, 52
Q_LOGHEAD, Q_LOGTAIL, Q_LOGBASE = 56, 58, 62
Q_RXBASE, Q_TXBASE = 20, 32
AREASIZE = 2048 + 16 * 2048                            # DMA block (unchanged)

REGS = dict(ax=UC_X86_REG_AX, bx=UC_X86_REG_BX, cx=UC_X86_REG_CX, dx=UC_X86_REG_DX,
            si=UC_X86_REG_SI, di=UC_X86_REG_DI, sp=UC_X86_REG_SP, ds=UC_X86_REG_DS,
            es=UC_X86_REG_ES, ss=UC_X86_REG_SS, fl=UC_X86_REG_EFLAGS) if Uc else {}

# receiver: AX=0 -> ES:DI = APP:0400 (length to [0300]); AX=1 -> count [0306]
RECEIVER = bytes([0x3D, 0x00, 0x00, 0x75, 0x0B, 0xBF, 0x00, 0x04, 0x0E, 0x07,
                  0x2E, 0x89, 0x0E, 0x00, 0x03, 0xCB,
                  0x2E, 0x89, 0x36, 0x02, 0x03, 0x2E, 0x8C, 0x1E, 0x04, 0x03,
                  0x2E, 0xFE, 0x06, 0x06, 0x03, 0xCB])


class Built:
    com = sym = None


def build():
    if Built.com is None:
        depguard.require_zig()
        from build_dos_network import build_usospkt
        from build_win3_usb_keyboard import elf_symbols
        tmp = Path(tempfile.mkdtemp(prefix='usospktq-'))
        com = build_usospkt(ROOT, tmp, tmp)
        Built.com, Built.sym = com.read_bytes(), elf_symbols(tmp / 'usospkt.elf')
    return Built.com, Built.sym


class Machine:
    def __init__(self, tx_done=True):
        com, self.s = build()
        self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        self.u.mem_map(0, 0x110000)
        self.u.mem_write(TSR * 16 + 0x100, com)
        self.u.mem_write(APP * 16, b'\xcd\x60\xcd\x2f\xf4')   # int 60h / int 2Fh / hlt
        self.u.mem_write(APP * 16 + 0x100, RECEIVER)
        self.u.mem_write(STUB * 16, b'\xcf')
        lin = TSR * 16
        self.area = ((lin + self.s['image_end'] + 127) & ~127) - lin
        self.phys = lin + self.area
        self.qoff = (self.area + AREASIZE + 15) & ~15
        self.qseg = TSR + self.qoff // 16
        self.block = self.qseg * 16
        self.poke('acc', b'\x01')
        self.poke('irq', b'\xff')
        self.poke('iobase', struct.pack('<H', IOBASE))
        self.poke('area', struct.pack('<H', self.area))
        self.poke('phys', struct.pack('<I', self.phys))
        self.poke('mac', MAC)
        self.poke('old08', struct.pack('<HH', 0, STUB))
        self.poke('old2f', struct.pack('<HH', 0, STUB))
        self.poke('qoff', struct.pack('<H', self.qoff))
        self.poke('qseg', struct.pack('<H', self.qseg))
        self.ivt(0x60, TSR, self.s['pkt_entry'])
        self.ivt(0x08, TSR, self.s['int08'])
        self.ivt(0x2F, TSR, self.s['int2f'])
        for i in range(16):                       # RX descriptors as nic_start leaves them
            self.u.mem_write(self.phys + i * 16, struct.pack('<IIII', self.phys + 2048 + i * 2048, 0, 0, 0))
        self.regs, self.ioaddr, self.tdh, self.sent, self.tx_done = {RCTL: 0x04008002}, 0, 0, [], tx_done
        self.u.hook_add(UC_HOOK_INSN, self.port_in, None, 1, 0, UC_X86_INS_IN)
        self.u.hook_add(UC_HOOK_INSN, self.port_out, None, 1, 0, UC_X86_INS_OUT)
        self.init_block()

    # -- setup -------------------------------------------------------
    def init_block(self):
        """What the install code writes into the queue block."""
        self.u.mem_write(self.block, bytes(Q_SIZE))
        hdr = {0: b'USQ1', 4: struct.pack('<H', 0x0100), 6: struct.pack('<H', Q_HDR),
               Q_FLAGS: struct.pack('<H', 1), 16: struct.pack('<H', Q_RXCNT),
               Q_RXSTRIDE: struct.pack('<H', Q_RXSTR), Q_RXBASE: struct.pack('<I', Q_RXBUF),
               28: struct.pack('<H', Q_TXCNT), Q_TXSTRIDE: struct.pack('<H', Q_TXSTR),
               Q_TXBASE: struct.pack('<I', Q_TXBUF), 60: struct.pack('<H', Q_LOGSZ),
               Q_LOGBASE: struct.pack('<I', Q_LOGOFF), 70: b'\x60', 72: MAC}
        for off, data in hdr.items():
            self.u.mem_write(self.block + off, data)

    def poke(self, name, data):
        self.u.mem_write(TSR * 16 + self.s[name], data)

    def peek(self, name, n):
        return bytes(self.u.mem_read(TSR * 16 + self.s[name], n))

    def q(self, off, n):
        return bytes(self.u.mem_read(self.block + off, n))

    def qput(self, off, data):
        self.u.mem_write(self.block + off, data)

    def qword(self, off):
        return struct.unpack('<H', self.q(off, 2))[0]

    def qdword(self, off):
        return struct.unpack('<I', self.q(off, 4))[0]

    def ivt(self, n, seg, off):
        self.u.mem_write(n * 4, struct.pack('<HH', off, seg))

    # -- emulated NIC ------------------------------------------------
    def port_in(self, uc, port, size, user):
        if port == IOBASE + 4:
            return self.regs.get(self.ioaddr, 0)
        return 0

    def port_out(self, uc, port, size, value, user):
        if port == IOBASE:
            self.ioaddr = value
        elif port == IOBASE + 4:
            self.regs[self.ioaddr] = value
            if self.ioaddr == TDT0:
                while self.tdh != value:
                    d = self.phys + 256 + self.tdh * 16
                    addr, _, cmd, pay = struct.unpack('<IIII', self.u.mem_read(d, 16))
                    self.sent.append((cmd, pay, bytes(self.u.mem_read(addr, cmd & 0xFFFF))))
                    if self.tx_done:
                        self.u.mem_write(d + 12, struct.pack('<I', pay | 1))
                    self.tdh = (self.tdh + 1) % 8

    # -- calls -------------------------------------------------------
    def call(self, vector=0x60, **r):
        u = self.u
        for k in ('ax', 'bx', 'cx', 'dx', 'si', 'di'):
            u.reg_write(REGS[k], r.get(k, 0))
        u.reg_write(REGS['ds'], r.get('ds', APP))
        u.reg_write(REGS['es'], r.get('es', APP))
        u.reg_write(REGS['ss'], APP)
        u.reg_write(REGS['sp'], 0xFFF0 - 6)
        u.mem_write(APP * 16 + 0xFFF0 - 6, struct.pack('<HHH', 2, APP, 0x202))
        u.reg_write(REGS['fl'], 0x002)
        off, seg = struct.unpack('<HH', u.mem_read(vector * 4, 4))
        u.reg_write(UC_X86_REG_CS, seg)
        u.reg_write(UC_X86_REG_IP, off)
        u.emu_start(seg * 16 + off, APP * 16 + 2, count=2_000_000)
        out = {k: u.reg_read(v) for k, v in REGS.items()}
        out['cf'] = out['fl'] & 1
        out['al'] = out['ax'] & 0xFF
        return out

    def qcall(self, bx, **r):
        return self.call(vector=0x2F, ax=0x5553, bx=bx, **r)

    def mem(self, seg, off, n):
        return bytes(self.u.mem_read(seg * 16 + off, n))

    def put(self, seg, off, data):
        self.u.mem_write(seg * 16 + off, data)

    def access(self, ethertype, receiver=0x100):
        self.put(APP, 0x500, ethertype)
        return self.call(ax=0x0201, bx=0xFFFF, cx=len(ethertype), dx=0, si=0x500, es=APP, di=receiver)

    def rx_frame(self, index, frame, status=0x3):
        self.u.mem_write(self.phys + 2048 + index * 2048, frame)
        self.u.mem_write(self.phys + index * 16 + 8, struct.pack('<II', status, len(frame)))

    def rx_slot(self, index):
        base = Q_RXBUF + index * Q_RXSTR
        return struct.unpack('<HHH', self.q(base, 6)), self.q(base + 8, Q_RXSTR - 8)

    def tx_slot(self, index, frame, head=None):
        base = Q_TXBUF + index * Q_TXSTR
        self.qput(base, struct.pack('<HHH', len(frame), 2, index))
        self.qput(base + 8, frame)
        self.qput(Q_TXHEAD, struct.pack('<H', index + 1 if head is None else head))

    def log_text(self):
        n = self.qword(Q_LOGHEAD)
        return self.q(Q_LOGOFF, n)


class SourceContract(unittest.TestCase):
    """The interface the DLL side is written against (see the report)."""

    @classmethod
    def setUpClass(cls):
        cls.src = SOURCE.read_text(encoding='ascii')

    def test_multiplex_and_subfunctions(self):
        self.assertIn('cmp ax, 0x5553', self.src)
        for bx, label in ((0xFFFF, 'q_query'), (1, 'q_attach'), (2, 'q_state'),
                          (3, 'q_kick'), (4, 'q_free')):
            want = '0xFFFF' if bx == 0xFFFF else str(bx)
            self.assertIn(f'cmp bx, {want}\n    je {label}', self.src)
        # everything else goes to the previous INT 2Fh handler
        self.assertIn('jne q_chain', self.src)
        self.assertIn('JMPFAR old2f', self.src)

    def test_block_constants(self):
        self.assertIn("mov dword ptr es:[Q_MAGIC], 0x31515355   /* \"USQ1\" */", self.src)
        self.assertIn('.set Q_RXBUFSZ, 2048', self.src)
        self.assertIn('.set Q_TXBUFSZ, 1536', self.src)
        self.assertIn('.set Q_TXCOUNT, 4', self.src)
        self.assertIn('.set Q_LOGBUFSZ, 512', self.src)
        self.assertIn('.set Q_SIZE, Q_LOGOFF + Q_LOGBUFSZ   /* 39712 bytes */', self.src)
        self.assertIn('mov word ptr es:[Q_VERSION], 0x0100', self.src)
        # RX ring: the existing hardware ring count, one frame per buffer
        self.assertIn('.set Q_RXSTR, 8 + Q_RXBUFSZ', self.src)
        self.assertIn('.set Q_TXBUF, Q_RXBUF + RX_COUNT * Q_RXSTR', self.src)

    def test_upcalls_switch_off_on_attach(self):
        self.assertIn('or byte ptr es:[Q_FLAGS], QF_ATTACH + QF_SUPPRESS', self.src)
        self.assertIn('and byte ptr es:[Q_FLAGS], 0xFF - (QF_ATTACH + QF_SUPPRESS)', self.src)
        self.assertIn('test byte ptr es:[Q_FLAGS], QF_ATTACH', self.src)
        # the RX path goes through the dispatcher, not straight to deliver
        self.assertIn('call rx_dispatch', self.src)
        self.assertNotIn('    call deliver\n', self.src)

    def test_isr_never_calls_dos(self):
        rx = self.src[self.src.index('q_rx_frame:'):self.src.index('q_tx_kick:')]
        for bad in ('int 0x21', 'int 0x10', 'int 0x2F'):
            self.assertNotIn(bad, rx)
        log = self.src[self.src.index('q_log:'):self.src.index('int2f:')]
        self.assertNotIn('int 0x21', log)

    def test_packet_driver_entry_unchanged(self):
        for ah, target in ((1, 'f_info'), (2, 'f_access'), (3, 'f_release'), (4, 'f_send'),
                           (5, 'f_term'), (6, 'f_getaddr'), (7, 'pk_ok'), (20, 'f_setmode'),
                           (21, 'f_getmode'), (24, 'f_stats'), (25, 'f_setaddr')):
            self.assertIn(f'cmp ah, {ah}\n    je {target}', self.src)
        self.assertIn('.asciz "PKT DRVR"', self.src)
        from build_dos_network import check_usospkt
        check_usospkt(build()[0])

    def test_dma_area_layout_kept(self):
        self.assertIn('.set A_TXRING, 256', self.src)
        self.assertIn('.set A_TXBUF, 512', self.src)
        self.assertIn('.set A_RXBUF, 2048', self.src)
        self.assertIn('.set AREA_SIZE, A_RXBUF + RX_COUNT * BUF_SIZE', self.src)


@unittest.skipIf(Uc is None, 'unicorn missing')
class QueueModeTest(unittest.TestCase):
    def setUp(self):
        self.m = Machine()

    def test_installed_block(self):
        self.assertEqual(self.m.q(0, 4), b'USQ1')
        self.assertEqual((self.m.qword(4), self.m.qword(6)), (0x0100, Q_HDR))
        self.assertEqual((self.m.qword(Q_RXHEAD), self.m.qword(Q_RXTAIL)), (0, 0))
        self.assertEqual(self.m.qword(Q_FLAGS) & 1, 1)          # ready
        self.assertEqual(self.m.qdword(Q_TXBASE), Q_TXBUF)

    def test_query(self):
        r = self.m.qcall(0xFFFF)
        self.assertEqual(r['al'], 0xFF)
        self.assertEqual((r['es'], r['di']), (self.m.qseg, 0))
        self.assertEqual(r['cx'], 0x0100)
        self.assertEqual(r['dx'], 1)                            # ready, not attached

    def test_attach_once_and_release(self):
        r = self.m.qcall(1)
        self.assertEqual((r['al'], r['es'], r['di']), (0, self.m.qseg, 0))
        self.assertEqual(r['cx'], 0x0100)
        self.assertEqual(r['dx'], 1 | 2 | 4)                    # ready + attached + suppress
        self.assertEqual(self.m.qword(Q_FLAGS) & 6, 6)
        self.assertEqual(self.m.qcall(1)['al'], 2)              # already owned
        self.assertEqual(self.m.qcall(4)['al'], 0)              # release
        self.assertEqual(self.m.log_text(), b'ATTACH\r\nRELEASE\r\n')
        self.assertEqual(self.m.qcall(4)['al'], 1)              # nothing attached
        self.assertEqual(self.m.qword(Q_FLAGS) & 6, 0)

    def test_state(self):
        r = self.m.qcall(2)
        self.assertEqual((r['al'], r['es'], r['di']), (0, self.m.qseg, 0))
        self.assertEqual((r['cx'], r['dx']), (0, 0))
        self.m.qcall(1)
        frame = MAC + bytes(6) + b'\x08\x00' + bytes(30)
        self.m.rx_frame(0, frame)
        self.m.call(vector=0x08)
        self.assertEqual(self.m.qcall(2)['cx'], 1)              # one frame waiting

    def test_rx_goes_to_the_ring_not_the_upcall(self):
        self.assertEqual(self.m.access(b'\x08\x00')['ax'], 1)
        self.m.qcall(1)
        frame = MAC + bytes(6) + b'\x08\x00' + bytes(range(90))
        self.m.rx_frame(0, frame)
        self.m.call(vector=0x08)
        (length, flags, seq), data = self.m.rx_slot(0)
        self.assertEqual((length, flags), (len(frame), 1))
        self.assertEqual(data[:len(frame)], frame)
        self.assertEqual(self.m.qword(Q_RXHEAD), 1)
        self.assertEqual(self.m.mem(APP, 0x306, 1), b'\x00')    # no upcall
        self.assertEqual(self.m.regs[RDT0], 0)                  # descriptor given back
        stats = struct.unpack('<7I', self.m.peek('stats', 28))
        self.assertEqual((stats[0], stats[2]), (1, len(frame)))

    def test_rx_ring_full_drops(self):
        self.m.qcall(1)
        frame = MAC + bytes(6) + b'\x08\x00' + bytes(40)
        for i in range(15):                       # 16 slots, one is the full/empty gap
            self.m.rx_frame(i, frame)
        self.m.call(vector=0x08)
        self.assertEqual(self.m.qword(Q_RXHEAD), 15)
        self.assertEqual(self.m.qdword(Q_RXDROP), 0)
        self.assertEqual(self.m.qcall(2)['cx'], 15)             # all waiting
        self.m.rx_frame(15, frame)                # 16th has nowhere to go
        self.m.call(vector=0x08)
        self.assertEqual(self.m.qdword(Q_RXDROP), 1)
        self.assertEqual(self.m.qword(Q_RXHEAD), 15)
        self.m.qput(Q_RXTAIL, struct.pack('<H', 1))             # client drains one
        self.m.rx_frame(0, frame)                 # rx_next wrapped to descriptor 0
        self.m.call(vector=0x08)
        self.assertEqual(self.m.qword(Q_RXHEAD), 0)             # wrapped
        self.assertEqual(self.m.rx_slot(15)[0][0], len(frame))
        self.assertEqual(self.m.rx_slot(0)[0][2], 0)

    def test_rx_errors_counted_for_the_client(self):
        self.m.qcall(1)
        self.m.rx_frame(0, MAC + bytes(6) + b'\x08\x00' + bytes(40), status=0x01000003)
        self.m.call(vector=0x08)
        self.assertEqual(self.m.qdword(48), 1)                  # rx_errors
        self.assertEqual(self.m.qword(Q_RXHEAD), 0)             # nothing queued
        self.assertEqual(struct.unpack('<7I', self.m.peek('stats', 28))[4], 1)

    def test_tx_kick(self):
        frame = bytes(range(60))
        self.m.qcall(1)
        self.m.tx_slot(0, frame)
        r = self.m.qcall(3)
        self.assertEqual(r['al'], 0)
        cmd, pay, data = self.m.sent[-1]
        self.assertEqual(data, frame)
        self.assertEqual(cmd, 60 | 0x2B300000)
        self.assertEqual(pay >> 14, 60)
        self.assertEqual(self.m.regs[TDT0], 1)
        self.assertEqual((self.m.qword(Q_TXTAIL), self.m.qdword(Q_TXDONE)), (1, 1))
        self.assertEqual(self.m.qcall(3)['al'], 1)              # nothing queued
        self.m.qcall(4)
        self.m.tx_slot(0, frame, head=1)
        self.assertEqual(self.m.qcall(3)['al'], 2)              # no client

    def test_tx_kick_timeout(self):
        m = Machine(tx_done=False)
        m.qcall(1)
        m.tx_slot(0, bytes(64))
        self.assertEqual(m.qcall(3)['al'], 3)
        self.assertEqual((m.qdword(Q_TXERR), m.qdword(Q_TXBUSY)), (1, 1))
        self.assertEqual(m.qword(Q_TXTAIL), 1)                  # slot retired
        self.assertIn(b'TX ERR', m.log_text())

    def test_release_returns_to_upcalls(self):
        self.assertEqual(self.m.access(b'\x08\x00')['ax'], 1)
        self.m.qcall(1)
        self.m.qcall(4)
        frame = MAC + bytes(6) + b'\x08\x00' + bytes(40)
        self.m.rx_frame(0, frame)
        self.m.call(vector=0x08)
        self.assertEqual(self.m.qword(Q_RXHEAD), 0)
        self.assertEqual(self.m.mem(APP, 0x306, 1), b'\x01')    # upcall again
        self.assertEqual(self.m.mem(APP, 0x400, len(frame)), frame)

    def test_other_multiplex_passed_on(self):
        r = self.m.call(vector=0x2F, ax=0x1224, bx=0x1234, cx=0x5678)
        self.assertEqual((r['ax'], r['bx'], r['cx']), (0x1224, 0x1234, 0x5678))
        r = self.m.call(vector=0x2F, ax=0x5553, bx=0x0099)
        self.assertEqual((r['ax'], r['bx']), (0x5553, 0x0099))

    def test_queue_block_inside_the_resident_size(self):
        # what the install reports: qoff + Q_SIZE, rounded up to paragraphs
        self.assertGreaterEqual(self.m.qoff + Q_SIZE, self.m.area + AREASIZE)
        self.assertLess(self.m.qoff + Q_SIZE, 0xF000 + Q_SIZE)   # own segment, no wrap


if __name__ == '__main__':
    unittest.main()
