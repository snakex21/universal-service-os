#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate QCOW backing metadata before any diagnostic QEMU image open.

This module performs no creation or writes. Its caller must pin every file,
enforce a raw-container size bound, and use only the authorized case.
"""
import os
import struct
from pathlib import Path
import diagnostic_boot_guard as guard

def inspect_header(stream,length,expected_backing,expected_format):
    if expected_format not in ('vhdx','qcow2') or not Path(expected_backing).is_absolute():
        raise ValueError('Explicit local backing and format required')
    if type(length) is not int or not 104<=length<=guard.FIRSTBOOT_BOUND:
        raise ValueError('QCOW container length outside diagnostic budget')
    stream.seek(0);head=stream.read(104)
    if len(head)!=104 or head[:4]!=b'QFI\xfb' or struct.unpack_from('>I',head,4)[0]!=3:
        raise ValueError('QCOW2 v3 header required')
    offset,count,bits,size=struct.unpack_from('>QIIQ',head,8)
    header_bytes=struct.unpack_from('>I',head,100)[0]
    if (not 9<=bits<=21 or size!=32*1024**3 or struct.unpack_from('>I',head,32)[0]!=0 or
        struct.unpack_from('>Q',head,72)[0]!=0 or not 104<=header_bytes<=4096 or header_bytes%8 or
        not header_bytes<=offset<=min(length,65536) or not 0<count<=4096 or count>length-offset):
        raise ValueError('QCOW identity, feature or backing bounds differ')
    stream.seek(104);extra=stream.read(header_bytes-104)
    if len(extra)!=header_bytes-104 or any(extra):raise ValueError('Unsupported QCOW header extension')
    stream.seek(offset);raw=stream.read(count)
    if len(raw)!=count:raise ValueError('Short backing name')
    name=raw.decode('utf-8','strict')
    if any(c in name for c in '\0\r\n,') or ':' in name[3:] or not Path(name).is_absolute():
        raise ValueError('Unsafe backing name')
    if os.path.normcase(os.path.normpath(name))!=os.path.normcase(os.path.normpath(str(expected_backing))):
        raise ValueError('Backing path differs')
    at=header_bytes;found=None;terminated=False
    while at+8<=offset:
        stream.seek(at);entry=stream.read(8)
        if len(entry)!=8:raise ValueError('Short QCOW extension')
        kind,n=struct.unpack('>II',entry);at+=8
        if kind==0:
            if n:raise ValueError('Invalid QCOW extension terminator')
            terminated=True;break
        padded=(n+7)&~7
        if n>4096 or padded>offset-at:raise ValueError('QCOW extension bounds')
        value=stream.read(n)
        if len(value)!=n:raise ValueError('Short QCOW extension value')
        if kind==0xe2792aca:
            if found is not None:raise ValueError('Duplicate backing format')
            found=value.decode('ascii','strict')
        elif kind!=0x6803f857:raise ValueError('Unsupported QCOW extension')
        at+=padded
    if not terminated or found!=expected_format:raise ValueError('Backing format missing or differs')
    return {'backing':name,'format':found,'virtual_bytes':size,'container_bytes':length}
