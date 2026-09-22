"""Build a deterministic flat ISO9660 image from named files."""
import re
import struct

BLOCK = 2048

def both16(value):
    return struct.pack('<H', value) + struct.pack('>H', value)

def both32(value):
    return struct.pack('<I', value) + struct.pack('>I', value)

def record(name, lba, size, directory=False):
    result = bytearray(33 + len(name) + int(len(name) % 2 == 0))
    result[0] = len(result)
    result[2:10] = both32(lba)
    result[10:18] = both32(size)
    result[18:25] = bytes([93, 11, 1, 0, 0, 0, 0])
    result[25] = 2 if directory else 0
    result[28:32] = both16(1)
    result[32] = len(name)
    result[33:33 + len(name)] = name
    return result

def pack_records(records):
    result = bytearray()
    for entry in records:
        if len(result) % BLOCK + len(entry) > BLOCK:
            result.extend(bytes(BLOCK - len(result) % BLOCK))
        result.extend(entry)
    result.extend(bytes(-len(result) % BLOCK))
    return result

def build(files, label='WIN3_USOS'):
    names = sorted(files)
    if not names or len(names) > 1000 or not re.fullmatch('[A-Z0-9_]{1,32}', label):
        raise ValueError('Invalid flat ISO catalog')
    for name in names:
        if not re.fullmatch(r"[A-Z0-9_$~!#%&'()@^`{}-]{1,8}(\.[A-Z0-9_$~!#%&'()@^`{}-]{1,3})?", name):
            raise ValueError('ISO requires a DOS 8.3 filename: ' + repr(name))
    root_length = len(pack_records([record(b'\0', 20, 0, True), record(b'\1', 20, 0, True)] +
                                   [record((name + ';1').encode(), 0, len(files[name])) for name in names]))
    next_lba = 20 + root_length // BLOCK
    records = [record(b'\0', 20, root_length, True), record(b'\1', 20, root_length, True)]
    contents = bytearray()
    for name in names:
        payload = files[name]
        records.append(record((name + ';1').encode(), next_lba, len(payload)))
        contents.extend(payload)
        padding = -len(payload) % BLOCK
        contents.extend(bytes(padding))
        next_lba += (len(payload) + padding) // BLOCK
    image = bytearray(20 * BLOCK)
    pvd = bytearray(BLOCK)
    pvd[:7] = b'\x01CD001\x01'
    pvd[8:40] = b'USOS'.ljust(32, b' ')
    pvd[40:72] = label.encode().ljust(32, b' ')
    pvd[80:88] = both32(next_lba)
    pvd[120:124] = both16(1); pvd[124:128] = both16(1)
    pvd[128:132] = both16(BLOCK); pvd[132:140] = both32(10)
    struct.pack_into('<I', pvd, 140, 18); struct.pack_into('>I', pvd, 148, 19)
    pvd[156:190] = record(b'\0', 20, root_length, True)
    for start, length in [(190, 128), (318, 128), (446, 128), (574, 128), (702, 37), (739, 37), (776, 37)]:
        pvd[start:start + length] = b' ' * length
    pvd[574:702] = b'USOS WINDOWS 3.X MEDIA CONVERTER'.ljust(128, b' ')
    for offset in (813, 830, 847, 864):
        pvd[offset:offset + 17] = b'0000000000000000\0'
    pvd[881] = 1
    image[16 * BLOCK:17 * BLOCK] = pvd
    image[17 * BLOCK:17 * BLOCK + 7] = b'\xffCD001\x01'
    image[18 * BLOCK:18 * BLOCK + 10] = b'\x01\0' + struct.pack('<IH', 20, 1) + b'\0\0'
    image[19 * BLOCK:19 * BLOCK + 10] = b'\x01\0' + struct.pack('>IH', 20, 1) + b'\0\0'
    image.extend(pack_records(records)); image.extend(contents)
    assert len(image) == next_lba * BLOCK
    return bytes(image)
