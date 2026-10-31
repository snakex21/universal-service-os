#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded logical reader of an already closed, independently mapped QCOW chain.

The caller validates native.qcow_chain(), hashes and deny-write locks, and
only then supplies qemu-img map JSON. No images are opened or modified here.
"""
from bisect import bisect_right
import os


class Reader:
    def __init__(self, rows, files, size):
        if type(size) is not int or not 0 < size <= 128 * 1024**3 or not 1 <= len(files) <= 16 or not isinstance(rows,list) or not 1 <= len(rows) <= 131072:
            raise ValueError('Explicit bounded map, chain and virtual size required')
        self.files, self.size, self.position = files, size, 0
        self.rows, self.starts = [], []
        cursor = 0
        for row in rows:
            start, length = row.get('start'), row.get('length')
            zero, data = row.get('zero'), row.get('data')
            if (type(start) is not int or type(length) is not int or start != cursor or not 0 < length <= size-start
                    or type(zero) is not bool or type(data) is not bool or row.get('compressed',False) is not False):
                raise ValueError('Map gap/overlap, compression or invalid logical bounds')
            depth, offset = row.get('depth'), row.get('offset')
            if not zero:
                if not data or type(depth) is not int or not 0 <= depth < len(files) or type(offset) is not int or offset < 0:
                    raise ValueError('Nonzero map extent must name physical chain data')
                length_on_disk = os.fstat(files[depth].fileno()).st_size
                if offset > length_on_disk or length > length_on_disk-offset:
                    raise ValueError('Mapped physical extent exceeds its pinned file')
            self.starts.append(start)
            self.rows.append((start,length,zero,depth,offset))
            cursor += length
        if cursor != size:
            raise ValueError('Map must cover the exact virtual disk')

    def seek(self,offset,whence=0):
        offset = offset if whence==0 else self.position+offset if whence==1 else self.size+offset if whence==2 else -1
        if type(offset) is not int or not 0 <= offset <= self.size:
            raise ValueError('Map seek outside virtual disk')
        self.position=offset
        return offset

    def read(self,count):
        if type(count) is not int or not 0 <= count <= 8*1024**2:
            raise ValueError('Explicit bounded map read required')
        count=min(count,self.size-self.position)
        out=bytearray(count)
        done=0
        while done<count:
            index=bisect_right(self.starts,self.position)-1
            start,length,zero,depth,offset=self.rows[index]
            within=self.position-start
            take=min(count-done,length-within)
            if take<=0:raise ValueError('Map extent made no progress')
            if not zero:
                file=self.files[depth];file.seek(offset+within)
                block=file.read(take)
                if len(block)!=take:raise ValueError('Pinned mapped file was truncated')
                out[done:done+take]=block
            done+=take;self.position+=take
        return bytes(out)
