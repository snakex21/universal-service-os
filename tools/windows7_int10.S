/* Minimal VBE INT10 compatibility handler for the UefiSeven 1.30 table layout.
 * USOS modification: unsupported requests return instead of looping forever;
 * VBE SetMode accepts bit 15 (preserve framebuffer) as well as normal LFB mode.
 * Layout/interface derived from manatails/UefiSeven Int10hHandler.asm (BSD):
 * Copyright (c) 2020 Seungjoo Kim; (c) 2016 Dawid Ciecierski;
 * (c) 2014 Red Hat, Inc.; (c) 2013-2014 Intel Corporation.
 * See tools/vendor/uefiseven/1.30/LICENSE.txt.
 */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    .fill 512, 1, 0x90
handler:
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
    jmp copy_info
get_mode_info:
    push ax
    mov ax, cx
    and ax, 0xbfff
    cmp ax, 0x00f1
    pop ax
    jne unsupported
    push si
    mov si, 256
copy_info:
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
set_mode:
    mov ax, bx
    and ax, 0x7fff
    cmp ax, 0x40f1
    jne unsupported
    jmp success
get_mode:
    mov bx, 0x40f1
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
