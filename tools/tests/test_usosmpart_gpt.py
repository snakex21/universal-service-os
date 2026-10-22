"""usosmpart synthetic MBR view of GPT sticks (Windows 2000 / XP x86), host only.

tools/nt/usosmpart/src/mpgpt.h (the code the driver builds in) is compiled
with the host C compiler together with tools/tests/usosmpart_gpt_harness.c
and run on synthetic GPT images written here: the USOS 3-partition stick
(ESP FAT32 + DATA NTFS + WORK NTFS), GPT attributes (hidden / no drive
letter / read-only), MSR and foreign types, > 2 TiB fallback, CRC damage,
hybrid MBR, more than four partitions, 4 KiB sectors, the write rule and the
SCSI CDB decoder. No Microsoft files, no disk access.
"""
from pathlib import Path
import os, shutil, struct, subprocess, tempfile, unittest, uuid, zlib

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / 'tools/nt/usosmpart/src/mpgpt.h'
HARNESS = ROOT / 'tools/tests/usosmpart_gpt_harness.c'

ESP = uuid.UUID('C12A7328-F81F-11D2-BA4B-00A0C93EC93B')
BASIC = uuid.UUID('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7')
MSR = uuid.UUID('E3C9E316-0B5C-4DB8-817D-F92DF00215AE')
LINUX = uuid.UUID('0FC63DAF-8483-4772-8E79-3D69D8477DE4')
DISK_GUID = uuid.UUID('11223344-5566-7788-99AA-BBCCDDEEFF00')


def compiler():
    for cc in (os.environ.get('CC'), 'gcc', 'cc', 'clang'):
        if cc and shutil.which(cc):
            return [cc]
    if shutil.which('zig'):
        return ['zig', 'cc']
    return None


def boot_sector(fs, bs):
    b = bytearray(bs)
    if fs == 'ntfs':
        b[3:11] = b'NTFS    '
    elif fs == 'exfat':
        b[3:11] = b'EXFAT   '
    elif fs == 'fat32':
        b[3:11] = b'MSWIN4.1'
        b[82:90] = b'FAT32   '
    elif fs == 'fat16':
        b[54:62] = b'FAT16   '
    elif fs == 'ext4':
        return bytes(b)                 # no 0x55AA
    b[510:512] = b'\x55\xaa'
    return bytes(b)


def make_image(path, total, parts, bs=512, mbr_sig=0, hybrid=False, entries=128,
               corrupt_entries=False, first_usable=None, last_usable_hi=0):
    """parts: (type uuid, first, last, attrs, fs or None, first_hi)."""
    esize = 128
    eblocks = (entries * esize + bs - 1) // bs
    first_usable = first_usable if first_usable is not None else 2 + eblocks
    last_usable = total - 2 - eblocks
    with open(path, 'wb') as f:
        f.truncate(total * bs)

        def put(lba, data):
            f.seek(lba * bs)
            f.write(data)
        mbr = bytearray(bs)
        struct.pack_into('<I', mbr, 440, mbr_sig)
        mbr[446 + 4] = 0xEE
        struct.pack_into('<II', mbr, 446 + 8, 1, min(total - 1, 0xFFFFFFFF))
        if hybrid:
            mbr[462 + 4] = 0x07
            struct.pack_into('<II', mbr, 462 + 8, parts[0][1], parts[0][2] - parts[0][1] + 1)
        mbr[510:512] = b'\x55\xaa'
        put(0, bytes(mbr))
        arr = bytearray(entries * esize)
        for i, p in enumerate(parts):
            ptype, first, last, attrs, fs = p[:5]
            hi = p[5] if len(p) > 5 else 0
            o = i * esize
            arr[o:o + 16] = ptype.bytes_le
            arr[o + 16:o + 32] = uuid.uuid4().bytes_le
            struct.pack_into('<QQQ', arr, o + 32, first | (hi << 32), last | (hi << 32), attrs)
            if fs and not hi:
                put(first, boot_sector(fs, bs))
        ecrc = zlib.crc32(bytes(arr))
        if corrupt_entries:
            arr[100] ^= 1
        put(2, bytes(arr))
        hdr = bytearray(bs)
        struct.pack_into('<8sIIIIQQQQ16sQIII', hdr, 0, b'EFI PART', 0x10000, 92, 0, 0, 1, total - 1,
                         first_usable, last_usable | (last_usable_hi << 32), DISK_GUID.bytes_le, 2,
                         entries, esize, ecrc)
        struct.pack_into('<I', hdr, 16, zlib.crc32(bytes(hdr[:92])))
        put(1, bytes(hdr))


@unittest.skipIf(compiler() is None, 'no host C compiler (gcc / cc / clang / zig)')
class SyntheticMbr(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.exe = Path(cls.tmp.name) / ('harness.exe' if os.name == 'nt' else 'harness')
        r = subprocess.run(compiler() + ['-std=c99', '-O1', '-Wall', '-Wextra', '-Werror', '-o', str(cls.exe),
                                         str(HARNESS)], capture_output=True, text=True)
        if r.returncode:
            raise AssertionError('harness build failed:\n' + r.stdout + r.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_img(self, total, parts, *queries, bs=512, last=None, **kw):
        img = Path(self.tmp.name) / 'img.bin'
        make_image(img, total, parts, bs=bs, **kw)
        r = subprocess.run([str(self.exe), str(img), str(last if last is not None else total - 1), str(bs)]
                           + [str(q) for q in queries], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        rc = int(lines[0].split()[0].split('=')[1])
        got = [tuple(int(x, 16) if i == 0 else int(x) for i, x in enumerate(l.split()[1:]))
               for l in lines if l.startswith('part ')]
        tail = next((bytes.fromhex(l.split()[1]) for l in lines if l.startswith('tail ')), None)
        rest = [l for l in lines[1:] if l.startswith(('w ', 'c '))]
        return rc, got, tail, rest

    USOS = 40960  # 20 MiB stand-in of the USOS stick layout

    def usos_parts(self, data_attrs=0, work_attrs=0):
        return [(ESP, 2048, 4095, 0, 'fat32'), (BASIC, 4096, 20479, data_attrs, 'ntfs'),
                (BASIC, 20480, self.USOS - 34, work_attrs, 'ntfs')]

    def test_usos_stick(self):
        last = self.USOS - 34
        rc, parts, tail, w = self.run_img(
            self.USOS, self.usos_parts(),
            'w', 0, 1, 'w', 1, 1, 'w', 33, 1, 'w', 2047, 2, 'w', 2048, 8, 'w', 4096, 128, 'w', 20479, 1,
            'w', 20479, 2, 'w', 20480, 1, 'w', last, 1, 'w', last, 2, 'w', self.USOS - 33, 1,
            'w', self.USOS - 1, 1, 'w', 4096, 0, 'w', 0x100001000, 1)
        self.assertEqual(rc, 0)
        self.assertEqual(parts, [(0xEF, 2048, 2048, 0), (0x07, 4096, 16384, 1), (0x07, 20480, last - 20479, 1)])
        self.assertEqual(len(tail), 72)
        g = DISK_GUID.bytes_le
        sig = 0
        for i in range(4):
            sig ^= struct.unpack_from('<I', g, 4 * i)[0]
        self.assertEqual(struct.unpack_from('<I', tail, 0)[0], sig)    # MBR sig 0 -> from the disk GUID
        self.assertEqual(tail[4:6], b'\0\0')
        self.assertEqual(tail[70:72], b'\x55\xaa')
        for i, (typ, start, count, _) in enumerate(parts + [(0, 0, 0, 0)]):
            e = tail[6 + 16 * i:22 + 16 * i]
            self.assertEqual(e[0], 0)                       # not active
            self.assertEqual(e[4], typ)
            self.assertEqual(struct.unpack_from('<II', e, 8), (start, count))
            if typ:
                self.assertEqual(e[1:4] + e[5:8], b'\xfe\xff\xff' * 2)
            else:
                self.assertEqual(e, bytes(16))
        allowed = [int(l.split()[3]) for l in w]
        # LBA 0, GPT header, entries, the gap before the ESP, the ESP: no;
        # inside DATA / WORK: yes; across DATA / WORK, the backup GPT, n = 0, > 32 bit: no
        self.assertEqual(allowed, [0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0])

    def test_mbr_signature_kept(self):
        rc, _, tail, _ = self.run_img(self.USOS, self.usos_parts(), mbr_sig=0xA1B2C3D4)
        self.assertEqual(rc, 0)
        self.assertEqual(struct.unpack_from('<I', tail, 0)[0], 0xA1B2C3D4)

    def test_attributes(self):
        for attrs in (1 << 63, 1 << 62, 1 << 60):
            rc, parts, _, w = self.run_img(self.USOS, self.usos_parts(data_attrs=attrs), 'w', 4096, 8)
            self.assertEqual(rc, 0, hex(attrs))
            self.assertEqual([p[1] for p in parts], [2048, 20480], hex(attrs))
            self.assertEqual(w, ['w 4096 8 0'])             # hidden DATA is not writable
        # bit 0 (platform required) alone does not hide a data partition
        rc, parts, _, _ = self.run_img(self.USOS, self.usos_parts(data_attrs=1))
        self.assertEqual(len(parts), 3)
        # both data partitions hidden: nothing to letter -> fallback (hide)
        rc, _, _, _ = self.run_img(self.USOS, self.usos_parts(1 << 63, 1 << 63))
        self.assertEqual(rc, 4)

    def test_types_and_file_systems(self):
        parts = [(MSR, 34, 2047, 0, None), (ESP, 2048, 4095, 0, 'fat32'), (BASIC, 4096, 8191, 0, 'fat32'),
                 (BASIC, 8192, 12287, 0, 'exfat'), (LINUX, 12288, 16383, 0, 'ntfs'),
                 (BASIC, 16384, 20479, 0, 'ext4'), (BASIC, 20480, 24575, 0, 'fat16')]
        rc, got, _, _ = self.run_img(self.USOS, parts)
        self.assertEqual(rc, 0)
        self.assertEqual(got, [(0xEF, 2048, 2048, 0), (0x0C, 4096, 4096, 1), (0x07, 8192, 4096, 1),
                               (0x0E, 20480, 4096, 1)])

    def test_more_than_four(self):
        parts = [(BASIC, 20480, 24575, 0, 'ntfs'), (ESP, 2048, 4095, 0, 'fat32'), (BASIC, 16384, 20479, 0, 'ntfs'),
                 (BASIC, 12288, 16383, 0, 'ntfs'), (BASIC, 8192, 12287, 0, 'ntfs'), (BASIC, 4096, 8191, 0, 'ntfs')]
        rc, got, _, _ = self.run_img(self.USOS, parts)
        self.assertEqual(rc, 0)
        # ESP dropped first, then the last GPT entry (LBA 4096); sorted by start
        self.assertEqual([p[1] for p in got], [8192, 12288, 16384, 20480])
        self.assertTrue(all(p[3] for p in got))

    def test_over_2tib_fallback(self):
        rc, _, _, _ = self.run_img(self.USOS, self.usos_parts(), last=0xFFFFFFFF)
        self.assertEqual(rc, 3)                              # READ CAPACITY(10) saturated
        rc, _, _, _ = self.run_img(self.USOS, self.usos_parts() + [(BASIC, 100, 200, 0, None, 1)])
        self.assertEqual(rc, 3)                              # an entry beyond 2^32 sectors
        rc, _, _, _ = self.run_img(self.USOS, self.usos_parts(), last_usable_hi=1)
        self.assertEqual(rc, 3)                              # header: last usable LBA beyond 2^32

    def test_bad_tables(self):
        rc, _, _, _ = self.run_img(self.USOS, self.usos_parts(), corrupt_entries=True)
        self.assertEqual(rc, 2)                              # entry array CRC
        rc, _, _, _ = self.run_img(self.USOS, self.usos_parts(), hybrid=True)
        self.assertEqual(rc, 1)                              # hybrid MBR: not this path
        rc, _, _, _ = self.run_img(self.USOS, [(ESP, 2048, 4095, 0, 'fat32'), (BASIC, 4000, 8191, 0, 'ntfs')])
        self.assertEqual(rc, 2)                              # overlapping entries
        rc, _, _, _ = self.run_img(self.USOS, [(BASIC, 20, 4095, 0, 'ntfs')])
        self.assertEqual(rc, 2)                              # entry inside the GPT area
        rc, _, _, _ = self.run_img(self.USOS, self.usos_parts(), last=20000)
        self.assertEqual(rc, 2)                              # GPT larger than the medium
        img = Path(self.tmp.name) / 'img.bin'
        make_image(img, self.USOS, self.usos_parts())
        with open(img, 'r+b') as f:
            f.seek(512 + 40)
            f.write(b'\x01')                                 # header byte changed, CRC not updated
        r = subprocess.run([str(self.exe), str(img), str(self.USOS - 1), '512'], capture_output=True, text=True)
        self.assertTrue(r.stdout.startswith('rc=2 '), r.stdout)

    def test_4k_sectors(self):
        total = 8192                                         # 32 MiB
        parts = [(ESP, 256, 511, 0, 'fat32'), (BASIC, 512, 4095, 0, 'ntfs'), (BASIC, 4096, total - 6, 0, 'ntfs')]
        rc, got, tail, _ = self.run_img(total, parts, bs=4096)
        self.assertEqual(rc, 0)
        self.assertEqual([p[:3] for p in got], [(0xEF, 256, 256), (0x07, 512, 3584), (0x07, 4096, total - 6 - 4095)])

    def test_cdb_decoder(self):
        _, _, _, c = self.run_img(self.USOS, self.usos_parts(),
                                  'c', '28000000000000000100',            # READ(10) LBA 0
                                  'c', '080000000000',                    # READ(6) LBA 0, 0 -> 256
                                  'c', '0a1fffff1000',                    # WRITE(6) LBA 0x1FFFFF, 16
                                  'c', '2a0000001000000008000000'[:20],   # WRITE(10) LBA 0x1000, 8
                                  'c', 'aa00000010000000002000000000'[:24],  # WRITE(12)
                                  'c', '8a000000000100000000000000080000',  # WRITE(16) LBA 2^32
                                  'c', '41000000100000000000',            # WRITE SAME(10), length 0
                                  'c', '04000000000000',                  # FORMAT UNIT
                                  'c', '420000000000000000000000',        # UNMAP
                                  'c', '2a00000010',                      # short WRITE(10)
                                  'c', '1200000024000000',                # INQUIRY
                                  'c', '35000000000000000000')            # SYNCHRONIZE CACHE
        self.assertEqual(c, ['c 1 0 1', 'c 1 0 256', 'c 2 2097151 16', 'c 2 4096 8', 'c 2 4096 32',
                             'c 2 4294967296 8', 'c 3 4096 0', 'c 3 0 0', 'c 3 0 0', 'c 3 0 0', 'c 0 0 0',
                             'c 0 0 0'])


class DriverWiring(unittest.TestCase):
    def test_source(self):
        src = (ROOT / 'tools/nt/usosmpart/src/usosmpart.c').read_text()
        self.assertIn('#include "mpgpt.h"', src)
        self.assertIn('MpgBuild(MpGptRead, Ext, lastLba, blockSize, buf, &Ext->Map) == MPG_OK ? MpMap : MpHide', src)
        self.assertIn('kind == MPG_CDB_READ && decision == MpMap && lba == 0', src)
        self.assertIn('RtlCopyMemory(va + 440, ext->Map.tail, sizeof(ext->Map.tail));', src)
        self.assertIn('decision == MpHide || !MpgWriteAllowed(&ext->Map, lba, n)', src)
        self.assertIn('IOCTL_SCSI_PASS_THROUGH_DIRECT', src)
        self.assertIn('ext->Decision == MpFlip || ext->Decision == MpHide || ext->Decision == MpMap', src)
        hdr = HEADER.read_text()
        self.assertIn('SPDX-License-Identifier: GPL-3.0-or-later', hdr)
        self.assertNotIn('#include', hdr.split('#define USOS_MPGPT_H', 1)[1])   # no kernel / CRT headers


if __name__ == '__main__':
    unittest.main()
