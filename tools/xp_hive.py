"""Minimal offline reader/normaliser for NT registry hives (regf, XP 1.3/1.5).

read_hive() returns every key and value, so two hives can be compared by
content. pin_hive() makes a hive edited through RegLoadAppKeyW reproducible:
the engine stamps the current time into every key it touches, the header's
reorganisation time and the loader's file name; content is not affected.
"""
import struct

HBIN=0x1000
# Fixed LastWriteTime for keys the build creates or edits: 2026-09-22 21:21:32 UTC.
PINNED_FILETIME=134029440920000000

def _cell(b,off):
    at=HBIN+off
    size=struct.unpack_from('<i',b,at)[0]
    if size>=0:raise ValueError('free cell referenced at 0x%x'%off)
    return b[at+4:at-size]

def _subkeys(b,off):
    data=_cell(b,off);sig=data[:2];n=struct.unpack_from('<H',data,2)[0]
    if sig in (b'lf',b'lh'):return [struct.unpack_from('<I',data,4+8*i)[0] for i in range(n)]
    if sig==b'li':return [struct.unpack_from('<I',data,4+4*i)[0] for i in range(n)]
    if sig==b'ri':return [k for i in range(n) for k in _subkeys(b,struct.unpack_from('<I',data,4+4*i)[0])]
    raise ValueError('unknown subkey list %r'%sig)

def _name(raw,compressed):return raw.decode('latin1') if compressed else raw.decode('utf-16-le')

def _value_data(b,vk):
    size,off,typ=struct.unpack_from('<IIi',vk,4)
    if size&0x80000000:return typ,vk[8:8+(size&0x7fffffff)]
    data=_cell(b,off)
    if data[:2]==b'db' and size>16344:
        n,lst=struct.unpack_from('<HI',data,2)
        segs=_cell(b,lst);out=b''
        for i in range(n):out+=_cell(b,struct.unpack_from('<I',segs,4*i)[0])[:16344]
        return typ,out[:size]
    return typ,data[:size]

def _nodes(b):
    """Yield (path, nk_file_offset, nk_data, values) for every key, depth first."""
    root=struct.unpack_from('<I',b,0x24)[0]
    stack=[(root,'')]
    while stack:
        off,parent=stack.pop()
        nk=_cell(b,off)
        if nk[:2]!=b'nk':raise ValueError('bad key cell at 0x%x'%off)
        flags=struct.unpack_from('<H',nk,2)[0]
        nsub,=struct.unpack_from('<I',nk,0x14);sublist,=struct.unpack_from('<I',nk,0x1c)
        nval,vlist=struct.unpack_from('<II',nk,0x24)
        nlen,=struct.unpack_from('<H',nk,0x48)
        name=_name(nk[0x4c:0x4c+nlen],flags&0x20)
        path=(parent+'\\'+name) if parent else name
        values={}
        if nval:
            vl=_cell(b,vlist)
            for i in range(nval):
                vk=_cell(b,struct.unpack_from('<I',vl,4*i)[0])
                if vk[:2]!=b'vk':raise ValueError('bad value cell')
                vlen,=struct.unpack_from('<H',vk,2);vflags,=struct.unpack_from('<H',vk,16)
                values[_name(vk[20:20+vlen],vflags&1).lower()]=_value_data(b,vk)
        yield path,HBIN+off+4,nk,values
        if nsub:
            for k in reversed(_subkeys(b,sublist)):stack.append((k,path))

def check_header(b):
    if b[:4]!=b'regf':raise ValueError('not a registry hive')
    return struct.unpack_from('<II',b,20)

def read_hive(data):
    """{lower-case key path relative to the root key: (last_write, {value: (type, bytes)})}"""
    check_header(data)
    out={}
    for path,_,nk,values in _nodes(data):
        rel=path.split('\\',1)[1].lower() if '\\' in path else ''
        out[rel]=(struct.unpack_from('<Q',nk,4)[0],values)
    return out

def checksum(b):
    x=0
    for i in range(0,0x1fc,4):x^=struct.unpack_from('<I',b,i)[0]
    return {0:1,0xffffffff:0xfffffffe}.get(x,x)

def pin_hive(edited,original):
    """Return `edited` with build-time metadata made reproducible:
    keys that are new or differ from `original` get PINNED_FILETIME, and the
    header's non-content fields (sequence numbers, timestamp, file name,
    reorganisation time, first-bin time, root parent link) are taken from
    `original`. Keys, values and cell layout are unchanged."""
    check_header(edited);check_header(original)
    b=bytearray(edited);before=read_hive(original)
    for path,at,nk,values in _nodes(bytes(b)):
        rel=path.split('\\',1)[1].lower() if '\\' in path else ''
        if before.get(rel)!=(struct.unpack_from('<Q',nk,4)[0],values):
            struct.pack_into('<Q',b,at+4,PINNED_FILETIME)
    # The root key's Parent is the link cell in the loading process's master
    # hive: a runtime value the kernel rewrites on every load.
    root=HBIN+struct.unpack_from('<I',b,0x24)[0]+4+0x10
    if struct.unpack_from('<I',original,0x24)!=struct.unpack_from('<I',b,0x24):raise ValueError('root key moved')
    for start,end in ((4,0x14),(0x30,0x70),(0xa8,0xb0),(HBIN+0x14,HBIN+0x1c),(root,root+4)):b[start:end]=original[start:end]
    struct.pack_into('<I',b,0x1fc,checksum(b))
    result=bytes(b)
    if read_hive_content(result)!=read_hive_content(edited):raise AssertionError('pinning changed hive content')
    return result

def read_hive_content(data):
    """Keys and values only (no timestamps): the equivalence relation."""
    return {k:v for k,(_,v) in read_hive(data).items()}
