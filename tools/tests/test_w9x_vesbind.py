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

class Parser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        value=os.environ.get('USOS_VESBIND_HOST_EXE')
        if not value:raise unittest.SkipTest('Set USOS_VESBIND_HOST_EXE to a native build of vesbind.c')
        cls.binary=Path(value).resolve();assert cls.binary.is_file()
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

    def test_950_pnp_vesa_binding_next_to_the_legacy_device_writes_the_mode_only(self):
        rc, out = self.run_parser(classes=self.CLASSES950, enum=self.ENUM950)
        self.assertEqual(rc, 0)
        self.assertEqual(out, reg([(CLS + r'\0001\DEFAULT', '"Mode"="16,1024,768"'),
            (CONFIG, '"BitsPerPixel"="16"\r\n"Resolution"="1024,768"')]))
        self.assertNotIn(b'"Driver"', out)
        config = reg([(CONFIG, '"BitsPerPixel"="16"\r\n"Resolution"="1024,768"')])
        self.assertEqual(self.run_parser(classes=self.CLASSES950, enum=self.ENUM950, config=config)[0], 0)
        self.assertNotEqual(self.run_parser(classes=self.CLASSES950, enum=self.ENUM950,
            config=config.replace(b'1024,768', b'640,480'))[0], 0)

    def test_950_pci_on_the_early_vesa_class_writes_the_profile_only(self):
        enum = self.ENUM950.replace(b'DISPLAY\\\\0001', b'Display\\\\0000')
        rc, out = self.run_parser(classes=self.CLASSES950, enum=enum)
        self.assertEqual(rc, 0)
        self.assertEqual(out, reg([(CONFIG, '"BitsPerPixel"="16"\r\n"Resolution"="1024,768"')]))

    def test_legacy_device_next_to_a_pci_display_that_needs_rebinding_fails(self):
        msdisp = self.CLASSES950.replace(b'"InfPath"="USOSVESA.INF"\r\n"InfSection"="VESA"\r\n"DriverDesc"="vesa',
                                         b'"InfPath"="MSDISP.INF"\r\n"InfSection"="VGA"\r\n"DriverDesc"="vesa')
        msdisp = msdisp.replace(b'"drv"="vesamini.drv"\r\n"minivdd"="vesamini.vxd"\r\n"Mode"="16,640,480"', b'"drv"="vga.drv"')
        self.assertIn(b'MSDISP.INF', msdisp)
        rc, out = self.run_parser(classes=msdisp, enum=self.ENUM950)
        self.assertNotEqual(rc, 0)
        self.assertIsNone(out)
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
        self.assertIn('VESBIND.EXE CHECK',text)
        self.assertIn(':ROLLBACK',text)
        for version in ['4 0 0 1068','4 0 0 1111','']:
            other=self.create(version)
            self.assertFalse((other/'VESALATE.BAT').exists())
            self.assertNotIn(b'VESALATE',(other/'VESA95.BAT').read_bytes())

if __name__=='__main__':unittest.main()
