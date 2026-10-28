#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Own small standards-shaped optical media. No vendor payload or library."""
import struct

BLOCK = 2048
PAYLOAD = b'own optical Unicode and offset fixture\n'


def put(b, at, fmt, *values):
    struct.pack_into(fmt, b, at, *values)


def both(b, at, fmt, value):
    put(b, at, '<' + fmt, value)
    put(b, at + struct.calcsize(fmt), '>' + fmt, value)


def iso_record(lba, size, directory, name, more=False):
    b = bytearray(33 + len(name) + (not len(name) % 2))
    b[0] = len(b)
    both(b, 2, 'I', lba)
    both(b, 10, 'I', size)
    b[18:25] = bytes((126, 10, 25, 12, 0, 0, 0))
    b[25] = (2 if directory else 0) | (128 if more else 0)
    both(b, 28, 'H', 1)
    b[32] = len(name)
    b[33:33 + len(name)] = name
    return b


def iso9660(joliet=False, multi=False):
    image = bytearray(320 * BLOCK)
    def descriptor(lba, kind, root, wide):
        b = bytearray(BLOCK)
        b[0:7] = bytes([kind]) + b'CD001\x01'
        b[8:40] = b'OWN'.ljust(32)
        b[40:72] = b'OPTICAL'.ljust(32)
        both(b, 80, 'I', 320)
        both(b, 120, 'H', 1); both(b, 124, 'H', 1); both(b, 128, 'H', BLOCK)
        b[156:190] = iso_record(root, BLOCK, True, b'\x00')
        if wide: b[88:91] = b'%/E'
        image[lba*BLOCK:(lba+1)*BLOCK] = b
    descriptor(16, 1, 24, False)
    if joliet: descriptor(17, 2, 26, True)
    end = 18 if joliet else 17
    image[end*BLOCK:end*BLOCK+7] = b'\xffCD001\x01'
    for root, child, wide in [(24, 25, False)] + ([(26, 27, True)] if joliet else []):
        def name(value): return value.encode('utf-16-be') if wide else value.encode('ascii')
        root_records = iso_record(root, BLOCK, True, b'\x00') + iso_record(root, BLOCK, True, b'\x01')
        root_records += iso_record(child, BLOCK, True, name('Sources' if wide else 'SOURCES'))
        image[root*BLOCK:root*BLOCK+len(root_records)] = root_records
        records = iso_record(child, BLOCK, True, b'\x00') + iso_record(root, BLOCK, True, b'\x01')
        file_name = name('Long Żółć.txt;1' if wide else 'LONG.TXT;1')
        if multi:
            records += iso_record(28, BLOCK, False, file_name, True)
            records += iso_record(30, len(PAYLOAD), False, file_name)
        else: records += iso_record(28, len(PAYLOAD), False, file_name)
        records += iso_record(29, 0, False, name('empty.dat;1' if wide else 'EMPTY.DAT;1'))
        image[child*BLOCK:child*BLOCK+len(records)] = records
    image[28*BLOCK:28*BLOCK+len(PAYLOAD)] = PAYLOAD
    image[30*BLOCK:30*BLOCK+len(PAYLOAD)] = PAYLOAD
    return bytes(image)


def crc16(b):
    crc = 0
    for byte in b:
        crc ^= byte << 8
        for _ in range(8): crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 65535
    return crc


def tag(b, ident, lba, version, used=None):
    used = len(b) if used is None else used
    put(b, 0, '<HHBBHHHI', ident, version, 0, 0, 1, crc16(b[16:used]), used-16, lba)
    b[4] = sum(b[:4] + b[5:16]) & 255
    return b


def long_ad(length, lba, ref):
    return struct.pack('<IIH6s', length, lba, ref, bytes(6))


def udf(revision=0x102, metadata=False, payload=PAYLOAD, file_name='Long Żółć.txt',
        extended=False, embedded=False, continuation=False, allocation_loop=False,
        directory_loop=False):
    if metadata and revision < 0x250: raise ValueError('Metadata partitions start at2.50')
    if embedded and (continuation or allocation_loop): raise ValueError('Embedded files have no allocation chain')
    if len(payload) > (BLOCK-216 if embedded else 2*BLOCK): raise ValueError('Small fixture payload only')
    image = bytearray(320 * BLOCK)
    version = 2 if revision < 0x200 else 3
    partition = 32
    ref = 1 if metadata else 0
    # Logical metadata positions stay the same in physical/metadata layouts.
    def block(lba): return partition + (64 if metadata else 0) + lba
    def store(lba, b): image[lba*BLOCK:lba*BLOCK+len(b)] = b
    for lba, label in [(16,b'BEA01'),(17,b'NSR02' if version==2 else b'NSR03'),(18,b'TEA01')]:
        b=bytearray(BLOCK); b[1:6]=label; b[6]=1; store(lba,b)
    anchor=bytearray(BLOCK); put(anchor,16,'<II',3*BLOCK,257); put(anchor,24,'<II',3*BLOCK,257)
    store(256,tag(anchor,2,256,version,512))
    end_anchor=bytearray(anchor)
    store(319,tag(end_anchor,2,319,version,512))
    pd=bytearray(BLOCK); put(pd,16,'<IHH',1,1,0); pd[25:30]=b'+NSR0'; pd[30]=ord('2') if version==2 else ord('3')
    put(pd,184,'<III',1,partition,192); store(257,tag(pd,5,257,version,512))
    lvd=bytearray(BLOCK); put(lvd,16,'<I',2); put(lvd,212,'<I',BLOCK)
    lvd[217:217+len(b'*OSTA UDF Compliant')]=b'*OSTA UDF Compliant'; put(lvd,240,'<H',revision)
    lvd[248:264]=long_ad(BLOCK,0,ref)
    maps=bytearray(struct.pack('<BBHH',1,6,1,0))
    if metadata:
        m=bytearray(64); m[0:2]=bytes([2,64]); m[5:28]=b'*UDF Metadata Partition'
        put(m,28,'<H',revision); put(m,36,'<HHIII',1,0,40,0xffffffff,0xffffffff)
        put(m,52,'<IH',32,1); maps+=m
    put(lvd,264,'<II',len(maps),2 if metadata else 1); lvd[440:440+len(maps)]=maps
    store(258,tag(lvd,6,258,version,440+len(maps)))
    store(259,tag(bytearray(BLOCK),8,259,version,512))
    fsd=bytearray(BLOCK); fsd[49:49+len(b'OSTA Compressed Unicode')]=b'OSTA Compressed Unicode'
    fsd[400:416]=long_ad(BLOCK,1,ref); store(block(0),tag(fsd,256,0,version,512))
    def fid(name,lba,directory,location,parent=False):
        encoded=b'' if parent else b'\x10'+name.encode('utf-16-be')
        b=bytearray((38+len(encoded)+3)&~3); put(b,16,'<HBB',1,(8 if parent else 0)|(2 if directory else 0),len(encoded))
        b[20:36]=long_ad(BLOCK,lba,ref); b[38:38+len(encoded)]=encoded
        return tag(b,257,location,version)
    root=fid('',1,True,2,True)+fid('Sources',1 if directory_loop else 3,True,2)
    directory=fid('',1,True,4,True)+fid(file_name,5,False,4)+fid('empty.dat',6,False,4)
    store(block(2),root); store(block(4),directory)
    def fe(lba,kind,data_lba,size,data_ref=ref):
        b=bytearray(BLOCK); put(b,20,'<H',4); b[27]=kind; put(b,48,'<H',1); put(b,56,'<Q',size)
        use_extended=extended and kind==5
        base=216 if use_extended else 176
        if use_extended:
            put(b,64,'<Q',size); put(b,72,'<Q',(size+BLOCK-1)//BLOCK); put(b,200,'<Q',lba+100)
        else:
            put(b,64,'<Q',(size+BLOCK-1)//BLOCK); put(b,160,'<Q',lba+100)
        if embedded and kind==5:
            put(b,34,'<H',3); ad=payload if size else b''
        elif kind==5 and size and (continuation or allocation_loop):
            put(b,34,'<H',1); ad=long_ad(0xc0000000|BLOCK,12,0)
        elif kind==4 or kind==250:
            put(b,34,'<H',0); ad=struct.pack('<II',size,data_lba)
        else:
            put(b,34,'<H',1); ad=long_ad(size,data_lba,data_ref)
        put(b,base-4,'<I',len(ad)); b[base:base+len(ad)]=ad
        return tag(b,266 if use_extended else 261,lba,version,base+len(ad))
    store(block(1),fe(1,4,2,len(root)))
    store(block(3),fe(3,4,4,len(directory)))
    store(block(5),fe(5,5,10,len(payload),0))
    store(block(6),fe(6,5,11,0,0))
    if continuation or allocation_loop:
        aed=bytearray(BLOCK)
        ads=(long_ad(0xc0000000|BLOCK,12,0) if allocation_loop else
             long_ad(min(BLOCK,len(payload)),10,0))
        if not allocation_loop and len(payload)>BLOCK:
            ads+=long_ad(len(payload)-BLOCK,11,0)
        put(aed,20,'<I',len(ads)); aed[24:24+len(ads)]=ads
        store(partition+12,tag(aed,258,12,version,24+len(ads)))
        store(partition+10,payload[:BLOCK]); store(partition+11,payload[BLOCK:])
    elif not embedded:
        store(partition+10,payload)
    if metadata:
        store(partition+40,fe(40,250,64,64*BLOCK,0))
    return bytes(image)


def udf_patch(image, physical_lba, offset, replacement, repair=True):
    """Change one descriptor; repair CRC/tag so structural tests reach the parser."""
    b=bytearray(image)
    block=bytearray(b[physical_lba*BLOCK:(physical_lba+1)*BLOCK])
    if len(block)!=BLOCK or offset<16 or offset+len(replacement)>BLOCK:
        raise ValueError('Descriptor patch outside fixture')
    block[offset:offset+len(replacement)]=replacement
    if repair:
        ident,version=struct.unpack_from('<HH',block)
        lba=struct.unpack_from('<I',block,12)[0]
        used=16+struct.unpack_from('<H',block,10)[0]
        tag(block,ident,lba,version,used)
    b[physical_lba*BLOCK:(physical_lba+1)*BLOCK]=block
    return bytes(b)


def iso9660_sparse_plan(size=4*1024**3+8193):
    """Sparse >4-GiB multi-extent plan; this function creates no disk image.

    A caller must reserve the logical size, create an owned regular sparse file,
    set its length and write these bounded chunks. Unwritten file bytes are zero.
    """
    first=0xfffff800
    if isinstance(size,bool) or not isinstance(size,int) or size<=4*1024**3 or size-first>0xffffffff:
        raise ValueError('Expected a two-extent file above4GiB')
    image=bytearray(iso9660())
    begin=32*BLOCK
    second=begin+first+2*BLOCK
    length=((second+size-first+BLOCK-1)//BLOCK)*BLOCK
    both(image,16*BLOCK+80,'I',length//BLOCK)
    root=iso_record(24,BLOCK,True,b'\x00')+iso_record(24,BLOCK,True,b'\x01')
    root+=iso_record(25,BLOCK,True,b'SOURCES')
    image[24*BLOCK:25*BLOCK]=root.ljust(BLOCK,b'\0')
    directory=iso_record(25,BLOCK,True,b'\x00')+iso_record(24,BLOCK,True,b'\x01')
    directory+=iso_record(begin//BLOCK,first,False,b'LARGE.BIN;1',True)
    directory+=iso_record(second//BLOCK,size-first,False,b'LARGE.BIN;1')
    image[25*BLOCK:26*BLOCK]=directory.ljust(BLOCK,b'\0')
    chunks=[(0,bytes(image)),(begin,b'FIRST-EXTENT-BEGIN'),
            (begin+first-16,b'FIRST-EXTENT-END'),
            (second,b'SECOND-EXTENT-BEGIN'),(second+size-first-16,b'SECOND-EXTENTEND')]
    return dict(logical_bytes=length,file_bytes=size,split=first,
                path='SOURCES/LARGE.BIN',chunks=chunks)


def sparse_sample(plan, offset, length=32):
    """Independent logical file bytes for random reads across the extent gap."""
    if offset<0 or length<0 or offset>plan['file_bytes'] or length>plan['file_bytes']-offset:
        raise ValueError('Sample outside fixture file')
    result=bytearray(length)
    first=plan['split']; begin=32*BLOCK; second=begin+first+2*BLOCK
    for physical,data in plan['chunks'][1:]:
        logical=physical-begin if physical<second else first+physical-second
        lo=max(logical,offset); hi=min(logical+len(data),offset+length)
        if lo<hi:result[lo-offset:hi-offset]=data[lo-logical:hi-logical]
    return bytes(result)
