"""Execute the NT 3.x MBR's bus-master quiesce (sector 3, "Q3").

A warm reset (the HAL's keyboard-controller reset after a bugcheck or a
restart) need not reset the PCIe devices, and neither the AMI firmware nor
SeaBIOS (CSMWrap) touches the X470's Intel I211 without a PXE boot: a NIC the
last NT boot left receiving could write into the next boot's memory before
usosnet351n resets it.  With bit 1 of the hook options byte (509) the MBR runs
sector 3 before the boot sector; it clears PCI Bus Master Enable on every
network controller (class 02h) and leaves everything else (xHCI: SeaBIOS
drives it) alone.  Whole MBR in Unicorn, PCI configuration mechanism #1
emulated on CF8h/CFCh.
"""
from pathlib import Path
import os
import struct
import subprocess
import sys
import unittest
from unicorn.x86_const import UC_X86_REG_EBP

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_nt3_mbr_cmos_e820 as base

OUT = base.ROOT / 'zig-out/nt3-mbr-quiesce-test'
OPT_KEEP_PCI_BIOS, OPT_QUIESCE = 1, 2


def build():
    base.depguard.require_zig()
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['ZIG_GLOBAL_CACHE_DIR'] = str(base.ROOT / 'tools/cache/zig-global')
    zig = str(base.ROOT / 'tools/zig/zig.exe')
    elf = OUT / 'nt3-e820-mbr.elf'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-nostdlib',
                    '-nodefaultlibs', '-Wl,-T,' + str(base.SRC / 'nt3_e820_mbr.ld'),
                    '-Wl,--entry=nt3_e820_mbr_start', str(base.SRC / 'nt3_e820_mbr.S'), '-o', str(elf)],
                   env=env, check=True)
    parts = {}
    for name in ('.text', '.hook', '.quiesce'):
        out = OUT / (name.strip('.') + '.bin')
        subprocess.run([zig, 'objcopy', '-O', 'binary', '-j', name, str(elf), str(out)], env=env, check=True)
        parts[name] = out.read_bytes()
    return parts['.text'], parts['.hook'], parts['.quiesce']


def bdf(bus, dev, fn):
    return (bus << 16) | (dev << 11) | (fn << 8)


# X470 shape: xHCI 01:00.0 + 0c:00.3, I211 25:00.0, a second NIC 03:00.1, VGA 0a:00.0.
def x470_pci():
    return {
        bdf(0x01, 0, 0): {0: 0x43D51022, 4: 0x00100406, 8: 0x0C033000},
        bdf(0x0C, 0, 3): {0: 0x145F1022, 4: 0x00100406, 8: 0x0C033000},
        bdf(0x25, 0, 0): {0: 0x15398086, 4: 0x00100406, 8: 0x02000003},
        bdf(0x03, 0, 1): {0: 0x816810EC, 4: 0x00100007, 8: 0x02000015},
        bdf(0x0A, 0, 0): {0: 0x731F1002, 4: 0x00100407, 8: 0x030000C1},
    }


class PciMachine(base.Machine):
    def __init__(self, mbr, hook, quiesce, pci, options, with_hook=True, with_quiesce=True):
        super().__init__(mbr, hook, {}, base.X470_MAP, with_hook)
        if with_hook:
            hs = bytearray(self.disk[1])
            hs[509] = options
            self.disk[1] = bytes(hs)
        if with_quiesce:
            self.disk[3] = quiesce
        self.pci = pci
        self.cf8 = 0
        self.pci_writes = []
        self.quiesce_calls = 0

    def code(self, uc, address, size, user):
        # 0000:7C00 is the quiesce code first (called), the VBR (F4) last.
        if address == 0x7C00 and uc.reg_read(base.UC_X86_REG_CS) == 0 and self.started and \
                bytes(uc.mem_read(0x7C00, 1)) != b'\xf4':
            self.quiesce_calls += 1
            return
        super().code(uc, address, size, user)
        if address == (base.BIOS_SEG << 4) + 0x13 * 4:
            # INT 13h wrote 7C00 (quiesce, then the VBR): drop Unicorn's
            # translations of the MBR that ran there first.
            uc.ctl_remove_cache(0x7C00, 0x7E00)

    def reg(self, port):
        dev = self.pci.get(self.cf8 & 0x00FFFF00)
        if not (self.cf8 & 0x80000000) or dev is None:
            return None, 0xFFFFFFFF
        r = self.cf8 & 0xFC
        return dev, dev.get(r, 0)

    def port_in(self, uc, port, size, user):
        if 0xCFC <= port <= 0xCFF:
            _, v = self.reg(port)
            return (v >> ((port - 0xCFC) * 8)) & ((1 << (size * 8)) - 1)
        if port == 0xCF8:
            return self.cf8
        return super().port_in(uc, port, size, user)

    def port_out(self, uc, port, size, value, user):
        if port in (0x70, 0x71):
            return super().port_out(uc, port, size, value, user)
        if port == 0xCF8 and size == 4:
            self.cf8 = value
        elif 0xCFC <= port <= 0xCFF:
            dev, v = self.reg(port)
            self.pci_writes.append((self.cf8, port, size, value))
            if dev is not None:
                shift = (port - 0xCFC) * 8
                mask = ((1 << (size * 8)) - 1) << shift
                dev[self.cf8 & 0xFC] = (v & ~mask) | ((value << shift) & mask)


class Nt3MbrQuiesce(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mbr, cls.hook, cls.quiesce = build()
        assert len(cls.mbr) <= 440, len(cls.mbr)
        assert len(cls.quiesce) == 512 and cls.quiesce[510:] == b'Q3', len(cls.quiesce)

    def boot(self, options, **kw):
        pci = kw.pop('pci', None) or x470_pci()
        m = PciMachine(self.mbr, self.hook, self.quiesce, pci, options, **kw)
        m.run(count=2_000_000)      # the full bus scan: 65536 functions
        return m

    def cmd(self, m, b, d, f):
        return m.pci[bdf(b, d, f)][4] & 0xFFFF

    def test_quiesce_clears_bus_master_on_network_controllers_only(self):
        m = self.boot(OPT_QUIESCE)
        self.assertEqual(self.cmd(m, 0x25, 0, 0), 0x0402)      # I211: BME off, rest kept
        self.assertEqual(self.cmd(m, 0x03, 0, 1), 0x0003)      # any class-02h NIC
        self.assertEqual(self.cmd(m, 0x01, 0, 0), 0x0406)      # xHCI untouched
        self.assertEqual(self.cmd(m, 0x0C, 0, 3), 0x0406)
        self.assertEqual(self.cmd(m, 0x0A, 0, 0), 0x0407)      # VGA untouched
        # Only the two command registers were written, one byte each.
        self.assertEqual(sorted((c & 0xFFFFFF, s) for c, p, s, v in m.pci_writes),
                         [(bdf(0x03, 0, 1) | 4, 1), (bdf(0x25, 0, 0) | 4, 1)])
        self.assertEqual(m.cf8, 0)
        self.assertEqual(sorted(m.writes), [2])                # E820 record only
        self.assertEqual(m.quiesce_calls, 1)

    def test_quiesce_with_keep_pci_bios_bit(self):
        m = self.boot(OPT_QUIESCE | OPT_KEEP_PCI_BIOS)
        self.assertEqual(self.cmd(m, 0x25, 0, 0), 0x0402)

    def test_no_option_bit_no_pci_access(self):
        for opt in (0, OPT_KEEP_PCI_BIOS, 64):
            m = self.boot(opt)
            self.assertEqual(m.pci_writes, [], opt)
            self.assertEqual(self.cmd(m, 0x25, 0, 0), 0x0406)

    def test_no_quiesce_sector_boots_unchanged(self):
        m = self.boot(OPT_QUIESCE, with_quiesce=False)
        self.assertEqual(m.quiesce_calls, 0)
        self.assertEqual(m.pci_writes, [])
        self.assertEqual(self.cmd(m, 0x25, 0, 0), 0x0406)

    def test_no_hook_sector_no_quiesce(self):
        m = self.boot(OPT_QUIESCE, with_hook=False)
        self.assertEqual(m.pci_writes, [])
        self.assertEqual(struct.unpack('<H', m.u.mem_read(0x413, 2))[0], 640)

    def test_boot_drive_and_vbr_kept(self):
        m = self.boot(OPT_QUIESCE)
        self.assertEqual(m.u.reg_read(UC_X86_REG_EBP) & 0xFFFF, 0x80)
        # The VBR (sector 63, F4 = hlt) replaced the quiesce code at 7C00.
        self.assertEqual(bytes(m.u.mem_read(0x7C00, 1)), b'\xf4')


if __name__ == '__main__':
    unittest.main()
