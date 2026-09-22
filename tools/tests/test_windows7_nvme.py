"""Bounded-file parsers and preservation/target guards for native Win7 NVMe."""
from pathlib import Path
import hashlib,struct,subprocess,sys,unittest,uuid,shutil,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from build_windows7_nvme import build_helpers,read_assets
NS='urn:schemas-microsoft-com:unattend'
OUT=ROOT/'zig-out/windows7-nvme'

def version_pe(version):
    """A non-executable PE resource fixture; never used as a bootable driver."""
    b=bytearray(1024);struct.pack_into('<H',b,0,0x5a4d);struct.pack_into('<I',b,0x3c,0x80)
    struct.pack_into('<IHH',b,0x80,0x4550,0x8664,1);struct.pack_into('<H',b,0x94,240)
    op=0x98;struct.pack_into('<H',b,op,0x20b);struct.pack_into('<I',b,op+108,16)
    struct.pack_into('<II',b,op+128,0x1000,512)
    section=op+240;b[section:section+8]=b'.rsrc\0\0\0';struct.pack_into('<IIII',b,section+8,512,0x1000,512,512)
    for at,ident,child in [(0,16,0x80000020),(32,1,0x80000040),(64,1033,96)]:
        struct.pack_into('<H',b,512+at+14,1);struct.pack_into('<II',b,512+at+16,ident,child)
    struct.pack_into('<II',b,512+96,0x1080,92)
    at=512+128;struct.pack_into('<HHH',b,at,92,52,0)
    key='VS_VERSION_INFO\0'.encode('utf-16-le');b[at+6:at+6+len(key)]=key
    a,c,d,e=version;struct.pack_into('<IIII',b,at+40,0xfeef04bd,0x10000,(a<<16)|c,(d<<16)|e)
    return bytes(b)

class Nvme(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build_helpers(ROOT,OUT);cls.assets=read_assets(ROOT)
        cls.work=OUT/('tests-'+uuid.uuid4().hex[:8]);cls.work.mkdir()
    def invoke(self,text,ok=True,source='0',encoding='utf-8'):
        folder=self.work/uuid.uuid4().hex;folder.mkdir();p=folder/'plik odpowiedzi ąść.xml';q=folder/'wynik.xml'
        if text is not None:p.write_text(text,encoding=encoding);before=p.read_bytes()
        command=[str(OUT/'usos-win7-unattend.exe'),str(p) if text is not None else '-',str(q),source]
        result=subprocess.run(command,capture_output=True)
        self.assertEqual(result.returncode==0,ok,result.stdout)
        if text is not None:self.assertEqual(p.read_bytes(),before)
        self.assertEqual(q.exists(),ok)
        return ET.parse(q).getroot() if ok else None
    def wrap(self,inner,prefix=''):
        return '<'+prefix+'unattend xmlns'+(':u' if prefix else '')+'="'+NS+'">'+inner+'</'+prefix+'unattend>'
    def test_manual_keeps_setup_interactive(self):
        root=self.invoke(None)
        self.assertEqual(len(root.findall('{'+NS+'}servicing/{'+NS+'}package')),2)
        self.assertFalse(root.findall('{'+NS+'}settings'))
        for source in root.findall('.//{'+NS+'}source'):
            self.assertEqual(OUT,Path(source.attrib['location']).parent)
    def test_native_sha2_transport_is_required_and_added_before_nvme(self):
        folder=self.work/uuid.uuid4().hex;folder.mkdir()
        helper=folder/'usos-win7-unattend.exe'
        shutil.copyfile(OUT/helper.name,helper)
        (folder/'usos-sha2-required.flag').write_text('1')
        output=folder/'answer.xml'
        command=[str(helper),'-',str(output),'0']
        self.assertNotEqual(0,subprocess.run(command,capture_output=True).returncode)
        self.assertFalse(output.exists())
        (folder/'Windows6.1-KB4474419-v3-x64.cab').write_bytes(b'path-only fixture; never serviced')
        result=subprocess.run(command,capture_output=True)
        self.assertEqual(0,result.returncode,result.stdout)
        root=ET.parse(output).getroot()
        identities=root.findall('.//{'+NS+'}assemblyIdentity')
        self.assertEqual(['Package_for_KB4474419','Package_for_KB2990941','Package_for_KB3087873'],[n.attrib['name'] for n in identities])
        self.assertEqual('6.1.3.2',identities[0].attrib['version'])
        self.assertFalse(root.findall('{'+NS+'}settings'))
    def test_kmdf_dependency_required_and_merged_once(self):
        from build_windows7_kmdf import read_cab, CAB_NAME
        folder=self.work/uuid.uuid4().hex;folder.mkdir()
        helper=folder/'usos-win7-unattend.exe'
        shutil.copyfile(OUT/helper.name,helper)
        (folder/'usos-kmdf-required.flag').write_text('1')
        output=folder/'answer.xml'
        command=[str(helper),'-',str(output),'0']
        self.assertNotEqual(0,subprocess.run(command,capture_output=True).returncode)
        self.assertFalse(output.exists())
        (folder/CAB_NAME).write_bytes(read_cab(ROOT))
        result=subprocess.run(command,capture_output=True)
        self.assertEqual(0,result.returncode,result.stdout)
        identities=ET.parse(output).findall('.//{'+NS+'}assemblyIdentity')
        self.assertEqual(['Package_for_KB2990941','Package_for_KB3087873','Package_for_KB2685811'],[n.attrib['name'] for n in identities])
        self.assertEqual('6.1.1.11',identities[-1].attrib['version'])
        merged=folder/'merged.xml'
        result=subprocess.run([str(helper),str(output),str(merged),'0'],capture_output=True)
        self.assertEqual(0,result.returncode,result.stdout)
        self.assertEqual(3,len(ET.parse(merged).findall('.//{'+NS+'}assemblyIdentity')))
        output.write_text(output.read_text().replace('6.1.1.11','6.1.1.9'))
        result=subprocess.run([str(helper),str(output),str(folder/'bad.xml'),'0'],capture_output=True)
        self.assertNotEqual(0,result.returncode)
        self.assertFalse((folder/'bad.xml').exists())
    def test_preserves_user_settings(self):
        settings='<settings pass="windowsPE"><component name="Microsoft-Windows-Setup"><DiskConfiguration><Disk><DiskID>1</DiskID><WillWipeDisk>true</WillWipeDisk></Disk></DiskConfiguration><ImageInstall><OSImage><InstallTo><DiskID>1</DiskID><PartitionID>3</PartitionID></InstallTo></OSImage></ImageInstall></component></settings>'
        text=self.wrap(settings);old=ET.fromstring(text);new=self.invoke(text)
        self.assertEqual(ET.tostring(old[0]),ET.tostring(new[0]))
    def test_utf16_and_cdata(self):
        self.invoke('<?xml version="1.0" encoding="utf-16"?>'+self.wrap('<settings pass="specialize"><value><![CDATA[</unattend> Zażółć]]></value></settings>'),encoding='utf-16')
    def test_source_disk_guard(self):
        cases=[('0',False),('1',True),(' \n000\t',False),('<![CDATA[0]]>',False),('<![CDATA[0]]><!--split--><![CDATA[1]]>',True),('-1',False),('',False),('<nested>1</nested>',False),('4294967296',False),('0x01',False)]
        for prefix in ('','u:'):
            for value,ok in cases:
                with self.subTest(prefix=prefix,value=value):
                    self.invoke(self.wrap('<'+prefix+'settings><'+prefix+'DiskID>'+value+'</'+prefix+'DiskID></'+prefix+'settings>',prefix),ok)
    def test_external_entities_rejected(self):
        self.invoke('<!DOCTYPE unattend [<!ENTITY e SYSTEM "file:///C:/untrusted">]>'+self.wrap('&e;'),False)
    def test_malformed_xml_rejected(self):
        for text in ('<wrong/>',self.wrap('<settings>'),self.wrap('<x>'*70+'</x>'*70)):
            with self.subTest(text=text[:40]):self.invoke(text,False)
    def test_existing_servicing(self):
        for inner in ('<servicing/>','<servicing></servicing>'):
            self.assertEqual(len(self.invoke(self.wrap(inner)).findall('.//{'+NS+'}package')),2)
    def test_existing_package_conflicts(self):
        package='<package action="install"><assemblyIdentity name="Package_for_KB2990941" version="6.1.3.0" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral"/><source location="X:\\trusted.cab"/></package>'
        good=self.wrap('<servicing>'+package+'</servicing>')
        self.assertEqual(len(self.invoke(good).findall('.//{'+NS+'}package')),2)
        for old,new in [('6.1.3.0','6.1.2.0'),('amd64','x86'),('31bf3856ad364e35','0000000000000000'),('action="install"','action="remove"'),(package,package+package)]:
            with self.subTest(old=old[:30]):self.invoke(good.replace(old,new),False)
    def test_output_is_never_overwritten(self):
        q=self.work/'existing.xml';q.write_bytes(b'preserve this file')
        result=subprocess.run([str(OUT/'usos-win7-unattend.exe'),'-',str(q),'0'],capture_output=True)
        self.assertNotEqual(result.returncode,0);self.assertEqual(q.read_bytes(),b'preserve this file')
    def test_invalid_guard_argument(self):self.invoke(None,False,source='not-a-number')
    def test_catalog_helper_refuses_host_windows(self):
        result=subprocess.run([str(OUT/'usos-win7-nvme.exe')],capture_output=True)
        self.assertNotEqual(result.returncode,0)
    def parse_version(self,data):
        p=self.work/(uuid.uuid4().hex+'.bin');p.write_bytes(data)
        result=subprocess.run([str(OUT/'pe-file-version.exe'),str(p)],capture_output=True)
        self.assertEqual(p.read_bytes(),data)
        return result
    def test_version_resource(self):
        for version in [(6,1,7601,17514),(6,1,7601,22822),(6,1,7601,25000)]:
            result=self.parse_version(version_pe(version));self.assertEqual(result.returncode,0)
            self.assertEqual(tuple(map(int,result.stdout.split())),version)
    def test_malformed_pe_ranges(self):
        original=version_pe((6,1,7601,18615));cases=[original[:512],b'bad']
        for offset,value in [(0x3c,0xfffffff0),(0x98+128,0xffffff00),(0x98+132,0xffffffff),(512+20,0x80000000),(512+96,0xffffff00),(512+128+40,0)]:
            b=bytearray(original);struct.pack_into('<I',b,offset,value);cases.append(bytes(b))
        for data in cases:
            with self.subTest(length=len(data)):self.assertEqual(self.parse_version(data).returncode,1)
    def test_pinned_component_versions(self):
        for line in self.assets['files.tsv'].decode().splitlines():
            branch,group,path,version=line.split('\t')
            if version=='-':continue
            result=self.parse_version(self.assets['bootstrap/'+branch+'/'+path])
            self.assertEqual(result.returncode,0,path);self.assertEqual(result.stdout.decode().strip(),version,path)

if __name__=='__main__':unittest.main()
