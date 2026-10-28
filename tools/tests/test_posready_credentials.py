"""POSReady password transfer: parser, special characters, bounds and guard.
Only synthetic strings; the native helper refuses this modern dev host.
"""
from pathlib import Path
import ctypes, os, shutil, subprocess, tempfile, unittest
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[2]

class Credentials(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent=ROOT/'zig-out/posrlog-tests';parent.mkdir(parents=True,exist_ok=True)
        cls.tmp=tempfile.TemporaryDirectory(dir=parent);out=Path(cls.tmp.name)
        c=out/'parser.c';dll=out/'parser.dll'
        c.write_text('#include "'+(ROOT/'tools/nt/posrlog/credentials.h').as_posix()+'"\n'
                     '__declspec(dllexport) int parse(const char*p,unsigned n,char*out,unsigned cap){return pr_password(p,n,out,cap);}\n')
        gcc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        subprocess.run([gcc,'-shared','-std=c99','-O2',str(c),'-o',str(dll)],check=True)
        cls.dll=ctypes.CDLL(str(dll));cls.fn=cls.dll.parse
        cls.fn.argtypes=[ctypes.c_char_p,ctypes.c_uint,ctypes.c_void_p,ctypes.c_uint];cls.fn.restype=ctypes.c_int

    @classmethod
    def tearDownClass(cls):
        # Windows keeps the loaded DLL open. Leave this tiny test module in
        # the application's own test folder until process exit.
        cls.tmp._finalizer.detach()

    def parse(self,xml,cap=2048):
        raw=xml.encode('utf-8');out=ctypes.create_string_buffer(cap+8);ctypes.memset(out,0xa5,cap+8)
        ok=self.fn(raw,len(raw),out,cap)
        self.assertEqual(bytes(out)[cap:],b'\xa5'*8)
        return ok,out.value if ok else b''

    def test_empty_keeps_blank_password(self):
        self.assertEqual(self.parse('<Unattend><UserData><AdminPassword Value="" EncryptedPassword="No" /></UserData></Unattend>'),(1,b''))

    def test_quotes_backslashes_entities_and_utf8(self):
        value='A\\B&quot;&amp;&apos;&lt;&gt;&#x105;&#128512;'
        ok,decoded=self.parse('<AdminPassword EncryptedPassword="No" Value="'+value+'"/>')
        self.assertEqual((ok,decoded),(1,'A\\B"&\'<>ą😀'.encode()))

    def test_comment_is_not_a_credential(self):
        self.assertEqual(self.parse('<!-- <AdminPassword Value="ignored"/> --><AdminPassword Value="ok"/>'),(1,b'ok'))

    def test_reject_ambiguous_encrypted_and_malformed(self):
        for xml in ('<AdminPassword Value="a"/><AdminPassword Value="b"/>',
                    '<AdminPassword Value="x" EncryptedPassword="Yes"/>',
                    '<AdminPassword Value="x" Value="y"/>','<AdminPassword Value="&unknown;"/>',
                    '<AdminPassword Value="&#0;"/>','<AdminPassword Value="&#xD800;"/>',
                    '<AdminPassword Value="unterminated>','<AdminPasswordX Value="x"/>',
                    '<!DOCTYPE x SYSTEM "local"><AdminPassword Value="x"/>'):
            self.assertEqual(self.parse(xml)[0],0)

    def test_buffer_limit(self):
        self.assertEqual(self.parse('<AdminPassword Value="abcd"/>',4)[0],0)
        self.assertEqual(self.parse('<AdminPassword Value="abc"/>',4),(1,b'abc'))

    def test_sif_to_xml_does_not_change_password_or_expand_it_again(self):
        sh=shutil.which('sh') or r'C:\Program Files\Git\bin\sh.exe'
        with tempfile.TemporaryDirectory(dir=ROOT/'zig-out/posrlog-tests') as tmp:
            folder=Path(tmp);script=folder/'answer.sh';sif=folder/'answer.sif'
            script.write_text((ROOT/'tools/posready_qemu_install.sh').read_text(),newline='\n')
            value='a\\b"&<>@FULL_NAME@'
            sif.write_text('[UserData]\nFullName=USOS\nAdminPassword='+value+'\nProductKey=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\n')
            result=subprocess.run([sh,'-c','. "$1"; posready_answer_xml "$2" "$3"','test',
                                   script.as_posix(),(ROOT/'tools/posready_unattended.xml').as_posix(),sif.as_posix()],
                                  capture_output=True,check=True)
            self.assertEqual(ET.fromstring(result.stdout).find('UserData/AdminPassword').get('Value'),value)

    @unittest.skipUnless(os.name=='nt','Windows host guard')
    def test_modern_host_is_refused_before_any_registry_write(self):
        exe=ROOT/'tools/nt/posrlog/bin/i386/posrlog.exe'
        self.assertEqual(subprocess.run([str(exe)],capture_output=True).returncode,2)

if __name__=='__main__':unittest.main()
