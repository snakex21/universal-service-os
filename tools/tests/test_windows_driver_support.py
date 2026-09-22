"""Validate driver transport and answer-file preservation using real Win32 helpers."""
from pathlib import Path
import struct, subprocess, sys, tempfile, unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
HELPERS = ROOT / 'zig-out/windows7-uefi'
NS = 'urn:schemas-microsoft-com:unattend'
WCM = 'http://schemas.microsoft.com/WMIConfig/2002/State'
COMPONENT = 'Microsoft-Windows-PnpCustomizationsNonWinPE'
PATH = r'X:\Windows\System32\usos-win7-drivers'

def archive(entries):
    data = bytearray(b'USOSDRV1' + struct.pack('<I', len(entries)))
    for name, payload in entries:
        name = name.encode('ascii')
        data += struct.pack('<HI', len(name), len(payload)) + name + payload
    return data

class Support(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0,str(ROOT/'tools'))
        from build_windows7_uefi import build
        build(ROOT,HELPERS)

    def setUp(self):
        parent = ROOT / 'zig-out/windows-driver-tests'
        parent.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_helper(self, name, *args):
        return subprocess.run([str(HELPERS / name), *map(str,args)], cwd=self.root,
                              capture_output=True, timeout=20)

    def test_archive_preserves_nested_paths_and_rejects_unsafe_or_truncated_names(self):
        file = self.root / 'drivers.bin'
        good = archive([(r'Vendor\controller\driver.inf', b'INF'), (r'Vendor\controller\x64\driver.sys', b'SYS'), (r'Vendor\controller\driver.cat', b'CAT')])
        file.write_bytes(good)
        self.assertEqual(0, self.run_helper('usos-drivers.exe','--inspect',file).returncode)
        for data in [good[:-1], good+b'x', archive([('../escape', b'x')]), archive([('C:\\escape', b'x')]),
                     archive([('CON.inf', b'x')]), archive([('sub\\LPT1.sys', b'x')]), archive([('bad.\\x', b'x')]),
                     archive([('x.inf', b'a'), ('X.INF', b'b')])]:
            file.write_bytes(data)
            self.assertNotEqual(0, self.run_helper('usos-drivers.exe','--inspect',file).returncode)
        self.assertFalse((self.root/'usos-win7-drivers').exists())

    def test_target_efi_assets_are_transported_as_data_not_boot_applications(self):
        from build_windows_native_support import build_stock_support
        build_stock_support(ROOT,self.root)
        data=(self.root/'win7-support.cpio').read_bytes()
        self.assertLess(len(data),64*1024*1024)
        files={};at=0
        while at<len(data):
            self.assertEqual(b'070701',data[at:at+6])
            size=int(data[at+54:at+62],16);length=int(data[at+94:at+102],16)
            name=data[at+110:at+110+length-1].decode('ascii')
            start=(at+110+length+3)&~3
            files[name]=data[start:start+size]
            at=(start+size+3)&~3
        self.assertFalse(any(name.lower().endswith('.efi') for name in files))
        self.assertNotIn('usos-stock-win7.flag',files)
        self.assertNotIn('usos-modern-win7.flag',files)
        self.assertEqual((HELPERS/'win7-wrapper.efi').read_bytes(),files['usos-win7-wrapper.bin'])
        self.assertEqual((ROOT/'tools/vendor/uefiseven/1.30/UefiSeven.efi').read_bytes(),files['usos-win7-video.bin'])
        from build_windows7_sha2 import read_cab, CAB_NAME
        self.assertEqual(read_cab(ROOT), files[CAB_NAME])
        self.assertIn('usos-sha2-required.flag', files)
        from build_windows7_nvme import read_assets
        for name,content in read_assets(ROOT).items():
            if name.startswith('updates/'):
                self.assertEqual(content,files[name.split('/')[-1]])

    def merge(self, content):
        output = self.root/'result.xml'
        if output.exists(): output.unlink()
        if content is None:
            source = '-'
        else:
            source = self.root/'input.xml'
            source.write_text(content, encoding='utf-8')
        result = self.run_helper('usos-unattend-drivers.exe',source,output,PATH)
        self.assertEqual(0,result.returncode,result.stderr)
        if content is not None: self.assertEqual(content,source.read_text(encoding='utf-8'))
        return ET.parse(output).getroot()

    def test_driver_path_added_to_new_and_existing_containers(self):
        component = f'<component name="{COMPONENT}" processorArchitecture="amd64"'
        bodies = ['', '<settings pass="offlineServicing"/>',
                  '<settings pass="offlineServicing">'+component+'/></settings>',
                  '<settings pass="offlineServicing">'+component+'><DriverPaths/></component></settings>',
                  '<settings pass="offlineServicing">'+component+'><DriverPaths><PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\\Old</Path></PathAndCredentials></DriverPaths></component></settings>']
        for body in bodies:
            tree = self.merge(f'<unattend xmlns="{NS}" xmlns:wcm="{WCM}">{body}<settings pass="oobeSystem"><component name="KeepMe"><Value>unchanged</Value></component></settings></unattend>')
            paths = tree.findall('.//{'+NS+'}Path')
            self.assertEqual(1, sum(node.text == PATH for node in paths))
            self.assertEqual('unchanged', tree.find('.//{'+NS+'}Value').text)
            self.assertEqual(1,len([n for n in tree if n.attrib.get('pass')=='offlineServicing']))
        tree = self.merge(None)
        self.assertEqual(PATH,tree.find('.//{'+NS+'}Path').text)
        self.assertIsNone(tree.find('.//{'+NS+'}DiskConfiguration'))

    def test_invalid_xml_and_existing_output_are_not_overwritten(self):
        source=self.root/'input.xml';output=self.root/'result.xml'
        for content in ['<bad/>',f'<!DOCTYPE unattend [<!ENTITY x SYSTEM "file:///secret">]><unattend xmlns="{NS}">&x;</unattend>',f'<unattend xmlns="{NS}"><settings pass="offlineServicing"/><settings pass="offlineServicing"/></unattend>']:
            source.write_text(content)
            self.assertNotEqual(0,self.run_helper('usos-unattend-drivers.exe',source,output,PATH).returncode)
            self.assertFalse(output.exists())
        output.write_text('keep')
        self.assertNotEqual(0,self.run_helper('usos-unattend-drivers.exe','-',output,PATH).returncode)
        self.assertEqual('keep',output.read_text())

    def test_answer_file_cannot_select_the_source_disk(self):
        source=self.root/'input.xml';output=self.root/'result.xml'
        source.write_text(f'<unattend xmlns="{NS}"><settings pass="windowsPE"><component name="Microsoft-Windows-Setup"><DiskConfiguration><Disk><DiskID>1</DiskID></Disk></DiskConfiguration></component></settings></unattend>')
        self.assertNotEqual(0,self.run_helper('usos-unattend-drivers.exe',source,output,PATH,'1').returncode)
        self.assertFalse(output.exists())
        self.assertEqual(0,self.run_helper('usos-unattend-drivers.exe',source,output,PATH,'2').returncode)
        self.assertEqual('1',ET.parse(output).find('.//{'+NS+'}DiskID').text)

if __name__=='__main__': unittest.main()
