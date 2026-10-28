"""FAT16 source selection and MBR geometry without touching a block device."""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'artifacts/fat16-tests';OUT.mkdir(parents=True,exist_ok=True)
SH=shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'


def shell(command):
    script=(ROOT/'tools/w9x_filesystem.sh').as_posix()
    return subprocess.run([SH,'-c',". '"+script+"'; "+command],capture_output=True)


def ne_image(version=(4,0,0,950),second=None):
    data=bytearray(2048);data[:2]=b'MZ';struct.pack_into('<I',data,60,128)
    data[128:130]=b'NE';struct.pack_into('<HH',data,128+36,64,128)
    p=192;struct.pack_into('<H',data,p,4);p+=2
    versions=[version] if second is None else [version,second]
    struct.pack_into('<HHI',data,p,0x8010,len(versions),0);p+=8
    for i,v in enumerate(versions):
        at=512+i*256
        struct.pack_into('<6H',data,p,at//16,16,0,0x8001,0,0);p+=12
        struct.pack_into('<HH',data,at,72,52);data[at+4:at+20]=b'VS_VERSION_INFO\0'
        struct.pack_into('<4I',data,at+20,0xfeef04bd,0x10000,(v[0]<<16)|v[1],(v[2]<<16)|v[3])
    struct.pack_into('<H',data,p,0)
    return data


def pe_image(plus=False):
    data=bytearray(2048);data[:2]=b'MZ';struct.pack_into('<I',data,60,128)
    pe=128;data[pe:pe+4]=b'PE\0\0';optional=240 if plus else 224;op=pe+24
    struct.pack_into('<H',data,pe+6,1);struct.pack_into('<H',data,pe+20,optional)
    struct.pack_into('<H',data,op,0x20b if plus else 0x10b);dd=112 if plus else 96
    struct.pack_into('<I',data,op+dd-4,16)
    struct.pack_into('<II',data,op+dd+16,0x1000,512)
    section=op+optional;struct.pack_into('<IIII',data,section+8,512,0x1000,512,512)
    # resource root -> type 16 -> name 1 -> language -> data entry
    for at,ident,child in ((512,16,0x80000020),(544,1,0x80000040),(576,1033,0x60)):
        struct.pack_into('<H',data,at+14,1);struct.pack_into('<II',data,at+16,ident,child)
    struct.pack_into('<IIII',data,608,0x1080,92,0,0)
    struct.pack_into('<HHH',data,640,92,52,0)
    key='VS_VERSION_INFO\0'.encode('utf-16le');data[646:646+len(key)]=key
    struct.pack_into('<4I',data,680,0xfeef04bd,0x10000,(6<<16)|1,(7601<<16)|17514)
    return data


class VersionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        if not Path(cc).is_file():raise unittest.SkipTest('host C compiler unavailable')
        cls.tmp=tempfile.TemporaryDirectory(prefix='version-',dir=OUT);cls.work=Path(cls.tmp.name)
        cls.exe=cls.work/'version.exe'
        env=dict(os.environ,TMP=str(cls.work),TEMP=str(cls.work))
        subprocess.run([cc,'-std=c11','-O2','-Wall','-Wextra','-Werror',str(ROOT/'tools/pe_file_version.c'),'-o',str(cls.exe)],
                       check=True,capture_output=True,env=env)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def read_version(self,data):
        source=self.work/'own-format.bin';source.write_bytes(data)
        return subprocess.run([str(self.exe),str(source)],capture_output=True,text=True)
    def test_ne_95_versions(self):
        for revision in (950,1068,1111):
            with self.subTest(revision=revision):
                r=self.read_version(ne_image((4,0,0,revision)))
                self.assertEqual(r.returncode,0);self.assertEqual(r.stdout.strip(),f'4 0 0 {revision}')
    def test_pe32_and_pe32plus_are_preserved(self):
        for plus in (False,True):
            r=self.read_version(pe_image(plus));self.assertEqual(r.returncode,0)
            self.assertEqual(r.stdout.strip(),'6 1 7601 17514')
    def test_conflicting_version_resources_are_rejected(self):
        self.assertNotEqual(self.read_version(ne_image(second=(4,0,0,1111))).returncode,0)
    def test_malformed_ne_bounds_and_values_are_rejected(self):
        changes=[(192,'<H',16),(196,'<H',4097),(202,'<H',0xffff),(512,'<H',20),
                 (514,'<H',51),(518,'<B',0),(532,'<I',0)]
        for at,fmt,value in changes:
            with self.subTest(at=at):
                data=ne_image();struct.pack_into(fmt,data,at,value)
                self.assertNotEqual(self.read_version(data).returncode,0)
        self.assertNotEqual(self.read_version(ne_image()[:240]).returncode,0)
    def test_signature_outside_version_resource_is_not_identity(self):
        data=ne_image();struct.pack_into('<H',data,194,0x8001)
        self.assertNotEqual(self.read_version(data).returncode,0)


class GeometryTests(unittest.TestCase):
    def test_rtm_osr1_fat16_and_osr2_fat32(self):
        for revision,bits in ((950,16),(1068,32),(1111,32),(1216,32)):
            r=shell(f"usos_w9x_fs_select 95 '4 0 0 {revision}' && printf '%s' \"$W9X_FAT_BITS\"")
            self.assertEqual((r.returncode,r.stdout),(0,str(bits).encode()))
        self.assertNotEqual(shell("usos_w9x_fs_select 95 'unknown'").returncode,0)
    def test_fat16_cap_and_real_chs_match_lba(self):
        r=shell("usos_w9x_fs_select 95 '4 0 0 950'; usos_w9x_fs_layout 67108864; usos_w9x_partition_entry 16 2048 \"$W9X_FS_SECTORS\"")
        self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(len(r.stdout),16)
        entry=r.stdout;self.assertEqual((entry[0],entry[4]),(128,6))
        start,sectors=struct.unpack_from('<II',entry,8);self.assertEqual((start,sectors),(2048,4192256))
        for field,lba in ((entry[1:4],start),(entry[5:8],start+sectors-1)):
            h,s,c=field;decoded=(((s&192)<<2)|c)*255*63+h*63+(s&63)-1
            self.assertEqual(decoded,lba)
        self.assertLess((sectors-1-32)//64,65525,'Must remain FAT16 after mkfs overhead')
    def test_small_target_is_not_grown(self):
        r=shell("usos_w9x_fs_select 95 '4 0 0 950'; usos_w9x_fs_layout 1048576; printf '%s' \"$W9X_FS_SECTORS\"")
        self.assertEqual(r.stdout,b'1048576')
    def test_existing_fat32_partition_entry_is_unchanged(self):
        for system in ('98','98SE','ME'):
            r=shell(f"usos_w9x_fs_select {system} ''; usos_w9x_partition_entry \"$W9X_FAT_BITS\" 2048 16777216")
            self.assertEqual(r.stdout,b'\x80\xfe\xff\xff\x0c\xfe\xff\xff'+struct.pack('<II',2048,16777216))
    def test_version_selection_precedes_first_target_write(self):
        script=(ROOT/'tools/w9x_csmwrap_target.sh').read_text()
        self.assertLess(script.index('usos_w9x_fs_select'),script.index('dd if=/dev/zero of="$TARGET_DEVICE"'))


if __name__=='__main__':unittest.main()
