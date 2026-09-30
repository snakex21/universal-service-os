"""Read files from the first FAT32 (or FAT16) partition of a raw disk image,
for checking Windows 9x test targets (docs/win9x-modern-2026-09-30.md).
Read-only; never writes the image.

  python fat32_read.py DISK.raw ls [DIR]          list a directory (\\ = root)
  python fat32_read.py DISK.raw cat PATH           print a text file
  python fat32_read.py DISK.raw get PATH OUTFILE   copy a file out
"""
import struct, sys


class Fat:
    def __init__(self, path):
        self.f = open(path, 'rb')
        mbr = self.read(0, 512)
        for i in range(4):
            e = mbr[446 + i * 16: 462 + i * 16]
            if e[4] in (0x0b, 0x0c, 0x06, 0x0e):
                self.base = struct.unpack_from('<I', e, 8)[0] * 512
                break
        else:
            raise SystemExit('no FAT partition in the MBR')
        b = self.read(self.base, 512)
        self.bps, self.spc = struct.unpack_from('<H', b, 11)[0], b[13]
        self.reserved, self.nfats = struct.unpack_from('<H', b, 14)[0], b[16]
        root_entries, fat16 = struct.unpack_from('<H', b, 17)[0], struct.unpack_from('<H', b, 22)[0]
        self.fat32 = fat16 == 0
        spf = struct.unpack_from('<I', b, 36)[0] if self.fat32 else fat16
        self.fat = self.base + self.reserved * self.bps
        root_sectors = (root_entries * 32 + self.bps - 1) // self.bps
        self.root16 = self.fat + self.nfats * spf * self.bps
        self.data = self.root16 + root_sectors * self.bps
        self.root = struct.unpack_from('<I', b, 44)[0] if self.fat32 else 0
        self.csize = self.spc * self.bps

    def read(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def chain(self, c):
        while 2 <= c < (0x0ffffff8 if self.fat32 else 0xfff8):
            yield c
            c = (struct.unpack('<I', self.read(self.fat + c * 4, 4))[0] & 0x0fffffff) if self.fat32 else struct.unpack('<H', self.read(self.fat + c * 2, 2))[0]

    def clusters(self, c):
        return b''.join(self.read(self.data + (x - 2) * self.csize, self.csize) for x in self.chain(c))

    def entries(self, c):
        raw = self.clusters(c) if c else self.read(self.root16, self.data - self.root16)
        lfn = ''
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xe5:
                lfn = ''
                continue
            if e[11] == 0x0f:
                part = (e[1:11] + e[14:26] + e[28:32]).decode('utf-16-le', 'replace').split('\x00')[0]
                lfn = part + lfn
                continue
            short = e[0:8].decode('cp1250').rstrip() + ('.' + e[8:11].decode('cp1250').rstrip() if e[8:11].strip() else '')
            cl = (struct.unpack_from('<H', e, 20)[0] << 16) | struct.unpack_from('<H', e, 26)[0]
            yield (lfn or short), short, e[11], cl, struct.unpack_from('<I', e, 28)[0]
            lfn = ''

    def find(self, path):
        c, attr, size = self.root, 0x10, 0
        for part in [p for p in path.replace('/', '\\').split('\\') if p]:
            for name, short, a, cl, sz in self.entries(c):
                if part.upper() in (name.upper(), short.upper()):
                    c, attr, size = cl, a, sz
                    break
            else:
                raise SystemExit('not found: ' + path)
        return c, attr, size


def main():
    fs = Fat(sys.argv[1])
    cmd = sys.argv[2]
    if cmd == 'ls':
        c, _, _ = fs.find(sys.argv[3] if len(sys.argv) > 3 else '\\')
        for name, short, a, cl, sz in fs.entries(c):
            print(('<DIR> ' if a & 0x10 else '%10d ' % sz) + name)
    else:
        c, _, size = fs.find(sys.argv[3])
        data = fs.clusters(c)[:size]
        if cmd == 'cat':
            sys.stdout.write(data.decode('cp1250', 'replace'))
        else:
            open(sys.argv[4], 'wb').write(data)


if __name__ == '__main__':
    main()
