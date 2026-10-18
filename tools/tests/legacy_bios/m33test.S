/*
 * M33TEST.COM - INT 33h probe for the DOS mouse QEMU test
 * (tools/tests/legacy_bios/run_dos_mouse_probe.py).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Resets the mouse driver (AX=0000h), shows its cursor (AX=0001h) and then
 * writes, about 18 times a second, one line at the top of the text screen
 * (B800:0000, no DOS output, so nothing scrolls):
 *   M33 I=FFFF N=0003 X=0140 Y=0064 B=0000 P=0001
 * I = reset result (FFFFh = driver present), N = buttons, X/Y = AX=0003h
 * position, B = its button state, P = AX=0005h press count of the left
 * button (accumulated). Any key ends it (cursor hidden again).
 * Built by the probe with zig cc + ld.lld at 0100h (src/platform/bios/msdos/com.ld).
 */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    /* No driver and a 0000:0000 vector (FreeDOS after VBMOUSE UNINSTALL):
     * show I=0000 without calling INT 33h. */
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, word ptr ds:[0x33 * 4]
    or ax, word ptr ds:[0x33 * 4 + 2]
    pop ds
    jz nodrv
    xor ax, ax
    int 0x33
    mov word ptr [inst], ax
    mov word ptr [nbtn], bx
    mov ax, 1
    int 0x33
next:
    mov ax, 3
    int 0x33
    mov word ptr [posx], cx
    mov word ptr [posy], dx
    mov word ptr [btns], bx
    mov ax, 5
    xor bx, bx
    int 0x33
    add word ptr [press], bx
    call show
    mov ah, 1
    int 0x16
    jnz done
    sti
    hlt
    jmp next
done:
    xor ah, ah
    int 0x16
    mov ax, 2
    int 0x33
    int 0x20
nodrv:
    call show
    mov ah, 1
    int 0x16
    jnz 1f
    sti
    hlt
    jmp nodrv
1:  xor ah, ah
    int 0x16
    int 0x20

/* Line: label bytes from 'text', each '#' run of 4 replaced by a value. */
show:
    push es
    mov ax, 0xb800
    mov es, ax
    xor di, di
    mov si, offset text
    mov bx, offset values
1:  lodsb
    or al, al
    jz 3f
    cmp al, '#'
    jne 2f
    mov dx, word ptr [bx]
    add bx, 2
    mov cx, 4
4:  rol dx, 4
    mov al, dl
    and al, 0x0f
    add al, '0'
    cmp al, '9'
    jbe 5f
    add al, 7
5:  mov ah, 0x1f
    stosw
    loop 4b
    jmp 1b
2:  mov ah, 0x1f
    stosw
    jmp 1b
3:  pop es
    ret

text:   .asciz "M33 I=# N=# X=# Y=# B=# P=# "
values:
inst:   .word 0
nbtn:   .word 0
posx:   .word 0
posy:   .word 0
btns:   .word 0
press:  .word 0
