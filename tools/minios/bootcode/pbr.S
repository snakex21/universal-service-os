/* SPDX-License-Identifier: GPL-3.0-or-later
 * Own QEMU experimental NT6 chain loader. The installer binds one verified
 * contiguous BOOTMGR run: a pinned copy in the MBR gap (LBA 1024, outside
 * every file system), so a later move of the NTFS bootmgr file does not matter.
 * Public handoff contract consulted: GNU GRUB ntldr.c, GPLv3+, real-mode
 * CS2000:0, segments0/SP7c00, DL BIOS disk, NTFS BPB at7c00, A20 enabled.
 * No Microsoft bootstrap bytes are incorporated.
 * At most 960 sectors (480 KiB, end 0x98000): Windows 10 22H2's BOOTMGR is
 * 413738 bytes (809 sectors); the int 12h / EBDA checks bound it at runtime.
 */
.intel_syntax noprefix
.code16
.section .text
.global minios_pbr_start
minios_pbr_start:
    .byte 0xeb, 0x52, 0x90
    .ascii "NTFS    "
.org 84
entry:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    cld
    mov byte ptr [drive], dl
    mov byte ptr [0x7c00 + 36], dl
    sti
    cmp word ptr [count], 0
    je fail
    cmp word ptr [count], 960
    ja fail
    int 0x12
    movzx eax, ax
    shl eax, 10
    movzx ebx, word ptr [count]
    shl ebx, 9
    add ebx, 0x20000
    cmp ebx, eax
    ja fail
    movzx ecx, word ptr [0x40e]
    shl ecx, 4
    test ecx, ecx
    jz memory_ok
    cmp ebx, ecx
    ja fail
memory_ok:
    mov ax, word ptr [count]
    mov word ptr [left], ax
    mov eax, dword ptr [run_lba]
    mov dword ptr [dap + 8], eax
    mov eax, dword ptr [run_lba + 4]
    mov dword ptr [dap + 12], eax
    mov ax, 3
    int 0x10
read_next:
    mov si, offset dap
    mov dl, byte ptr [drive]
    mov ah, 0x42
    int 0x13
    jc fail
    add word ptr [dap + 6], 0x20
    add dword ptr [dap + 8], 1
    adc dword ptr [dap + 12], 0
    dec word ptr [left]
    jnz read_next
    mov ax, 0x2401
    int 0x15
    in al, 0x92
    or al, 2
    and al, 0xfe
    out 0x92, al
    cli
    xor eax, eax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, 0x7c00
    xor ebx, ebx
    xor ecx, ecx
    xor edx, edx
    mov dl, byte ptr [drive]
    xor esi, esi
    xor edi, edi
    xor ebp, ebp
    cld
    sti
    .byte 0xea
    .word 0, 0x2000
fail:
    mov ax, 0x0e50
    mov bx, 7
    int 0x10
    cli
halt:
    hlt
    jmp halt
.org 448
 drive: .byte 0
.balign 4
 dap:
    .byte 16, 0
    .word 1
    .word 0, 0x2000
    .quad 0
 left: .word 0
.org 480
 run_lba: .quad 0
 count: .word 0
    .word 0
    .ascii "USOSPB1\0"
.org 510
    .word 0xaa55
