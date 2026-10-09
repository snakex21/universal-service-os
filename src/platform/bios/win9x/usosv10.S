/*
 * USOSV10.COM - INT 10h on a private stack, for DOS programs with tiny stacks
 * under a video BIOS that needs a deep one (Windows 1.x/2.x WIN.COM logo on
 * the X470 under CSMWrap).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Why: WIN.COM of Windows 2.03 sets SP to the end of its 256-byte stack,
 * which sits directly behind its own code (CS:0F70-106F), and calls the logo
 * code (CGA.LGO) from CS:0F39. The logo calls INT 10h (AH=0Fh, AX=0006h,
 * AX=1000h/1001h, AH=02h/0Eh) with about 200 bytes of stack left above
 * WIN.COM's code. A 1987 CGA/EGA BIOS needs a few dozen bytes; a modern
 * option ROM (the RX 560 VBIOS under CSMWrap) needs more, so its stack frames
 * overwrite WIN.COM's code at 0F39-0F6E, the logo's final RETF lands on that
 * residue (0F6Dh) and the CPU slides through the stack area into an invalid
 * opcode (USOSWHERE 1.4: #UD at CS:0FADh with the logo's DS=CS+107h,
 * ES=B800h, BX=0007h). SeaVGABIOS in QEMU switches to its own stack, which
 * is why QEMU never showed it.
 *
 * What: a TSR that hooks INT 10h. Every outermost call runs the previous
 * handler on a 2 KiB stack inside this TSR; nested calls (an interrupt
 * handler calling INT 10h while the BIOS runs) chain directly, they are
 * already on that stack. For the functions that return nothing but AL/AX
 * (AH=00h-0Eh except 03h/04h, AX=1000h-1003h/1010h/1012h) BX, CX, DX, SI,
 * DI, BP, DS and ES are restored after the BIOS call, as a CGA/EGA BIOS
 * kept them. The arithmetic flags come back from the BIOS, IF/TF from the
 * caller. Only SS:SP differ inside the BIOS; no INT 10h function takes
 * parameters on the stack.
 *
 * The stack is filled with 5Ah at install; the deepest use since then is
 * printed by "USOSV10 /S" (and at install after a no-clear mode set of the
 * current text mode, the most expensive call we can make without changing
 * the screen).
 */
.intel_syntax noprefix
.code16
.equ STKSZ, 2048
.section .text
.global _start
_start:
    jmp install

sig:    .ascii "USOSV10A"
old10:  .long 0
oss:    .word 0
osp:    .word 0
rfl:    .word 0
tax:    .word 0
busy:   .byte 0
keep:   .byte 0
ncalls: .word 0

.macro JMPFAR x
    .byte 0x2e, 0xff, 0x2e
    .word \x
.endm
.macro CALLFAR x
    .byte 0x2e, 0xff, 0x1e
    .word \x
.endm

int10:
    cmp byte ptr cs:[busy], 0
    je 1f
    JMPFAR old10
1:  cli
    mov byte ptr cs:[busy], 1
    inc word ptr cs:[ncalls]
    mov word ptr cs:[oss], ss
    mov word ptr cs:[osp], sp
    mov word ptr cs:[tax], ax
    mov ax, cs
    mov ss, ax
    mov sp, offset stktop
    mov ax, word ptr cs:[tax]
    /* functions without outputs beyond AX: keep the other registers */
    mov byte ptr cs:[keep], 0
    cmp ah, 0x10
    jne 2f
    cmp al, 3
    jbe 3f
    cmp al, 0x10
    je 3f
    cmp al, 0x12
    je 3f
    jmp 4f
2:  cmp ah, 0x0e
    ja 4f
    cmp ah, 3
    je 4f
    cmp ah, 4
    je 4f
3:  mov byte ptr cs:[keep], 1
4:  push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es
    pushf
    CALLFAR old10
    pushf
    pop word ptr cs:[rfl]
    cmp byte ptr cs:[keep], 0
    je 5f
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    jmp 6f
5:  add sp, 16
6:  cli
    mov word ptr cs:[tax], ax
    mov ss, word ptr cs:[oss]
    mov sp, word ptr cs:[osp]
    /* caller's frame: IP, CS, FLAGS. BIOS result flags, caller's IF/TF */
    push bp
    mov bp, sp
    mov ax, word ptr cs:[rfl]
    and ax, 0xfcff
    and word ptr [bp + 6], 0x0300
    or word ptr [bp + 6], ax
    pop bp
    mov ax, word ptr cs:[tax]
    mov byte ptr cs:[busy], 0
    iret

/* private stack, 5Ah = never used */
stkbot:
    .space STKSZ, 0x5a
stktop:
resend:

/* ---- transient part ---- */

/* es = resident segment -> ax = deepest stack use in bytes */
depth:
    mov di, offset stkbot
    mov cx, STKSZ
    mov al, 0x5a
    cld
    repe scasb
    mov ax, cx
    jz 1f
    inc ax
1:  ret

/* ax -> 5 decimal digits (leading blanks) ending at ds:di */
dec5:
    push bx
    push cx
    push di
    mov bx, 10
    mov cx, 5
1:  xor dx, dx
    div bx
    add dl, '0'
    mov byte ptr [di], dl
    dec di
    dec cx
    or ax, ax
    jnz 1b
2:  jcxz 3f
    mov byte ptr [di], ' '
    dec di
    dec cx
    jmp 2b
3:  pop di
    pop cx
    pop bx
    ret

/* print the deepest stack use and the call count of the copy at es */
report:
    call depth
    mov di, offset m_num + 4
    call dec5
    mov ax, word ptr es:[ncalls]
    mov di, offset m_calls + 4
    call dec5
    mov dx, offset m_dep
    mov ah, 9
    int 0x21
    ret

install:
    cld
    mov ax, 0x3510
    int 0x21
    mov word ptr [old10], bx
    mov word ptr [old10 + 2], es
    /* already resident (we are the INT 10h handler): report only */
    mov si, offset sig
    mov di, si
    mov cx, 8
    repe cmpsb
    jne 1f
    mov dx, offset m_res
    mov ah, 9
    int 0x21
    call report
    mov ax, 0x4c00
    int 0x21
1:  mov dx, offset int10
    mov ax, 0x2510
    int 0x21
    push cs
    pop es
    /* self-test in a text mode: mode set without clearing (AL bit 7) */
    mov ah, 0x0f
    int 0x10
    and al, 0x7f
    cmp al, 3
    je 2f
    cmp al, 2
    je 2f
    cmp al, 7
    jne 3f
2:  push ax
    mov ah, 3
    int 0x10
    pop ax
    push dx
    push cx
    or al, 0x80
    xor ah, ah
    int 0x10
    pop cx
    mov ah, 1
    int 0x10
    pop dx
    xor bh, bh
    mov ah, 2
    int 0x10
3:  mov dx, offset m_ok
    mov ah, 9
    int 0x21
    call report
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
    .ascii "USOSV10 1.0 resident: INT 10h on its own 2 KiB stack. GPL-3.0-or-later.\r\n$"
m_res:
    .ascii "USOSV10 already resident.\r\n$"
m_dep:
    .ascii "USOSV10: deepest INT 10h stack use "
m_num:
    .ascii "    0 bytes of 2048 (WIN.COM 2.x leaves ~200), calls "
m_calls:
    .ascii "    0\r\n$"
