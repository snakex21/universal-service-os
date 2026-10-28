#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only virtual-install oracle and guarded normalization of a fresh export.

Public formats: Microsoft's VHD specification1.0 (download id23850) and
https://learn.microsoft.com/windows/win32/api/winioctl/ni-winioctl-fsctl_set_sparse
No Microsoft payload, physical-device path or general-purpose write API.
"""
import ctypes as C
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import uuid
import zlib

import wim_oracle as oracle
import logged_run
import wim_pool as pool

REPO = Path(__file__).resolve().parents[2]

SECTOR = 512
BLOCK = 2 * 1024 * 1024
MAX_VIRTUAL = 128 * 1024**3
UNSAFE_ATTRIBUTES = 0x10 | 0x400 | 0x800 | 0x4000  # directory/reparse/compressed/encrypted


def regular(path):
    path = oracle.local(Path(path))
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or getattr(info, 'st_file_attributes', 0) & UNSAFE_ATTRIBUTES:
        raise ValueError('One ordinary local regular-file link required')
    return path


def checksum(data, offset):
    value = bytearray(data)
    recorded = struct.unpack_from('>I', value, offset)[0]
    value[offset:offset + 4] = bytes(4)
    if recorded != (~sum(value) & 0xffffffff):
        raise ValueError('VHD checksum differs')


class DynamicVhd:
    """Bounded logical seek/read of an independent fresh QEMU dynamic VHD.

    Only dynamic type3,2MiB blocks and512-byte sectors are accepted. BAT and
    bitmaps are interpreted independently of QEMU and MiniOS filesystem code.
    No parent, differencing, compressed or write support is provided.
    """
    def __init__(self, path, *, stream=None):
        # A supplied stream is the already-guarded exclusive normalization
        # handle; do not open/query the pathname again while share mode is0.
        self.path = regular(path) if stream is None else Path(path)
        self.own_file = stream is None
        self.file = self.path.open('rb') if stream is None else stream
        self.file_bytes = os.fstat(self.file.fileno()).st_size
        self.position = 0
        self.bitmap_index, self.bitmap = None, None
        try:
            self._parse()
        except BaseException:
            if self.own_file:
                self.file.close()
            raise

    def _at(self, offset, size):
        if offset < 0 or size < 0 or offset > self.file_bytes or size > self.file_bytes - offset:
            raise ValueError('VHD physical range outside container')
        self.file.seek(offset)
        data = self.file.read(size)
        if len(data) != size:
            raise ValueError('VHD physical read truncated')
        return data

    def _parse(self):
        if self.file_bytes < 2560 or self.file_bytes % SECTOR:
            raise ValueError('VHD container length invalid')
        footer = self._at(self.file_bytes - SECTOR, SECTOR)
        if footer[:8] != b'conectix' or self._at(0, SECTOR) != footer:
            raise ValueError('Dynamic VHD footer/backup differs')
        checksum(footer, 64)
        if struct.unpack_from('>II', footer, 8) != (2, 0x10000) or struct.unpack_from('>I', footer, 60)[0] != 3:
            raise ValueError('Only fresh dynamic VHD1.0 accepted')
        original, current = struct.unpack_from('>QQ', footer, 40)
        if original != current or not 32 * 1024**2 <= current <= MAX_VIRTUAL or current % SECTOR:
            raise ValueError('VHD virtual geometry invalid')
        self.size = current
        header_at = struct.unpack_from('>Q', footer, 16)[0]
        if header_at != SECTOR:
            raise ValueError('Fresh VHD dynamic-header offset differs')
        header = self._at(header_at, 1024)
        if header[:8] != b'cxsparse' or struct.unpack_from('>Q', header, 8)[0] != 0xffffffffffffffff:
            raise ValueError('VHD dynamic-header signature invalid')
        checksum(header, 36)
        table_at = struct.unpack_from('>Q', header, 16)[0]
        version, entries, block = struct.unpack_from('>III', header, 24)
        if (version != 0x10000 or block != BLOCK or entries != (self.size + block - 1) // block
                or table_at < header_at + 1024 or table_at % SECTOR or any(header[40:])):
            raise ValueError('VHD BAT/parent/block geometry invalid')
        table_bytes = (entries * 4 + SECTOR - 1) // SECTOR * SECTOR
        if table_at + table_bytes > self.file_bytes - SECTOR:
            raise ValueError('VHD BAT outside metadata range')
        self.bat = struct.unpack('>' + 'I' * entries, self._at(table_at, entries * 4))
        self.bitmap_bytes = ((block // SECTOR + 7) // 8 + SECTOR - 1) // SECTOR * SECTOR
        self.minimum_data = table_at + table_bytes
        spans = []
        for index, sector in enumerate(self.bat):
            if sector == 0xffffffff:
                continue
            begin = sector * SECTOR
            end = begin + self.bitmap_bytes + block
            if begin < self.minimum_data or end > self.file_bytes - SECTOR:
                raise ValueError('VHD BAT block outside container data')
            spans.append((begin, end, index))
        spans.sort()
        for previous, following in zip(spans, spans[1:]):
            if previous[1] > following[0]:
                raise ValueError('VHD BAT blocks duplicate/overlap')

    def seek(self, offset, whence=0):
        position = offset if whence == 0 else self.position + offset if whence == 1 else self.size + offset if whence == 2 else -1
        if position < 0 or position > self.size:
            raise ValueError('VHD logical seek outside image')
        self.position = position
        return position

    def read(self, count):
        if type(count) is not int or not 0 <= count <= 32 * 1024**2:
            raise ValueError('Bounded explicit VHD read size required')
        count = min(count, self.size - self.position)
        result, done = bytearray(count), 0
        while done < count:
            block_index, within = divmod(self.position, BLOCK)
            take = min(count - done, BLOCK - within)
            sector = self.bat[block_index]
            if sector != 0xffffffff:
                base = sector * SECTOR
                if self.bitmap_index != block_index:
                    self.bitmap = self._at(base, self.bitmap_bytes)
                    self.bitmap_index = block_index
                if self.bitmap == b'\xff' * self.bitmap_bytes:
                    result[done:done + take] = self._at(base + self.bitmap_bytes + within, take)
                else:
                    moved = 0
                    while moved < take:
                        sector_index, local = divmod(within + moved, SECTOR)
                        amount = min(take - moved, SECTOR - local)
                        if self.bitmap[sector_index // 8] & (0x80 >> (sector_index % 8)):
                            result[done + moved:done + moved + amount] = self._at(base + self.bitmap_bytes + within + moved, amount)
                        moved += amount
            self.position += take
            done += take
        return bytes(result)

    def close(self):
        if self.own_file:
            self.file.close()


def _kernel():
    if os.name != 'nt':
        raise ValueError('Fresh VHD normalization requires Windows')
    kernel = C.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [C.c_wchar_p, C.c_uint32, C.c_uint32, C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p]
    kernel.CreateFileW.restype = C.c_void_p
    kernel.CloseHandle.argtypes = [C.c_void_p]
    kernel.GetFileInformationByHandle.argtypes = [C.c_void_p, C.c_void_p]
    kernel.GetFileInformationByHandle.restype = C.c_int
    kernel.GetFinalPathNameByHandleW.argtypes = [C.c_void_p, C.c_wchar_p, C.c_uint32, C.c_uint32]
    kernel.GetFinalPathNameByHandleW.restype = C.c_uint32
    kernel.DeviceIoControl.argtypes = [C.c_void_p, C.c_uint32, C.c_void_p, C.c_uint32, C.c_void_p, C.c_uint32, C.POINTER(C.c_uint32), C.c_void_p]
    kernel.DeviceIoControl.restype = C.c_int
    kernel.FlushFileBuffers.argtypes = [C.c_void_p]
    kernel.FlushFileBuffers.restype = C.c_int
    return kernel


def normalize_fresh_vhd(path, workspace, expected_sha256, expected_bytes):
    """Only for a new unique export in this invocation's fresh owned directory.

    The caller must create the fresh output directory/export without overwrite.
    The exact named VHD is checked again on an exclusive no-reparse handle.
    FSCTL changes allocation metadata, never VHD payload bytes or the qcow2.
    """
    import msvcrt
    path, workspace = regular(path), oracle.local(Path(workspace))
    if (path.suffix.lower() != '.vhd' or path == workspace or not path.is_relative_to(workspace)
            or not re.fullmatch('[0-9a-f]{64}', expected_sha256) or path.stat().st_size != expected_bytes):
        raise ValueError('Exact fresh owned VHD path/length/SHA required')
    kernel = _kernel()
    expected_name = os.path.normcase(str(path.resolve()))
    handle = kernel.CreateFileW(str(path), 0xc0000000, 0, None, 3, 0x00200000, None)
    if handle == C.c_void_p(-1).value:
        raise C.WinError(C.get_last_error())
    try:
        info = C.create_string_buffer(52)
        resolved = C.create_unicode_buffer(32768)
        if not kernel.GetFileInformationByHandle(handle, info):
            raise C.WinError(C.get_last_error())
        length = kernel.GetFinalPathNameByHandleW(handle, resolved, len(resolved), 0)
        resolved_name = resolved.value[4:] if resolved.value.startswith('\\\\?\\') else resolved.value
        if (not 0 < length < len(resolved) or os.path.normcase(os.path.normpath(resolved_name)) != expected_name
                or struct.unpack_from('<I', info.raw, 40)[0] != 1
                or struct.unpack_from('<I', info.raw, 0)[0] & (UNSAFE_ATTRIBUTES | 1)):
            raise ValueError('Exclusive VHD identity/link/host-attribute guard failed')
        original_identity = info.raw[28:52]
        descriptor = msvcrt.open_osfhandle(handle, os.O_RDWR | os.O_BINARY)
        handle = None
        with os.fdopen(descriptor, 'r+b', buffering=0) as stream:
            raw_handle = msvcrt.get_osfhandle(stream.fileno())
            if os.fstat(stream.fileno()).st_size != expected_bytes or oracle.digest_stream(stream) != expected_sha256:
                raise ValueError('Exclusive VHD payload pin differs')
            parsed = DynamicVhd(path, stream=stream)
            before = struct.unpack_from('<I', info.raw, 0)[0]
            unsparse = C.c_ubyte(0)
            returned = C.c_uint32()
            if not kernel.DeviceIoControl(raw_handle, 0x900c4, C.byref(unsparse), 1, None, 0, C.byref(returned), None):
                raise C.WinError(C.get_last_error())
            if not kernel.FlushFileBuffers(raw_handle) or not kernel.GetFileInformationByHandle(raw_handle, info):
                raise C.WinError(C.get_last_error())
            after = struct.unpack_from('<I', info.raw, 0)[0]
            if (after & (UNSAFE_ATTRIBUTES | 0x200) or info.raw[28:52] != original_identity
                    or os.fstat(stream.fileno()).st_size != expected_bytes or oracle.digest_stream(stream) != expected_sha256):
                raise ValueError('Normalized VHD bytes/identity/ordinary attributes differ')
            return dict(kind='fresh-owned-vhd-in-place-normalization', passed=True, bytes=expected_bytes,
                        sha256_before=expected_sha256, sha256_after=expected_sha256, virtual_bytes=parsed.size,
                        attributes_before=before, attributes_after=after, exclusive_handle=True,
                        operation='FSCTL_SET_SPARSE(FALSE)', source_qcow2_opened=False, image_deleted=False)
    finally:
        if handle is not None:
            kernel.CloseHandle(handle)


def disk_layout(reader, mode):
    """Independently check the complete installation partition table."""
    mib = 1024 * 1024
    if mode not in ('uefi', 'bios') or reader.size % SECTOR:
        raise ValueError('Explicit BIOS/UEFI512-byte virtual geometry required')
    def read(at, count):
        reader.seek(at)
        data = reader.read(count)
        if len(data) != count:
            raise ValueError('Truncated partition table')
        return data
    mbr = read(0, SECTOR)
    if mbr[510:512] != b'\x55\xaa':
        raise ValueError('Installation MBR signature missing')
    rows = []
    if mode == 'bios':
        signature = struct.unpack_from('<I', mbr, 440)[0]
        if signature in (0, 0xffffffff) or any(mbr[478:510]):
            raise ValueError('Two-partition MBR signature/table shape invalid')
        for index in range(2):
            raw = mbr[446 + index * 16:462 + index * 16]
            start, sectors = struct.unpack_from('<II', raw, 8)
            if raw[4] != 7 or raw[0] != (0x80 if index == 0 else 0):
                raise ValueError('MBR requires one active system and one Windows NTFS partition')
            rows.append(dict(number=index + 1, start=start * SECTOR, bytes=sectors * SECTOR,
                             filesystem='NTFS', mbr_type=7, active=index == 0))
        expected = [(mib, 100 * mib), (101 * mib, reader.size // mib * mib - 101 * mib)]
        result = dict(style='MBR', mbr_signature=signature)
    else:
        if (mbr[446] or mbr[450] != 0xee or struct.unpack_from('<I', mbr, 454)[0] != 1
                or struct.unpack_from('<I', mbr, 458)[0] != min(reader.size // SECTOR - 1, 0xffffffff)
                or any(mbr[462:510])):
            raise ValueError('Strict protective MBR required')
        def header(at):
            data = bytearray(read(at * SECTOR, SECTOR))
            if (data[:8] != b'EFI PART' or struct.unpack_from('<II', data, 8) != (0x10000, 92)
                    or struct.unpack_from('<I', data, 20)[0] != 0):
                raise ValueError('GPT header signature/version/size invalid')
            own, peer, first, last = struct.unpack_from('<QQQQ', data, 24)
            entries_at, entries, width, table_crc = struct.unpack_from('<QIII', data, 72)
            recorded = struct.unpack_from('<I', data, 16)[0]
            struct.pack_into('<I', data, 16, 0)
            if (zlib.crc32(data[:92]) != recorded or own != at or first != 34
                    or last != reader.size // SECTOR - 34 or entries != 128 or width != 128):
                raise ValueError('GPT header CRC/usable geometry invalid')
            table = read(entries_at * SECTOR, entries * width)
            if zlib.crc32(table) != table_crc:
                raise ValueError('GPT entry CRC invalid')
            return dict(peer=peer, entries_at=entries_at, disk=bytes(data[56:72]), table=table)
        primary, backup = header(1), header(reader.size // SECTOR - 1)
        if (primary['peer'] != reader.size // SECTOR - 1 or backup['peer'] != 1
                or primary['entries_at'] != 2 or backup['entries_at'] != reader.size // SECTOR - 33
                or primary['disk'] != backup['disk'] or primary['table'] != backup['table']):
            raise ValueError('GPT primary/backup identity or table differs')
        if primary['disk'] == bytes(16) or any(primary['table'][384:]):
            raise ValueError('Exactly three GPT entries and nonzero disk GUID required')
        kinds = ['c12a7328-f81f-11d2-ba4b-00a0c93ec93b', 'e3c9e316-0b5c-4db8-817d-f92df00215ae', 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7']
        guids = {str(uuid.UUID(bytes_le=primary['disk']))}
        for index in range(3):
            raw = primary['table'][index * 128:(index + 1) * 128]
            kind, guid = str(uuid.UUID(bytes_le=raw[:16])), str(uuid.UUID(bytes_le=raw[16:32]))
            start, last, attributes = struct.unpack_from('<QQQ', raw, 32)
            if kind != kinds[index] or raw[16:32] == bytes(16) or guid in guids or attributes:
                raise ValueError('GPT type/unique GUID/attributes differ')
            guids.add(guid)
            rows.append(dict(number=index + 1, start=start * SECTOR, bytes=(last - start + 1) * SECTOR,
                             filesystem=['FAT32', None, 'NTFS'][index], gpt_type=kind, guid=guid))
        end = (reader.size - 33 * SECTOR) // mib * mib
        expected = [(mib, 300 * mib), (301 * mib, 16 * mib), (317 * mib, end - 317 * mib)]
        result = dict(style='GPT', disk_guid=str(uuid.UUID(bytes_le=primary['disk'])))
    for row, (start, size) in zip(rows, expected):
        if (row['start'] != start or row['bytes'] != size or start % mib or size <= 0 or size % mib
                or start > reader.size or size > reader.size - start):
            raise ValueError('Installation partition size/alignment/layout differs')
    result.update(schema='minios-install-layout-v1', mode=mode, image_bytes=reader.size,
                  sector_bytes=SECTOR, partitions=rows, windows_number=3 if mode == 'uefi' else 2,
                  system_number=1)
    return result


def qcow_chain(source, virtual_bytes):
    """Validate backing names before asking QEMU to open any backing file."""
    chain, seen, current = [], set(), oracle.owned(source)
    while current is not None:
        current = regular(current)
        if current in seen or len(chain) >= 16:
            raise ValueError('QCOW2 backing cycle/depth exceeded')
        oracle.owned(current)
        seen.add(current)
        if current.suffix.lower() not in ('.qcow2', '.raw', '.vhd'):
            raise ValueError('Only owned qcow2/raw/dynamic-VHD backing files accepted')
        backing = None
        with current.open('rb') as stream:
            if current.suffix.lower() == '.raw':
                if current.stat().st_size != virtual_bytes:
                    raise ValueError('Raw backing virtual length differs')
            elif current.suffix.lower() == '.vhd':
                # A VHD is always a terminal ordinary dynamic type3 file;
                # parent/differencing/fixed disks are rejected by the parser.
                parsed = DynamicVhd(current, stream=stream)
                if parsed.size != virtual_bytes:
                    raise ValueError('Dynamic VHD backing virtual length differs')
            else:
                header = stream.read(104)
                if len(header) < 104 or header[:4] != b'QFI\xfb':
                    raise ValueError('QCOW2 header missing')
                version = struct.unpack_from('>I', header, 4)[0]
                offset, count, bits, size = struct.unpack_from('>QIIQ', header, 8)
                if (version not in (2, 3) or not 9 <= bits <= 21 or size != virtual_bytes
                        or struct.unpack_from('>I', header, 32)[0] != 0
                        or version == 3 and struct.unpack_from('>Q', header, 72)[0] & ~1):
                    raise ValueError('Unsupported/encrypted/external-data QCOW2')
                if bool(offset) != bool(count) or count > 4096 or offset > current.stat().st_size or count > current.stat().st_size - offset:
                    raise ValueError('QCOW2 backing-name bounds invalid')
                if count:
                    stream.seek(offset)
                    name = stream.read(count).decode('utf-8', 'strict')
                    if any(char in name for char in '\0\r\n,') or ':' in name[3:]:
                        raise ValueError('Unsafe QCOW2 backing protocol/name')
                    backing = Path(name)
                    if not backing.is_absolute():
                        backing = current.parent / backing
                    oracle.owned(backing)
        chain.append(current)
        current = backing
    return chain


def empty_wrapper(path):
    """Require no current QCOW2 data mappings, even if a snapshot exists."""
    path = regular(oracle.owned(path))
    length = path.stat().st_size
    if path.suffix != '.qcow2' or not 104 <= length <= 8 * 1024**2:
        raise ValueError('Bounded new empty QCOW2 wrapper required')
    with path.open('rb') as source:
        header = source.read(104)
        if header[:4] != b'QFI\xfb': raise ValueError('Wrapper QCOW2 header missing')
        version, bits = struct.unpack_from('>I',header,4)[0], struct.unpack_from('>I',header,20)[0]
        if (version not in (2,3) or not 9 <= bits <= 21 or struct.unpack_from('>I',header,32)[0]
            or version==3 and struct.unpack_from('>Q',header,72)[0]):
            raise ValueError('Closed unencrypted ordinary wrapper required')
        count, offset = struct.unpack_from('>IQ',header,36)
        cluster = 1 << bits
        virtual_bytes=struct.unpack_from('>Q',header,24)[0]
        expected=(virtual_bytes+cluster*(cluster//8)-1)//(cluster*(cluster//8))
        if not 0 < count == expected <= 32768 or offset < cluster or offset % cluster or offset > length or count*8 > length-offset:
            raise ValueError('Wrapper L1 geometry is invalid')
        source.seek(offset)
        if any(source.read(count*8)):
            raise ValueError('Prepared wrapper already contains guest data mappings')


def prepared_reuse(args, locks):
    """Validate a completed firmware-created immutable VHD before any output.

    The caller subsequently holds both chain files read-only and runs a real
    qemu-img logical comparison. This does not normalize/chmod/create an image.
    """
    vhd = regular(oracle.owned(args.reuse_prepared_vhd))
    receipt = regular(oracle.owned(args.prep_receipt))
    pin = args.prep_receipt_sha256
    if not isinstance(pin,str) or not re.fullmatch('[0-9a-f]{64}',pin) or receipt.stat().st_size>1024**2:
        raise ValueError('Exact bounded completed preparation receipt pin required')
    stream = locks.enter_context(oracle.readonly(receipt))
    if oracle.digest_stream(stream)!=pin:raise ValueError('Preparation receipt changed')
    prep = json.loads(receipt.read_text(encoding='utf-8-sig'))
    mode = 'gpt' if args.mode=='uefi' else 'mbr'
    if (prep.get('schema')!='minios-install-firmware-v1' or prep.get('passed') is not True
        or prep.get('qemu_only') is not True or prep.get('dirty')!=0 or not re.fullmatch('[0-9a-f]{40}',prep.get('head',''))
        or prep.get('mode')!=mode or prep.get('target')!=str(args.source) or prep.get('target_bytes')!=args.virtual_bytes
        or prep.get('target_format')!='vpc' or prep.get('prepared_vhd')!=str(vhd)
        or prep.get('returncode')!=33 or type(prep.get('returncode')) is not int
        or prep.get('timed_out') is not False or prep.get('source_unchanged') is not True
        or prep.get('base_unchanged') is not True or prep.get('guest_completion_wait') is not True
        or prep.get('physical_disks_opened') is not False or receipt.parent!=args.source.parent or vhd.parent!=receipt.parent
        or prep.get('prepared_vhd_bytes')!=vhd.stat().st_size or vhd.suffix!='.vhd'):
        raise ValueError('Complete clean successful firmware VHD preparation required')
    if not isinstance(prep.get('prepared_vhd_sha256'),str) or not re.fullmatch('[0-9a-f]{64}',prep['prepared_vhd_sha256']):
        raise ValueError('Exact prepared VHD pin required')
    if oracle.digest(args.source)!=prep.get('target_sha256') or oracle.digest(vhd)!=prep['prepared_vhd_sha256']:
        raise ValueError('Prepared wrapper or VHD bytes changed')
    attrs = getattr(vhd.stat(),'st_file_attributes',0)
    if not attrs & 1 or attrs & (UNSAFE_ATTRIBUTES | 0x200):
        raise ValueError('Prepared VHD must already be ordinary nonsparse and readonly')
    normalized = prep.get('prepared_vhd_normalization',{})
    if (normalized.get('kind')!='fresh-owned-vhd-in-place-normalization' or normalized.get('passed') is not True
        or normalized.get('bytes')!=prep['prepared_vhd_bytes'] or normalized.get('virtual_bytes')!=args.virtual_bytes
        or normalized.get('sha256_before')!=prep['prepared_vhd_sha256'] or normalized.get('sha256_after')!=prep['prepared_vhd_sha256']
        or normalized.get('exclusive_handle') is not True or normalized.get('operation')!='FSCTL_SET_SPARSE(FALSE)'
        or normalized.get('source_qcow2_opened') is not False or normalized.get('image_deleted') is not False
        or type(normalized.get('attributes_after')) is not int or normalized['attributes_after'] & (UNSAFE_ATTRIBUTES | 0x201)):
        raise ValueError('Byte-preserving completed firmware VHD normalization proof required')
    if qcow_chain(args.source,args.virtual_bytes)!=[args.source,vhd]:
        raise ValueError('Exactly empty wrapper backed by specified prepared VHD required')
    empty_wrapper(args.source)
    return dict(vhd=vhd,sha256=prep['prepared_vhd_sha256'],wrapper_sha256=prep['target_sha256'],normalization=normalized,
                receipt=receipt,receipt_sha256=pin)


def execute(command, log, env, head, timeout=7200):
    if logged_run.tree(REPO) != (head, 0):
        raise ValueError('F3: clean frozen HEAD required before native gate')
    with log.open('x', encoding='utf-8', newline='\n') as output:
        output.write(f'HEAD {head}\nWORKTREE_DIRTY 0\nCOMMAND {json.dumps(list(map(str, command)))}\n')
        output.flush()
        result = subprocess.run(list(map(str, command)), cwd=REPO, env=env, stdout=output,
                                stderr=subprocess.STDOUT, timeout=timeout)
        output.write(f'EXIT {result.returncode}\n')
    if result.returncode or logged_run.tree(REPO) != (head, 0):
        raise ValueError(f'Native gate failed or tree changed; retained {log}')


def verify(args):
    """Closed QEMU target→one ordinary dynamic VHD→all native RO gates.

    args: source,out,plan,qemu_img,pwsh,virtual_bytes,mode,expected_tree,
    expected_security. No preparation/format/boot, cleanup or physical access.
    """
    for path in (args.out, args.source, args.expected_tree, args.expected_security):
        oracle.owned(path)
    for path in (args.qemu_img, args.pwsh):
        oracle.local(path)
    if args.out.exists() or args.source.suffix.lower() != '.qcow2' or type(args.virtual_bytes) is not int or not 0 < args.virtual_bytes <= MAX_VIRTUAL:
        raise ValueError('Fresh output and explicit bounded closed QCOW2 target required')
    reuse_path = getattr(args,'reuse_prepared_vhd',None)
    reuse_args = (getattr(args,'prep_receipt',None),getattr(args,'prep_receipt_sha256',None))
    if bool(reuse_path)!=all(value is not None for value in reuse_args) or not reuse_path and any(value is not None for value in reuse_args):
        raise ValueError('Reuse requires explicit VHD and pinned preparation receipt together')
    head, dirty = logged_run.tree(REPO)
    if dirty:
        raise ValueError('F3: clean tree required')
    with contextlib.ExitStack() as locks:
        reused = prepared_reuse(args,locks) if reuse_path else None
        chain = qcow_chain(args.source, args.virtual_bytes)
        pins = {path: oracle.digest(path) for path in chain}
        expected_pins = {path: oracle.digest(path) for path in (args.expected_tree, args.expected_security)}
        for path in chain:
            locks.enter_context(oracle.readonly(path))
        if qcow_chain(args.source, args.virtual_bytes) != chain or any(oracle.digest(path) != pin for path, pin in pins.items()):
            raise ValueError('QCOW2 source/backing chain changed before locked export')
        if reused and (pins.get(args.source)!=reused['wrapper_sha256'] or pins.get(reused['vhd'])!=reused['sha256']):
            raise ValueError('Locked prepared chain differs from firmware receipt')
        capacity = (pool.enforce_incremental(args.plan,args.out,512*1024**2,closed_scope=True) if reused
                    else pool.enforce(args.plan,args.out))
        args.out.mkdir(parents=True)
        env = oracle.environment(args.out)
        if reused:
            vhd,vhd_sha,normalized = reused['vhd'],reused['sha256'],reused['normalization']
            # No -s allocation comparison: an empty wrapper and the same VHD
            # must match every logical byte, regardless of container metadata.
            empty_wrapper(args.source)
            execute([args.qemu_img,'compare','-f','qcow2','-F','vpc',args.source,vhd],
                    args.out/'prepared-logical-compare.log',env,head)
        else:
            vhd = args.out / 'readonly-install.vhd'
            execute([args.qemu_img, 'convert', '-f', 'qcow2', '-O', 'vpc', '-o',
                     'subformat=dynamic,force_size=on', args.source, vhd], args.out / 'vhd-convert.log', env, head)
            vhd_sha = oracle.digest(vhd)
            normalized = normalize_fresh_vhd(vhd, args.out, vhd_sha, vhd.stat().st_size)
        reader = DynamicVhd(vhd)
        try:
            if reader.size != args.virtual_bytes:
                raise ValueError('VHD virtual size differs from explicit QEMU target')
            layout = disk_layout(reader, args.mode)
        finally:
            reader.close()
        oracle.save(args.out / 'layout.json', layout)
        layout_sha = oracle.digest(args.out / 'layout.json')
        if not reused:os.chmod(vhd, stat.S_IREAD)
        windows = next(row for row in layout['partitions'] if row['number'] == layout['windows_number'])
        # Import only after source/geometry guards. This is the existing raw
        # NTFS/SDS implementation with the independent VHD seek/read adapter.
        import wim_security_readonly as security
        proof_path = args.out / 'raw-security.json'
        proof = security.verify_tree(vhd, vhd_sha, args.expected_security, args.expected_tree, proof_path,
                                     vhd_partition=(windows['start'], windows['bytes']))
        if not proof['passed']:
            raise ValueError('Independent NTFS/SDS/tree proof failed before native mounting')
        native_results = []
        with oracle.readonly(vhd):
            for row in layout['partitions']:
                if row['filesystem'] is None:
                    continue
                out = args.out / f'native-partition-{row["number"]}'
                log = args.out / f'native-partition-{row["number"]}.log'
                if row['filesystem'] == 'FAT32':
                    command = [args.pwsh, '-NoProfile', '-File', REPO / 'tools/tests/test_minios_fat32_chkdsk.ps1',
                               '-Workspace', oracle.RUNTIME, '-Vhd', vhd, '-ExpectedImageBytes', args.virtual_bytes,
                               '-ExpectedVhdSha256', vhd_sha, '-PartitionNumber', row['number'],
                               '-ExpectedPartitionStart', row['start'], '-ExpectedPartitionBytes', row['bytes'], '-Out', out]
                else:
                    command = [args.pwsh, '-NoProfile', '-File', REPO / 'tools/tests/minios_install_readonly.ps1',
                               '-Workspace', oracle.RUNTIME, '-InstallVhd', vhd, '-InstallVhdSha256', vhd_sha,
                               '-InstallImageBytes', args.virtual_bytes, '-LayoutJson', args.out / 'layout.json',
                               '-LayoutSha256', layout_sha, '-PartitionNumber', row['number'], '-InstallOut', out]
                    if row['number'] == layout['windows_number']:
                        command += ['-ExpectedTree', args.expected_tree, '-ExpectedSecurity', args.expected_security,
                                    '-RawSecurityProof', proof_path, '-RawSecurityProofSha256', oracle.digest(proof_path)]
                execute(command, log, env, head)
                receipt = json.loads((out / 'result.json').read_text(encoding='utf-8-sig'))
                if receipt.get('passed') is not True or receipt.get('chkdsk_exit') != 0:
                    raise ValueError('Native filesystem gate failed; stop without boot')
                native_results.append(dict(number=row['number'], filesystem=row['filesystem'],
                                           result=str((out / 'result.json').relative_to(args.out)),
                                           sha256=oracle.digest(out / 'result.json'), chkdsk_exit=0))
        if (any(oracle.digest(path) != pin for path, pin in pins.items())
                or any(oracle.digest(path) != pin for path, pin in expected_pins.items())
                or oracle.digest(vhd) != vhd_sha or logged_run.tree(REPO) != (head, 0)
                or reused and oracle.digest(reused['receipt'])!=reused['receipt_sha256']):
            raise ValueError('Closed source/backing/VHD/manifests or HEAD changed')
    result = dict(schema='minios-install-native-v1', passed=True, head=head, dirty=0,
                  capacity_preflight=capacity, virtual_bytes=args.virtual_bytes, mode=args.mode,
                  source_sha256=pins[args.source], source_backing_chain_unchanged=True,
                  source_backing_chain=[dict(path=str(path.relative_to(oracle.RUNTIME)), sha256=pin) for path, pin in pins.items()],
                  vhd=str(vhd), vhd_sha256=vhd_sha, vhd_bytes=vhd.stat().st_size,
                  normalization=normalized, layout_sha256=layout_sha,
                  expected_tree_sha256=expected_pins[args.expected_tree], expected_security_sha256=expected_pins[args.expected_security],
                  raw_security_result_sha256=oracle.digest(proof_path), native_results=native_results,
                  extra_full_raw_or_fixed_vhd_copies=0, boot_attempted=False, deleted=False,
                  reused_prepared_vhd=bool(reused),vhd_export_performed=not bool(reused),
                  normalization_performed_during_native=not bool(reused),
                  prep_receipt=str(reused['receipt']) if reused else None,
                  prep_receipt_sha256=reused['receipt_sha256'] if reused else None,
                  prepared_logical_compare_exit=0 if reused else None)
    oracle.save(args.out / 'result.json', result)
    return result


run = verify


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'out', 'plan', 'qemu-img', 'pwsh', 'expected-tree', 'expected-security'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--virtual-bytes', type=int, required=True)
    parser.add_argument('--mode', choices=['uefi', 'bios'], required=True)
    parser.add_argument('--reuse-prepared-vhd',type=Path)
    parser.add_argument('--prep-receipt',type=Path)
    parser.add_argument('--prep-receipt-sha256')
    print(json.dumps(verify(parser.parse_args())))
