# SPDX-License-Identifier: GPL-3.0-or-later
"""Disjoint, pre-write limits for the one bootfiles review case."""
import json
from pathlib import Path

import firstboot_output

MIB = 1024**2
LIMITS = {
    'boot-base.raw': 65*MIB,
    'target.qcow2': 128*MIB,
    'boot.qcow2': 8*MIB,
    'vars.fd': MIB,
    'entropy.bin': 64,
    'USOSBOOT.CFG': 4096,
    'debug.log': 2*MIB,
    'qemu.stderr': MIB,
    'boot-files.json': MIB,
    'result.json': MIB,
}
assert sum(LIMITS.values()) <= 208*MIB


class Scope:
    def __init__(self, root):
        self.root = Path(root)

    def save(self, name, data):
        if name not in LIMITS or name in ('boot-base.raw', 'target.qcow2', 'boot.qcow2'):
            raise ValueError('Undeclared or device output')
        with firstboot_output.Sink(self.root/name, LIMITS[name]) as stream:
            stream.write(data)

    def save_json(self, name, obj):
        self.save(name, (json.dumps(obj, ensure_ascii=True, indent=2)+'\n').encode())

    def audit(self):
        total = 0
        for path in self.root.rglob('*'):
            info = path.lstat()
            if path.is_symlink() or getattr(info, 'st_file_attributes', 0) & 0x400:
                raise ValueError('Link in bootfiles output')
            if path.is_dir():
                continue
            name = path.relative_to(self.root).as_posix()
            if info.st_nlink != 1 or name not in LIMITS or info.st_size > LIMITS[name]:
                raise ValueError('Unexpected, shared or oversized bootfiles output: '+name)
            total += info.st_size
        return total
