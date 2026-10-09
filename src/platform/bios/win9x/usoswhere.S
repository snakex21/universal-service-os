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
 * /G also draws the three rows in the 16-colour planar graphics modes
 * 0Eh, 10h, 11h and 12h (EGA/VGA, 80 bytes per scan line; white on black,
 * 8x8 BIOS font from INT 10h AX=1130h, top right 320x24 pixels), e.g. over
 * the Windows 2.x logo. It saves and restores the VGA sequencer map mask
 * and the graphics controller registers 1, 3, 5 and 8 and both index
 * registers around the drawing (VGA: readable; not for a real EGA).
 *
 * The hooks change no register and no flag before chaining. Running it a
 * second time only prints a message. It cannot be unloaded (reboot).
 *
 * Built with tools/build_win9x_support.py (zig cc, linked at 0100h).
 */
.intel_syntax noprefix
.code16
.equ ATTR, 0x1f
.equ ROW0, 8
.equ ROW1, 49 - 40
.equ ROW2, 41 - 40
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
gflag:  .byte 0
vmode:  .byte 0
font:   .long 0
/* three rows of 40 characters (screen columns 40-79), filled per tick */
scr:    .space 120, ' '

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
    mov byte ptr [vmode], al
    cmp al, 3
    jbe 11f
    call gmode
    jc 9f
11: push cs
    pop es
    /* row 0 */
    mov di, offset scr + ROW0
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
    mov di, offset scr + 40 + ROW1
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
    mov di, offset scr + 80 + ROW2
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
    cmp byte ptr [vmode], 3
    ja 12f
    call textout
    jmp 9f
12: call gfxout
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

/* CF clear when [vmode] is a planar 80-byte mode, /G was given and the
 * font is known */
gmode:
    cmp byte ptr [gflag], 0
    je 1f
    cmp word ptr [font + 2], 0
    je 1f
    mov al, byte ptr [vmode]
    cmp al, 0x0e
    je 2f
    cmp al, 0x10
    jb 1f
    cmp al, 0x12
    ja 1f
2:  clc
    ret
1:  stc
    ret

/* the buffer rows to B800h, same columns as before (row starts ROWn) */
textout:
    push 0xb800
    pop es
    mov si, offset scr + ROW0
    mov di, (0 * 80 + 40 + ROW0) * 2
    mov cx, 40 - ROW0
    call 1f
    mov si, offset scr + 40 + ROW1
    mov di, (1 * 80 + 40 + ROW1) * 2
    mov cx, 40 - ROW1
    call 1f
    mov si, offset scr + 80 + ROW2
    mov di, (2 * 80 + 40 + ROW2) * 2
    mov cx, 40 - ROW2
1:  lodsb
    mov ah, ATTR
    stosw
    loop 1b
    ret

/* dx = index port, bl = index, bh = new value -> al = old value */
vreg:
    mov al, bl
    out dx, al
    inc dx
    in al, dx
    xchg al, bh
    out dx, al
    dec dx
    mov al, bh
    ret

/* the buffer to A000h: write mode 0, all planes, bit mask FFh, so each
 * font byte gives white (1) and black (0) pixels */
gfxout:
    mov dx, 0x3c4
    in al, dx
    push ax
    mov bx, 0x0f02
    call vreg
    push ax
    mov dx, 0x3ce
    in al, dx
    push ax
    mov bx, 0x0001
    call vreg
    push ax
    mov bx, 0x0003
    call vreg
    push ax
    mov bx, 0x0005
    call vreg
    push ax
    mov bx, 0xff08
    call vreg
    push ax
    push 0xa000
    pop es
    mov si, offset scr
    mov di, 40
    mov bp, 3
1:  mov dx, 40
2:  lodsb
    cmp al, 0x80
    jb 3f
    mov al, '.'
3:  xor ah, ah
    shl ax, 3
    push ds
    push si
    push di
    lds si, dword ptr cs:[font]
    add si, ax
    mov cx, 8
4:  lodsb
    mov byte ptr es:[di], al
    add di, 80
    loop 4b
    pop di
    pop si
    pop ds
    inc di
    dec dx
    jnz 2b
    add di, 8 * 80 - 40
    dec bp
    jnz 1b
    mov dx, 0x3ce
    pop ax
    mov bh, al
    mov bl, 8
    call vreg
    pop ax
    mov bh, al
    mov bl, 5
    call vreg
    pop ax
    mov bh, al
    mov bl, 3
    call vreg
    pop ax
    mov bh, al
    mov bl, 1
    call vreg
    pop ax
    out dx, al
    mov dx, 0x3c4
    pop ax
    mov bh, al
    mov bl, 2
    call vreg
    pop ax
    out dx, al
    ret

/* al -> es:di (the row buffer) */
pch:
    stosb
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
1:  /* /G: also draw in the planar graphics modes */
    mov si, 0x81
    mov cl, byte ptr [0x80]
    xor ch, ch
    jcxz 3f
4:  lodsb
    or al, 0x20
    cmp al, 'g'
    loopne 4b
    jne 3f
    mov byte ptr [gflag], 1
    push es
    push bx
    push bp
    mov ax, 0x1130
    mov bh, 3
    int 0x10
    mov word ptr [font], bp
    mov word ptr [font + 2], es
    pop bp
    pop bx
    pop es
3:  mov word ptr [old08], bx
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
    .ascii "last INT 13h/15h/21h/2Fh AX, last 8 CS values. GPL-3.0-or-later.\r\n"
    .ascii "/G: also in EGA/VGA 16-colour graphics modes.\r\n$"
m_again:
    .ascii "USOSWHERE is already resident.\r\n$"
