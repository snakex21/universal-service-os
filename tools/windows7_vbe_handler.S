/* USOS multi-mode VBE INT10 handler for the Windows 7 / Vista UefiSeven path.
 * Replaces UefiSeven's one-mode handler at C000:0200 (same entry, same IVT
 * vector) so Windows sees 1024x768 (its boot graphics need it) plus the
 * monitor-native mode, all on the one GOP framebuffer.
 * Layout (segment C000), filled by tools/windows7_vbe_table.zig:
 *   0000 VbeInfoBlock (256 bytes, mode list inside)
 *   03FC current mode (word, written if the segment is writable)
 *   03FE number of modes (word); modes are 0x00F1 + index
 *   0400 ModeInfoBlock of mode index 0, 0500 index 1, ...
 * Interface follows UefiSeven 1.30 Int10hHandler.asm (BSD-2-Clause:
 * (c) 2020 Seungjoo Kim; (c) 2016 Dawid Ciecierski; (c) 2014 Red Hat;
 * (c) 2013-2014 Intel); see tools/vendor/uefiseven/1.30/LICENSE.txt.
 * Unknown requests return AX=014F instead of hanging.
 */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    cmp ax, 0x4f00
    je get_info
    cmp ax, 0x4f01
    je get_mode_info
    cmp ax, 0x4f02
    je set_mode
    cmp ax, 0x4f03
    je get_mode
    cmp ah, 0
    je set_legacy
unsupported:
    mov ax, 0x014f
    iret
get_info:
    push si
    mov si, 0
    jmp copy_block
get_mode_info:
    push si
    mov si, cx
    and si, 0x01ff
    sub si, 0x00f1
    jb bad_mode
    cmp si, word ptr cs:[0x3fe]
    jae bad_mode
    shl si, 8
    add si, 0x400
copy_block:
    push ds
    push es
    push di
    push cx
    push cs
    pop ds
    mov cx, 256
    cld
    rep movsb
    pop cx
    pop di
    pop es
    pop ds
    pop si
success:
    mov ax, 0x004f
    iret
bad_mode:
    pop si
    jmp unsupported
set_mode:
    push si
    mov si, bx
    and si, 0x01ff
    sub si, 0x00f1
    jb set_ok
    cmp si, word ptr cs:[0x3fe]
    jae bad_mode
set_ok:
    mov word ptr cs:[0x3fc], bx
    pop si
    jmp success
get_mode:
    mov bx, word ptr cs:[0x3fc]
    jmp success
set_legacy:
    cmp al, 3
    je legacy_text
    cmp al, 0x12
    jne unsupported
    mov al, 0x20
    iret
legacy_text:
    mov al, 0x30
    iret
