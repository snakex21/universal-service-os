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
 *   row 1  10:aaaa 13:aaaa 15:aaaa 21:aaaa 2F:aaaa
 *          AX of the last INT 10h mode set (AH=00h only), and of the last
 *          INT 13h, 15h, 21h and 2Fh call (INT 15h without AH=4Fh/90h/91h,
 *          which the keyboard and disk BIOS issue all the time)
 *   row 2  the last 8 distinct interrupted CS values, most recent first
 *   row 3  k:cccc:iiii n:nnnn  (1.2) CS:IP interrupted by the last keyboard
 *          IRQ (INT 09h) and the number of keyboard IRQs seen
 *   row 4  c:bbbbbbbbbbbbbbbb s:ssss:pppp d:eeii  (1.3) the 8 code bytes at
 *          the CS:IP of the last tick, the interrupted SS:SP and the DOS
 *          critical-error and InDOS flags (SDA+0/+1; InDOS 01 = inside a
 *          DOS call such as EXEC)
 *   row 5  w:aaaa bbbb cccc b:eeee:bbbb i:nnnn  (1.3) the top three words
 *          on the interrupted stack, ES:BX (buffer) of the last INT 13h
 *          call and the number of INT 13h calls (still growing = disk I/O
 *          goes on)
 *
 * Since 1.2 the corner is also redrawn from INT 09h, so pressing a key
 * (Shift, Ctrl) during a hang shows where the CPU is even when the timer
 * no longer reaches us (IRQ0 masked or INT 08h taken over without
 * chaining): k: changes with every key press, t: shows whether the timer
 * still runs. INT 09h is chained unchanged (Ctrl+Alt+Del still works).
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
 * Graphics is detected from the BDA mode byte and, since 1.1, also from the
 * VGA graphics controller (register 6 bit 0 set, 256-colour shift and
 * chain-4 off), so a program that switches to planar graphics through the
 * ports without INT 10h is covered too. Without a font pointer from INT 10h
 * AX=1130h the BIOS 8x8 font at F000:FA6Eh is used; the install message
 * prints the pointer in use.
 *
 * Since 1.2 /G also draws in the CGA 640x200 two-colour mode 06h (B800h,
 * interlaced), which the Windows 2.x logo code CGA.LGO uses (it sets mode
 * 6 and makes colour 0 blue); 1.1 drew nothing over that logo.
 *
 * 1.3 (Windows 2.03 on the X470: the loop was at 124A:0FAD, inside the
 * 256-byte stack of WIN.COM): rows 4 and 5 tell code from data at the
 * loop address and show whether DOS (EXEC) is still busy.
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
.equ ROW1, 41 - 40
.equ ROW2, 41 - 40
.equ ROW3, 41 - 40
.equ ROW4, 41 - 40
.equ ROW5, 41 - 40
.equ NROWS, 6
.section .text
.global _start
_start:
    jmp install

sig:    .ascii "USOSWHR1"
old08:  .long 0
old09:  .long 0
old10:  .long 0
old13:  .long 0
old15:  .long 0
old21:  .long 0
old2f:  .long 0
sda:    .long 0
ticks:  .word 0
ax10:   .word 0
ax13:   .word 0
ax15:   .word 0
ax21:   .word 0
ax2f:   .word 0
ring:   .space 16
gflag:  .byte 0
vmode:  .byte 0
font:   .long 0
lcs:    .word 0
lip:    .word 0
kcs:    .word 0
kip:    .word 0
kcnt:   .word 0
busy:   .byte 0
cbytes: .space 8
lss:    .word 0
lsp:    .word 0
stkw:   .space 6
es13:   .word 0
bx13:   .word 0
n13:    .word 0
/* six rows of 40 characters (screen columns 40-79), filled per tick */
scr:    .space 40 * NROWS, ' '

/* far jump through a dword at cs:[x] (FF /5 with a CS override) */
.macro JMPFAR x
    .byte 0x2e, 0xff, 0x2e
    .word \x
.endm

int10:
    pushf
    or ah, ah
    jnz 1f
    mov word ptr cs:[ax10], ax
1:  popf
    JMPFAR old10
int13:
    mov word ptr cs:[ax13], ax
    mov word ptr cs:[es13], es
    mov word ptr cs:[bx13], bx
    pushf
    inc word ptr cs:[n13]
    popf
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
    mov ax, word ptr [bp + 20]
    mov word ptr [lip], ax
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
    mov word ptr [lcs], ax
    /* 1.3: code bytes at CS:IP, interrupted SS:SP, top 3 stack words
     * (frame: FLAGS at bp+24, the interrupted stack starts at bp+26) */
    push ds
    lds si, dword ptr [bp + 20]
    mov di, offset cbytes
    movsw
    movsw
    movsw
    movsw
    pop ds
    mov word ptr [lss], ss
    lea si, [bp + 26]
    mov word ptr [lsp], si
    push ds
    push ss
    pop ds
    mov di, offset stkw
    movsw
    movsw
    movsw
    pop ds
    call draw
    jmp regout

/* keyboard IRQ: remember the interrupted CS:IP, redraw, chain */
int09:
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
    cld
    push cs
    pop ds
    inc word ptr [kcnt]
    mov ax, word ptr [bp + 20]
    mov word ptr [kip], ax
    mov ax, word ptr [bp + 22]
    mov word ptr [kcs], ax
    call draw
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    JMPFAR old09

/* build the four rows from the saved values and put them on the screen
 * (ds = cs, direction flag clear); not re-entered */
draw:
    cmp byte ptr [busy], 0
    jne 14f
    mov byte ptr [busy], 1
    push 0x40
    pop es
    mov al, byte ptr es:[0x49]
    mov byte ptr [vmode], al
    cmp al, 3
    jbe 13f
    cmp al, 6
    je 15f
    call gmode
    jc 9f
    jmp 11f
15: cmp byte ptr [gflag], 0
    je 9f
    cmp word ptr [font + 2], 0
    je 9f
    jmp 11f
    /* text mode by the BDA: planar graphics set through the ports? */
13: call gport
    jc 11f
    mov byte ptr [vmode], 0x12
11: push cs
    pop es
    /* row 0 */
    mov di, offset scr + ROW0
    mov ax, word ptr [lcs]
    call hex4
    mov al, ':'
    call pch
    mov ax, word ptr [lip]
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
    mov si, offset s_10
    call pstr
    mov ax, word ptr [ax10]
    call hex4
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
    /* row 3 */
    mov di, offset scr + 120 + ROW3
    mov si, offset s_k
    call pstr
    mov ax, word ptr [kcs]
    call hex4
    mov al, ':'
    call pch
    mov ax, word ptr [kip]
    call hex4
    mov si, offset s_n
    call pstr
    mov ax, word ptr [kcnt]
    call hex4
    /* row 4 */
    mov di, offset scr + 160 + ROW4
    mov si, offset s_c
    call pstr
    mov si, offset cbytes
    mov bx, 8
17: lodsb
    call hex2
    dec bx
    jnz 17b
    mov si, offset s_s
    call pstr
    mov ax, word ptr [lss]
    call hex4
    mov al, ':'
    call pch
    mov ax, word ptr [lsp]
    call hex4
    mov si, offset s_d
    call pstr
    mov ax, 0xffff
    cmp word ptr [sda + 2], 0
    je 18f
    push es
    les bx, dword ptr [sda]
    mov ax, word ptr es:[bx]
    pop es
    xchg ah, al
18: call hex4
    /* row 5 */
    mov di, offset scr + 200 + ROW5
    mov si, offset s_w
    call pstr
    mov si, offset stkw
    mov bx, 3
19: lodsw
    call hex4
    mov al, ' '
    call pch
    dec bx
    jnz 19b
    mov si, offset s_b
    call pstr
    mov ax, word ptr [es13]
    call hex4
    mov al, ':'
    call pch
    mov ax, word ptr [bx13]
    call hex4
    mov si, offset s_i
    call pstr
    mov ax, word ptr [n13]
    call hex4
    cmp byte ptr [vmode], 3
    ja 12f
    call textout
    jmp 9f
12: cmp byte ptr [vmode], 6
    jne 16f
    call cgaout
    jmp 9f
16: call gfxout
9:  mov byte ptr [busy], 0
14: ret

regout:
    pop es
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

/* CF clear when /G was given, a font is known and the VGA graphics
 * controller is in planar graphics (GC 6 bit 0 set, GC 5 bit 6 clear,
 * sequencer 4 bit 3 clear); the index registers are restored */
gport:
    cmp byte ptr [gflag], 0
    je 1f
    cmp word ptr [font + 2], 0
    je 1f
    mov dx, 0x3ce
    in al, dx
    mov ah, al
    mov al, 6
    out dx, al
    inc dx
    in al, dx
    mov bl, al
    dec dx
    mov al, 5
    out dx, al
    inc dx
    in al, dx
    mov bh, al
    dec dx
    mov al, ah
    out dx, al
    mov dx, 0x3c4
    in al, dx
    mov ah, al
    mov al, 4
    out dx, al
    inc dx
    in al, dx
    mov cl, al
    dec dx
    mov al, ah
    out dx, al
    test bl, 1
    jz 1f
    test bh, 0x40
    jnz 1f
    test cl, 8
    jnz 1f
    clc
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
    call 1f
    mov si, offset scr + 120 + ROW3
    mov di, (3 * 80 + 40 + ROW3) * 2
    mov cx, 40 - ROW3
    call 1f
    mov si, offset scr + 160 + ROW4
    mov di, (4 * 80 + 40 + ROW4) * 2
    mov cx, 40 - ROW4
    call 1f
    mov si, offset scr + 200 + ROW5
    mov di, (5 * 80 + 40 + ROW5) * 2
    mov cx, 40 - ROW5
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
    mov bp, NROWS
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

/* the buffer to B800h in CGA mode 06h (640x200, one bit per pixel, even
 * scan lines at 0000h, odd ones at 2000h, 80 bytes per line): 4 rows of
 * 8 scan lines = 320 bytes per text row in each bank */
cgaout:
    push 0xb800
    pop es
    mov si, offset scr
    mov di, 40
    mov bp, NROWS
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
    mov cx, 4
4:  lodsb
    mov byte ptr es:[di], al
    lodsb
    mov byte ptr es:[di + 0x2000], al
    add di, 80
    loop 4b
    pop di
    pop si
    pop ds
    inc di
    dec dx
    jnz 2b
    add di, 320 - 40
    dec bp
    jnz 1b
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
/* al -> two hex digits at es:di */
hex2:
    mov ah, al
    mov cx, 2
    mov dx, ax
    jmp 1f
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
s_10: .asciz "10:"
s_13: .asciz " 13:"
s_15: .asciz " 15:"
s_21: .asciz " 21:"
s_2f: .asciz " 2F:"
s_k:  .asciz "k:"
s_n:  .asciz " n:"
s_c:  .asciz "c:"
s_s:  .asciz " s:"
s_d:  .asciz " d:"
s_w:  .asciz "w:"
s_b:  .asciz "b:"
s_i:  .asciz " i:"

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
    cmp word ptr [font + 2], 0
    jne 5f
    mov word ptr [font], 0xfa6e
    mov word ptr [font + 2], 0xf000
5:  push es
    push cs
    pop es
    mov di, offset m_fseg
    mov ax, word ptr [font + 2]
    call hex4
    inc di
    mov ax, word ptr [font]
    call hex4
    pop es
    mov dx, offset m_font
    mov ah, 9
    int 0x21
3:  mov word ptr [old08], bx
    mov word ptr [old08 + 2], es
    mov ax, 0x3509
    int 0x21
    mov word ptr [old09], bx
    mov word ptr [old09 + 2], es
    mov ax, 0x3510
    int 0x21
    mov word ptr [old10], bx
    mov word ptr [old10 + 2], es
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
    mov dx, offset int10
    mov ax, 0x2510
    int 0x21
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
    mov dx, offset int09
    mov ax, 0x2509
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
    .ascii "USOSWHERE 1.3 resident: top right = CS:IP, ticks, PSP+name,\r\n"
    .ascii "last INT 10h mode set + 13h/15h/21h/2Fh AX, last 8 CS values,\r\n"
    .ascii "k: CS:IP at the last key press (press Shift during a hang),\r\n"
    .ascii "c: code bytes at CS:IP, SS:SP, d: InDOS, w: stack, INT 13h.\r\n"
    .ascii "GPL-3.0-or-later. /G: also CGA mode 6 + EGA/VGA 16 colours.\r\n$"
m_font:
    .ascii "USOSWHERE /G font "
m_fseg:
    .ascii "SSSS:OOOO\r\n$"
m_again:
    .ascii "USOSWHERE is already resident.\r\n$"
