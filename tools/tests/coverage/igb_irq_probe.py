"""One read-only Q35/82576 register snapshot, never guest RAM or DMA.

Only a single root 8086:10c9 at 00:03.0 and the Q35 ICH9 LPC are accepted.
Source contracts: QEMU hw/net/igb.c, igb_core.c and hw/isa/lpc_ich9.c.
No ICR/EICR reads: these would acknowledge live interrupt causes.
"""
import re
import struct


class ProbeError(ValueError):
    pass


def mapped_io(text):
    pattern = r'^\s*([0-9a-fA-F]{8,16})-([0-9a-fA-F]{8,16}) \(prio \d+, i/o\): ([a-zA-Z0-9_-]+)\s*$'
    return {(int(a, 16), int(b, 16), name) for a, b, name in re.findall(pattern, text, re.M)}


def parse_bytes(reply, address, size):
    result = bytearray()
    for line in reply.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'\s*(?:0x)?([a-fA-F0-9]+):\s*((?:0x[a-fA-F0-9]{2}\s*)+)', line)
        if not match or int(match[1], 16) != address + len(result):
            raise ProbeError('Unexpected MMIO response')
        result.extend(int(x, 16) for x in re.findall(r'0x([a-fA-F0-9]{2})', match[2]))
        if len(result) > size:
            raise ProbeError('Oversized MMIO response')
    if len(result) != size:
        raise ProbeError('Incomplete MMIO response')
    return bytes(result)


def pci_caps(config):
    msi = msix = None
    at = config[0x34] if config[6] & 0x10 else 0
    visited = set()
    while at:
        if at in visited or at & 3 or not 0x40 <= at <= 0xfc:
            raise ProbeError('Invalid PCI capability chain')
        visited.add(at)
        kind, at_next, control = struct.unpack_from('<BBH', config, at)
        if kind == 5:
            if msi is not None:
                raise ProbeError('Duplicate MSI capability')
            msi = bool(control & 1)
        if kind == 0x11:
            if msix is not None:
                raise ProbeError('Duplicate MSI-X capability')
            msix = bool(control & 0x8000)
        at = at_next
    return dict(msi_enabled=msi, msix_enabled=msix)


async def snapshot(qmp):
    pci = await qmp.command('query-pci')
    devices = [d for b in pci for d in b.get('devices', [])]
    nic = [d for d in devices if d.get('id') == {'vendor': 0x8086, 'device': 0x10c9}]
    lpc = [d for d in devices if d.get('id') == {'vendor': 0x8086, 'device': 0x2918}]
    if len(nic) != 1 or len(lpc) != 1:
        raise ProbeError('Unique Q35 LPC and 82576 required')
    nic, lpc = nic[0], lpc[0]
    if (nic.get('bus'), nic.get('slot'), nic.get('function'), nic.get('class_info', {}).get('class')) != (0, 3, 0, 0x200):
        raise ProbeError('Unexpected NIC BDF/class')
    if (lpc.get('bus'), lpc.get('slot'), lpc.get('function'), lpc.get('class_info', {}).get('class')) != (0, 31, 0, 0x601):
        raise ProbeError('Unexpected LPC BDF/class')
    regions = mapped_io(await qmp.command('human-monitor-command', {'command-line': 'info mtree -f'}))
    ecam = {(a, b) for a, b, name in regions if name == 'pcie-mmcfg-mmio'}
    if len(ecam) != 1:
        raise ProbeError('Unique Q35 ECAM required')
    low, high = next(iter(ecam))
    if low & 0xfffffff or high - low + 1 != 0x10000000 or high >= 2**32:
        raise ProbeError('Unexpected ECAM bounds')
    total = 0

    async def read(address, size, region):
        nonlocal total
        if region not in ('pcie-mmcfg-mmio', 'igb-mmio') or not 0 < size <= 256 or total + size > 512:
            raise ProbeError('Register budget exceeded')
        if not any(n == region and a <= address and address + size - 1 <= b for a, b, n in regions):
            raise ProbeError('Read outside mapped registers')
        total += size
        reply = await qmp.command('human-monitor-command', {'command-line': f'xp /{size}bx 0x{address:x}'})
        return parse_bytes(reply, address, size)

    config = await read(low + (3 << 15), 256, 'pcie-mmcfg-mmio')
    vendor, device, command = struct.unpack_from('<HHH', config)
    if (vendor, device) != (0x8086, 0x10c9) or config[9:12] != b'\0\0\x02' or config[14] & 0x7f:
        raise ProbeError('ECAM NIC identity mismatch')
    bar = struct.unpack_from('<I', config, 0x10)[0]
    bars = [r for r in nic.get('regions', []) if r.get('bar') == 0 and r.get('type') == 'memory']
    if not command & 2 or bar & 15 or len(bars) != 1 or bars[0].get('address') != bar or bars[0].get('size') != 0x20000:
        raise ProbeError('Unsupported or disabled NIC BAR0')
    registers = {}
    for name, offset in (('ctrl', 0), ('status', 8), ('ims', 0xd0), ('rctl', 0x100), ('tctl', 0x400), ('gpie', 0x1514), ('eims', 0x1524), ('eiam', 0x1530)):
        registers[name] = struct.unpack('<I', await read(bar + offset, 4, 'igb-mmio'))[0]
    lpc_at = low + (31 << 15)
    if await read(lpc_at, 4, 'pcie-mmcfg-mmio') != b'\x86\x80\x18\x29':
        raise ProbeError('ECAM LPC identity mismatch')
    routes = await read(lpc_at + 0x60, 4, 'pcie-mmcfg-mmio') + await read(lpc_at + 0x68, 4, 'pcie-mmcfg-mmio')
    return dict(status='ok', pci_bdf='00:03.0', pci_id='8086:10c9', irq_line=nic.get('irq'), irq_pin=nic.get('irq_pin'),
                bus_master_enabled=bool(command & 4), intx_disabled=bool(command & 0x400), **pci_caps(config), registers=registers,
                lpc_pirq_routes=[dict(index=i, disabled=bool(v & 0x80), irq=v & 15) for i, v in enumerate(routes)],
                register_bytes_read=total, read_budget=512, guest_ram_read=False, dma_rings_read=False, raw_replies_saved=False)


async def probe(qmp):
    try:
        return await snapshot(qmp)
    except Exception as error:
        return dict(status='unavailable', error_type=type(error).__name__, reason=str(error) if isinstance(error, ProbeError) else 'Register snapshot failed',
                    guest_ram_read=False, dma_rings_read=False, raw_replies_saved=False)
