import subprocess, struct, tempfile, unittest
from pathlib import Path
SCRIPT=Path(__file__).with_name("patch_vdi_geometry.py")
class VdiGeometryTests(unittest.TestCase):
    def check_header(self,size,mapoff=512,ok=True):
        data=bytearray(4096)
        for off,value in [(0x40,0xBEDA107F),(0x44,0x10001),(0x48,size),(0x154,mapoff),(0x168,512)]:
            struct.pack_into("<I",data,off,value)
        data[512:]=b"Z"*(len(data)-512)
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[3]/"tools/cache/tmp") as tmp:
            path=Path(tmp)/"test.vdi";path.write_bytes(data)
            result=subprocess.run(["python",str(SCRIPT),str(path),"--cylinders","1024","--heads","240","--sectors","63"],capture_output=True)
            actual=path.read_bytes()
            if ok:
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(struct.unpack_from("<I",actual,0x48)[0],400)
                self.assertEqual(struct.unpack_from("<III",actual,0x1c8),(1024,240,63))
                allowed=set(range(0x48,0x4c))|set(range(0x15c,0x168))|set(range(0x1c8,0x1d8))
                self.assertTrue(all(a==b or i in allowed for i,(a,b) in enumerate(zip(data,actual))))
            else:
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(actual,data)
    def test_old_header_is_upgraded_before_vbox_can_clear_lchs(self): self.check_header(384)
    def test_current_header_keeps_guest_data(self): self.check_header(400)
    def test_reject_unknown_header_without_write(self): self.check_header(300,ok=False)
    def test_reject_overlapping_map_without_write(self): self.check_header(384,448,False)
if __name__=="__main__": unittest.main()
