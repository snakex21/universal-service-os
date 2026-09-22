"""Exercise the native reader against corrupted/untrusted GPT input, offline."""
import pathlib,struct,subprocess,sys,unittest,uuid,zlib
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'zig-out/windows-source-mount/tests'
GUID='6cd1f746-084e-4bfb-a2b9-19eb561f9489'
BASIC=uuid.UUID('ebd0a0a2-b9e5-4433-87c0-68b6b72699c7').bytes_le
SIZE=4*1024*1024
LAST=SIZE//512-1
def fixture():
    data=bytearray(SIZE)
    table=bytearray(16384)
    table[:16]=BASIC;table[16:32]=uuid.UUID(GUID).bytes_le
    struct.pack_into('<QQ',table,32,2048,4095)
    data[2048*512+3:2048*512+11]=b'NTFS    '
    struct.pack_into('<H',data,2048*512+11,512)
    struct.pack_into('<Q',data,2048*512+40,2047)
    data[2048*512+510:2048*512+512]=b'\x55\xaa'
    rewrite(data,table)
    return data,table
def rewrite(data,table):
    for at,alt,entry in ((1,LAST,2),(LAST,1,LAST-32)):
        h=bytearray(512);h[:8]=b'EFI PART'
        struct.pack_into('<II',h,8,0x10000,92)
        struct.pack_into('<QQQQ',h,24,at,alt,34,LAST-33)
        h[56:72]=bytes(range(16))
        struct.pack_into('<QIII',h,72,entry,128,128,zlib.crc32(table))
        struct.pack_into('<I',h,16,zlib.crc32(h[:92]))
        data[at*512:(at+1)*512]=h
        data[entry*512:entry*512+len(table)]=table
class Reader(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0,str(ROOT/'tools'))
        from build_windows_source_mount import build
        build(ROOT,ROOT/'zig-out/windows-source-mount')
    def config_case(self,data,expected):
        OUT.mkdir(parents=True,exist_ok=True)
        path=OUT/'config.bin';path.write_bytes(data)
        for arch in ('x86','x86_64'):
            result=subprocess.run([str(ROOT/('zig-out/windows-source-mount/usos-source-'+arch+'.exe')),'--inspect-config',str(path)],capture_output=True)
            self.assertEqual(result.returncode==0,expected,(arch,result.stdout,result.stderr))
        self.assertEqual(path.read_bytes(),data)
    def iso_config(self,path=b'Systems\\Windows\\Windows Vista\\Images\\Vista SP2.iso'):
        return b'USOSISO1'+uuid.UUID(GUID).bytes_le+struct.pack('<Q',3702233088)+path+b'\0'
    def test_iso_config(self):self.config_case(self.iso_config(),True)
    def test_usb_logging_and_watcher_refuse_host_windows(self):
        for arch in ('x86','x86_64'):
            helper=ROOT/('zig-out/windows-source-mount/usos-source-'+arch+'.exe')
            result=subprocess.run([str(helper),'--log-root'],capture_output=True,timeout=5)
            self.assertNotEqual(0,result.returncode)
            self.assertIn(b'restricted to WinPE',result.stdout)
            logger=ROOT/('zig-out/windows-source-mount/usos-log-'+arch+'.exe')
            result=subprocess.run([str(logger),'--watch'],capture_output=True,timeout=5)
            self.assertNotEqual(0,result.returncode)
    def test_windows10_iso_config(self):self.config_case(self.iso_config(b'Systems\\Windows\\Windows 10\\Images\\Windows 10 x86.iso'),True)
    def test_legacy_config(self):self.config_case(('work_partuuid='+GUID+'\r\n').encode(),True)
    def test_iso_traversal(self):
        for path in (b'..\\Vista.iso',b'Vista\\..\\bad.iso',b'Vista\\.',b'Vista\\..',b'\\root.iso',b'C:\\Vista.iso',b'Vista/boot.iso',b'bad".iso',b'folder\\\\bad.iso'):
            with self.subTest(path=path):self.config_case(self.iso_config(path),False)
    def test_iso_embedded_nul(self):self.config_case(self.iso_config(b'Vista.iso\0other'),False)
    def test_iso_missing_terminator(self):self.config_case(self.iso_config()[:-1],False)
    def test_iso_zero_identity(self):
        d=bytearray(self.iso_config());d[8:24]=bytes(16);self.config_case(d,False)
    def test_iso_short_image(self):
        d=bytearray(self.iso_config());struct.pack_into('<Q',d,24,0);self.config_case(d,False)
    def test_iso_long_path(self):self.config_case(self.iso_config(b'a'*512),False)
    def run_case(self,data,expected=False,guid=GUID):
        OUT.mkdir(parents=True,exist_ok=True)
        path=OUT/'fixture.raw';path.write_bytes(data)
        for arch in ('x86','x86_64'):
            result=subprocess.run([str(ROOT/('zig-out/windows-source-mount/usos-source-'+arch+'.exe')),'--inspect',str(path),guid],capture_output=True)
            self.assertEqual(result.returncode==0,expected,(arch,result.stdout,result.stderr))
        self.assertEqual(path.read_bytes(),data,'Inspector must never modify input')
    def test_valid(self): self.run_case(fixture()[0],True)
    def test_wrong_identity(self): self.run_case(fixture()[0],guid=str(uuid.uuid4()))
    def test_bad_header_crc(self):
        d,_=fixture();d[512+56]^=1;self.run_case(d)
    def test_bad_entry_crc(self):
        d,_=fixture();d[1024+90]^=1;self.run_case(d)
    def test_backup_mismatch(self):
        d,_=fixture();d[(LAST-32)*512+90]^=1;self.run_case(d)
    def test_duplicate_guid(self):
        d,t=fixture();t[128:256]=t[:128];rewrite(d,t);self.run_case(d)
    def test_overlapping_partition(self):
        d,t=fixture();t[128:256]=t[:128];t[144:160]=uuid.uuid4().bytes_le;rewrite(d,t);self.run_case(d)
    def test_range_outside_usable(self):
        d,t=fixture();struct.pack_into('<Q',t,40,LAST);rewrite(d,t);self.run_case(d)
    def test_inverted_range(self):
        d,t=fixture();struct.pack_into('<QQ',t,32,4095,2048);rewrite(d,t);self.run_case(d)
    def test_wrong_partition_type(self):
        d,t=fixture();t[:16]=uuid.uuid4().bytes_le;rewrite(d,t);self.run_case(d)
    def test_wrong_filesystem(self):
        d,_=fixture();d[2048*512+3]=0;self.run_case(d)
    def test_ntfs_outside_partition(self):
        d,_=fixture();struct.pack_into('<Q',d,2048*512+40,0xffffffffffffffff);self.run_case(d)
    def test_truncated(self): self.run_case(fixture()[0][:-512])
    def test_table_overflow(self):
        d,_=fixture();h=bytearray(d[512:1024]);struct.pack_into('<Q',h,72,0xffffffffffffffff);struct.pack_into('<I',h,16,0);struct.pack_into('<I',h,16,zlib.crc32(h[:92]));d[512:1024]=h;self.run_case(d)
if __name__=='__main__':unittest.main()
