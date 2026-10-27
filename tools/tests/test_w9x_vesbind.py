"""Execute the same C parser on synthetic exports; original DOS is separate."""
from pathlib import Path
import os, re, shutil, subprocess, sys, unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh,scratch
ROOT=Path(__file__).resolve().parents[2]
CLS=r'HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Class\Display'
DEVICE=r'HKEY_LOCAL_MACHINE\Enum\PCI\VEN_1002&DEV_67DF&SUBSYS_E3661DA2&REV_EF\BUS_0A&DEV_00&FUNC_00'
ID=r'HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\IDConfigDB'
CONFIG=r'HKEY_LOCAL_MACHINE\Config\0001\Display\Settings'
def reg(sections):
    return ('REGEDIT4\r\n\r\n'+'\r\n\r\n'.join('['+key+']\r\n'+body for key,body in sections)+'\r\n').encode('ascii')
CLASSES=reg([(CLS+r'\0000','"InfPath"="USOSVESA.INF"'),
    (CLS+r'\0000\DEFAULT','"drv"="vesamini.drv"\r\n"minivdd"="vesamini.vxd"\r\n"Mode"="16,1024,768"'),
    (CLS+r'\0001','"InfPath"="MSDISP.INF"'),
    (CLS+r'\0001\DEFAULT','"drv"="vga.drv"')])
ENUM=reg([(DEVICE,'"Class"="Display"\r\n"Driver"="Display\\\\0001"')])
IDCONFIG=reg([(ID,'"CurrentConfig"="0001"')])

def host_binary():
    """USOS_VESBIND_HOST_EXE, else a native build with gcc / cc from PATH."""
    value=os.environ.get('USOS_VESBIND_HOST_EXE')
    if value:
        binary=Path(value).resolve();assert binary.is_file();return binary
    compiler=shutil.which('gcc') or shutil.which('cc')
    if not compiler:raise unittest.SkipTest('Set USOS_VESBIND_HOST_EXE to a native build of vesbind.c (no gcc / cc)')
    out=scratch('vesbind-host-')/('vesbind'+('.exe' if os.name=='nt' else ''))
    subprocess.run([compiler,'-O1','-Wall','-Werror','-Wno-misleading-indentation','-o',str(out),str(ROOT/'src/platform/bios/win9x/vesbind.c')],check=True)
    return out

class Parser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary=host_binary()
    def setUp(self):
        self.tmp=scratch('vesbind-');self.addCleanup(shutil.rmtree,self.tmp,ignore_errors=True)
    def run_parser(self,classes=CLASSES,enum=ENUM,idconfig=IDCONFIG,config=None):
        for name,data in [('classes.reg',classes),('enum.reg',enum),('id.reg',idconfig)]:
            (self.tmp/name).write_bytes(data)
        last=self.tmp/'output.reg'
        if config is not None:last.write_bytes(config)
        elif last.exists():last.unlink()
        result=subprocess.run([str(self.binary),'CHECK' if config is not None else 'PLAN',
            str(self.tmp/'classes.reg'),str(self.tmp/'enum.reg'),str(self.tmp/'id.reg'),str(last)],capture_output=True)
        self.assertFalse(result.stdout+result.stderr)
        return result.returncode,last.read_bytes() if last.exists() else None
    def test_actual_device_path_is_preserved_only_binding_and_current_profile_written(self):
        rc,out=self.run_parser();self.assertEqual(rc,0)
        self.assertEqual(out,reg([(DEVICE,'"Driver"="Display\\\\0000"'),
            (CONFIG,'"BitsPerPixel"="16"\r\n"Resolution"="1024,768"')]))
        self.assertNotIn(b'1234',out)
        self.assertNotIn(b'InfPath',out)
    def test_legacy_device_and_real_current_profile(self):
        device=r'HKEY_LOCAL_MACHINE\Enum\Root\*PNP0900\0000'
        rc,out=self.run_parser(enum=ENUM.replace(DEVICE.encode(),device.encode()),
            idconfig=IDCONFIG.replace(b'0001',b'0002'))
        self.assertEqual(rc,0);self.assertIn(device.encode(),out)
        self.assertIn(b'Config\\0002\\Display\\Settings',out)
    def test_multiple_or_missing_display_and_custom_driver_are_rejected(self):
        for data in [reg([]),ENUM+reg([(DEVICE.replace('67DF','67FF'),
            '"Class"="Display"\r\n"Driver"="Display\\\\0001"')]).split(b'\r\n\r\n',1)[1],
            ENUM.replace(b'"Display"',b'"Net"')]:
            self.assertNotEqual(self.run_parser(enum=data)[0],0)
        self.assertNotEqual(self.run_parser(classes=CLASSES.replace(b'MSDISP.INF',b'CUSTOM.INF'))[0],0)
        self.assertNotEqual(self.run_parser(classes=CLASSES.replace(b'vesamini.vxd',b'other.vxd'))[0],0)
    def test_malformed_duplicate_and_truncated_input_fail_closed(self):
        for data in [b'',ENUM.replace(b'REGEDIT4',b'Windows Registry Editor Version 5.00'),
            ENUM.replace(b'"Class"="Display"',b'"Class"="Display"\r\n"Class"="Display"'),
            ENUM.replace(b'Display\\\\0001',b'Display\\x0001'),b'REGEDIT4\r\n'+b'x'*800]:
            rc,out=self.run_parser(enum=data);self.assertNotEqual(rc,0);self.assertIsNone(out)
        self.assertNotEqual(self.run_parser(idconfig=IDCONFIG.replace(b'0001',b'zero'))[0],0)
    def test_check_requires_binding_and_both_mode_values(self):
        config=reg([(CONFIG,'"BitsPerPixel"="16"\r\n"Resolution"="1024,768"')])
        active=ENUM.replace(b'Display\\\\0001',b'Display\\\\0000')
        self.assertEqual(self.run_parser(enum=active,config=config)[0],0)
        self.assertNotEqual(self.run_parser(config=config)[0],0)
        self.assertNotEqual(self.run_parser(enum=active,config=config.replace(b'1024,768',b'640,480'))[0],0)
        self.assertNotEqual(self.run_parser(enum=active,config=config.replace(b'"BitsPerPixel"',b'"Other"'))[0],0)

    # The X470 950 PL state (2026-10-25, synthetic minimal copy of VL2/VL3):
    # the early import put the legacy *PNP0900 on Display\0000 (USOSVESA),
    # GUI PnP then installed the RX 560 from USOSVESA.INF as its own
    # Display\0001 (16,640,480 default) and kept *PNP0900.
    PCI950 = r'HKEY_LOCAL_MACHINE\Enum\PCI\VEN_1002&DEV_67EF\BUS_0A&DEV_00&FUNC_00'
    ROOT950 = r'HKEY_LOCAL_MACHINE\Enum\Root\*PNP0900\0000'
    CLASSES950 = reg([(CLS, '@="Karty graficzne"\r\n"Installer"="SetupX.Dll, Display_ClassInstaller"'),
        (CLS + r'\0000', '"Ver"="4.0"\r\n"DevLoader"="*vdd"\r\n"InfPath"="USOSVESA.INF"\r\n"InfSection"="VESA"'),
        (CLS + r'\0000\DEFAULT', '"Mode"="16,1024,768"\r\n"drv"="vesamini.drv"\r\n"vdd"="*vdd"\r\n"minivdd"="vesamini.vxd"'),
        (CLS + r'\0000\MODES\16\1024,768', ''),
        (CLS + r'\0001', '"InfPath"="USOSVESA.INF"\r\n"InfSection"="VESA"\r\n"DriverDesc"="vesa (vmdisp9x) 1002:67ef"'),
        (CLS + r'\0001\DEFAULT', '"drv"="vesamini.drv"\r\n"minivdd"="vesamini.vxd"\r\n"Mode"="16,640,480"'),
        (CLS + r'\0001\MODES\4\640,480', '"drv"="vga.drv"')])
    ENUM950 = reg([(r'HKEY_LOCAL_MACHINE\Enum\Monitor\Default_Monitor\0001', '"Class"="Monitor"\r\n"Driver"="Monitor\\\\0000"'),
        (r'HKEY_LOCAL_MACHINE\Enum\Root\*PNP0900', ''),
        (ROOT950, '"InfName"="MSDISP.INF"\r\n"Class"="Display"\r\n"HardwareID"="*PNP0900"\r\n"Driver"="Display\\\\0000"'),
        (ROOT950 + r'\LogConfig', '"0"=hex:00,04,00,00'),
        (r'HKEY_LOCAL_MACHINE\Enum\PCI\VEN_1002&DEV_67EF', ''),
        (PCI950, '"CompatibleIDs"="PCI\\\\CC_0300"\r\n"Class"="DISPLAY"\r\n"Driver"="DISPLAY\\\\0001"\r\n'
                 '"Mfg"="JHRobotics (vmdisp9x, via USOS)"'),
        (PCI950 + r'\LogConfig', '"0000"=hex:00,04,00,00'),
        (r'HKEY_LOCAL_MACHINE\Enum\PCI\VEN_8086&DEV_1539\BUS_04&DEV_00&FUNC_00', '"Class"="Net"\r\n"Driver"="Net\\\\0009"')])

    # The export after VESALATE's VESBIND DELKEY Enum\Root\*PNP0900 (exit 3 path):
    # no legacy display devnode any more.
    def without_legacy(self, enum=None):
        enum = self.ENUM950 if enum is None else enum
        start = enum.index(b'[HKEY_LOCAL_MACHINE\\Enum\\Root\\*PNP0900]')
        end = enum.index(b'[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_1002&DEV_67EF]')
        return enum[:start] + enum[end:]

    def test_950_pnp_vesa_binding_next_to_the_legacy_device_writes_the_mode_and_drops_the_legacy(self):
        rc, out = self.run_parser(classes=self.CLASSES950, enum=self.ENUM950)
        self.assertEqual(rc, 3)  # plan written + the batch deletes Enum\Root\*PNP0900
        self.assertEqual(out, reg([(CLS + r'\0001\DEFAULT', '"Mode"="16,1024,768"'),
            (CONFIG, '"BitsPerPixel"="16"\r\n"Resolution"="1024,768"')]))
        self.assertNotIn(b'"Driver"', out)
        config = reg([(CONFIG, '"BitsPerPixel"="16"\r\n"Resolution"="1024,768"')])
        alone = self.without_legacy()
        self.assertNotIn(b'PNP0900', alone)
        self.assertIn(self.PCI950.encode(), alone)
        self.assertEqual(self.run_parser(classes=self.CLASSES950, enum=alone, config=config)[0], 0)
        # The legacy display still there: CHECK fails -> rollback.
        self.assertNotEqual(self.run_parser(classes=self.CLASSES950, enum=self.ENUM950, config=config)[0], 0)
        self.assertNotEqual(self.run_parser(classes=self.CLASSES950, enum=alone,
            config=config.replace(b'1024,768', b'640,480'))[0], 0)
        # Without the legacy devnode PLAN is a plain mode plan again.
        self.assertEqual(self.run_parser(classes=self.CLASSES950, enum=alone)[0], 0)

    def test_950_pci_on_the_early_vesa_class_writes_the_profile_only(self):
        enum = self.ENUM950.replace(b'DISPLAY\\\\0001', b'Display\\\\0000')
        rc, out = self.run_parser(classes=self.CLASSES950, enum=enum)
        self.assertEqual(rc, 3)
        self.assertEqual(out, reg([(CONFIG, '"BitsPerPixel"="16"\r\n"Resolution"="1024,768"')]))
        self.assertEqual(self.run_parser(classes=self.CLASSES950, enum=self.without_legacy(enum))[0], 0)

    def test_legacy_device_next_to_a_pci_display_on_msdisp_is_rebound_and_dropped(self):
        msdisp = self.CLASSES950.replace(b'"InfPath"="USOSVESA.INF"\r\n"InfSection"="VESA"\r\n"DriverDesc"="vesa',
                                         b'"InfPath"="MSDISP.INF"\r\n"InfSection"="VGA"\r\n"DriverDesc"="vesa')
        msdisp = msdisp.replace(b'"drv"="vesamini.drv"\r\n"minivdd"="vesamini.vxd"\r\n"Mode"="16,640,480"', b'"drv"="vga.drv"')
        self.assertIn(b'MSDISP.INF', msdisp)
        rc, out = self.run_parser(classes=msdisp, enum=self.ENUM950)
        self.assertEqual(rc, 3)
        self.assertIn(b'[' + self.PCI950.encode() + b']\r\n"Driver"="Display\\\\0000"\r\n', out)
        self.assertNotIn(b'PNP0900', out)
        # Without the legacy device the MSDISP one is rebound as before.
        alone = self.ENUM950.replace(b'"Class"="Display"\r\n"HardwareID"="*PNP0900"', b'"Class"="Other"\r\n"HardwareID"="*PNP0900"')
        rc, out = self.run_parser(classes=msdisp, enum=alone)
        self.assertEqual(rc, 0)
        self.assertIn(b'[' + self.PCI950.encode() + b']\r\n"Driver"="Display\\\\0000"\r\n', out)
        # A custom driver on the PCI display still fails.
        custom = self.CLASSES950.replace(b'"Mode"="16,640,480"', b'"Mode"="16,640,480"').replace(
            b'"DriverDesc"="vesa (vmdisp9x) 1002:67ef"', b'"DriverDesc"="x"').replace(
            b'\\0001\\DEFAULT]\r\n"drv"="vesamini.drv"', b'\\0001\\DEFAULT]\r\n"drv"="atidrv.drv"')
        self.assertNotEqual(self.run_parser(classes=custom, enum=self.ENUM950)[0], 0)
        # Two PCI displays or two legacy ones stay ambiguous.
        two = self.ENUM950 + reg([(self.PCI950.replace('BUS_0A', 'BUS_0B'), '"Class"="Display"\r\n"Driver"="Display\\\\0001"')]).split(b'\r\n\r\n', 1)[1]
        self.assertNotEqual(self.run_parser(classes=self.CLASSES950, enum=two)[0], 0)
        two = self.ENUM950 + reg([(self.ROOT950.replace('\\0000', '\\0001'), '"Class"="Display"\r\n"Driver"="Display\\\\0000"')]).split(b'\r\n\r\n', 1)[1]
        self.assertNotEqual(self.run_parser(classes=self.CLASSES950, enum=two)[0], 0)

# --- DELKEY: synthetic Windows 95 CREG hives (own builder, no MS data) ---
import struct
from w9x_creg import Hive, NONE


def creg(tree, per_block=6, checksums=True, slack=0):
    """tree: {name: (values, subtree)}; values: [(name, type, bytes)].
    Entries 1Ch bytes from RGKN+20h, never across a 4 KB page; per_block
    records to a block, each block ending in one free record (as on 950)."""
    entries, recs = [], []          # entry: [parent, child, next, id, blk]

    def add(name, values, parent):
        entries.append([parent, None, None, 0, 0]); recs.append((name, values)); return len(entries) - 1

    def walk(sub, parent):
        prev = None
        for name, (values, kids) in sub.items():
            i = add(name, values, parent)
            if prev is None: entries[parent][1] = i
            else: entries[prev][2] = i
            prev = i; walk(kids, i)
    add('', [], None); walk(tree, 0)
    rel, pos = [], 0x20
    for _ in entries:
        if (pos & 0xfff) + 0x1c > 0x1000: pos = (pos | 0xfff) + 1
        rel.append(pos); pos += 0x1c
    kn_size = (pos + 0x40 + 0xfff) & ~0xfff
    rgkn = bytearray(kn_size)
    flags = 0x0d if checksums else 0x0b
    struct.pack_into('<4sIIIII', rgkn, 0, b'RGKN', kn_size, 0x20, pos, flags, 0)
    struct.pack_into('<III', rgkn, pos, 0x80000000, kn_size - pos, NONE)
    blocks = [[] for _ in range((len(recs) + per_block - 1) // per_block)]
    for i, (name, values) in enumerate(recs):
        b, kid = divmod(i, per_block); entries[i][3] = kid; entries[i][4] = b
        body = b''.join(struct.pack('<IIHH', t, 0, len(n), len(d)) + n.encode('cp1250') + d for n, t, d in values)
        raw = name.encode('cp1250')
        used = 0x14 + len(raw) + len(body)
        blocks[b].append(struct.pack('<IHHIHHI', used + slack, kid, b, used, len(raw), len(values), 0)
                         + raw + body + b'\0' * slack)
    z = lambda v: NONE if v is None else rel[v]
    for i, e in enumerate(entries):
        struct.pack_into('<IIIIIIHH', rgkn, rel[i], 0, sum(recs[i][0].upper().encode()), NONE,
                         z(e[0]), z(e[1]), z(e[2]), e[3], e[4])

    def fix(buf, at):
        if checksums:
            total = sum(struct.unpack('<%dI' % (len(buf) // 4), bytes(buf))) & 0xffffffff
            struct.pack_into('<I', buf, at, (-total) & 0xffffffff)
    fix(rgkn, 0x14)
    out = []
    for b, items in enumerate(blocks):
        data = b''.join(items)
        size = (0x20 + len(data) + 0x40 + 3) & ~3
        blk = bytearray(size)
        free_at = 0x20 + len(data)
        struct.pack_into('<4sIIHHIHHII', blk, 0, b'RGDB', size, size - free_at, flags, b, free_at,
                         len(items) - 1, len(items), 0, 0)
        blk[0x20:free_at] = data
        struct.pack_into('<IHHI', blk, free_at, size - free_at, 0xffff, 0xffff, NONE)
        fix(blk, 0x1c); out.append(bytes(blk))
    head = bytearray(0x20)
    struct.pack_into('<4sIIIHH', head, 0, b'CREG', 0x10000, 0x20 + kn_size, 0, len(out), 5 if checksums else 1)
    fix(head, 0x0c)
    return bytes(head) + bytes(rgkn) + b''.join(out)


def dump(data):
    """Every key path (lower case) -> its values; a key reached twice fails."""
    hive, out, seen = Hive(data), {}, set()

    def walk(rel, path):
        for name, child in hive.children(rel):
            assert child not in seen; seen.add(child)
            p = path + '\\' + name
            out[p.lower()] = hive._record(child)[1]
            walk(child, p)
    walk(hive.root, '')
    return out


def sums_ok(data):
    """Every section with flag bit 2 sums to 0; returns how many have one."""
    def total(b): return sum(struct.unpack('<%dI' % (len(b) // 4), b)) & 0xffffffff
    n = 0
    if struct.unpack_from('<H', data, 0x12)[0] & 4:
        assert total(data[:0x20]) == 0, 'CREG'; n += 1
    size = struct.unpack_from('<I', data, 0x24)[0]
    if struct.unpack_from('<H', data, 0x30)[0] & 4:
        assert total(data[0x20:0x20 + size]) == 0, 'RGKN'; n += 1
    off = 0x20 + size
    for b in range(struct.unpack_from('<H', data, 0x10)[0]):
        bs = struct.unpack_from('<I', data, off + 4)[0]
        if struct.unpack_from('<H', data, off + 0x0c)[0] & 4:
            assert total(data[off:off + bs]) == 0, b; n += 1
        off += bs
    return n


def rgdb_problems(data):
    """Per RGDB block the free-list faults the 950 VMM trips over: the list
    from header +10 (next at record +08, -1 ends it) must reach every free
    record exactly once, only free records, and header +08 must be their
    total. {block: [fault, ...]}; empty = consistent."""
    size = struct.unpack_from('<I', data, 0x24)[0]
    off, faults = 0x20 + size, {}
    for b in range(struct.unpack_from('<H', data, 0x10)[0]):
        bs, fb, _f, _n, ff = struct.unpack_from('<IIHHI', data, off + 4)
        pos, frees, bad = 0x20, {}, []
        while pos < bs:
            rs, kid, blk = struct.unpack_from('<IHH', data, off + pos)
            assert 0x14 <= rs <= bs - pos
            if kid == 0xffff:
                assert blk == 0xffff; frees[pos] = rs
            pos += rs
        assert pos == bs
        chain, q = [], ff
        while q != NONE:
            if q in chain: bad.append('loop at %#x' % q); break
            if q not in frees: bad.append('list -> %#x, not a free record' % q); break
            chain.append(q); q = struct.unpack_from('<I', data, off + q + 8)[0]
        if not bad and set(chain) != set(frees):
            bad.append('free records not on the list: %s' % sorted(set(frees) - set(chain)))
        if fb != sum(frees.values()):
            bad.append('header free %#x != %#x' % (fb, sum(frees.values())))
        if bad: faults[b] = bad
        off += bs
    return faults


def free_lists(data):
    """RGKN free chunks (offset, size) in list order; per block (header free
    bytes, header first free, [(pos, size) of the free records in list
    order]). Every block's free list must be consistent (rgdb_problems)."""
    size, _root, first = struct.unpack_from('<III', data, 0x24)
    chunks, cur = [], first
    while cur != NONE:
        flag, csize, nxt = struct.unpack_from('<III', data, 0x20 + cur)
        assert flag == 0x80000000; chunks.append((cur, csize)); cur = nxt
    assert not rgdb_problems(data), rgdb_problems(data)
    blocks, off = [], 0x20 + size
    for _ in range(struct.unpack_from('<H', data, 0x10)[0]):
        bs, fb, _f, _n, ff = struct.unpack_from('<IIHHI', data, off + 4)
        frees, q = [], ff
        while q != NONE:
            rs, ids, q2 = struct.unpack_from('<III', data, off + q)
            assert ids == NONE              # +04: id and block both -1; +08: next
            frees.append((q, rs)); q = q2
        blocks.append((fb, ff, frees)); off += bs
    return chunks, blocks


def SZ(s): return (s + '\0').encode('cp1250')


TREE = {
    'Enum': ([], {
        'Monitor': ([('Class', 1, SZ('Monitor'))],
                    {'Default_Monitor': ([], {'0001': ([('Driver', 1, SZ('Monitor\\0000'))], {})})}),
        'Root': ([], {
            '*PNP0A03': ([('Class', 1, SZ('System'))], {'0000': ([], {})}),
            '*PNP0900': ([], {'0000': ([('Class', 1, SZ('Display')), ('Driver', 1, SZ('Display\\0000')),
                                        ('ConfigFlags', 3, b'\0\0\0\0')],
                                       {'LogConfig': ([('0', 3, bytes(range(40)))], {})})}),
            '*PNP0F0E': ([('Class', 1, SZ('Mouse'))], {})}),
        'PCI': ([], {'VEN_1002&DEV_67EF': ([], {'BUS_0A&DEV_00&FUNC_00': ([('Class', 1, SZ('DISPLAY'))], {})})})}),
    'System': ([], {'CurrentControlSet': ([], {'Services': ([('x', 1, SZ('y'))], {})})}),
}
LEGACY = 'Enum\\Root\\*PNP0900'


class DelKey(unittest.TestCase):
    """VESBIND DELKEY: VESALATE's replacement for REGEDIT /D, which the 950
    real-mode REGEDIT does not have."""
    @classmethod
    def setUpClass(cls):
        cls.binary = host_binary()

    def setUp(self):
        self.tmp = scratch('delkey-'); self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def run_del(self, data, key):
        hive = self.tmp / 'SYSTEM.DAT'; hive.write_bytes(data)
        result = subprocess.run([str(self.binary), 'DELKEY', str(hive), key], capture_output=True)
        self.assertFalse(result.stdout + result.stderr)
        return result.returncode, hive.read_bytes()

    def check_deleted(self, data, key, gone):
        before = dump(data); sums_ok(data)
        rc, after = self.run_del(data, key)
        self.assertEqual(rc, 0)
        self.assertEqual(len(after), len(data))
        new = dump(after)
        removed = {k for k in before if k == gone or k.startswith(gone + '\\')}
        self.assertTrue(removed)
        self.assertEqual(set(new), set(before) - removed)
        for k in new:
            self.assertEqual(new[k], before[k], k)      # parents, siblings, values intact
        sums_ok(after); free_lists(after)
        return before, after, removed

    def test_optional_log_distinguishes_open_header_missing_key_and_success(self):
        hive=self.tmp/'SYSTEM.DAT';log=self.tmp/'VLDEL.LOG'
        valid=creg(TREE)
        for data,key,code,reason in ((None,'Enum',2,'hive-open'),
                                    (b'not a hive','Enum',2,'creg-header'),
                                    (valid,'DoesNotExist',1,'not-found'),
                                    (valid,r'Enum\Root\*PNP0900',0,'complete')):
            with self.subTest(reason=reason):
                if hive.exists():hive.unlink()
                if data is not None:hive.write_bytes(data)
                result=subprocess.run([str(self.binary),'DELKEY',str(hive),key,str(log)],capture_output=True)
                self.assertEqual(result.returncode,code)
                self.assertFalse(result.stdout+result.stderr)
                self.assertEqual(log.read_bytes(),f'version=1\r\nexit={code}\r\nreason={reason}\r\n'.encode('ascii'))
                if data is not None and code:self.assertEqual(hive.read_bytes(),data)
                if code==0:self.assertNotIn(r'\enum\root\*pnp0900',dump(hive.read_bytes()))

    def test_deletes_a_middle_sibling_and_its_subtree(self):
        data = creg(TREE)
        _, after, removed = self.check_deleted(data, LEGACY, '\\enum\\root\\*pnp0900')
        self.assertEqual(len(removed), 3)
        chunks, blocks = free_lists(after)
        old_chunks, old_blocks = free_lists(data)
        self.assertEqual(sums_ok(after), 2 + len(blocks))
        # Three freed entries, sorted, in front of the old tail chunk.
        self.assertEqual([c[1] for c in chunks[:-1]], [0x1c] * 3)
        self.assertEqual(chunks[-1], old_chunks[-1])
        self.assertEqual([c[0] for c in chunks], sorted(c[0] for c in chunks))
        self.assertGreater(sum(b[0] for b in blocks), sum(b[0] for b in old_blocks))
        for fb, ff, frees in blocks:
            self.assertEqual(fb, sum(r[1] for r in frees))
            self.assertEqual(ff, min(r[0] for r in frees))
            for (a, n), (b, _) in zip(frees, frees[1:]):
                self.assertNotEqual(a + n, b)           # neighbours merged
        self.assertEqual(self.run_del(after, LEGACY), (1, after))

    def test_first_last_and_top_level_keys(self):
        data = creg(TREE)
        _, after, _ = self.check_deleted(data, 'Enum\\Monitor', '\\enum\\monitor')
        self.check_deleted(after, 'Enum\\PCI', '\\enum\\pci')
        self.check_deleted(data, 'Enum\\Root\\*PNP0F0E', '\\enum\\root\\*pnp0f0e')
        self.check_deleted(data, 'System', '\\system')
        self.check_deleted(data, 'Enum', '\\enum')

    def test_prefix_case_and_records_across_blocks(self):
        data = creg(TREE, per_block=2, slack=3)          # odd record sizes: unaligned fields
        self.assertGreater(len(free_lists(data)[1]), 6)
        self.check_deleted(data, 'HKEY_LOCAL_MACHINE\\enum\\ROOT\\*pnp0900', '\\enum\\root\\*pnp0900')

    def test_neighbouring_freed_records_merge(self):
        data = creg(TREE, per_block=64)
        _, after, _ = self.check_deleted(data, 'Enum\\Root', '\\enum\\root')
        (_fb, _ff, frees), = free_lists(after)[1]
        self.assertEqual(len(frees), 2)                  # the Root run and the old tail

    def test_freed_record_keeps_the_existing_free_tail_on_the_list(self):
        """The X470 950 BSOD: the freed record became the list head and its
        +08 was set to -1, so the block's free tail fell off the list and VMM
        page-faulted looking for it (VMM obj6 602235)."""
        data = creg(TREE, per_block=64)
        (_fb, _ff, old), = free_lists(data)[1]
        self.assertEqual(len(old), 1)                    # one free tail record
        _, after, _ = self.check_deleted(data, 'Enum\\Monitor\\Default_Monitor\\0001',
                                         '\\enum\\monitor\\default_monitor\\0001')
        (fb, ff, frees), = free_lists(after)[1]
        self.assertEqual(len(frees), 2)
        self.assertEqual(frees[-1], old[0])               # the tail is still reachable
        self.assertEqual(ff, frees[0][0]); self.assertLess(frees[0][0], old[0][0])
        self.assertEqual(fb, sum(r[1] for r in frees))

    def test_two_deletes_in_one_block_keep_every_free_record_listed(self):
        data = creg(TREE, per_block=64)
        _, after, _ = self.check_deleted(data, 'Enum\\Monitor\\Default_Monitor\\0001',
                                         '\\enum\\monitor\\default_monitor\\0001')
        _, after, _ = self.check_deleted(after, 'Enum\\Root\\*PNP0F0E', '\\enum\\root\\*pnp0f0e')
        (fb, _ff, frees), = free_lists(after)[1]
        self.assertEqual(len(frees), 3)
        self.assertEqual([r[0] for r in frees], sorted(r[0] for r in frees))
        self.assertEqual(fb, sum(r[1] for r in frees))

    def test_delete_next_to_an_already_free_record_merges(self):
        data = creg(TREE, per_block=64)
        _, first, _ = self.check_deleted(data, 'Enum\\Root\\*PNP0A03', '\\enum\\root\\*pnp0a03')
        (_fb, _ff, one), = free_lists(first)[1]
        _, after, _ = self.check_deleted(first, LEGACY, '\\enum\\root\\*pnp0900')
        (fb, _ff, frees), = free_lists(after)[1]
        self.assertEqual(len(frees), len(one))            # *PNP0900 grew the *PNP0A03 run
        self.assertEqual(frees[0][0], one[0][0]); self.assertGreater(frees[0][1], one[0][1])
        self.assertEqual(fb, sum(r[1] for r in frees))

    def test_hive_without_checksums(self):
        data = creg(TREE, checksums=False)
        self.assertEqual(sums_ok(data), 0)
        _, after, _ = self.check_deleted(data, LEGACY + '\\0000\\LogConfig', '\\enum\\root\\*pnp0900\\0000\\logconfig')
        self.assertEqual(after[0x34:0x38], data[0x34:0x38])

    def test_many_pages_of_entries(self):
        tree = {'Enum': ([], {'Root': ([], {'*PNP%04X' % i: ([('Class', 1, SZ('Other'))], {'0000': ([], {})})
                                            for i in range(300)})})}
        tree['Enum'][1]['Root'][1]['*PNP0900'] = TREE['Enum'][1]['Root'][1]['*PNP0900']
        data = creg(tree, per_block=200)
        self.assertGreater(struct.unpack_from('<I', data, 0x24)[0], 0x4000)
        self.check_deleted(data, LEGACY, '\\enum\\root\\*pnp0900')
        self.check_deleted(data, 'Enum\\Root\\*PNP0001', '\\enum\\root\\*pnp0001')

    def test_missing_key_and_refusals_leave_the_file_alone(self):
        data = creg(TREE)
        for key in ['Enum\\Root\\*PNP0901', 'Enum\\Nothing\\X', 'Enum\\Root\\*PNP09']:
            self.assertEqual(self.run_del(data, key), (1, data), key)
        for key in ['\\', 'HKEY_LOCAL_MACHINE\\', 'Enum\\\\Root']:
            self.assertEqual(self.run_del(data, key), (2, data), key)
        bad = bytearray(data); bad[0x200] ^= 1                          # RGKN checksum wrong
        self.assertEqual(self.run_del(bytes(bad), LEGACY), (2, bytes(bad)))
        bad = bytearray(data); bad[-0x30] ^= 1                          # last RGDB block
        self.assertEqual(self.run_del(bytes(bad), LEGACY), (2, bytes(bad)))
        for bad in [b'', data[:0x40], b'REGF' + data[4:], data[:-4]]:
            self.assertEqual(self.run_del(bad, LEGACY)[0], 2)
        result = subprocess.run([str(self.binary), 'DELKEY', str(self.tmp / 'none.dat'), 'Enum'], capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_real_950_hive_copy(self):
        """Optional, local only: USOS_W95_SYSTEM_HIVE = a copy of a 950
        SYSTEM.DAT (for example the X470 C:\\USOS9X\\SYSTEM.VL). Never committed."""
        source = os.environ.get('USOS_W95_SYSTEM_HIVE')
        if not source:
            self.skipTest('set USOS_W95_SYSTEM_HIVE to a local 950 SYSTEM.DAT copy')
        data = Path(source).read_bytes()
        if Hive(data).key(LEGACY) is None:
            self.skipTest('no Enum\\Root\\*PNP0900 in that hive')
        # Original hives must never be copied into repo scratch, even when
        # ignored. Keep this real-data fixture beside its private source.
        import tempfile
        previous=self.tmp
        self.tmp=Path(tempfile.mkdtemp(prefix='vesbind-real-',dir=Path(source).resolve().parent))
        try:
            _, after, removed = self.check_deleted(data, LEGACY, '\\enum\\root\\*pnp0900')
        finally:self.tmp=previous
        self.assertIn('\\enum\\root\\*pnp0900\\0000\\logconfig', removed)
        self.assertGreaterEqual(sums_ok(after), 3)


def set_block32(data, blk, at, value):
    """data with DWORD block+at = value; the block checksum (flag bit 2) kept."""
    out = bytearray(data); off = 0x20 + struct.unpack_from('<I', out, 0x24)[0]
    for _ in range(blk): off += struct.unpack_from('<I', out, off + 4)[0]
    size, _fb, flags = struct.unpack_from('<IIH', out, off + 4)
    struct.pack_into('<I', out, off + at, value)
    if flags & 4:
        struct.pack_into('<I', out, off + 0x1c, 0)
        total = sum(struct.unpack_from('<%dI' % (size // 4), out, off)) & 0xffffffff
        struct.pack_into('<I', out, off + 0x1c, (-total) & 0xffffffff)
    return bytes(out)


class FixFree(unittest.TestCase):
    """VESBIND FIXFREE: rebuilds the RGDB free lists an older DELKEY broke."""
    @classmethod
    def setUpClass(cls):
        cls.binary = host_binary()

    def setUp(self):
        self.tmp = scratch('fixfree-'); self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def run_fix(self, data):
        hive, log = self.tmp / 'SYSTEM.DAT', self.tmp / 'FIXFREE.LOG'
        if hive.exists(): hive.unlink()
        if data is not None: hive.write_bytes(data)
        result = subprocess.run([str(self.binary), 'FIXFREE', str(hive), str(log)], capture_output=True)
        self.assertFalse(result.stdout + result.stderr)
        text = log.read_bytes().decode('ascii')
        self.assertEqual(text, 'version=1\r\nexit=%d\r\n%s' % (result.returncode, text.split('\r\n', 2)[2]))
        return result.returncode, text.split('reason=')[1].strip(), hive.read_bytes() if data is not None else None

    def broken(self, checksums=True):
        """The old DELKEY pattern: a freed record at the list head with -1 at
        +08, the block's existing free records unreachable, header +08 still
        counting them (X470 950 PL SYSTEM.DAT, 2026-10-26, blocks 16 and 55)."""
        data = creg(TREE, per_block=4, checksums=checksums)
        hive = self.tmp / 'SYSTEM.DAT'; hive.write_bytes(data)
        subprocess.run([str(self.binary), 'DELKEY', str(hive), 'Enum\\Monitor\\Default_Monitor\\0001'], check=True)
        good = hive.read_bytes()
        blocks = free_lists(good)[1]
        hit = [b for b, (_fb, _ff, frees) in enumerate(blocks) if len(frees) > 1]
        self.assertTrue(hit)
        b = hit[0]; head = blocks[b][1]
        bad = set_block32(good, b, head + 8, NONE)
        self.assertIn(b, rgdb_problems(bad)); sums_ok(bad)
        return good, bad

    def test_repairs_the_old_delkey_pattern(self):
        for checksums in (True, False):
            with self.subTest(checksums=checksums):
                good, bad = self.broken(checksums)
                rc, reason, fixed = self.run_fix(bad)
                self.assertEqual((rc, reason), (0, 'complete'))
                self.assertEqual(fixed, good)            # address order, as DELKEY now leaves it
                self.assertFalse(rgdb_problems(fixed)); sums_ok(fixed)
                self.assertEqual(dump(fixed), dump(bad))
                self.assertEqual(self.run_fix(fixed), (1, 'consistent', fixed))

    def test_wrong_free_count_unlisted_records_and_loops(self):
        good, _ = self.broken()
        b, (fb, ff, frees) = [(i, x) for i, x in enumerate(free_lists(good)[1]) if len(x[2]) > 1][0]
        cases = {'count': set_block32(good, b, 8, fb + 4),
                 'head-skips-first': set_block32(good, b, 0x10, frees[1][0]),
                 'empty-list': set_block32(good, b, 0x10, NONE),
                 'loop': set_block32(good, b, frees[-1][0] + 8, frees[0][0])}
        for name, bad in cases.items():
            with self.subTest(name):
                self.assertTrue(rgdb_problems(bad))
                rc, _, fixed = self.run_fix(bad)
                self.assertEqual(rc, 0)
                self.assertEqual(fixed, good)

    def test_consistent_lifo_list_is_left_alone(self):
        """VMM frees onto the list head, so a valid list need not be sorted."""
        good, _ = self.broken()
        b, (fb, ff, frees) = [(i, x) for i, x in enumerate(free_lists(good)[1]) if len(x[2]) > 1][0]
        self.assertEqual(len(frees), 2)
        lifo = set_block32(good, b, 0x10, frees[1][0])
        lifo = set_block32(lifo, b, frees[1][0] + 8, frees[0][0])
        lifo = set_block32(lifo, b, frees[0][0] + 8, NONE)
        self.assertFalse(rgdb_problems(lifo))
        self.assertEqual(self.run_fix(lifo), (1, 'consistent', lifo))

    def test_clean_hive_untouched_and_refusals(self):
        data = creg(TREE)
        self.assertEqual(self.run_fix(data), (1, 'consistent', data))
        self.assertEqual(self.run_fix(None)[:2], (2, 'hive-open'))
        self.assertEqual(self.run_fix(b'not a hive'), (2, 'creg-header', b'not a hive'))
        bad = bytearray(data); bad[-0x30] ^= 1                          # last RGDB checksum
        self.assertEqual(self.run_fix(bytes(bad)), (2, 'rgdb-checksum', bytes(bad)))
        _, broken = self.broken(checksums=False)
        tiled = set_block32(broken, 0, 0x20, 0x13)                     # record size below 14h
        self.assertEqual(self.run_fix(tiled), (2, 'rgdb-records', tiled))


RUNONCE = 'Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce'
RO_VALUES = [('ClassSetup', 1, SZ('rundll.exe sysdm.cpl,DMFirstTimeSetup')), ('InitShell', 1, SZ('1')),
             ('TapiSetup', 1, SZ('tapiini.exe')), ('USOSVmd', 1, SZ('rundll.exe setupx.dll,InstallHinfSection'))]


def ro_tree(values=RO_VALUES):
    tree = dict(TREE)
    tree['Software'] = ([], {'Microsoft': ([], {'Windows': ([], {'CurrentVersion': ([('ProgramFilesDir', 1, SZ('C:\\Program Files'))], {
        'RunOnce': (list(values), {'Setup': ([('Drukarki', 1, SZ('rundll32.exe sysdm.cpl,InstallDevice_Rundll printer,,0'))], {})}),
        'Run': ([('USOSLog', 1, SZ('C:\\USOS9X\\USOSLOG.EXE'))], {})})})})})
    return tree


def record_layout(data):
    """(block, position) -> (size, bytes used, value count) for every key
    record, and every block's (free bytes, first free)."""
    size = struct.unpack_from('<I', data, 0x24)[0]
    off, recs, heads = 0x20 + size, {}, []
    for b in range(struct.unpack_from('<H', data, 0x10)[0]):
        bs, fb, _f, _n, ff = struct.unpack_from('<IIHHI', data, off + 4)
        heads.append((fb, ff)); pos = 0x20
        while pos < bs:
            rs, kid, _blk, used, _nl, nv = struct.unpack_from('<IHHIHH', data, off + pos)
            if kid != 0xffff:
                recs[(b, pos)] = (rs, used, nv)
                # bytes behind the values up to the record end: zero after DELVAL
                recs[(b, pos, 'tail')] = data[off + pos + used:off + pos + rs]
            pos += rs
        off += bs
    return recs, heads


class DelVal(unittest.TestCase):
    """VESBIND DELVAL: one value out of a key's record (REG95.BAT removes HKLM
    RunOnce InitShell, the 95 Explorer's forced Welcome window)."""
    @classmethod
    def setUpClass(cls):
        cls.binary = host_binary()

    def setUp(self):
        self.tmp = scratch('delval-'); self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def run_val(self, data, key, value, log=False):
        hive = self.tmp / 'SYSTEM.DAT'
        if hive.exists(): hive.unlink()
        if data is not None: hive.write_bytes(data)
        args = [str(self.binary), 'DELVAL', str(hive), key, value] + ([str(self.tmp / 'DELVAL.LOG')] if log else [])
        result = subprocess.run(args, capture_output=True)
        self.assertFalse(result.stdout + result.stderr)
        return result.returncode, hive.read_bytes() if data is not None else None

    def check_removed(self, data, key, value):
        before = dump(data); sums_ok(data)
        rc, after = self.run_val(data, key, value)
        self.assertEqual(rc, 0)
        self.assertEqual(len(after), len(data))
        new = dump(after)
        self.assertEqual(set(new), set(before))                       # no key added or lost
        k = '\\' + key.lower().replace('hkey_local_machine\\', '', 1)
        want = [v for v in before[k] if v[0].lower() != value.lower()]
        self.assertEqual(len(want), len(before[k]) - 1)
        self.assertEqual(new[k], want)                                 # order of the rest kept
        for other in new:
            if other != k: self.assertEqual(new[other], before[other], other)
        sums_ok(after); self.assertFalse(rgdb_problems(after))
        self.assertEqual(free_lists(after), free_lists(data))           # no free record / chunk changed
        old_recs, old_heads = record_layout(data); recs, heads = record_layout(after)
        self.assertEqual(heads, old_heads)
        self.assertEqual(set(recs), set(old_recs))
        shrunk = 0
        for at, info in recs.items():
            if len(at) == 3: continue
            size, used, nv = info; old_size, old_used, old_nv = old_recs[at]
            self.assertEqual(size, old_size, at)                         # record sizes unchanged
            tail, old_tail = recs[at + ('tail',)], old_recs[at + ('tail',)]
            if used == old_used:
                self.assertEqual((nv, tail), (old_nv, old_tail), at)
                continue
            shrunk += 1                                                  # the freed bytes are zero
            self.assertEqual((nv, tail), (old_nv - 1, b'\0' * (old_used - used) + old_tail), at)
        self.assertEqual(shrunk, 1)
        return after

    def test_removes_initshell_and_keeps_the_rest(self):
        data = creg(ro_tree())
        after = self.check_removed(data, RUNONCE, 'InitShell')
        self.assertEqual(self.run_val(after, RUNONCE, 'InitShell'), (1, after))
        self.assertEqual(Hive(after).value(RUNONCE, 'TapiSetup'), (1, SZ('tapiini.exe')))
        self.assertEqual(Hive(after).value(RUNONCE + '\\Setup', 'Drukarki')[0], 1)

    def test_first_last_only_value_case_and_prefix(self):
        data = creg(ro_tree())
        self.check_removed(data, RUNONCE, 'ClassSetup')
        self.check_removed(data, RUNONCE, 'usosvmd')
        self.check_removed(data, 'HKEY_LOCAL_MACHINE\\' + RUNONCE.upper(), 'INITSHELL')
        only = creg(ro_tree([('InitShell', 1, SZ('1'))]))
        after = self.check_removed(only, RUNONCE, 'InitShell')
        self.assertEqual(Hive(after).values(RUNONCE), [])

    def test_slack_records_unaligned_fields_and_no_checksums(self):
        for per_block, slack, checksums in ((2, 3, True), (64, 0, True), (6, 5, False)):
            with self.subTest(per_block=per_block, slack=slack, checksums=checksums):
                data = creg(ro_tree(), per_block=per_block, slack=slack, checksums=checksums)
                after = self.check_removed(data, RUNONCE, 'InitShell')
                if not checksums: self.assertEqual(sums_ok(after), 0)

    def test_two_deletes_then_delkey_keep_the_hive_consistent(self):
        data = creg(ro_tree(), per_block=4)
        after = self.check_removed(data, RUNONCE, 'InitShell')
        after = self.check_removed(after, RUNONCE, 'TapiSetup')
        hive = self.tmp / 'SYSTEM.DAT'; hive.write_bytes(after)
        subprocess.run([str(self.binary), 'DELKEY', str(hive), RUNONCE + '\\Setup'], check=True)
        last = hive.read_bytes(); sums_ok(last); self.assertFalse(rgdb_problems(last))
        self.assertEqual([v[0] for v in Hive(last).values(RUNONCE)], ['ClassSetup', 'USOSVmd'])

    def test_missing_refused_and_logged(self):
        data = creg(ro_tree())
        dup = creg(ro_tree(RO_VALUES + [('initshell', 1, SZ('2'))]))
        for blob, key, value, code, reason in ((data, RUNONCE, 'NoSuchValue', 1, 'not-found'),
                                              (data, RUNONCE + 'X', 'InitShell', 1, 'not-found'),
                                              (data, 'Enum\\Monitor\\Default_Monitor', 'InitShell', 1, 'not-found'),
                                              (data, 'Enum', 'Class', 1, 'not-found'),          # key without a record value
                                              (dup, RUNONCE, 'InitShell', 2, 'duplicate'),
                                              (b'not a hive', RUNONCE, 'InitShell', 2, 'creg-header'),
                                              (None, RUNONCE, 'InitShell', 2, 'hive-open'),
                                              (data, '\\', 'InitShell', 2, 'argument'),
                                              (data, RUNONCE, 'x' * 256, 2, 'argument'),
                                              (data, RUNONCE, 'InitShell', 0, 'complete')):
            with self.subTest(key=key, value=value[:20], reason=reason):
                rc, after = self.run_val(blob, key, value, log=True)
                self.assertEqual(rc, code)
                self.assertEqual((self.tmp / 'DELVAL.LOG').read_bytes(),
                                 f'version=1\r\nexit={code}\r\nreason={reason}\r\n'.encode('ascii'))
                if code and blob is not None: self.assertEqual(after, blob)
        bad = bytearray(data); bad[-0x30] ^= 1                          # last RGDB checksum
        self.assertEqual(self.run_val(bytes(bad), RUNONCE, 'InitShell'), (2, bytes(bad)))
        # A value list that overruns the record's bytes used: refused, untouched.
        hive = Hive(data); rel = hive.key(RUNONCE); _p, _c, _s, kid, blk = hive._entry(rel)
        off = 0x20 + struct.unpack_from('<I', data, 0x24)[0]
        for _ in range(blk): off += struct.unpack_from('<I', data, off + 4)[0]
        pos = 0x20
        while struct.unpack_from('<HH', data, off + pos + 4) != (kid, blk): pos += struct.unpack_from('<I', data, off + pos)[0]
        nv = struct.unpack_from('<H', data, off + pos + 0x0e)[0]
        over = set_block16(data, blk, pos + 0x0e, nv + 1)
        self.assertEqual(self.run_val(over, RUNONCE, 'USOSVmd'), (2, over))

    def test_real_hive_copy(self):
        """Optional, local only: USOS_W95_RUNONCE_HIVE = a copy of a 95
        SYSTEM.DAT / SYSTEM.1ST with RunOnce InitShell. Never committed."""
        source = os.environ.get('USOS_W95_RUNONCE_HIVE')
        if not source:
            self.skipTest('set USOS_W95_RUNONCE_HIVE to a local 95 SYSTEM.DAT copy')
        data = Path(source).read_bytes()
        if Hive(data).value(RUNONCE, 'InitShell') is None:
            self.skipTest('no RunOnce InitShell in that hive')
        import tempfile
        previous = self.tmp
        self.tmp = Path(tempfile.mkdtemp(prefix='delval-real-', dir=Path(source).resolve().parent))
        try:
            after = self.check_removed(data, RUNONCE, 'InitShell')
        finally:
            shutil.rmtree(self.tmp, ignore_errors=True); self.tmp = previous
        self.assertIsNone(Hive(after).value(RUNONCE, 'InitShell'))


def set_block16(data, blk, at, value):
    """data with WORD block+at = value; the block checksum (flag bit 2) kept."""
    out = bytearray(data); off = 0x20 + struct.unpack_from('<I', out, 0x24)[0]
    for _ in range(blk): off += struct.unpack_from('<I', out, off + 4)[0]
    size, _fb, flags = struct.unpack_from('<IIH', out, off + 4)
    struct.pack_into('<H', out, off + at, value)
    if flags & 4:
        struct.pack_into('<I', out, off + 0x1c, 0)
        total = sum(struct.unpack_from('<%dI' % (size // 4), out, off)) & 0xffffffff
        struct.pack_into('<I', out, off + 0x1c, (-total) & 0xffffffff)
    return bytes(out)


class WrapGrp(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.binary=host_binary()
    def setUp(self):
        self.tmp=scratch('grpstep-');self.addCleanup(shutil.rmtree,self.tmp,ignore_errors=True)
    def run_wrap(self,data):
        source=self.tmp/'TZ0.CHK';out=self.tmp/'TZGRP.REG';source.write_bytes(data)
        if out.exists():out.unlink()
        result=subprocess.run([str(self.binary),'WRAPGRP',str(source),str(out)],capture_output=True)
        self.assertFalse(result.stdout+result.stderr)
        return result.returncode,out.read_bytes() if out.exists() else None
    def test_original_pl_en_and_other_names_matched_only_by_exact_command(self):
        key=r'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce\Setup'
        for name in ('Programy w menu Start','Programs on the Start menu','Anderer Name'):
            with self.subTest(name=name):
                data=reg([(key,'"'+name+'"="C:\\\\WINDOWS\\\\grpconv.exe -s"')])
                code,out=self.run_wrap(data);self.assertEqual(code,0)
                self.assertEqual(out,reg([(key,'"'+name+'"="C:\\\\USOS9X\\\\USOSGRPW.EXE -s"')]))
    def test_unrelated_commands_keys_and_non_setup_values_stay_untouched(self):
        key=r'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce\Setup'
        for command in ('other.exe -s','evilgrpconv.exe -s','grpconv.exe -other','grpconv.exe -s extra'):
            self.assertEqual(self.run_wrap(reg([(key,'"Same name"="'+command+'"')])),(1,None))
        self.assertEqual(self.run_wrap(reg([(key.rsplit('\\',1)[0],'"Step"="grpconv.exe -s"')])),(1,None))
    def test_duplicate_matching_steps_and_malformed_export_fail_without_output(self):
        key=r'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce\Setup'
        duplicate=reg([(key,'"First"="grpconv.exe -s"\r\n"Second"="grpconv.exe -s"')])
        self.assertEqual(self.run_wrap(duplicate),(2,None))
        self.assertEqual(self.run_wrap(b'not REGEDIT4\r\n'),(2,None))

class Generator(unittest.TestCase):
    def create(self,version='4 0 0 950'):
        tmp=scratch('vesalate-');self.addCleanup(shutil.rmtree,tmp,ignore_errors=True)
        (tmp/'VESBIND.EXE').write_bytes(b'host generator fixture only')
        lib=(ROOT/'tools/w9x_vesa95.sh').as_posix()
        rc,out,err=sh(f'. "{lib}"\nw9x_vesa95_write "{tmp.as_posix()}" 16 1024,768 "{version}"')
        self.assertEqual(rc,0,out+err)
        return tmp
    def test_scope_boundary_journal_and_dos_limits(self):
        tmp=self.create();parent=(tmp/'VESA95.BAT').read_bytes();child=(tmp/'VESALATE.BAT').read_bytes()
        self.assertLess(parent.index(b'CALL C:\\USOS9X\\VESALATE.BAT'),parent.index(b'VESA95.OK GOTO END'))
        # Fail-soft: a failed late binding is logged on the target disk and the
        # old VESA95 path continues (no PAUSE loop withholding Windows).
        self.assertNotIn(b'PAUSE',parent)
        failed=parent.split(b':VLFAIL\r\n')[1].split(b':VLNEXT\r\n')[0]
        self.assertIn(b'>> C:\\USOS9X\\USOSLOG.TXT\r\n',failed)
        self.assertNotIn(b'GOTO',failed)
        text=child.decode('ascii')
        boundary=text.index('IF NOT ERRORLEVEL 1 GOTO PENDING')
        for op in ['ECHO run>','ATTRIB.EXE -S -R -H','VESBIND.EXE PLAN','COPY /Y SYSTEM.DAT']:
            self.assertLess(boundary,text.index(op))
        for b in [parent,child]:
            self.assertEqual(b.count(b'\n'),b.count(b'\r\n'))
            self.assertLessEqual(max(map(len,b.split(b'\r\n'))),125)
            labels=re.findall(rb'^:([A-Z0-9]+)\r?$',b,re.M);self.assertEqual(len(labels),len(set(labels)))
        self.assertIn('VLATE.RUN GOTO FAIL',text)
        # REGEDIT restores R/S/H. Delete the legacy devnode while the
        # backup source is writable, then import and check the actual hive.
        plan=text.index('VESBIND.EXE PLAN')
        self.assertLess(plan,text.index('IF ERRORLEVEL 4 GOTO FAIL'))
        self.assertLess(text.index('IF ERRORLEVEL 3 GOTO VLDEL'),text.index('IF ERRORLEVEL 1 GOTO FAIL',plan))
        # 950's real-mode REGEDIT has no /D: never used for the deletion.
        self.assertNotIn(' /D ',text)
        dele=text.index('C:\\USOS9X\\VESBIND.EXE DELKEY C:\\WINDOWS\\SYSTEM.DAT HKEY_LOCAL_MACHINE\\Enum\\Root\\*PNP0900 C:\\USOS9X\\VLDEL.LOG\r\n')
        self.assertLess(dele,text.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\VLATE.REG\r\n'))
        self.assertLess(text.index('IF NOT EXIST C:\\USOS9X\\VLDEL.FLG GOTO VLIMPORT'),dele)
        after=text[dele:text.index(':VLEXP\r\n')]
        # Exit 3 (write failed) and 2 (refused) roll back, both logged; exit 1 is logged only.
        self.assertLess(after.index('IF ERRORLEVEL 3 GOTO ROLLBACK'),after.index('IF ERRORLEVEL 2 GOTO ROLLBACK'))
        self.assertEqual(after.count('>> C:\\USOS9X\\USOSLOG.TXT'),3)
        self.assertNotIn('IF ERRORLEVEL 1 GOTO',after)
        self.assertLess(dele,text.index('/E C:\\USOS9X\\VL5.REG'))
        self.assertLess(text.index(':VLEXP'),text.index('/E C:\\USOS9X\\VL5.REG'))
        self.assertLess(text.index('DEL C:\\USOS9X\\VLDEL.FLG'),plan)
        self.assertIn('VESBIND.EXE CHECK',text)
        self.assertIn(':ROLLBACK',text)
        rollback=text.split(':ROLLBACK\r\n',1)[1].split(':ATTRFAIL\r\n',1)[0]
        self.assertLess(rollback.index('ATTRIB.EXE -S -R -H SYSTEM.DAT'),rollback.index('COPY /Y C:\\USOS9X\\SYSTEM.VL SYSTEM.DAT'))
        failure=text.split(':FAIL\r\n',1)[1]
        self.assertLess(failure.index('VLATE.ERR'),failure.index('DEL C:\\USOS9X\\VLATE.RUN'))
        self.assertIn('TYPE C:\\USOS9X\\VLDEL.LOG',failure)
        for version in ['4 0 0 1068','4 0 0 1111','']:
            other=self.create(version)
            self.assertFalse((other/'VESALATE.BAT').exists())
            self.assertNotIn(b'VESALATE',(other/'VESA95.BAT').read_bytes())

if __name__=='__main__':unittest.main()
