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

NAME83 = r"[A-Z0-9_$~!#%&'()@^`{}-]{1,8}(\.[A-Z0-9_$~!#%&'()@^`{}-]{1,3})?"
DIRNAME = r"[A-Z0-9_]{1,8}"


def path_table(entries, big):
    pack = (lambda v: struct.pack('>I', v)) if big else (lambda v: struct.pack('<I', v))
    pack16 = (lambda v: struct.pack('>H', v)) if big else (lambda v: struct.pack('<H', v))
    result = bytearray()
    for name, lba, parent in entries:
        result += bytes([len(name), 0]) + pack(lba) + pack16(parent) + name + bytes(len(name) % 2)
    return result


def build(files, label='WIN3_USOS'):
    """files: {'NAME.EXT': bytes} in the root, or {'DIR/NAME.EXT': bytes} one
    directory level deep (Windows 1.0x keeps its PIF files in the PIF directory of its first disk)."""
    names = sorted(files)
    if not names or len(names) > 1000 or not re.fullmatch('[A-Z0-9_]{1,32}', label):
        raise ValueError('Invalid flat ISO catalog')
    tree = {'': []}
    for name in names:
        parts = name.split('/')
        if len(parts) > 2 or not re.fullmatch(NAME83, parts[-1]) or (len(parts) == 2 and not re.fullmatch(DIRNAME, parts[0])):
            raise ValueError('ISO requires a DOS 8.3 filename: ' + repr(name))
        directory = parts[0] if len(parts) == 2 else ''
        if directory and directory in files:
            raise ValueError('A file and a directory share a name: ' + directory)
        tree.setdefault(directory, []).append(name)
    subdirs = sorted(d for d in tree if d)

    def dir_length(directory):
        entries = [record(b'\0', 0, 0, True), record(b'\1', 0, 0, True)]
        if not directory:
            entries += [record(d.encode(), 0, 0, True) for d in subdirs]
        entries += [record((n.split('/')[-1] + ';1').encode(), 0, len(files[n])) for n in tree[directory]]
        return len(pack_records(entries))

    lengths = {d: dir_length(d) for d in [''] + subdirs}
    tables = path_table([(b'\0', 0, 1)] + [(d.encode(), 0, 1) for d in subdirs], False)
    table_blocks = (len(tables) + BLOCK - 1) // BLOCK
    lba_of = {}
    next_lba = 18 + 2 * table_blocks
    for d in [''] + subdirs:
        lba_of[d] = next_lba
        next_lba += lengths[d] // BLOCK
    file_lba = {}
    contents = bytearray()
    for directory in [''] + subdirs:
        for name in tree[directory]:
            payload = files[name]
            file_lba[name] = next_lba
            contents.extend(payload)
            padding = -len(payload) % BLOCK
            contents.extend(bytes(padding))
            next_lba += (len(payload) + padding) // BLOCK
    directories = bytearray()
    for directory in [''] + subdirs:
        own, parent = lba_of[directory], lba_of['']
        records = [record(b'\0', own, lengths[directory], True), record(b'\1', parent, lengths[''], True)]
        if not directory:
            records += [record(d.encode(), lba_of[d], lengths[d], True) for d in subdirs]
        records += [record((n.split('/')[-1] + ';1').encode(), file_lba[n], len(files[n])) for n in tree[directory]]
        packed = pack_records(records)
        assert len(packed) == lengths[directory]
        directories.extend(packed)
    entries = [(b'\0', lba_of[''], 1)] + [(d.encode(), lba_of[d], 1) for d in subdirs]
    little, big = path_table(entries, False), path_table(entries, True)
    root_length = lengths['']
    image = bytearray(18 * BLOCK)
    pvd = bytearray(BLOCK)
    pvd[:7] = b'\x01CD001\x01'
    pvd[8:40] = b'USOS'.ljust(32, b' ')
    pvd[40:72] = label.encode().ljust(32, b' ')
    pvd[80:88] = both32(next_lba)
    pvd[120:124] = both16(1); pvd[124:128] = both16(1)
    pvd[128:132] = both16(BLOCK); pvd[132:140] = both32(len(little))
    struct.pack_into('<I', pvd, 140, 18); struct.pack_into('>I', pvd, 148, 18 + table_blocks)
    pvd[156:190] = record(b'\0', lba_of[''], root_length, True)
    for start, length in [(190, 128), (318, 128), (446, 128), (574, 128), (702, 37), (739, 37), (776, 37)]:
        pvd[start:start + length] = b' ' * length
    pvd[574:702] = b'USOS WINDOWS 3.X MEDIA CONVERTER'.ljust(128, b' ')
    for offset in (813, 830, 847, 864):
        pvd[offset:offset + 17] = b'0000000000000000\0'
    pvd[881] = 1
    image[16 * BLOCK:17 * BLOCK] = pvd
    image[17 * BLOCK:17 * BLOCK + 7] = b'\xffCD001\x01'
    image.extend(little + bytes(table_blocks * BLOCK - len(little)))
    image.extend(big + bytes(table_blocks * BLOCK - len(big)))
    image.extend(directories); image.extend(contents)
    assert len(image) == next_lba * BLOCK
    return bytes(image)
