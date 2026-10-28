import asyncio
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('bounded_igb_irq_probe', Path(__file__).with_name('igb_irq_probe.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class Qmp:
    def __init__(self):
        self.calls = []
        self.config = bytearray(256)
        struct.pack_into('<HHHH', self.config, 0, 0x8086, 0x10c9, 7, 0x10)
        self.config[11] = 2
        struct.pack_into('<I', self.config, 0x10, 0x81000000)
        self.config[0x34] = 0x40
        struct.pack_into('<BBH', self.config, 0x40, 5, 0x70, 0)
        struct.pack_into('<BBH', self.config, 0x70, 0x11, 0, 0)
        self.nic = dict(bus=0, slot=3, function=0, id=dict(vendor=0x8086, device=0x10c9),
                        class_info={'class': 0x200}, irq=11, irq_pin=1,
                        regions=[dict(bar=0, type='memory', address=0x81000000, size=0x20000)])
        self.lpc = dict(bus=0, slot=31, function=0, id=dict(vendor=0x8086, device=0x2918), class_info={'class': 0x601})
        self.devices = [self.nic, self.lpc]
        self.tree = ('e0000000-efffffff (prio 1, i/o): pcie-mmcfg-mmio\n'
                     '81000000-8101ffff (prio 1, i/o): igb-mmio\n')
        self.routes = bytes([11] * 8)
        self.bad_reply = False

    async def command(self, name, args=None):
        self.calls.append((name, args))
        if name == 'query-pci':
            return [dict(bus=0, devices=self.devices)]
        command = args['command-line']
        if command == 'info mtree -f':
            return self.tree
        words = command.split()
        if len(words) != 3 or words[0] != 'xp' or not words[1].startswith('/'):
            raise AssertionError('Only exact read-only xp commands allowed')
        size, addr = int(words[1][1:-2]), int(words[2], 16)
        if addr == 0xe0018000 and size == 256:
            data = bytes(self.config)
        elif 0x81000000 <= addr and addr + size <= 0x81020000:
            if addr - 0x81000000 not in (0, 8, 0xd0, 0x100, 0x400, 0x1514, 0x1524, 0x1530):
                raise AssertionError('Unexpected or acknowledging register read')
            data = struct.pack('<I', 0x84 if addr == 0x810000d0 else 0)
        elif addr == 0xe00f8000 and size == 4:
            data = b'\x86\x80\x18\x29'
        elif addr == 0xe00f8060 and size == 4:
            data = self.routes[:4]
        elif addr == 0xe00f8068 and size == 4:
            data = self.routes[4:]
        else:
            raise AssertionError('Unexpected or RAM address')
        if self.bad_reply:
            return 'private arbitrary server payload'
        return '\n'.join(f'{addr+i:016x}: ' + ' '.join(f'0x{x:02x}' for x in data[i:i+16]) for i in range(0, len(data), 16))


class ProbeTests(unittest.IsolatedAsyncioTestCase):
    async def test_complete_bounded_snapshot(self):
        q = Qmp()
        result = await p.probe(q)
        self.assertEqual(result['status'], 'ok')
        self.assertEqual(result['register_bytes_read'], 300)
        self.assertFalse(result['guest_ram_read'])
        self.assertFalse(result['msix_enabled'])
        self.assertEqual(result['registers']['ims'], 0x84)
        self.assertTrue(all(not x['disabled'] and x['irq'] == 11 for x in result['lpc_pirq_routes']))

    async def test_enabled_msix_and_disabled_pin_remain_distinct(self):
        q = Qmp()
        struct.pack_into('<H', q.config, 4, 0x407)
        struct.pack_into('<H', q.config, 0x72, 0x8000)
        q.routes = bytes([0x80] * 8)
        result = await p.probe(q)
        self.assertTrue(result['msix_enabled'])
        self.assertTrue(result['intx_disabled'])
        self.assertTrue(all(x['disabled'] for x in result['lpc_pirq_routes']))

    async def test_qapi_subsystem_fields_do_not_change_identity(self):
        q = Qmp()
        q.nic['id'].update(subsystem=0x10c9, **{'subsystem-vendor': 0x8086})
        q.lpc['id'].update(subsystem=0x1100, **{'subsystem-vendor': 0x1af4})
        self.assertEqual((await p.probe(q))['status'], 'ok')

    async def test_duplicate_target_refused_before_read(self):
        q = Qmp(); q.devices.append(q.nic)
        self.assertEqual((await p.probe(q))['status'], 'unavailable')
        self.assertEqual(len(q.calls), 1)

    async def test_wrong_bdf_refused_before_read(self):
        q = Qmp(); q.nic['slot'] = 4
        self.assertEqual((await p.probe(q))['status'], 'unavailable')
        self.assertEqual(len(q.calls), 1)

    async def test_unmapped_bar_refused_without_access(self):
        q = Qmp(); q.tree = q.tree.splitlines()[0]
        result = await p.probe(q)
        self.assertEqual(result['status'], 'unavailable')
        self.assertEqual(len(q.calls), 3)  # ECAM only, no BAR read.

    async def test_wrong_ecam_size_refused(self):
        q = Qmp(); q.tree = q.tree.replace('efffffff', 'e00fffff')
        self.assertEqual((await p.probe(q))['status'], 'unavailable')
        self.assertEqual(len(q.calls), 2)

    async def test_ecam_identity_mismatch_refused(self):
        q = Qmp(); q.config[0] = 0
        self.assertEqual((await p.probe(q))['status'], 'unavailable')
        self.assertEqual(len(q.calls), 3)

    async def test_raw_reply_never_exported(self):
        q = Qmp(); q.bad_reply = True
        result = await p.probe(q)
        self.assertEqual(result['status'], 'unavailable')
        self.assertNotIn('private', repr(result))

    def test_capability_loop_refused(self):
        q = Qmp(); q.config[0x71] = 0x40
        with self.assertRaises(p.ProbeError): p.pci_caps(q.config)

    def test_reply_offset_and_length_must_match(self):
        for text in ('1001: 0x01', '1000: 0x01 0x02', '1000: 0x01\n1002: 0x02'):
            with self.assertRaises(p.ProbeError): p.parse_bytes(text, 0x1000, 1 if '\n' not in text else 2)


if __name__ == '__main__':
    unittest.main()
