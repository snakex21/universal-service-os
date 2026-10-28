"""Runs the MSZIP block decoder of the user's NT 3.5x SETUPDD.SYS (text-mode
Setup) under unicorn on every CFDATA block of a one-folder cabinet and
returns the decoded bytes. Own code, GPL-3.0-or-later; the Microsoft binary
is read from the user's media and never stored in the repository.

The decoder is located by its MSZIP "CK" check (cmp word ptr [eax], 4B43h;
3.51 build 1057 SETUPDD.SYS RVA 0x206C0); the entry is 0x1B bytes before
it (it stores the alloc/free callbacks, then checks "CK"). Arguments, stdcall:
(in, in_size, out, out_max, *out_size, alloc, free); 0 = success.

Why (X470 2026-10-28): this decoder reads a stored block's LEN but not its
NLEN, so a stored-block cabinet decodes as NLEN + data[:-2]
(OEMNADLB.INF began 08 96 "[Identification]").
"""
import struct
import sys

import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import UC_X86_REG_EAX, UC_X86_REG_ESP

CHECK = bytes.fromhex('66813843 4b'.replace(' ', ''))  # cmp word ptr [eax], 0x4b43


def entry_rva(pe):
    img = pe.get_memory_mapped_image()
    hits = [i for i in range(len(img)) if img.startswith(CHECK, i)]
    if len(hits) != 1:
        raise ValueError('MSZIP "CK" check found %d times' % len(hits))
    rva = hits[0] - 0x1b
    # mov eax,[esp+18h]; mov ecx,[esp+1Ch]
    if img[rva:rva + 8] != bytes.fromhex('8b4424188b4c241c'):
        raise ValueError('unexpected decoder prologue')
    return rva


def decode(sys_path, cab):
    pe = pefile.PE(sys_path)
    base = pe.OPTIONAL_HEADER.ImageBase
    img = pe.get_memory_mapped_image()
    fn = base + entry_rva(pe)
    uc = Uc(UC_ARCH_X86, UC_MODE_32)
    uc.mem_map(base, (len(img) + 0xfff) & ~0xfff)
    uc.mem_write(base, img)
    stk, heap, io, stub = 0x800000, 0x1000000, 0x2000000, 0x700000
    uc.mem_map(stk - 0x10000, 0x20000)
    uc.mem_map(heap, 0x400000)
    uc.mem_map(io, 0x100000)
    uc.mem_map(stub, 0x1000)
    uc.mem_write(stub, b'\xc3\xc3\xc3\xc3')  # alloc, free, return sentinel
    top = [heap]

    def hook(u, addr, _size, _data):
        if addr == stub:
            n = struct.unpack('<I', u.mem_read(u.reg_read(UC_X86_REG_ESP) + 4, 4))[0]
            u.reg_write(UC_X86_REG_EAX, top[0])
            top[0] += (n + 15) & ~15
        elif addr == stub + 2:
            u.emu_stop()

    uc.hook_add(UC_HOOK_CODE, hook, begin=stub, end=stub + 4)
    if cab[:4] != b'MSCF' or struct.unpack_from('<H', cab, 0x1e)[0] != 0:
        raise ValueError('not a plain cabinet')
    p = struct.unpack_from('<I', cab, 0x24)[0]
    blocks = struct.unpack_from('<H', cab, 0x28)[0]
    out = b''
    for _ in range(blocks):
        _csum, cb, _cu = struct.unpack_from('<IHH', cab, p)
        uc.mem_write(io, cab[p + 8:p + 8 + cb])
        p += 8 + cb
        outp, szp = io + 0x10000, io + 0x80000
        uc.mem_write(szp, b'\0' * 4)
        esp = stk - 0x100
        uc.mem_write(esp, struct.pack('<8I', stub + 2, io, cb, outp, 0x8000, szp, stub, stub + 1))
        uc.reg_write(UC_X86_REG_ESP, esp)
        uc.emu_start(fn, 0, count=50_000_000)
        if uc.reg_read(UC_X86_REG_EAX) != 0:
            raise ValueError('decoder refused the block')
        n = struct.unpack('<I', uc.mem_read(szp, 4))[0]
        out += bytes(uc.mem_read(outp, n))
    return out


if __name__ == '__main__':
    data = decode(sys.argv[1], open(sys.argv[2], 'rb').read())
    if len(sys.argv) > 3:
        open(sys.argv[3], 'wb').write(data)
    import hashlib
    print(len(data), hashlib.sha256(data).hexdigest(), data[:24])
