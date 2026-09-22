"""Read/replace existing files in a FAT32 test image; never allocate or format."""
import struct
class FatImage:
    def __init__(self, path):
        self.f = open(path, "r+b")
        header = self.read(512, 512)
        assert header[:8] == b"EFI PART"
        entries = self.read(struct.unpack_from("<Q", header, 72)[0]*512, 16384)
        matches = [entries[i:i+128] for i in range(0,len(entries),128) if entries[i:i+16] == bytes.fromhex("28732ac11ff8d211ba4b00a0c93ec93b")]
        assert len(matches)==1
        self.start = struct.unpack_from("<Q",matches[0],32)[0]*512
        boot=self.read(self.start,512)
        assert struct.unpack_from("<H",boot,11)[0]==512
        self.cb=boot[13]*512
        reserved=struct.unpack_from("<H",boot,14)[0]
        fatsz=struct.unpack_from("<I",boot,36)[0]
        self.fat=self.read(self.start+reserved*512,fatsz*512)
        self.data=self.start+(reserved+boot[16]*fatsz)*512
        self.root=struct.unpack_from("<I",boot,44)[0]
    def read(self, off, count):
        self.f.seek(off); data=self.f.read(count); assert len(data)==count; return data
    def chain(self, cluster):
        result=[]; seen=set()
        while 2 <= cluster < 0xffffff8:
            assert cluster not in seen; seen.add(cluster)
            result.append(self.data+(cluster-2)*self.cb)
            cluster=struct.unpack_from("<I",self.fat,cluster*4)[0]&0xfffffff
        return result
    def find(self,path):
        cluster=self.root
        for component in path.strip("/").split("/"):
            found=None; lfn={}
            for off in self.chain(cluster):
                data=self.read(off,self.cb)
                for j in range(0,len(data),32):
                    ent=data[j:j+32]
                    if ent[0] in (0,229): lfn={}; continue
                    if ent[11]==15:
                        lfn[ent[0]&31]=(ent[1:11]+ent[14:26]+ent[28:32]).decode("utf-16le")
                        continue
                    short=ent[:8].decode("ascii").rstrip()
                    ext=ent[8:11].decode("ascii").rstrip()
                    name="".join(lfn[k] for k in sorted(lfn)).split("\x00")[0].rstrip("\uffff") if lfn else short+("."+ext if ext else "")
                    lfn={}
                    if name.lower()==component.lower():
                        found=(off+j,ent); break
                if found: break
            if not found: raise FileNotFoundError(path)
            loc,ent=found
            cluster=(struct.unpack_from("<H",ent,20)[0]<<16)|struct.unpack_from("<H",ent,26)[0]
        return loc,cluster,struct.unpack_from("<I",ent,28)[0]
    def contents(self,path):
        _,cluster,size=self.find(path)
        return b"".join(self.read(off,self.cb) for off in self.chain(cluster))[:size]
    def replace(self,path,data):
        loc,cluster,_=self.find(path); offsets=self.chain(cluster)
        assert len(data)<=len(offsets)*self.cb
        for i,off in enumerate(offsets):
            self.f.seek(off); self.f.write(data[i*self.cb:(i+1)*self.cb].ljust(self.cb,b"\x00"))
        self.f.seek(loc+28); self.f.write(struct.pack("<I",len(data))); self.f.flush()
    def close(self): self.f.close()
