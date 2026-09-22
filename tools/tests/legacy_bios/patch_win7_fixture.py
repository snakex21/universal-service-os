import struct, sys, zlib
from pathlib import Path
root=Path(__file__).resolve().parents[3]
p=Path(sys.argv[1]).resolve()
assert p.is_relative_to(root/'zig-out')
with p.open('r+b') as f:
    f.seek(512); h=bytearray(f.read(512)); assert h[:8]==b'EFI PART'
    size,count=struct.unpack_from('<II',h,84)[0],struct.unpack_from('<I',h,80)[0]
    assert size==128 and count==128
    start=struct.unpack_from('<Q',h,72)[0]*512
    f.seek(start); entries=bytearray(f.read(size*count))
    for i,name in enumerate(('USOS_ESP','USOS_DATA','USOS_WORK')):
        assert entries[i*128:i*128+16]!=bytes(16)
        entries[i*128+56:i*128+128]=name.encode('utf-16le').ljust(72,b'\0')
    for pos in (512,struct.unpack_from('<Q',h,32)[0]*512):
        f.seek(pos); header=bytearray(f.read(512)); assert header[:8]==b'EFI PART'
        f.seek(struct.unpack_from('<Q',header,72)[0]*512); f.write(entries)
        struct.pack_into('<I',header,88,zlib.crc32(entries))
        struct.pack_into('<I',header,16,0)
        struct.pack_into('<I',header,16,zlib.crc32(header[:92]))
        f.seek(pos); f.write(header)
    stage=(root/'zig-out/legacy-bios/stage1.bin').read_bytes()
    core=(root/'zig-out/legacy-bios/core-slot.bin').read_bytes()
    assert len(stage)==440 and len(core)==262144
    f.seek(0); f.write(stage)
    f.seek(64*512); f.write(core)
print('PASS: three GPT names and production BIOS boot code installed in fixture')
