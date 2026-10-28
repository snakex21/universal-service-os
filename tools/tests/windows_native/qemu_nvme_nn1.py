#!/usr/bin/env python3
"""Test-harness only: make a running QEMU's NVMe controller report one
namespace (Identify Controller NN = 1) instead of QEMU's fixed 256.

    python qemu_nvme_nn1.py PID [SERIAL]

Why: Windows 7's stornvme (KB2990941) walks every NSID up to NN; QEMU 11
answers inactive NSIDs with an all-zero Identify Namespace, and that stornvme
then shows phantom disks and blocks volume enumeration (docs/windows7-nvme.md,
"Warunki testu NVMe"). Real controllers (the X470 test disk, Micron 3400)
report NN = 1. Nothing on disk is changed: the controller's Identify data in
the QEMU process memory (serial at offset 4, model "QEMU NVMe Ctrl" at 24,
NN at 516) is patched once, after QEMU started and before the guest's driver
reads it. Windows only; reads/writes only that process.
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as w
import struct
import sys

PROCESS_VM_READ, PROCESS_VM_WRITE, PROCESS_VM_OPERATION, PROCESS_QUERY_INFORMATION = 0x10, 0x20, 0x8, 0x400
MEM_COMMIT, PAGE_READWRITE = 0x1000, 0x04


class MBI(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p), ("AllocationProtect", w.DWORD),
                ("PartitionId", w.WORD), ("RegionSize", ctypes.c_size_t), ("State", w.DWORD), ("Protect", w.DWORD), ("Type", w.DWORD)]


def main() -> int:
    pid = int(sys.argv[1])
    serial = (sys.argv[2] if len(sys.argv) > 2 else "USOSTARGET").encode().ljust(20, b" ")
    needle = serial + b"QEMU NVMe Ctrl"
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.VirtualQueryEx.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.POINTER(MBI), ctypes.c_size_t]
    k.ReadProcessMemory.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    k.WriteProcessMemory.argtypes = k.ReadProcessMemory.argtypes
    h = k.OpenProcess(PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        print("OpenProcess failed", ctypes.get_last_error()); return 2
    addr, patched = 0, 0
    mbi = MBI()
    while k.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), ctypes.sizeof(mbi)):
        base, size = mbi.BaseAddress or 0, mbi.RegionSize
        if mbi.State == MEM_COMMIT and mbi.Protect == PAGE_READWRITE and size < (1 << 31):
            buf = ctypes.create_string_buffer(size); got = ctypes.c_size_t()
            if k.ReadProcessMemory(h, ctypes.c_void_p(base), buf, size, ctypes.byref(got)):
                data = buf.raw[:got.value]
                at = data.find(needle)
                while at >= 0:
                    ident = at - 4
                    if ident >= 0 and ident + 520 <= len(data) and struct.unpack_from("<I", data, ident + 516)[0] == 256:
                        one = ctypes.c_uint32(1); wrote = ctypes.c_size_t()
                        if k.WriteProcessMemory(h, ctypes.c_void_p(base + ident + 516), ctypes.byref(one), 4, ctypes.byref(wrote)):
                            patched += 1
                            print(f"NN 256 -> 1 at 0x{base + ident:x}")
                    at = data.find(needle, at + 1)
        addr = base + size
        if addr >= (1 << 47):
            break
    k.CloseHandle(h)
    print(f"patched={patched}")
    return 0 if patched else 1


if __name__ == "__main__":
    sys.exit(main())
