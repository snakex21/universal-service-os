"""Windows 95 fresh install: the usosnet4 adapter, TCP/IP and client by
registry (tools/network_setup.sh usos_net_w95_*, NET95.REG imported with
REG95.REG by tools/w9x_reg95.sh) and Windows Logon as the primary logon.

The X470 in-place kit 95-net (2026-10-20, PASS) registered the I211 the same
way on an installed 95: the New Hardware wizard never ran, the card worked
with TCP/IP (DHCP) and the client. A fresh install gets those values before
95's first PnP pass on the PC, for the devnode instance 95 OSR2's PCI
enumerator gives the card (derived from the PCI path; X470 values from the
95 OSR2.1 PL registry of that install). Host only (Git sh).
Run: python tools/tests/test_w9x_net95.py
"""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh
from test_w9x_reg95 import ANSWER_95, REG95

ROOT = Path(__file__).resolve().parents[2]
NET = (ROOT / 'tools/network_setup.sh').as_posix()
INF95 = ROOT / 'tools/nt/usosnet/inf/usosnet95.inf'
I211 = '/sys/devices/pci0000:00/0000:00:01.3/0000:02:00.2/0000:03:01.0/0000:08:00.0'
KLASS = 'HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class'


def run(code, env=None):
    rc, out, err = sh(f'. "{NET}"\n' + code, env or {})
    return rc, out, err


class Instance(unittest.TestCase):
    def inst(self, path):
        rc, out, _ = run(f"usos_net_w95_instance '{path}'")
        return out.strip() if rc == 0 else None

    def test_x470_registry_instances(self):
        # 95-fresh2 SYSTEM.DAT (read-only): I211, NVMe, GPU, root-bus devices.
        self.assertEqual(self.inst(I211), '0008020B00')
        self.assertEqual(self.inst('/sys/devices/pci0000:00/0000:00:01.3/0000:02:00.2/0000:03:04.0/0000:20:00.0'), '0020020B00')
        self.assertEqual(self.inst('/sys/devices/pci0000:00/0000:00:03.1/0000:19:00.0'), '001900')
        self.assertEqual(self.inst('/sys/devices/pci0000:00/0000:00:01.3/0000:02:00.0'), '000B00')
        self.assertEqual(self.inst('/sys/devices/pci0000:00/0000:00:18.3'), 'BUS_00&DEV_18&FUNC_03')
        self.assertEqual(self.inst('/sys/devices/pci0000:00/0000:00:14.0'), 'BUS_00&DEV_14&FUNC_00')

    def test_950_bus_dev_func_instances(self):
        # 95 RTM PL (4.00.950) on the X470 (w95rtm-micron SYSTEM.DAT,
        # 2026-10-25): Enum\PCI\VEN_8086&DEV_1539\BUS_04&DEV_00&FUNC_00 for
        # the I211 at 04:00.0 behind three bridges; NVMe BUS_07&DEV_00&FUNC_00.
        rtm = '/sys/devices/pci0000:00/0000:00:01.3/0000:01:00.2/0000:02:01.0/0000:04:00.0'
        rc, out, _ = run(f"usos_net_w95_instance '{rtm}' 03")
        self.assertEqual((rc, out.strip()), (0, 'BUS_04&DEV_00&FUNC_00'))
        rc, out, _ = run("usos_net_w95_instance '/sys/devices/pci0000:00/0000:00:01.1/0000:07:00.0' 03")
        self.assertEqual(out.strip(), 'BUS_07&DEV_00&FUNC_00')
        rc, out, _ = run("usos_net_w95_instance '/sys/devices/pci0000:00/0000:00:14.3' 03")
        self.assertEqual(out.strip(), 'BUS_00&DEV_14&FUNC_03')
        rc, out, _ = run(f"usos_net_w95_instance '{rtm}' 04")
        self.assertEqual(out.strip(), '0008020B00')   # OSR2 naming unchanged
        rc, out, _ = run("usos_net_w95_instance '' 03")
        self.assertNotEqual(rc, 0)

    def test_no_pci_chain(self):
        self.assertIsNone(self.inst('/tmp/pci/0000-08-00.0'))
        self.assertIsNone(self.inst(''))


class Net95Reg(unittest.TestCase):
    def reg(self):
        rc, out, err = run("usos_net_w95_reg 'PCI\\VEN_8086&DEV_1539' 0008020B00 'Intel(R) I211 (USOS usosnet)' USOSNETI211.ndi > \"$T\"",
                           {'T': (Path(self.tmp) / 'NET95.REG').as_posix()})
        self.assertEqual(rc, 0, err)
        return (Path(self.tmp) / 'NET95.REG').read_bytes()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='usos-net95-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_kit_equivalent_values(self):
        data = self.reg()
        self.assertTrue(data.startswith(b'REGEDIT4\r\n'))
        self.assertEqual(data.count(b'\n'), data.count(b'\r\n'))
        text = data.decode('ascii')
        dev = '[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_8086&DEV_1539\\0008020B00]\r\n'
        for token in (dev + '"Class"="Net"\r\n"Driver"="Net\\\\0009"\r\n',
                      '[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_8086&DEV_1539\\0008020B00\\Bindings]\r\n"MSTCP\\\\0009"=""',
                      '[%s\\Net\\0009]\r\n"DriverDesc"="Intel(R) I211 (USOS usosnet)"' % KLASS,
                      '"InfSection"="USOSNETI211.ndi"', '"MatchingDeviceId"="PCI\\\\VEN_8086&DEV_1539"',
                      '"DevLoader"="*ndis"', '"DeviceVxDs"="usosnet.sys"', '"MajorNdisVersion"=hex:04',
                      '[%s\\NetTrans\\0009]\r\n"DriverDesc"="TCP/IP"\r\n"IPAddress"="0.0.0.0"' % KLASS,
                      '[HKEY_LOCAL_MACHINE\\Enum\\Network\\MSTCP\\0009\\Bindings]\r\n"VREDIR\\\\0009"=""',
                      '[%s\\NetClient\\0009]' % KLASS, '"NetworkProvider"="Microsoft Network"',
                      '[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\VxD\\VREDIR]\r\n"StaticVxD"="vredir.vxd"',
                      '[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\control\\NetworkProvider\\Order]\r\n"MSNP32"=""',
                      '"ProviderPath"="msnp32.dll"'):
            self.assertIn(token, text)
        # No file and printer sharing service, no Network\Logon here (REG95).
        self.assertNotIn('NetService', text)
        self.assertNotIn('Network\\Logon', text)
        # The adapter parameters of usosnet95.inf, for the Advanced tab.
        inf = INF95.read_text(encoding='ascii')
        for p in ('PollMode', 'SkipPhy', 'DebugPort', 'NetworkAddress'):
            self.assertIn('Ndi\\params\\%s]' % p, text)
            self.assertIn('Ndi\\params\\%s,ParamDesc' % p, inf)


class Stage(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-net95-stage-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.lib = self.tmp / 'lib'
        (self.lib / 'network').mkdir(parents=True)
        shutil.copyfile(INF95, self.lib / 'network/usosnet95.inf')
        (self.lib / 'network/usosnet4.sys').write_bytes(b'own NDIS 4 test fixture, not a driver')
        # NT4 staging also copies the silent network evidence logger.
        (self.lib / 'network/USOSLOG.EXE').write_bytes(b'own logger test fixture, not a program')
        self.pci = self.tmp / 'pci'
        self.target = self.tmp / 'target'
        self.target.mkdir()
        self.cfg = self.tmp / 'config'
        self.cfg.write_text('system=95\nnetwork=on\nip=dhcp\ngateway=\ndns=\nhome_page=about:blank\ndialup=off\n')

    def card(self, index, device='1539'):
        p = self.pci / index
        p.mkdir(parents=True)
        for k, v in dict(vendor='0x8086', device='0x' + device, subsystem_vendor='0x1849', subsystem_device='0x1539',
                         revision='0x03', **{'class': '0x020000'}).items():
            (p / k).write_text(v + '\n')

    def stage(self, path=None):
        env = {'USOS_NET_W95_PATH': path} if path else {}
        rc, out, err = run('usos_net_stage ' + ' '.join("'%s'" % p.as_posix() for p in (self.cfg, self.target, self.lib, self.pci)), env)
        self.assertEqual(rc, 0, out + err)
        return out, self.target / 'USOS9X/NET/NET95.REG'

    def test_one_card_with_a_pci_path(self):
        self.card('0000-08-00.0')
        out, reg = self.stage(I211)
        self.assertIn('NET95.REG staged', out)
        text = reg.read_bytes().decode('ascii')
        self.assertIn('Enum\\PCI\\VEN_8086&DEV_1539\\0008020B00]', text)
        self.assertIn('"DriverDesc"="Intel(R) I211 Gigabit Network Connection (USOS usosnet)"', text)
        self.assertIn('"InfSection"="USOSNETI211.ndi"', text)
        self.assertNotIn('UsosBootBar0', text)   # OSR2 NDIS 4 driver: none
        self.assertTrue((self.target / 'USOS9X/NET/USOSNET.INF').exists())   # PnP fallback stays
        log = (self.target / 'USOS9X/LOGS/NETSETUP.TXT').read_text()
        self.assertIn('0008020B00', log)

    def test_950_card_gets_bus_dev_func_devnode(self):
        # 95 RTM (4.00.950): BUS_bb&DEV_dd&FUNC_ff devnode, NDIS 3 driver.
        shutil.copyfile(ROOT / 'tools/nt/usosnet/inf/usosnet95rtm.inf', self.lib / 'network/usosnet95rtm.inf')
        (self.lib / 'network/win95-rtm').mkdir()
        (self.lib / 'network/win95-rtm/usosnet4.sys').write_bytes(b'own NDIS 3 test fixture, not a driver')
        self.card('0000-04-00.0')
        (self.pci / '0000-04-00.0/resource').write_text('0x00000000fc900000 0x00000000fc91ffff 0x0000000000040200\n'
                                                        '0x0000000000000000 0x0000000000000000 0x0000000000000000\n')
        env = {'USOS_NET_W95_PATH': '/sys/devices/pci0000:00/0000:00:01.3/0000:01:00.2/0000:02:01.0/0000:04:00.0',
               'USOS_NET_W95_VERSION': '4 0 0 950'}
        rc, out, err = run('usos_net_stage ' + ' '.join("'%s'" % p.as_posix() for p in (self.cfg, self.target, self.lib, self.pci)), env)
        self.assertEqual(rc, 0, out + err)
        text = (self.target / 'USOS9X/NET/NET95.REG').read_bytes().decode('ascii')
        dev = '[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_8086&DEV_1539\\BUS_04&DEV_00&FUNC_00'
        self.assertIn(dev + ']\r\n', text)
        self.assertIn(dev + '\\Bindings]\r\n"MSTCP\\\\0009"=""', text)
        self.assertNotIn('0008020B00', text)
        # Firmware BAR0 for the NDIS 3 driver's restore (only after a failed MMIO probe).
        self.assertIn('"DebugPort"="0"\r\n"UsosBootBar0"="FC900000"\r\n', text)
        self.assertEqual(text.count('UsosBootBar0'), 1)
        self.assertIn('UsosBootBar0=FC900000', (self.target / 'USOS9X/LOGS/NETSETUP.TXT').read_text())
        self.assertIn('"MajorNdisVersion"=hex:03', text)

    def test_no_pci_path_keeps_pnp_and_inf(self):
        self.card('0000-08-00.0')
        out, reg = self.stage()
        self.assertIn('no NET95.REG (PnP + USOSNET.INF)', out)
        self.assertFalse(reg.exists())
        self.assertTrue((self.target / 'USOS9X/NET/USOSNET.SYS').exists())

    def test_two_cards_no_registry(self):
        self.card('a')
        self.card('b', '1533')
        out, reg = self.stage(I211)
        self.assertIn('2 matched cards; no NET95.REG', out)
        self.assertFalse(reg.exists())

    def test_static_ip_logged(self):
        self.cfg.write_text('system=95\nnetwork=on\nip=192.168.1.20/24\ngateway=192.168.1.1\ndns=\nhome_page=about:blank\ndialup=off\n')
        self.card('0000-08-00.0')
        out, reg = self.stage(I211)
        self.assertIn('static LAN IP not applied on 95: NET95.REG uses DHCP', out)
        self.assertTrue(reg.exists())

    def test_other_systems_never_get_net95(self):
        for system in ('98SE', 'ME', 'NT4'):
            self.cfg.write_text(f'system={system}\nnetwork=on\nip=dhcp\ngateway=\ndns=\nhome_page=about:blank\ndialup=off\n')
            self.card('c' + system)
            self.stage(I211)
            self.assertFalse(list(self.target.rglob('NET95.REG')), system)
            shutil.rmtree(self.pci)


class Reg95Merge(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-net95-reg95-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / 'out/NET').mkdir(parents=True)
        (self.tmp / 'MSBATCH.INF').write_bytes(ANSWER_95.encode('ascii'))

    def write(self, net=True, answer=None, version=''):
        if answer:
            (self.tmp / 'MSBATCH.INF').write_bytes(answer.encode('ascii'))
        out = (self.tmp / 'out').as_posix()
        netreg = (self.tmp / 'out/NET/NET95.REG').as_posix()
        code = (f". \"{REG95}\"\n"
                + (f"usos_net_w95_reg 'PCI\\VEN_8086&DEV_1539' 0008020B00 'I211' USOSNETI211.ndi > '{netreg}'\n" if net else '')
                + f"w9x_reg95_write '{out}' '{(self.tmp / 'MSBATCH.INF').as_posix()}' '' '' {repr(netreg) if net else repr('')} '{version}'\n")
        rc, so, err = run(code)
        self.assertEqual(rc, 0, so + err)
        return ((self.tmp / 'out/REG95.REG').read_bytes().decode('ascii'),
                (self.tmp / 'out/REG95.BAT').read_bytes().decode('ascii'))

    def test_windows_logon_every_95_install(self):
        reg, bat = self.write(net=False)
        logon = '[HKEY_LOCAL_MACHINE\\Network\\Logon]\r\n"ProcessLoginScript"=hex:01\r\n"LMLogon"=hex:00,00,00,00\r\n'
        self.assertIn(logon, reg)
        self.assertNotIn('PrimaryProvider', reg)
        self.assertNotIn('"username"', reg)                 # ANSWER_95 has no DefaultUserName
        imp = bat.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\REG95.REG')
        self.assertLess(bat.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT /D HKEY_LOCAL_MACHINE\\Network\\Logon'), imp)
        # REG95LGN.REG is written at prep time, never exported after the import
        # (the export kept Setup's PrimaryProvider "Microsoft Network").
        self.assertNotIn('REG95LGN', bat)
        self.assertNotIn('NET95', bat)
        self.assertEqual(self.lgn(), b'REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\Network\\Logon]\r\n'
                                     b'"ProcessLoginScript"=hex:01\r\n"LMLogon"=hex:00,00,00,00\r\n\r\n')
        reg, _ = self.write(net=False, answer=ANSWER_95.replace(
            'DefaultPassword,,""', 'DefaultUserName,,"USOS"\r\nHKLM,"Software\\Microsoft\\Windows\\CurrentVersion\\Winlogon",DefaultPassword,,""'))
        self.assertIn('"LMLogon"=hex:00,00,00,00\r\n"username"="USOS"\r\n', reg)
        self.assertEqual(self.lgn(), b'REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\Network\\Logon]\r\n'
                                     b'"ProcessLoginScript"=hex:01\r\n"LMLogon"=hex:00,00,00,00\r\n"username"="USOS"\r\n\r\n')

    def lgn(self):
        return (self.tmp / 'out/REG95LGN.REG').read_bytes()

    def test_950_logon_no_primary_provider_and_delkey(self):
        # An answer's own PrimaryProvider line never reaches REG95LGN.REG.
        answer = ANSWER_95.replace('DefaultPassword,,""', 'DefaultPassword,,""\r\n'
                                   'HKLM,"Network\\Logon",PrimaryProvider,,"Microsoft Network"')
        reg, bat = self.write(net=False, answer=answer, version='4 0 0 950')
        lgn = self.lgn()
        self.assertTrue(lgn.startswith(b'REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\Network\\Logon]\r\n'))
        self.assertNotIn(b'PrimaryProvider', lgn)
        self.assertNotIn(b'Microsoft Network', lgn)
        self.assertEqual(lgn.count(b'['), 1)
        self.assertIn(b'"ProcessLoginScript"=hex:01\r\n', lgn)
        # 950 real-mode REGEDIT has no /D: VESBIND DELKEY with a backup.
        self.assertFalse([l for l in bat.split('\r\n') if l.startswith('REGEDIT') and ' /D ' in l])
        lines = bat.split('\r\n')
        delkey = lines.index('C:\\USOS9X\\VESBIND.EXE DELKEY C:\\WINDOWS\\SYSTEM.DAT HKEY_LOCAL_MACHINE\\Network\\Logon C:\\USOS9X\\R95DEL.LOG')
        self.assertLess(lines.index('C:\\WINDOWS\\COMMAND\\ATTRIB.EXE -S -R -H SYSTEM.DAT'), delkey)
        self.assertLess(lines.index('COPY /Y SYSTEM.DAT C:\\USOS9X\\SYSTEM.R95 > NUL'), delkey)
        self.assertEqual(lines[delkey + 1], 'IF ERRORLEVEL 3 COPY /Y C:\\USOS9X\\SYSTEM.R95 SYSTEM.DAT > NUL')
        self.assertLess(delkey, lines.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\REG95.REG'))
        self.assertLess(lines.index(':LGNSKIP'), lines.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\REG95.REG'))
        self.assertIn('IF NOT EXIST C:\\USOS9X\\VESBIND.EXE GOTO LGNSKIP', lines)
        self.assertNotIn('REG95LGN', bat)
        self.assertLessEqual(max(len(line) for line in lines), 125)
        # FIRSTBT.BAT's guard still finds the key in the prep-time file.
        self.assertIn(b'Network\\Logon]', lgn)

    def test_net95_merged_before_comments_and_checked(self):
        reg, bat = self.write()
        self.assertEqual(reg.count('REGEDIT4'), 1)
        self.assertEqual(reg.count('\n'), reg.count('\r\n'))
        self.assertLess(reg.index('Enum\\PCI\\VEN_8086&DEV_1539\\0008020B00]'), reg.index('; USOS: not converted'))
        self.assertTrue(reg.rstrip('\r\n').splitlines()[-1].startswith('; USOS: not converted'))
        self.assertLessEqual(max(len(line) for line in bat.split('\r\n')), 125)
        for token in ('/E C:\\USOS9X\\NET\\C1.REG HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_8086&DEV_1539\\0008020B00\r\n',
                      '/E C:\\USOS9X\\NET\\C2.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\Net\r\n',
                      '/E C:\\USOS9X\\NET\\C3.REG HKEY_LOCAL_MACHINE\\Enum\\Network\r\n',
                      'FIND.EXE "usosnet.sys" C:\\USOS9X\\NET\\C2.REG', 'FIND.EXE "Net\\\\0009" C:\\USOS9X\\NET\\C1.REG',
                      'FIND.EXE "NetClient\\\\0009" C:\\USOS9X\\NET\\C3.REG', 'ECHO ok> C:\\USOS9X\\NET\\NET95.OK',
                      '> C:\\USOS9X\\NET\\NET95.ERR'):
            self.assertIn(token, bat)
        self.assertLess(bat.index('NET\\C1.REG'), bat.index('ATTRIB.EXE +S +R +H SYSTEM.DAT'))


class Msbatch950(unittest.TestCase):
    # X470 95 RTM PL native (2026-10-26): Clients=VREDIR / Protocols=MSTCP
    # without an adapter -> NETDI's NETGEN.INF adapter picker, twice; empty
    # keys (2026-10-27) -> NETDI defaults and the picker once.
    GOLDEN = ROOT / 'src/flow/answer/testdata/golden/options.windows-95.x86.inf'

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-net950-msbatch-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def clear(self, data):
        inf = self.tmp / 'MSBATCH.INF'
        inf.write_bytes(data)
        rc, out, err = run(f"usos_net_w950_msbatch '{inf.as_posix()}'")
        self.assertEqual(rc, 0, out + err)
        return inf.read_bytes()

    def test_rendered_answer_gets_no_setup_network_section(self):
        # X470 run 2026-10-27: empty Clients= / Protocols= / Services= made
        # 950 NETDI take its defaults (NETLOG "1Got default NWLINK,NETBEUI",
        # "VREDIR,NWREDIR"). Without [Network] NETDI's batch CreateNetwork
        # does not run (Batch.NetworkSectionPresent=0).
        before = self.GOLDEN.read_bytes()
        self.assertIn(b'[Network]\r\n', before)
        after = self.clear(before)
        self.assertNotIn(b'[network]', after.lower())
        net = after[after.index(b'[USOS.Network]\r\n'):]
        net = net[:net.index(b'\r\n\r\n') + 4]
        self.assertIn(b'ComputerName="USOS-9X"\r\nWorkgroup="USOSLAB"\r\nDescription="Tester"\r\n', net)
        self.assertEqual(after.count(b'\n'), after.count(b'\r\n'))
        # Only the section header differs.
        self.assertEqual(after.replace(b'[USOS.Network]\r\n', b'[Network]\r\n'), before)
        self.assertEqual(self.clear(after), after)                  # idempotent

    def test_only_the_network_header_is_renamed(self):
        data = (b'[Setup]\r\nExpress=1\r\n\r\n[NETWORK] \r\nComputerName="X"\r\nClients=VREDIR\r\n\r\n'
                b'[MSTCP]\r\nDHCP=1\r\n\r\n[Other]\r\nNetwork=1\r\n[NetworkX]\r\n')
        self.assertEqual(self.clear(data),
                         b'[Setup]\r\nExpress=1\r\n\r\n[USOS.Network]\r\nComputerName="X"\r\nClients=VREDIR\r\n\r\n'
                         b'[MSTCP]\r\nDHCP=1\r\n\r\n[Other]\r\nNetwork=1\r\n[NetworkX]\r\n')
        # LF input comes out CR LF; a file without [Network] is unchanged.
        self.assertEqual(self.clear(b'[Network]\nProtocols=MSTCP\n'), b'[USOS.Network]\r\nProtocols=MSTCP\r\n')
        self.assertEqual(self.clear(b'[Setup]\r\nExpress=1\r\n'), b'[Setup]\r\nExpress=1\r\n')

    def test_identity_survives_in_reg95(self):
        # REG95's VNETSUP identity reads the renamed section of the staged file.
        out = self.tmp / 'USOS9X'
        (out / 'NET').mkdir(parents=True)
        inf = self.tmp / 'MSBATCH.INF'
        inf.write_bytes(self.GOLDEN.read_bytes())
        self.clear(inf.read_bytes())
        reg = out / 'NET/NET95.REG'
        rc, so, err = run(f'. "{REG95}"\n'
                          f"usos_net_w95_reg 'PCI\\VEN_8086&DEV_10C9' 'BUS_00&DEV_03&FUNC_00' '82576' USOSNET82576.ndi 03 > '{reg.as_posix()}'\n"
                          f"w9x_reg95_write '{out.as_posix()}' '{inf.as_posix()}' '' '' '{reg.as_posix()}' '4 0 0 950'\n")
        self.assertEqual(rc, 0, so + err)
        text = (out / 'REG95.REG').read_bytes().decode('ascii')
        self.assertIn('[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\VxD\\VNETSUP]\r\n'
                      '"ComputerName"="USOS-9X"\r\n"Workgroup"="USOSLAB"\r\n"Comment"="Tester"\r\n', text)

    def test_target_clears_only_950_usos_answers(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        at = text.index('usos_net_w950_msbatch "$work/c/USOS9X/MSBATCH.INF"')
        block = text[text.rindex('\nif ', 0, at):at]
        self.assertIn('[ "$ANSWER_KIND" != USER ]', block)
        self.assertIn('[ "$SYSTEM_TAG:${setup_version:-}" = \'95:4 0 0 950\' ]', block)
        self.assertLess(text.index('usos_net_stage "$work/network.ini"'), at)
        self.assertLess(at, text.index('w9x_reg95_write "$work/c/USOS9X"'))


class TargetWiring(unittest.TestCase):
    def test_net95_passed_to_reg95(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('[ ! -f "$work/c/USOS9X/NET/NET95.REG" ] || reg95_net="$work/c/USOS9X/NET/NET95.REG"', text)
        self.assertIn('"$reg95_log" "$reg95_vmd" "$reg95_net"', text)
        self.assertLess(text.index('usos_net_stage "$work/network.ini"'), text.index('reg95_net='))
        setup = (ROOT / 'tools/network_setup.sh').read_text(encoding='utf-8')
        self.assertIn('if [ "$_un_os" = 95 ]; then usos_net_w95_stage; fi', setup)


if __name__ == '__main__':
    unittest.main()
