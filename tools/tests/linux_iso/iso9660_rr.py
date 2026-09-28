"""Tiny ISO9660 reader with Rock Ridge NM names (test tooling only)."""
import sys, struct

def rr_name(rec):
    nlen = rec[32]
    su = rec[33 + nlen + ((nlen + 1) & 1) - (0 if nlen % 2 else 0):]
    # system use starts after name + pad byte when name length even
    off = 33 + nlen + (1 if nlen % 2 == 0 else 0)
    su = rec[off:]
    name = b""
    i = 0
    while i + 4 <= len(su):
        sig, ln = su[i:i+2], su[i+2]
        if ln < 4: break
        if sig == b"NM":
            name += su[i+5:i+ln]
        i += ln
    return name.decode("latin1") if name else None

class Iso:
    def __init__(self, path):
        self.f = open(path, "rb")
        pvd = self.read(16 * 2048, 2048)
        assert pvd[1:6] == b"CD001"
        self.label = pvd[40:72].decode().strip()
        self.root = pvd[156:190]
    def read(self, off, n):
        self.f.seek(off); return self.f.read(n)
    def entries(self, rec):
        lba, size = struct.unpack_from("<I", rec, 2)[0], struct.unpack_from("<I", rec, 10)[0]
        data = self.read(lba * 2048, size)
        i = 0; out = []
        while i < len(data):
            l = data[i]
            if l == 0:
                i = (i // 2048 + 1) * 2048; continue
            r = data[i:i+l]; i += l
            nlen = r[32]; raw = r[33:33+nlen]
            if raw in (b"\0", b"\1"): continue
            name = rr_name(r) or raw.decode("latin1").split(";")[0].rstrip(".")
            out.append((name, r))
        return out
    def find(self, path):
        rec = self.root
        for comp in [p for p in path.split("/") if p]:
            for name, r in self.entries(rec):
                if name.lower() == comp.lower():
                    rec = r; break
            else:
                return None
        return rec
    def isdir(self, r): return bool(r[25] & 2)
    def cat(self, path):
        r = self.find(path)
        if r is None: return None
        lba, size = struct.unpack_from("<I", r, 2)[0], struct.unpack_from("<I", r, 10)[0]
        return self.read(lba * 2048, size)
    def ls(self, path):
        r = self.find(path)
        return [(n, struct.unpack_from("<I", e, 10)[0], self.isdir(e)) for n, e in self.entries(r)] if r else None

if __name__ == "__main__":
    iso = Iso(sys.argv[1])
    print("LABEL", iso.label)
    for a in sys.argv[2:]:
        if a.startswith("ls:"):
            print(a, iso.ls(a[3:]))
        else:
            d = iso.cat(a)
            print("=====", a); print(d.decode("utf-8", "replace") if d else None)
