#!/usr/bin/env python3
"""Minimal read-only reader for Windows 95/98/Me registry files (USER.DAT,
SYSTEM.DAT: the "CREG" format), for offline checks of QEMU installs.

Layout (little endian):
  CREG header (0x20 bytes): 'CREG', version, offset of the first RGDB block,
      checksum, number of RGDB blocks (WORD at 0x10).
  RGKN at 0x20: 'RGKN', size, offset of the root key entry (relative to
      RGKN), ... Key entries (0x1C bytes, offsets relative to RGKN, 0xFFFFFFFF
      = none): +0x00 type/in-use, +0x04 hash, +0x08 next free, +0x0C parent,
      +0x10 first child, +0x14 next sibling, +0x18 WORD key id,
      +0x1A WORD RGDB block number (0xFFFF = no data record).
  RGDB blocks (from the header offset, each 'RGDB' + size): 0x20-byte block
      header, then key records: +0x00 record size, +0x04 WORD key id,
      +0x06 WORD block number, +0x08 bytes used, +0x0C WORD name length,
      +0x0E WORD value count, +0x10 DWORD, +0x14 name, then the values:
      +0x00 type, +0x04 DWORD, +0x08 WORD name length, +0x0A WORD data
      length, name, data.

Value types: 1 REG_SZ, 3 REG_BINARY, 4 REG_DWORD. Names compare case-insensitively.

    python tools/tests/w9x_creg.py USER.DAT "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced"
"""
from __future__ import annotations

import struct
import sys

NONE = 0xFFFFFFFF


class Hive:
    def __init__(self, data: bytes):
        if data[:4] != b"CREG":
            raise ValueError("not a CREG file")
        self.data = data
        rgdb_off = struct.unpack_from("<I", data, 8)[0]
        nblocks = struct.unpack_from("<H", data, 0x10)[0]
        self.rgkn = 0x20
        if data[self.rgkn:self.rgkn + 4] != b"RGKN":
            raise ValueError("no RGKN")
        self.root = struct.unpack_from("<I", data, self.rgkn + 8)[0]
        # (block, id) -> (name, values)
        self.records: dict[tuple[int, int], tuple[str, list[tuple[str, int, bytes]]]] = {}
        off = rgdb_off
        for _ in range(nblocks):
            if data[off:off + 4] != b"RGDB":
                break
            size = struct.unpack_from("<I", data, off + 4)[0]
            pos, end = off + 0x20, off + size
            while pos + 0x14 <= end:
                rsize, kid, blk, used, nlen, nval = struct.unpack_from("<IHHIHH", data, pos)
                if rsize == 0 or rsize > end - pos:
                    break
                if used >= 0x14 and kid != 0xFFFF:
                    name = data[pos + 0x14:pos + 0x14 + nlen].decode("cp1250", errors="replace")
                    vals = []
                    vp = pos + 0x14 + nlen
                    for _ in range(nval):
                        vtype, _r, vnl, vdl = struct.unpack_from("<IIHH", data, vp)
                        vname = data[vp + 12:vp + 12 + vnl].decode("cp1250", errors="replace")
                        vdata = data[vp + 12 + vnl:vp + 12 + vnl + vdl]
                        vals.append((vname, vtype, vdata))
                        vp += 12 + vnl + vdl
                    self.records[(blk, kid)] = (name, vals)
                pos += rsize
            off += size

    def _entry(self, rel: int) -> tuple[int, int, int, int, int]:
        p = self.rgkn + rel
        _t, _h, _nf, parent, child, sibling, kid, blk = struct.unpack_from("<IIIIIIHH", self.data, p)
        return parent, child, sibling, kid, blk

    def _record(self, rel: int):
        _p, _c, _s, kid, blk = self._entry(rel)
        return self.records.get((blk, kid))

    def children(self, rel: int):
        child = self._entry(rel)[1]
        while child != NONE:
            rec = self._record(child)
            yield (rec[0] if rec else "?"), child
            child = self._entry(child)[2]

    def key(self, path: str) -> int | None:
        rel = self.root
        for comp in [c for c in path.split("\\") if c]:
            for name, crel in self.children(rel):
                if name.lower() == comp.lower():
                    rel = crel
                    break
            else:
                return None
        return rel

    def values(self, path: str) -> list[tuple[str, int, bytes]] | None:
        rel = self.key(path)
        if rel is None:
            return None
        rec = self._record(rel)
        return rec[1] if rec else []

    def value(self, path: str, name: str) -> tuple[int, bytes] | None:
        for vname, vtype, vdata in self.values(path) or []:
            if vname.lower() == name.lower():
                return vtype, vdata
        return None


def main() -> int:
    hive = Hive(open(sys.argv[1], "rb").read())
    path = sys.argv[2] if len(sys.argv) > 2 else ""
    rel = hive.key(path)
    if rel is None:
        print("no such key")
        return 1
    for name, _ in hive.children(rel):
        print(f"[{name}]")
    for vname, vtype, vdata in hive.values(path) or []:
        print(f"{vname or '@'} type={vtype} {vdata.hex()} {vdata!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
