/* SPDX-License-Identifier: GPL-3.0-or-later
 * Own explicit active-NTFS EDD chain loader. No Microsoft bootstrap bytes.
 * Linked at0x600, initially entered at0x7c00, then relocated below the PBR.
 */
.intel_syntax noprefix
.code16
.section .text
.global minios_mbr_start
minios_mbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    cld
    mov si, 0x7c00
    mov di, 0x600
    mov cx, 256
    rep movsw
    .byte 0xea
    .word relocated
    .word 0
relocated:
    mov byte ptr [drive], dl
    sti
    mov si, 0x600 + 446
    mov cx, 4
    xor bx, bx
scan:
    mov al, byte ptr [si]
    test al, al
    jz next
    cmp al, 0x80
    jne fail
    test bx, bx
    jnz fail
    cmp byte ptr [si + 4], 7
    jne fail
    mov bx, si
next:
    add si, 16
    loop scan
    test bx, bx
    jz fail
    mov eax, dword ptr [bx + 8]
    test eax, eax
    jz fail
    cmp dword ptr [bx + 12], 0
    je fail
    mov dword ptr [dap + 8], eax
    mov bx, 0x55aa
    mov dl, byte ptr [drive]
    mov ah, 0x41
    int 0x13
    jc fail
    cmp bx, 0xaa55
    jne fail
    test cl, 1
    jz fail
    mov si, offset dap
    mov dl, byte ptr [drive]
    mov ah, 0x42
    int 0x13
    jc fail
    cmp word ptr [0x7dfe], 0xaa55
    jne fail
    mov dl, byte ptr [drive]
    .byte 0xea
    .word 0x7c00
    .word 0
fail:
    mov ax, 0x0e4d
    mov bx, 7
    int 0x10
    cli
halt:
    hlt
    jmp halt
.balign 4
 drive: .byte 0
.balign 4
 dap:
    .byte 16, 0
    .word 1
    .word 0x7c00, 0
    .quad 0
.org 432
    .ascii "USOSMB1\0"
.org 510
    .word 0xaa55
