"""USOS BIOS entry shim for the pinned GPL-2.0-or-later wimboot 2.9.0.

Linux leaves the 8259 PIC and PIT configured for its own interrupt handlers.
Restore BIOS vectors before wimboot calls firmware services. Only the unused
Linux setup padding and its initial far-return destination are changed; the
protected-mode payload and the original vendor file remain unchanged.
"""
import hashlib
import struct
import os
import subprocess

WIMBOOT_SHA256 = "5f067ccdc4d084d5bf77b6c853bd0f8402dfc2b4cd1b103d358993ae97fae8e3"
INT13_RUNTIME_SIZE = 0x200


def _int13_geometry_fallback() -> bytes:
    # Real-mode INT13 wrapper at CS:04a0; saved BIOS vector at CS:04f0.
    # AH=08 is bookkeeping only: existing hard disks use the BDA count;
    # floppies/out-of-range drives report unavailable during this RAM boot.
    # Actual reads/writes and EDD queries still go directly to firmware.
    # AH=08 itself may hang after kexec, including the floppy probe.
    code = bytearray.fromhex(
        "80 fc 08 75 00 "       # cmp ah,8; jne chain
        "80 fa 80 72 00 "       # cmp dl,80h; jb invalid
        "53 1e 31 db 8e db 8a 1e 75 04 1f "  # bx=BDA[475]; restore ds
        "b7 80 00 df 38 fa 73 00 "  # bh=80h+count; cmp dl,bh; jae restore_chain
        "88 da 5b "             # dl=count; restore bx
        # This bootstrap uses EDD/linear I/O. Legacy CHS is a compatibility
        # envelope, not the physical size: AH=48 still supplies real geometry.
        "b9 ff ff b6 fe 31 c0"  # cx=ffff; dh=fe; ax=0
    )
    # Clear only CF in the caller's original frame, preserving IF.
    code += bytes.fromhex("55 89 e5 36 83 66 06 fe 5d cf")
    restore = len(code)
    code += b'\x5b'  # pop bx before rejecting an out-of-range request
    invalid = len(code)
    code += bytes.fromhex('55 89 e5 36 83 4e 06 01 5d b4 01 cf')
    chain = len(code)
    code += bytes.fromhex("2e ff 2e f0 04")  # jmp far cs:[04f0]
    code[4] = chain - 5
    code[9] = invalid - 10
    code[28] = restore - 29
    return bytes(code)


def make_kexec_wimboot(original: bytes) -> bytes:
    if hashlib.sha256(original).hexdigest() != WIMBOOT_SHA256:
        raise ValueError("Unsupported wimboot: BIOS shim requires pinned 2.9.0")
    image = bytearray(original)
    entry = 0x202 + image[0x201]
    if image[entry:entry + 2] != b"\x1e\x68" or image[entry + 4] != 0xcb:
        raise ValueError("Unexpected wimboot real-mode entry")
    if image[0x400:0x4a0 + INT13_RUNTIME_SIZE] != bytes(0x4a0 + INT13_RUNTIME_SIZE - 0x400):
        raise ValueError("wimboot setup padding is occupied")
    resume = struct.unpack_from("<H", image, entry + 2)[0]
    # cli; cld; lidt cs:[0x480]. The original entry has already normalized CS.
    code = bytearray.fromhex("fa fc 2e 0f 01 1e 80 04")
    for port, value in (
        (0x20, 0x11), (0xa0, 0x11),  # ICW1: initialize both PICs
        (0x21, 0x08), (0xa1, 0x70),  # BIOS interrupt vectors
        (0x21, 0x04), (0xa1, 0x02),  # cascade on IRQ2
        (0x21, 0x01), (0xa1, 0x01),  # 8086 mode
        (0x21, 0xf8), (0xa1, 0xbf),  # timer, keyboard, cascade, primary IDE
        (0x43, 0x36), (0x40, 0), (0x40, 0),  # PIT channel 0: BIOS 18.2 Hz
    ):
        # mov al, value; out port, al; out 0x80, al (legacy I/O delay)
        code += bytes((0xb0, value, 0xe6, port, 0xe6, 0x80))
    # Save and wrap INT13. Windows 7 bootmgr first asks BIOS drive 80h for the
    # drive count. After kexec a firmware geometry call may fail or hang;
    # bootmgr then misses even wimboot's working RAM disk (BCD c000000e).
    code += b'\xe8' + struct.pack('<h', 0x520 - (0x400 + len(code) + 3))
    # USOS leaves a VESA framebuffer active. BIOS teletype output (including
    # wimboot diagnostics and bootmgr) is not reliably rendered in that mode.
    # Restore VGA text mode after restoring firmware interrupts, preserving
    # the Linux setup registers. The original prefix expects IF/DF clear.
    code += bytes.fromhex(
        '66 60 1e 06 0f a0 0f a8 b8 03 00 cd 10 '
        '0f a9 0f a1 07 1f 66 61 fa fc'
    )
    code += b"\x0e\x68" + struct.pack("<H", resume) + b"\xcb"  # push cs; push resume; retf
    if len(code) > 0x80:
        raise ValueError("BIOS entry shim exceeds reserved padding")
    struct.pack_into("<H", image, entry + 2, 0x400)
    image[0x400:0x400 + len(code)] = code
    struct.pack_into("<HI", image, 0x480, 0x3ff, 0)  # real-mode IVT
    wrapper = _int13_geometry_fallback()
    if len(wrapper) > 0x50:
        raise ValueError("INT13 wrapper exceeds reserved padding")
    image[0x4a0:0x4a0 + len(wrapper)] = wrapper
    # The Linux-loaded setup area may be reused by Windows. Copy the lasting
    # handler into wimboot's reserved runtime prefix at physical 0x20000,
    # below its bss16 and payload (vendor script.lds / prefix.S). Initialize
    # the complete 512-byte working block, including vector/data and padding;
    # copying only the executable bytes was insufficient in the BIOS test.
    installer = bytes.fromhex(
        "1e 06 56 57 51 50 8c c8 8e d8 b8 00 20 8e c0 "
        "be a0 04 bf a0 04 b9"
    ) + struct.pack('<H', INT13_RUNTIME_SIZE) + bytes.fromhex(
        "f3 a4 31 c0 8e d8 66 a1 4c 00 26 66 a3 f0 04 "
        "c7 06 4c 00 a0 04 c7 06 4e 00 00 20 "
        "58 59 5f 5e 07 1f c3"
    )
    if len(installer) > 0x60:
        raise ValueError('INT13 installer exceeds reserved padding')
    image[0x520:0x520 + len(installer)] = installer
    return bytes(image)


def _build_asm_blob(root, output, source, section, name):
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['ZIG_GLOBAL_CACHE_DIR'] = str(root / 'tools/cache/zig-global')
    env['ZIG_LOCAL_CACHE_DIR'] = str(output / 'cache')
    zig = str(root / 'tools/zig/zig.exe')
    obj = output / (name + '.o')
    blob = output / (name + '.bin')
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386',
                    '-c', str(root / source), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', '-j', section,
                    str(obj), str(blob)], env=env, check=True)
    return blob.read_bytes()


def build_disk_order(root, output):
    """Compile the same disk-order hook used by the native BIOS path."""
    return _build_asm_blob(root, output, 'src/platform/bios/windows_disk_order.S',
                           '.rodata.windows_disk_order', 'disk-order')


def build_kexec_bridge(root, output):
    """Compile the BIOS compatibility bridge used after Linux kexec."""
    data = _build_asm_blob(root, output, 'src/platform/bios/windows_kexec_bridge.S',
                           '.rodata.windows_kexec_bridge', 'kexec-bridge')
    if len(data) != 0x100:
        raise ValueError(f'Kexec bridge must be exactly 256 bytes, got {len(data)}')
    return data


def build_kexec_cpu_reset(root, output):
    """Compile the real-mode CPU-state reset used before BIOS bootmgr."""
    data = _build_asm_blob(root, output, 'src/platform/bios/windows_kexec_cpu_reset.S',
                           '.rodata.windows_kexec_cpu_reset', 'kexec-cpu-reset')
    if len(data) != 0x40:
        raise ValueError(f'Kexec CPU reset must be exactly 64 bytes, got {len(data)}')
    return data


def make_ordered_kexec_wimboot(original: bytes, disk_order: bytes, kexec_bridge: bytes, cpu_reset: bytes) -> bytes:
    """Restore firmware interrupt setup, then apply native disk ordering.

    This uses separate, non-overlapping resident blocks: disk ordering at
    20500h..205ffh and geometry fallback at 20800h..208ffh. Both are below the
    vendor prefix BSS at 20a00h. Windows protected-mode code is untouched.
    The request supplies its observed BIOS drive at file offset 05fah.
    """
    if hashlib.sha256(original).hexdigest() != WIMBOOT_SHA256:
        raise ValueError('Unsupported wimboot')
    if len(disk_order) != 512 or disk_order[0x1fa] != 0xff:
        raise ValueError('Invalid disk-order hook')
    if len(kexec_bridge) != 0x100:
        raise ValueError('Invalid kexec BIOS bridge')
    if len(cpu_reset) != 0x40:
        raise ValueError('Invalid kexec CPU reset')
    if original[0x400:0xa00] != bytes(0x600):
        raise ValueError('wimboot setup padding is occupied')
    image = bytearray(original)
    entry = 0x202 + image[0x201]
    if image[entry:entry + 2] != b'\x1e\x68' or image[entry + 4] != 0xcb:
        raise ValueError('Unexpected wimboot entry')
    resume = struct.unpack_from('<H', image, entry + 2)[0]
    image[0x400:0x600] = disk_order
    struct.pack_into('<H', image, 0x5fc, resume)
    struct.pack_into('<H', image, entry + 2, 0x600)
    code = bytearray.fromhex('fa fc 2e 0f 01 1e 80 06')
    # kexec can leave EFER/CR4 in a 64-bit-Linux state even after entering
    # real mode.  Native BIOS boot never has that state.  Reset it before any
    # firmware call or before bootmgr gets a chance to enable paging.
    code += b'\xe8' + struct.pack('<h', 0x720 - (0x600 + len(code) + 3))
    for port, value in ((0x20,0x11),(0xa0,0x11),(0x21,0x08),(0xa1,0x70),
                        (0x21,0x04),(0xa1,0x02),(0x21,0x01),(0xa1,0x01),
                        (0x21,0xf8),(0xa1,0xbf),(0x43,0x36),(0x40,0),(0x40,0)):
        code += bytes((0xb0,value,0xe6,port,0xe6,0x80))
    code += b'\xe8' + struct.pack('<h', 0x880 - (0x600 + len(code) + 3))
    # Install an INT15/e820 bridge before wimboot enters protected mode.
    # The bridge serves the kexec-provided boot_params memory map instead of
    # re-entering legacy firmware after Linux.
    #
    # On the physical MS-7100, wimboot reaches bootmgr.exe and then stalls.
    # WinPE itself does not need firmware hard disks at this point: bootmgr,
    # BCD, boot.sdi and boot.wim are all on wimboot's RAM disk, and Windows
    # will enumerate SATA/USB again using its native drivers.  Hide the stale
    # post-Linux BIOS disk list so initialise_int13() creates the RAM disk as
    # drive 80h and bootmgr never needs to touch physical INT13 services.
    image[0x706] = 1
    code += b'\xe8' + struct.pack('<h', 0x900 - (0x600 + len(code) + 3))
    code += bytes.fromhex('66 60 1e 06 0f a0 0f a8 b8 03 00 cd 10 0f a9 0f a1 07 1f 66 61 fa fc')
    code += bytes.fromhex('0e 68 00 04 cb')
    if len(code) > 0x80:
        raise ValueError('Ordered entry exceeds padding')
    image[0x600:0x600 + len(code)] = code
    struct.pack_into('<HI', image, 0x680, 0x3ff, 0)
    geometry = _int13_geometry_fallback().replace(bytes.fromhex('2e ff 2e f0 04'), bytes.fromhex('2e ff 2e f0 08'))
    image[0x800:0x800 + len(geometry)] = geometry
    installer = bytes.fromhex(
        '1e 06 56 57 51 50 8c c8 8e d8 b8 00 20 8e c0 '
        'be 00 08 bf 00 08 b9 00 01 f3 a4 31 c0 8e d8 '
        '66 a1 4c 00 26 66 a3 f0 08 '
        'c7 06 4c 00 00 08 c7 06 4e 00 00 20 '
        '58 59 5f 5e 07 1f c3')
    if len(installer) > 0x70:
        raise ValueError('Ordered hook installer overlaps vector storage')
    image[0x720:0x760] = cpu_reset
    image[0x880:0x880 + len(installer)] = installer
    image[0x900:0xa00] = kexec_bridge
    return bytes(image)
