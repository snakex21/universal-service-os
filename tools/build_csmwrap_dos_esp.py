"""CSMWrap ESP image for MS-DOS / Windows 3.x targets installed under CSMWrap.

docs/design/bios-via-csmwrap.md section 4.2. The BIOS Core cannot run
mkfs.fat/mtools like tools/xp_csmwrap_esp.sh, so the build writes the used
part of the 64 MiB FAT16 ESP here, from the CSMWrap tree release.go staged
(zig-out/usb/EFI/USOS/csmwrap): the Core copies this image to the target's
tail (the XP rule), sets the BPB hidden-sectors field to the partition start,
reads it back and then publishes MBR slot 2 as type 0xEF.

Contents (as on the XP CSMWrap ESP):
  \\EFI\\BOOT\\csmwrap.ini      first file, cluster 2 (the Core patches
                                "verbose = false" to "verbose = true " when
                                EFI\\USOS\\csmwrap-verbose.flag is on the stick)
  \\EFI\\BOOT\\BOOTX64.EFI      CSMWrap 3.1.2-usos3, pinned hash
  \\CSMWRAP\\...                licences, SOURCES.txt, source archive,
                                patches\\, licenses\\ (LGPL obligations)

  python tools/build_csmwrap_dos_esp.py [--csmwrap DIR] [--out FILE]

The image is deterministic (fixed timestamps, sorted files).
"""
from pathlib import Path
import argparse, hashlib, json, struct, sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'tools/vendor/csmwrap/3.1.2-usos3/manifest.json'
TOTAL_SECTORS = 131072            # 64 MiB, the XP ESP size
TAIL_SECTORS = 133120             # USOS_XP_ESP_TAIL_SECTORS
SPC = 4                           # 2 KiB clusters
RESERVED = 1
FATS = 2
ROOT_ENTRIES = 512
FAT_SECTORS = 128
ROOT_SECTORS = ROOT_ENTRIES * 32 // 512
DATA_START = RESERVED + FATS * FAT_SECTORS + ROOT_SECTORS   # 289
CLUSTERS = (TOTAL_SECTORS - DATA_START) // SPC
CLUSTER_BYTES = SPC * 512
INI = b'serial = false\r\nverbose = false\r\n'
INI_VERBOSE_OFFSET = DATA_START * 512 + INI.index(b'verbose = false')
# 2026-09-29 00:00:00 in FAT date/time.
FAT_DATE = ((2026 - 1980) << 9) | (9 << 5) | 29
FAT_TIME = 0
assert 4085 <= CLUSTERS < 65525 and (CLUSTERS + 2) * 2 <= FAT_SECTORS * 512


def short_name(name, used):
    base, _, ext = name.upper().rpartition('.') if '.' in name else (name.upper(), '', '')
    ok = lambda s: all(c.isalnum() or c in '_-$~!#%&()@^{}' for c in s)
    if name == name.upper() and len(base) <= 8 and len(ext) <= 3 and base and ok(base) and ok(ext):
        return (base.ljust(8) + ext.ljust(3)).encode(), False
    clean = ''.join(c for c in base if c.isalnum())[:6] or 'FILE'
    ext = ''.join(c for c in ext if c.isalnum())[:3]
    for n in range(1, 100):
        tail = f'~{n}'
        key = (clean[:8 - len(tail)] + tail).ljust(8) + ext.ljust(3)
        if key not in used:
            return key.encode(), True
    raise ValueError(name)


def lfn_entries(name, short):
    checksum = 0
    for b in short:
        checksum = (((checksum & 1) << 7) + (checksum >> 1) + b) & 0xFF
    units = list(name.encode('utf-16-le'))
    chars = [units[i] | units[i + 1] << 8 for i in range(0, len(units), 2)]
    parts = [chars[i:i + 13] for i in range(0, len(chars), 13)]
    out = []
    for seq, part in enumerate(parts, 1):
        part = part + ([0x0000] if len(part) < 13 else [])
        part = part + [0xFFFF] * (13 - len(part))
        order = seq | (0x40 if seq == len(parts) else 0)
        e = bytearray(32)
        e[0] = order
        struct.pack_into('<5H', e, 1, *part[0:5])
        e[11], e[12], e[13] = 0x0F, 0, checksum
        struct.pack_into('<6H', e, 14, *part[5:11])
        struct.pack_into('<2H', e, 28, *part[11:13])
        out.append(bytes(e))
    return list(reversed(out))


class Image:
    def __init__(self):
        self.fat = [0xFFF8, 0xFFFF]
        self.data = bytearray()
        self.root = []

    def alloc(self, payload):
        count = max(1, -(-len(payload) // CLUSTER_BYTES))
        first = len(self.fat)
        if first + count > CLUSTERS + 2:
            raise ValueError('CSMWrap ESP image full')
        for i in range(count):
            self.fat.append(first + i + 1 if i + 1 < count else 0xFFFF)
        self.data += payload + b'\0' * (count * CLUSTER_BYTES - len(payload))
        return first

    @staticmethod
    def entry(name, attr, cluster, size, used):
        key, needs_lfn = short_name(name, used)
        used.add(key.decode())
        e = bytearray(32)
        e[0:11] = key
        e[11] = attr
        struct.pack_into('<HHHHHHHI', e, 14, FAT_TIME, FAT_DATE, FAT_DATE, 0, FAT_TIME, FAT_DATE, cluster, size)
        return (lfn_entries(name, key) if needs_lfn else []) + [bytes(e)]

    def directory(self, parent_cluster, children):
        """children: list of (name, attr, cluster, size); returns the directory bytes."""
        used = {'.          ', '..         '}
        entries = []
        if parent_cluster is not None:
            entries.append(None)  # '.' placeholder, filled with own cluster
            dotdot = bytearray(32)
            dotdot[0:11] = b'..         '
            dotdot[11] = 0x10
            struct.pack_into('<HHHHHHHI', dotdot, 14, FAT_TIME, FAT_DATE, FAT_DATE, 0, FAT_TIME, FAT_DATE, parent_cluster, 0)
            entries.append(bytes(dotdot))
        for name, attr, cluster, size in children:
            entries += self.entry(name, attr, cluster, size, used)
        return entries


def build(csmwrap: Path, out: Path):
    manifest = json.loads(MANIFEST.read_text(encoding='utf-8'))
    efi = (csmwrap / 'csmwrapx64.efi').read_bytes()
    if hashlib.sha256(efi).hexdigest() != manifest['files']['csmwrapx64.efi']:
        raise SystemExit('staged csmwrapx64.efi does not match the pinned ' + manifest['version'] + ' hash')
    top = ['LICENSE-CSMWrap-LGPL-2.1.txt', 'COPYING-SeaBIOS-LGPLv3.txt', 'COPYING-SeaBIOS-GPLv3.txt', 'SOURCES.txt', 'csmwrap-3.1.2-src.tar.xz']
    patches = sorted(p.name for p in (csmwrap / 'patches').glob('*.patch'))
    licenses = sorted(p.name for p in (csmwrap / 'licenses').glob('*.txt'))
    if sorted(patches) != sorted(manifest['patches']) or not licenses:
        raise SystemExit('staged CSMWrap patches/licences are incomplete')
    img = Image()
    # csmwrap.ini first: cluster 2 = the first data sector (INI_VERBOSE_OFFSET).
    ini_cluster = img.alloc(INI)
    assert ini_cluster == 2
    efi_cluster = img.alloc(efi)

    def file_list(names, sub=''):
        result = []
        for name in names:
            data = (csmwrap / sub / name).read_bytes() if sub else (csmwrap / name).read_bytes()
            result.append((name, 0x20, img.alloc(data), len(data)))
        return result

    def dot_entry(cluster):
        dot = bytearray(32)
        dot[0:11] = b'.          '
        dot[11] = 0x10
        struct.pack_into('<HHHHHHHI', dot, 14, FAT_TIME, FAT_DATE, FAT_DATE, 0, FAT_TIME, FAT_DATE, cluster, 0)
        return bytes(dot)

    def fill(cluster, parent, children):
        """Writes a one-cluster subdirectory ('.', '..' = parent, 0 = root)."""
        entries = img.directory(parent, children)
        entries[0] = dot_entry(cluster)
        blob = b''.join(entries)
        if len(blob) > CLUSTER_BYTES:
            raise ValueError('directory larger than one cluster')
        off = (cluster - 2) * CLUSTER_BYTES
        img.data[off:off + len(blob)] = blob

    top_files = file_list(top)
    patch_files = file_list(patches, 'patches')
    license_files = file_list(licenses, 'licenses')
    # One cluster per directory; clusters first, contents once all are known.
    efi_dir, boot_dir, csm_dir, patches_dir, licenses_dir = (img.alloc(bytes(CLUSTER_BYTES)) for _ in range(5))
    fill(boot_dir, efi_dir, [('csmwrap.ini', 0x20, ini_cluster, len(INI)), ('BOOTX64.EFI', 0x20, efi_cluster, len(efi))])
    fill(patches_dir, csm_dir, patch_files)
    fill(licenses_dir, csm_dir, license_files)
    fill(efi_dir, 0, [('BOOT', 0x10, boot_dir, 0)])
    fill(csm_dir, 0, top_files + [('patches', 0x10, patches_dir, 0), ('licenses', 0x10, licenses_dir, 0)])
    root_entries = []
    label = bytearray(32)
    label[0:11] = b'CSMWRAP    '
    label[11] = 0x08
    struct.pack_into('<HH', label, 22, FAT_TIME, FAT_DATE)
    root_entries.append(bytes(label))
    used = set()
    root_entries += Image.entry('EFI', 0x10, efi_dir, 0, used)
    root_entries += Image.entry('CSMWRAP', 0x10, csm_dir, 0, used)
    root = b''.join(root_entries).ljust(ROOT_SECTORS * 512, b'\0')

    boot = bytearray(512)
    boot[0:3] = b'\xEB\x3C\x90'
    boot[3:11] = b'USOS1.1 '
    struct.pack_into('<HBHBHHBHHHII', boot, 11, 512, SPC, RESERVED, FATS, ROOT_ENTRIES, 0, 0xF8,
                     FAT_SECTORS, 63, 255, 0, TOTAL_SECTORS)
    boot[36] = 0x80
    boot[38] = 0x29
    struct.pack_into('<I', boot, 39, 0x55534F53)
    boot[43:54] = b'CSMWRAP    '
    boot[54:62] = b'FAT16   '
    # Not bootable in BIOS mode: int 18h.
    boot[62:66] = b'\xCD\x18\xEB\xFE'
    boot[510:512] = b'\x55\xAA'
    fat = b''.join(struct.pack('<H', v) for v in img.fat).ljust(FAT_SECTORS * 512, b'\0')
    image = bytes(boot) + fat + fat + root + bytes(img.data)
    assert len(image) % 512 == 0 and image[INI_VERBOSE_OFFSET:INI_VERBOSE_OFFSET + 15] == b'verbose = false'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(image)
    print(f'[PASS] CSMWrap DOS ESP image: {out} {len(image)} bytes ({len(image) // 512} of {TOTAL_SECTORS} sectors), '
          f'CSMWrap {manifest["version"]}, {len(patches)} patches, {len(licenses)} licence notices, '
          f'ini at byte {INI_VERBOSE_OFFSET}')
    return image


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--csmwrap', type=Path, default=ROOT / 'zig-out/usb/EFI/USOS/csmwrap')
    p.add_argument('--out', type=Path, default=ROOT / 'zig-out/dos-native/msdos/CSMESP.IMG')
    a = p.parse_args()
    build(a.csmwrap, a.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
