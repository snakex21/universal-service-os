/* SPDX-License-Identifier: GPL-3.0-or-later
 * Own synthetic two-sector file: verifies BIOS handoff, never Windows code.
 */
.intel_syntax noprefix
.code16
.section .text
.global minios_test_start
minios_test_start:
    cmp sp, 0x7c00
    jne fail
    cmp dx, 0x80
    jne fail
    mov ax, cs
    cmp ax, 0x2000
    jne fail
    mov ax, ds
    test ax, ax
    jnz fail
    mov ax, es
    test ax, ax
    jnz fail
    mov ax, fs
    test ax, ax
    jnz fail
    mov ax, gs
    test ax, ax
    jnz fail
    mov ax, ss
    test ax, ax
    jnz fail
    cmp dword ptr [0x7c00 + 28], 2048
    jne fail
    cmp byte ptr [0x7c00 + 36], 0x80
    jne fail
    mov ax, 0x2000
    mov es, ax
    cmp word ptr es:[1022], 0x5aa5
    jne fail
    mov dx, 0xf4
    mov eax, 0x10
    out dx, eax
halt:
    cli
    hlt
    jmp halt
fail:
    mov dx, 0xf4
    mov eax, 0x11
    out dx, eax
    jmp halt
.org 1022
    .word 0x5aa5
