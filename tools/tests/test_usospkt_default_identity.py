"""Pin the X470-approved default packet driver before the queue experiment.

Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later
"""
from pathlib import Path
import hashlib
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard
from build_dos_network import build_usospkt, NET_FILES
from build_win3_usb_keyboard import elf_symbols


def test_default_driver_is_the_approved_reference(tmp_path):
    # Integration 922d1171, excluding 6974778d, built with the pinned Zig.
    depguard.require_zig()
    com = build_usospkt(ROOT, tmp_path, tmp_path)
    assert com.stat().st_size == 8157
    assert hashlib.sha256(com.read_bytes()).hexdigest() == (
        '98cfdf5ad6c8d7c805927d7f7247ef326ca36414c3622189a0a238c16ae933eb')
    symbols = elf_symbols(tmp_path / 'usospkt.elf')
    assert ((symbols['image_end'] + 127) & ~127) + 34816 == 43264
    assert 'USOSPKTQ.COM' not in NET_FILES
