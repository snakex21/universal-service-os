/* test-only fake "old INT 10h" for tools/tests/legacy_bios/test_u9v10stk.py, linked at 1000h.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later. */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    cmp ax, 0x1a00
    je nested
    pushf
    pop word ptr cs:[0x00]
    mov word ptr cs:[0x02], ss
    mov word ptr cs:[0x04], sp
    mov word ptr cs:[0x06], ax
    mov word ptr cs:[0x08], bx
    mov word ptr cs:[0x0a], cx
    mov word ptr cs:[0x0c], dx
    mov word ptr cs:[0x0e], si
    mov word ptr cs:[0x10], di
    mov word ptr cs:[0x12], bp
    mov word ptr cs:[0x14], ds
    mov word ptr cs:[0x16], es
    mov bp, sp
    mov ax, word ptr [bp+4]
    mov word ptr cs:[0x18], ax
    mov ax, word ptr cs:[0x06]
    mov bp, word ptr cs:[0x12]
    /* burn 1536 bytes of stack */
    mov cx, 768
1:  push cx
    loop 1b
    mov cx, 768
2:  pop word ptr cs:[0x1c]
    loop 2b
    mov cx, word ptr cs:[0x0a]
    cmp ax, 0x1100
    jne 3f
    push ax
    push bx
    mov ax, 0x1a00
    int 0x10
    mov byte ptr cs:[0x1e], al
    pop bx
    pop ax
3:  /* outputs */
    xor ax, 0x5555
    inc bx
    not cx
    mov si, 0x1111
    mov di, 0x2222
    mov bp, 0x3333
    push cs
    pop ds
    push word ptr cs:[0x26]
    pop es
    cmp dx, 1
    je retf2
    mov dx, 0x4444
    /* iret style: set CF ZF, clear SF in the frame */
    push bp
    mov bp, sp
    or word ptr [bp+6], 0x0041
    and word ptr [bp+6], ~0x0080
    pop bp
    iret
retf2:
    /* live-flags style: CF=1 ZF=0 SF=1 OF=1, DF=1, IF=1 */
    mov dx, 0x5555
    mov word ptr cs:[0x28], 0x0e83
    push word ptr cs:[0x28]
    popf
    .byte 0xca, 0x02, 0x00   /* retf 2 (16-bit) */
nested:
    mov word ptr cs:[0x20], sp
    mov word ptr cs:[0x22], ss
    inc byte ptr cs:[0x24]
    mov al, 0x1a
    mov bx, 0x0008
    iret
