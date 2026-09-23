"""Read and pin the per-file metadata of Microsoft cabinets (MSCF).

makecab copies each input file's local modification time into its CFFILE
entry. Files the build writes itself would otherwise carry the build time,
so the same inputs never produced the same cabinet twice. The compressed
data blocks do not depend on it (and no checksum covers CFFILE entries).
"""
import struct

# 2026-09-22 21:21:32 as a FAT date/time: the build of the hardware-proven bundles.
PINNED_STAMP=(((2026-1980)<<9)|(9<<5)|22,(21<<11)|(21<<5)|(32//2))

def entries(data):
    """[(name, size, folder_offset, folder, date, time, attribs, entry_offset)]"""
    if data[:4]!=b'MSCF':raise ValueError('not a cabinet')
    files_at,=struct.unpack_from('<I',data,16)
    count,=struct.unpack_from('<H',data,28)
    out=[];at=files_at
    for _ in range(count):
        size,offset,folder,date,time,attribs=struct.unpack_from('<IIHHHH',data,at)
        end=data.index(b'\0',at+16)
        out.append((data[at+16:end].decode('latin1'),size,offset,folder,date,time,attribs,at))
        at=end+1
    return out

def stamps(data):
    """{lower-case name: (date, time)} of a source cabinet."""
    return {e[0].lower():(e[4],e[5]) for e in entries(data)}

def pin(path,source_stamps=None,default=PINNED_STAMP):
    """Rewrite every entry's date/time: a file taken unchanged from a source
    cabinet keeps that cabinet's stamp, anything else gets `default`."""
    data=bytearray(path.read_bytes())
    for name,*_,at in entries(data):
        struct.pack_into('<HH',data,at+10,*(source_stamps or {}).get(name.lower(),default))
    path.write_bytes(bytes(data))
