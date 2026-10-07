/*
 * USOSWHERE.COM - "where is the CPU" locator for hangs under DOS (Windows
 * 9x Setup under CSMWrap/SeaBIOS on real hardware).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * A small TSR. It hooks INT 08h (timer, chained to the previous handler)
 * and at every tick writes straight into text video memory (B800h, only
 * in text modes 0-3) at the top right corner:
 *
 *   row 0  cccc:iiii t:tttt p:pppp NAME....
 *          interrupted CS:IP (from the interrupt frame), own tick counter,
 *          current DOS PSP (from the DOS swappable data area, INT 21h
 *          AX=5D06h at install time) and the owner name in its MCB
 *   row 1  13:aaaa 15:aaaa 21:aaaa 2F:aaaa
 *          AX of the last INT 13h, 15h, 21h and 2Fh call (INT 15h without
 *          AH=4Fh/90h/91h, which the keyboard and disk BIOS issue all the
 *          time)
 *   row 2  the last 8 distinct interrupted CS values, most recent first
 *
 * After a hang a photo of the corner shows where it is:
 *   t still counting  -> interrupts on; CS:IP is the loop (mostly the same
 *                        values on every photo)
 *   t frozen          -> interrupts off (CLI loop or dead), CS:IP is the
 *                        last place a tick came in
 * An address inside an MZ program maps to its file as
 *   image offset = (CS - (PSP + 10h)) * 16 + IP
 *   file offset  = image offset + header size (MZ e_cparhdr * 16)
 * when CS is in the program's load image.
 *
 * The hooks change no register and no flag before chaining. Running it a
 * second time only prints a message. It cannot be unloaded (reboot).
 *
 * Built with tools/build_win9x_support.py (zig cc, linked at 0100h).
 */
.intel_syntax noprefix
.code16
.equ ATTR, 0x1f
.equ ROW0, (0 * 80 + 48) * 2
.equ ROW1, (1 * 80 + 49) * 2
.equ ROW2, (2 * 80 + 41) * 2
.section .text
.global _start
_start:
    jmp install

sig:    .ascii "USOSWHR1"
old08:  .long 0
old13:  .long 0
old15:  .long 0
old21:  .long 0
old2f:  .long 0
sda:    .long 0
ticks:  .word 0
ax13:   .word 0
ax15:   .word 0
ax21:   .word 0
ax2f:   .word 0
ring:   .space 16

/* far jump through a dword at cs:[x] (FF /5 with a CS override) */
.macro JMPFAR x
    .byte 0x2e, 0xff, 0x2e
    .word \x
.endm

int13:
    mov word ptr cs:[ax13], ax
    JMPFAR old13
int21:
    mov word ptr cs:[ax21], ax
    JMPFAR old21
int2f:
    mov word ptr cs:[ax2f], ax
    JMPFAR old2f
int15:
    pushf
    cmp ah, 0x4f
    je 1f
    cmp ah, 0x90
    je 1f
    cmp ah, 0x91
    je 1f
    mov word ptr cs:[ax15], ax
1:  popf
    JMPFAR old15

int08:
    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es
    mov bp, sp
    /* our pushf at bp+18, the interrupt frame: IP bp+20, CS bp+22 */
    cld
    push cs
    pop ds
    inc word ptr [ticks]
    /* most recently used list: move or insert CS at the front */
    push ds
    pop es
    mov ax, word ptr [bp + 22]
    mov di, offset ring
    mov cx, 8
    repne scasw
    je 1f
    mov di, offset ring + 16
1:  sub di, 2
2:  cmp di, offset ring
    je 3f
    mov bx, word ptr [di - 2]
    mov word ptr [di], bx
    sub di, 2
    jmp 2b
3:  mov word ptr [ring], ax
    push 0x40
    pop es
    mov al, byte ptr es:[0x49]
    cmp al, 3
    ja 9f
    push 0xb800
    pop es
    /* row 0 */
    mov di, ROW0
    mov ax, word ptr [bp + 22]
    call hex4
    mov al, ':'
    call pch
    mov ax, word ptr [bp + 20]
    call hex4
    mov si, offset s_t
    call pstr
    mov ax, word ptr [ticks]
    call hex4
    mov si, offset s_p
    call pstr
    xor ax, ax
    cmp word ptr [sda + 2], 0
    je 3f
    push es
    les bx, dword ptr [sda]
    mov ax, word ptr es:[bx + 0x10]
    pop es
3:  push ax
    call hex4
    mov al, ' '
    call pch
    pop ax
    mov cx, 8
    or ax, ax
    jz 5f
    dec ax
    push ds
    mov ds, ax
    mov si, 8
4:  lodsb
    cmp al, ' '
    jae 6f
    mov al, '.'
6:  call pch
    loop 4b
    pop ds
    jmp 7f
5:  mov al, ' '
    call pch
    loop 5b
7:  /* row 1 */
    mov di, ROW1
    mov si, offset s_13
    call pstr
    mov ax, word ptr [ax13]
    call hex4
    mov si, offset s_15
    call pstr
    mov ax, word ptr [ax15]
    call hex4
    mov si, offset s_21
    call pstr
    mov ax, word ptr [ax21]
    call hex4
    mov si, offset s_2f
    call pstr
    mov ax, word ptr [ax2f]
    call hex4
    /* row 2 */
    mov di, ROW2
    mov si, offset ring
    mov cx, 8
8:  lodsw
    push cx
    call hex4
    pop cx
    mov al, ' '
    cmp cx, 1
    je 10f
    call pch
10: loop 8b
9:  pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    JMPFAR old08

/* al -> es:di with ATTR */
pch:
    mov ah, ATTR
    stosw
    ret
/* ds:si zero-terminated -> es:di */
pstr:
    lodsb
    or al, al
    jz 1f
    call pch
    jmp pstr
1:  ret
/* ax -> four hex digits at es:di */
hex4:
    mov cx, 4
    mov dx, ax
1:  rol dx, 4
    mov al, dl
    and al, 0x0f
    add al, '0'
    cmp al, '9'
    jbe 2f
    add al, 7
2:  call pch
    loop 1b
    ret

s_t:  .asciz " t:"
s_p:  .asciz " p:"
s_13: .asciz "13:"
s_15: .asciz " 15:"
s_21: .asciz " 21:"
s_2f: .asciz " 2F:"

resend:

/* ---------------- transient part ---------------- */
install:
    cld
    mov ax, 0x3508
    int 0x21
    mov si, offset sig
    mov di, si
    mov cx, 8
    repe cmpsb
    jne 1f
    mov dx, offset m_again
    mov ah, 9
    int 0x21
    mov ax, 0x4c01
    int 0x21
1:  mov word ptr [old08], bx
    mov word ptr [old08 + 2], es
    mov ax, 0x3513
    int 0x21
    mov word ptr [old13], bx
    mov word ptr [old13 + 2], es
    mov ax, 0x3515
    int 0x21
    mov word ptr [old15], bx
    mov word ptr [old15 + 2], es
    mov ax, 0x3521
    int 0x21
    mov word ptr [old21], bx
    mov word ptr [old21 + 2], es
    mov ax, 0x352f
    int 0x21
    mov word ptr [old2f], bx
    mov word ptr [old2f + 2], es
    /* DOS swappable data area: current PSP at SDA+10h */
    push ds
    mov ax, 0x5d06
    int 0x21
    jc 2f
    mov word ptr cs:[sda], si
    mov word ptr cs:[sda + 2], ds
2:  pop ds
    mov dx, offset int13
    mov ax, 0x2513
    int 0x21
    mov dx, offset int15
    mov ax, 0x2515
    int 0x21
    mov dx, offset int21
    mov ax, 0x2521
    int 0x21
    mov dx, offset int2f
    mov ax, 0x252f
    int 0x21
    mov dx, offset int08
    mov ax, 0x2508
    int 0x21
    mov dx, offset m_ok
    mov ah, 9
    int 0x21
    /* free the environment, stay resident up to resend */
    mov es, word ptr [0x2c]
    mov ah, 0x49
    int 0x21
    mov word ptr [0x2c], 0
    mov dx, offset resend + 15
    shr dx, 4
    mov ax, 0x3100
    int 0x21

m_ok:
    .ascii "USOSWHERE 1.0 resident: top right = CS:IP, ticks, PSP+name,\r\n"
    .ascii "last INT 13h/15h/21h/2Fh AX, last 8 CS values. GPL-3.0-or-later.\r\n$"
m_again:
    .ascii "USOSWHERE is already resident.\r\n$"
