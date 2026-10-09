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
 *   row 3  k:cccc:iiii n:nnnn x:xxxx f:ffff  (1.2) CS:IP interrupted by the
 *          last keyboard IRQ (INT 09h) and the number of keyboard IRQs seen;
 *          (1.4) traced instructions and AX of the INT 21h that ended the
 *          trace (see below)
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
 * 1.4 (D5 with 1.3: 1263:0FAD, code bytes 0F 00 00 .. = SLDT, #UD in real
 * mode; the default INT 06h handler of SeaBIOS/CSMWrap is a bare IRET, so the
 * CPU faults on the same instruction forever while the timer ticks; the
 * stack was empty, SS:SP 1263:106F, InDOS 0, PSP still WIN.COM, no INT 21h
 * after the EXEC 4B00h):
 *   - INT 06h (#UD) handler: on the first invalid opcode it switches to text
 *     mode 3 and dumps one screen: the faulting CS:IP and FLAGS, all
 *     registers, 8 code bytes, 8 stack words, and the last 176 instruction
 *     addresses (oldest first, 8 per row) before the fault; then it halts
 *     with interrupts on (Ctrl+Alt+Del works).
 *   - instruction trace: when the DOS EXEC (INT 21h AX=4B00h) is called by a
 *     program whose MCB name starts with WIN (WIN.COM starting WIN200.BIN),
 *     the trap flag is set for DOS and for the caller; INT 01h records every
 *     CS:IP (consecutive repeats once) in a ring of 176 entries. BIOS and
 *     option ROM code (CS >= C000h) runs untraced (TF cleared, the caller's
 *     IRET restores it), our own code is not recorded. The first INT 21h
 *     after that (the child's first DOS call, or the caller after a failed
 *     EXEC) stops the trace: f: = its AX and caller CS:IP. Without an INT 21h
 *     or a #UD within 10 s the timer dumps the same screen (reason T).
 *   - row 3 of the corner adds x: (traced steps) and f: (that INT 21h AX).
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
/* 1.4: trace ring entries (22 rows of 8 on the dump screen) */
.equ RINGN, 176
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
/* 1.4: #UD dump and EXEC trace */
trarm:  .byte 0         /* 0 idle, 1 tracing, 2 trace ended, 3 dumped */
dreason: .byte 0
armt:   .word 0
tcnt:   .word 0
rhead:  .word 0
rnum:   .word 0
udcnt:  .word 0
f21ax:  .word 0
f21ip:  .word 0
f21cs:  .word 0
u_ip:   .word 0
u_cs:   .word 0
u_fl:   .word 0
/* r_ax..r_es in the order of s_regs; r_sp, r_ss adjacent (lds) */
r_ax:   .word 0
r_bx:   .word 0
r_cx:   .word 0
r_dx:   .word 0
r_si:   .word 0
r_di:   .word 0
r_bp:   .word 0
r_ds:   .word 0
r_es:   .word 0
r_sp:   .word 0
r_ss:   .word 0
ucode:  .space 8
ustk:   .space 16
dpos:   .word 0
dleft:  .word 0
dcol:   .byte 0
/* six rows of 40 characters (screen columns 40-79), filled per tick */
scr:    .space 40 * NROWS, ' '

/* far jump through a dword at cs:[x] (FF /5 with a CS override) */
.macro JMPFAR x
    .byte 0x2e, 0xff, 0x2e
    .word \x
.endm
/* far call through a dword at cs:[x] (FF /3 with a CS override; the
 * assembler would add a 66h prefix to "call dword ptr") */
.macro CALLFAR x
    .byte 0x2e, 0xff, 0x1e
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
    cmp byte ptr cs:[trarm], 1
    je 5f
    ja 9f
    cmp ax, 0x4b00
    jne 9f
    call iswin
    jne 9f
    /* WIN* starts its child: trace DOS (TF now) and the caller after the
     * IRET of DOS (TF in its saved FLAGS) */
    mov byte ptr cs:[trarm], 1
    mov word ptr cs:[armt], 0
    push bp
    mov bp, sp
    or word ptr [bp + 6], 0x100
    pop bp
    push ax
    pushf
    pop ax
    or ah, 1
    push ax
    popf
    pop ax
    JMPFAR old21
    /* tracing and a new DOS call: the trace ends here */
5:  mov word ptr cs:[f21ax], ax
    push bp
    mov bp, sp
    push ax
    mov ax, word ptr [bp + 2]
    mov word ptr cs:[f21ip], ax
    mov ax, word ptr [bp + 4]
    mov word ptr cs:[f21cs], ax
    and word ptr [bp + 6], 0xfeff
    mov byte ptr cs:[trarm], 2
    pushf
    pop ax
    and ah, 0xfe
    push ax
    popf
    pop ax
    pop bp
9:  JMPFAR old21

/* ZF set when the current PSP belongs to a program named WIN* */
iswin:
    cmp word ptr cs:[sda + 2], 0
    jne 1f
    cmp sp, 0
    ret
1:  push ds
    push bx
    lds bx, dword ptr cs:[sda]
    mov bx, word ptr [bx + 0x10]
    dec bx
    mov ds, bx
    cmp word ptr ds:[8], 0x4957
    jne 2f
    cmp byte ptr ds:[10], 'N'
2:  pop bx
    pop ds
    ret

/* single step: record CS:IP of the next instruction */
int01:
    push bp
    mov bp, sp
    push ax
    push bx
    push si
    push ds
    push cs
    pop ds
    cmp byte ptr [trarm], 1
    jne 8f
    mov ax, word ptr [bp + 4]
    cmp ax, 0xc000
    jae 8f
    mov bx, cs
    cmp ax, bx
    je 9f
    inc word ptr [tcnt]
    mov bx, word ptr [rhead]
    cmp word ptr [rnum], 0
    je 3f
    mov si, bx
    sub si, 4
    jnc 1f
    add si, RINGN * 4
1:  mov ax, word ptr [bp + 2]
    cmp word ptr [si + ring2], ax
    jne 3f
    mov ax, word ptr [bp + 4]
    cmp word ptr [si + ring2 + 2], ax
    je 9f
3:  mov ax, word ptr [bp + 2]
    mov word ptr [bx + ring2], ax
    mov ax, word ptr [bp + 4]
    mov word ptr [bx + ring2 + 2], ax
    add bx, 4
    cmp bx, RINGN * 4
    jb 4f
    xor bx, bx
4:  mov word ptr [rhead], bx
    cmp word ptr [rnum], RINGN
    jae 9f
    inc word ptr [rnum]
    jmp 9f
    /* not tracing, or BIOS/ROM code: TF off (an IRET restores the caller's) */
8:  and word ptr [bp + 6], 0xfeff
9:  pop ds
    pop si
    pop bx
    pop ax
    pop bp
    iret

/* invalid opcode: dump once, then halt with interrupts on */
int06:
    mov word ptr cs:[r_ax], ax
    mov word ptr cs:[r_bx], bx
    mov word ptr cs:[r_cx], cx
    mov word ptr cs:[r_dx], dx
    mov word ptr cs:[r_si], si
    mov word ptr cs:[r_di], di
    mov word ptr cs:[r_bp], bp
    mov word ptr cs:[r_ds], ds
    mov word ptr cs:[r_es], es
    mov word ptr cs:[r_ss], ss
    mov bp, sp
    lea ax, [bp + 6]
    mov word ptr cs:[r_sp], ax
    mov ax, word ptr [bp]
    mov word ptr cs:[u_ip], ax
    mov ax, word ptr [bp + 2]
    mov word ptr cs:[u_cs], ax
    mov ax, word ptr [bp + 4]
    mov word ptr cs:[u_fl], ax
    inc word ptr cs:[udcnt]
    cmp byte ptr cs:[trarm], 3
    je 1f
    push cs
    pop ds
    push cs
    pop es
    cld
    mov byte ptr [dreason], 'U'
    call dump
1:  sti
2:  hlt
    jmp 2b
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
    /* 1.4: trace running for 10 s without a DOS call or #UD: dump */
    cmp byte ptr [trarm], 1
    jne regout
    inc word ptr [armt]
    cmp word ptr [armt], 182
    jb regout
    mov ax, word ptr [bp + 20]
    mov word ptr [u_ip], ax
    mov ax, word ptr [bp + 22]
    mov word ptr [u_cs], ax
    mov ax, word ptr [bp + 24]
    mov word ptr [u_fl], ax
    /* saved ax at bp+16 ... es at bp+0 = r_ax ... r_es */
    mov si, offset r_ax
    mov di, 16
21: mov ax, word ptr [bp + di]
    mov word ptr [si], ax
    add si, 2
    sub di, 2
    jns 21b
    mov word ptr [r_ss], ss
    lea ax, [bp + 26]
    mov word ptr [r_sp], ax
    /* chain first (EOI), then dump and halt */
    pushf
    CALLFAR old08
    push cs
    pop ds
    push cs
    pop es
    cld
    mov byte ptr [dreason], 'T'
    call dump
    sti
22: hlt
    jmp 22b

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
    mov si, offset s_x
    call pstr
    mov ax, word ptr [tcnt]
    call hex4
    mov si, offset s_f
    call pstr
    mov ax, word ptr [f21ax]
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

/* 1.4: one text screen with the fault, registers and the trace ring
 * (ds = es = cs, direction flag clear); the corner is no longer drawn */
dump:
    mov byte ptr [busy], 1
    mov byte ptr [trarm], 3
    push ds
    lds si, dword ptr cs:[u_ip]
    mov di, offset ucode
    mov cx, 8
    rep movsb
    pop ds
    push ds
    lds si, dword ptr cs:[r_sp]
    mov di, offset ustk
    mov cx, 16
    rep movsb
    pop ds
    mov ax, 3
    int 0x10
    /* row 0 */
    call lclr
    mov si, offset s_h
    call pstr
    mov al, byte ptr [dreason]
    call pch
    mov si, offset s_at
    call pstr
    mov ax, word ptr [u_cs]
    call hex4
    mov al, ':'
    call pch
    mov ax, word ptr [u_ip]
    call hex4
    mov si, offset s_fl
    call pstr
    mov ax, word ptr [u_fl]
    call hex4
    mov si, offset s_x
    call pstr
    mov ax, word ptr [tcnt]
    call hex4
    mov si, offset s_u
    call pstr
    mov ax, word ptr [udcnt]
    call hex4
    mov si, offset s_f
    call pstr
    mov ax, word ptr [f21ax]
    call hex4
    mov al, '@'
    call pch
    mov ax, word ptr [f21cs]
    call hex4
    mov al, ':'
    call pch
    mov ax, word ptr [f21ip]
    call hex4
    mov si, offset s_p
    call pstr
    xor ax, ax
    cmp word ptr [sda + 2], 0
    je 1f
    push es
    les bx, dword ptr [sda]
    mov ax, word ptr es:[bx + 0x10]
    pop es
1:  call hex4
    xor bx, bx
    call rowout
    /* row 1: registers */
    call lclr
    mov si, offset r_ax
    mov bx, offset s_regs
2:  mov al, byte ptr [bx]
    call pch
    mov al, byte ptr [bx + 1]
    call pch
    mov al, ':'
    call pch
    lodsw
    call hex4
    mov al, ' '
    call pch
    add bx, 2
    cmp si, offset r_sp
    jb 2b
    mov bx, 1
    call rowout
    /* row 2: code bytes, SS:SP, stack words */
    call lclr
    mov si, offset s_c
    call pstr
    mov si, offset ucode
    mov bx, 8
3:  lodsb
    call hex2
    dec bx
    jnz 3b
    mov si, offset s_s
    call pstr
    mov ax, word ptr [r_ss]
    call hex4
    mov al, ':'
    call pch
    mov ax, word ptr [r_sp]
    call hex4
    mov si, offset s_ww
    call pstr
    mov si, offset ustk
    mov bx, 8
4:  lodsw
    call hex4
    mov al, ' '
    call pch
    dec bx
    jnz 4b
    mov bx, 2
    call rowout
    /* rows 3-24: the trace ring, oldest first */
    mov ax, word ptr [rnum]
    mov word ptr [dleft], ax
    shl ax, 2
    mov si, word ptr [rhead]
    sub si, ax
    jnc 5f
    add si, RINGN * 4
5:  mov word ptr [dpos], si
    mov bx, 3
6:  cmp word ptr [dleft], 0
    je 9f
    call lclr
    mov byte ptr [dcol], 8
7:  cmp word ptr [dleft], 0
    je 8f
    mov si, word ptr [dpos]
    mov ax, word ptr [si + ring2 + 2]
    call hex4
    mov al, ':'
    call pch
    mov si, word ptr [dpos]
    mov ax, word ptr [si + ring2]
    call hex4
    mov al, ' '
    call pch
    add word ptr [dpos], 4
    cmp word ptr [dpos], RINGN * 4
    jb 10f
    mov word ptr [dpos], 0
10: dec word ptr [dleft]
    dec byte ptr [dcol]
    jnz 7b
8:  call rowout
    inc bx
    cmp bx, 25
    jb 6b
9:  ret

/* lbuf = 80 spaces, di = lbuf */
lclr:
    push ax
    push cx
    mov di, offset lbuf
    mov cx, 80
    mov al, ' '
    rep stosb
    mov di, offset lbuf
    pop cx
    pop ax
    ret

/* lbuf -> text row bx (B800h, grey on black) */
rowout:
    push es
    push ax
    push cx
    push dx
    push si
    push di
    mov ax, 160
    mul bx
    mov di, ax
    push 0xb800
    pop es
    mov si, offset lbuf
    mov cx, 80
    mov ah, 0x07
1:  lodsb
    stosw
    loop 1b
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    pop es
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
s_x:  .asciz " x:"
s_f:  .asciz " f:"
s_h:  .asciz "USOSWHERE 1.4 "
s_at: .asciz " at "
s_fl: .asciz " fl:"
s_u:  .asciz " u:"
s_ww: .asciz " w:"
s_regs: .ascii "axbxcxdxsidibpdses"

resend:
/* 1.4: trace ring and dump line buffer, resident but not in the file (they
 * overlay the transient part below once it has run) */
.set ring2, resend
.set lbuf, resend + RINGN * 4
.set resall, lbuf + 80

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
    mov dx, offset int01
    mov ax, 0x2501
    int 0x21
    mov dx, offset int06
    mov ax, 0x2506
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
    mov dx, offset resall + 15
    shr dx, 4
    mov ax, 0x3100
    int 0x21

m_ok:
    .ascii "USOSWHERE 1.4 resident: top right = CS:IP, ticks, PSP+name,\r\n"
    .ascii "last INT 10h mode set + 13h/15h/21h/2Fh AX, last 8 CS values,\r\n"
    .ascii "k: CS:IP at the last key press (press Shift during a hang),\r\n"
    .ascii "c: code bytes at CS:IP, SS:SP, d: InDOS, w: stack, INT 13h.\r\n"
    .ascii "#UD (INT 06h) or 10 s trace after the EXEC of WIN: dump screen.\r\n"
    .ascii "GPL-3.0-or-later. /G: also CGA mode 6 + EGA/VGA 16 colours.\r\n$"
m_font:
    .ascii "USOSWHERE /G font "
m_fseg:
    .ascii "SSSS:OOOO\r\n$"
m_again:
    .ascii "USOSWHERE is already resident.\r\n$"
