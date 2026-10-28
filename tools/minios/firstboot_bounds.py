#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fixed raw envelope beneath writable QCOW; auxiliary bounds in firstboot_output."""
import contextlib
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import stat
import struct

import install_native as native
import wim_oracle as oracle

MiB = 1024**2
SCOPE_BYTES = 2*1024**3
AUXILIARY_RESERVATION = 256*MiB
CONTAINER_BYTES = SCOPE_BYTES-AUXILIARY_RESERVATION
SCOPE_HARD_BOUND_PROVEN = True


def header_limits(header, current_bytes, maximum, virtual_bytes):
    if (len(header) < 104 or header[:4] != b'QFI\xfb' or
        struct.unpack_from('>I', header, 4)[0] not in (2,3)):
        raise ValueError('Existing fresh QCOW2 header required before padding')
    cluster_bits = struct.unpack_from('>I', header, 20)[0]
    if not 9 <= cluster_bits <= 21:
        raise ValueError('Bounded valid QCOW2 cluster size required')
    cluster = 1 << cluster_bits
    if (type(maximum) is not int or maximum <= 0 or maximum > CONTAINER_BYTES or
        maximum % cluster or current_bytes > maximum or current_bytes < 104 or
        struct.unpack_from('>Q', header, 24)[0] != virtual_bytes):
        raise ValueError('Explicit aligned container bound/virtual geometry differs')
    # External DATA files could escape the envelope, so disallow them.
    if header[7] == 3 and struct.unpack_from('>Q', header, 72)[0] & (1 << 2):
        raise ValueError('External QCOW2 data files are outside this bounded model')
    return cluster


@contextlib.contextmanager
def exclusive_file(path):
    """One owned regular file, no sharing/reparse/hardlink/device ambiguity."""
    if os.name != 'nt':
        raise ValueError('Explicit Windows sparse-envelope implementation required')
    path = native.regular(oracle.owned(Path(path)))
    if path.suffix.lower() != '.qcow2':
        raise ValueError('Exact fresh QCOW2 path required')
    kernel = C.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [C.c_wchar_p,C.c_uint32,C.c_uint32,C.c_void_p,C.c_uint32,C.c_uint32,C.c_void_p]
    kernel.CreateFileW.restype = C.c_void_p
    kernel.CloseHandle.argtypes = [C.c_void_p]
    handle = kernel.CreateFileW(str(path),0xc0000000,0,None,3,0x00200000,None)
    if handle == C.c_void_p(-1).value:
        raise C.WinError(C.get_last_error())
    import msvcrt
    try:
        fd = msvcrt.open_osfhandle(handle,os.O_RDWR|os.O_BINARY)
    except BaseException:
        kernel.CloseHandle(handle)
        raise
    with os.fdopen(fd,'r+b',buffering=0) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or getattr(info,'st_file_attributes',0) & (0x400|0x800|0x4000):
            raise ValueError('Exclusive ordinary non-reparse file identity required')
        yield stream, kernel, handle


def pad(path, virtual_bytes, maximum=CONTAINER_BYTES):
    """Pad only an already created+snapshotted local overlay, preserving bytes.

    FSCTL_SET_SPARSE changes a host file allocation attribute, not RTC/guest/
    physical-device state. No file is deleted. The prefix and file ID are
    checked while the same exclusive handle stays open.
    """
    path = Path(path)
    with exclusive_file(path) as (stream,kernel,handle):
        before = os.fstat(stream.fileno())
        cluster = header_limits(stream.read(104),before.st_size,maximum,virtual_bytes)
        stream.seek(0)
        sha = hashlib.sha256()
        while data := stream.read(MiB):
            sha.update(data)
        original_sha = sha.hexdigest()
        kernel.DeviceIoControl.argtypes = [C.c_void_p,C.c_uint32,C.c_void_p,C.c_uint32,C.c_void_p,C.c_uint32,C.POINTER(C.c_uint32),C.c_void_p]
        kernel.DeviceIoControl.restype = C.c_int
        returned = C.c_uint32()
        if not kernel.DeviceIoControl(handle,0x000900c4,None,0,None,0,C.byref(returned),None):
            raise C.WinError(C.get_last_error())
        os.ftruncate(stream.fileno(),maximum)
        stream.flush(); os.fsync(stream.fileno())
        after = os.fstat(stream.fileno())
        if (after.st_size != maximum or after.st_ino != before.st_ino or after.st_dev != before.st_dev or
            after.st_nlink != 1 or not getattr(after,'st_file_attributes',0) & 0x200):
            raise ValueError('Exact sparse envelope identity/size differs')
        stream.seek(0)
        sha = hashlib.sha256(); remaining = before.st_size
        while remaining:
            data = stream.read(min(MiB,remaining))
            if not data: raise ValueError('Truncated original QCOW prefix')
            sha.update(data); remaining -= len(data)
        if sha.hexdigest() != original_sha:
            raise ValueError('Padding changed original QCOW2 bytes')
        for offset in (before.st_size,maximum-min(4096,maximum-before.st_size)):
            if offset < maximum:
                stream.seek(offset)
                if any(stream.read(min(4096,maximum-offset))):
                    raise ValueError('Fresh sparse extension is not zero')
    return dict(schema='minios-firstboot-envelope-v1',container=str(path),container_bytes=maximum,
                original_bytes=before.st_size,original_sha256=original_sha,cluster_bytes=cluster,
                virtual_bytes=virtual_bytes,sparse=True,container_hard_bound=True,
                auxiliary_reservation_bytes=AUXILIARY_RESERVATION,
                scope_hard_bound_proven=SCOPE_HARD_BOUND_PROVEN,
                snapshot_precedes_padding=True,physical_devices_opened=False,deleted=[])


def blockdev_arguments(path, maximum=CONTAINER_BYTES):
    if type(maximum) is not int or not 0 < maximum <= CONTAINER_BYTES or maximum % 65536:
        raise ValueError('Explicit aligned fixed-container limit required')
    # Backing header is the already pinned, immutable prepared chain. QEMU's
    # normal backing open is read-only; external DATA files are disallowed.
    nodes = [dict(driver='file',**{'node-name':'firstboot-file'},filename=str(path)),
             dict(driver='raw',**{'node-name':'firstboot-limit'},file='firstboot-file',offset=0,size=maximum),
             dict(driver='qcow2',**{'node-name':'windows'},file='firstboot-limit')]
    result = []
    for node in nodes: result += ['-blockdev',json.dumps(node,separators=(',',':'))]
    return result
