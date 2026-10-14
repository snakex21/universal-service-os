/*
 * USOSMS1.DRV - BIOS pointing-device mouse driver for Windows 1.0x
 * (1.01-1.04), used for the USB mouse of a UEFI PC without a CSM.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Windows 1.0x ships drivers only for mice it drives itself (MOUSE.DRV:
 * Microsoft bus/InPort and serial, MSMOUSE1/2: Mouse Systems serial,
 * LMOUSE: Logitech serial). None of them uses the BIOS. Under CSMWrap the
 * USB mouse exists only as SeaBIOS's BIOS pointing device (INT 15h
 * AX=C2xxh): SeaBIOS polls it from its timer interrupt and far-calls the
 * C207h handler with each 3-byte PS/2 packet. This driver:
 *   - Inquire: initializes the BIOS pointing device (C205h, 3-byte
 *     packets); success = a mouse exists (MOUSEINFO of Windows 1.0x is 14
 *     bytes, filled like the shipped drivers fill it),
 *   - Enable: registers its own C207h handler (stores packets in a ring),
 *     enables the device (C200h), hooks INT 74h (IRQ 12; USOSKBC /M issues
 *     a software INT 74h after every packet the BIOS delivered from its
 *     timer) and INT 08h (the same without USOSKBC); both handlers chain
 *     the previous one first, then hand the queued packets to Windows,
 *   - Disable: device off (C200h), handler 0:0 (C207h), vectors back when
 *     still ours (otherwise the handlers stay as plain chains).
 * Movement is divided by the word after the "USM1" signature (default 2,
 * remainder carried); USER adds its own doubling above the thresholds.
 * Events go to the procedure USER passes to Enable with the register
 * interface of the shipped drivers: AX flags (1 move, 2/4 left down/up,
 * 8/10h right down/up), BX/CX relative movement (Y down positive), DX
 * number of buttons; called after the end of interrupt with interrupts
 * enabled, at most one dispatcher at a time.
 * The interface (exports INQUIRE 1, ENABLE 2, DISABLE 3; module MOUSE; the
 * MOUSEINFO size; the event registers) was read from the NE headers and
 * the code of the Windows 1.01/1.04 mouse drivers on the user's media; no
 * Microsoft code is used here. One fixed code segment that also holds the
 * data (no data segment, no imports, no relocations), like NOMOUSE.DRV.
 * Built with tools/build_win3_usb_keyboard.py (zig cc, linked at offset 0,
 * NE file written by the build script); docs/windows-early-2026-10-07.md.
 */
.intel_syntax noprefix
.code16
.section .text
.global seg_start
INFO_SIZE = 14                      /* MOUSEINFO of Windows 1.0x */
RING_N = 32                         /* packets, power of two */
seg_start:

/* MOUSEINFO (Windows 1.0x, 14 bytes) */
info:
m_exists:   .byte 0
m_relative: .byte 0
            .word 2                 /* buttons */
            .word 40                /* rate (reports per second) */
            .word 2, 2              /* X/Y threshold */
            .word 0, 0              /* X/Y resolution */
.if . - info - INFO_SIZE
.error "MOUSEINFO must be 14 bytes"
.endif

    .ascii "USM1"                   /* diagnostics: signature, version */
    .word 1
divisor:    .word 2                 /* movement / divisor, remainder carried
                                       (a USB mouse reports far more counts
                                       than a 1985 bus mouse) */
.global event_proc
event_proc: .long 0                 /* USER's mouse event procedure */
old08:      .long 0
old74:      .long 0
probed:     .byte 0
enabled:    .byte 0                 /* 1 device on, events to USER */
hooked:     .byte 0                 /* 1 our INT 08h/74h handlers in the IVT */
busy:       .byte 0
buttons:    .byte 0                 /* last state given to USER */
head:       .byte 0                 /* ring of 4-byte packets (status, X, Y) */
tail:       .byte 0
            .byte 0
.global packets
packets:    .word 0                 /* counters for diagnostics */
.global events
events:     .word 0
dropped:    .word 0
            .word 0
acc_x:      .word 0
acc_y:      .word 0
ring:       .fill RING_N * 4, 1, 0

/* INT 15h AX=C2xxh. In: AX, BH. Out: CF. */
bios_mouse:
    int 0x15
    ret

/* Ordinal 1: Inquire(LPMOUSEINFO) -> AX = bytes written. */
.global inquire
inquire:
    push bp
    mov bp, sp
    push ds
    push si
    push di
    push cs
    pop ds
    call probe
    les di, [bp + 6]
    mov si, offset info
    mov cx, INFO_SIZE
    cld
    rep movsb
    mov ax, INFO_SIZE
    pop di
    pop si
    pop ds
    pop bp
    .byte 0xca, 4, 0                /* retf 4 (16-bit far return) */

/* Once: is there a BIOS pointing device (C205h init, 3-byte packets)?
 * DS = CS. */
probe:
    cmp byte ptr [probed], 0
    jne 9f
    mov byte ptr [probed], 1
    mov ax, 0xc205
    mov bh, 3
    call bios_mouse
    jc 9f
    mov byte ptr [m_exists], 0xff
9:  ret

/* Ordinal 2: Enable(lpEventProc). */
.global enable
enable:
    push bp
    mov bp, sp
    push ds
    push es
    push si
    push di
    push cs
    pop ds
    mov ax, [bp + 6]
    mov word ptr [event_proc], ax
    mov ax, [bp + 8]
    mov word ptr [event_proc + 2], ax
    cmp byte ptr [enabled], 0
    jne 9f
    call probe
    cmp byte ptr [m_exists], 0
    je 9f
    mov ax, 0xc205
    mov bh, 3
    call bios_mouse
    jc 9f
    push cs
    pop es
    mov bx, offset callback
    mov ax, 0xc207
    call bios_mouse
    jc 8f
    mov ax, 0xc200
    mov bh, 1
    call bios_mouse
    jc 7f
    cli
    mov byte ptr [head], 0
    mov byte ptr [tail], 0
    mov byte ptr [buttons], 0
    mov word ptr [acc_x], 0
    mov word ptr [acc_y], 0
    call hook
    mov byte ptr [enabled], 1
    sti
    jmp 9f
7:  xor bx, bx                      /* C200h failed: handler off again */
    mov es, bx
    mov ax, 0xc207
    call bios_mouse
8:  mov byte ptr [m_exists], 0
9:  pop di
    pop si
    pop es
    pop ds
    pop bp
    .byte 0xca, 4, 0                /* retf 4 (16-bit far return) */

/* INT 08h and 74h to our handlers (once; later Enables reuse them).
 * DS = CS, interrupts off. */
hook:
    cmp byte ptr [hooked], 0
    jne 9f
    xor ax, ax
    mov es, ax
    mov ax, es:[0x08 * 4]
    mov word ptr [old08], ax
    mov ax, es:[0x08 * 4 + 2]
    mov word ptr [old08 + 2], ax
    mov ax, es:[0x74 * 4]
    mov word ptr [old74], ax
    mov ax, es:[0x74 * 4 + 2]
    mov word ptr [old74 + 2], ax
    mov word ptr es:[0x08 * 4], offset int08
    mov es:[0x08 * 4 + 2], cs
    mov word ptr es:[0x74 * 4], offset int74
    mov es:[0x74 * 4 + 2], cs
    mov byte ptr [hooked], 1
9:  ret

/* Ordinal 3: Disable. */
.global disable
disable:
    push ds
    push es
    push si
    push di
    push bp
    push cs
    pop ds
    cmp byte ptr [enabled], 0
    je 9f
    mov byte ptr [enabled], 0
    mov ax, 0xc200
    mov bh, 0
    call bios_mouse
    xor bx, bx
    mov es, bx
    mov ax, 0xc207
    call bios_mouse
    cli
    xor ax, ax
    mov es, ax
    /* Vectors back only when nobody hooked them after us. */
    cmp word ptr es:[0x08 * 4], offset int08
    jne 9f
    mov ax, cs
    cmp es:[0x08 * 4 + 2], ax
    jne 9f
    cmp word ptr es:[0x74 * 4], offset int74
    jne 9f
    cmp es:[0x74 * 4 + 2], ax
    jne 9f
    mov ax, word ptr [old08]
    mov es:[0x08 * 4], ax
    mov ax, word ptr [old08 + 2]
    mov es:[0x08 * 4 + 2], ax
    mov ax, word ptr [old74]
    mov es:[0x74 * 4], ax
    mov ax, word ptr [old74 + 2]
    mov es:[0x74 * 4 + 2], ax
    mov byte ptr [hooked], 0
9:  sti
    pop bp
    pop di
    pop si
    pop es
    pop ds
    .byte 0xcb                      /* retf */

/* C207h handler: the BIOS far-calls it with the status, X, Y and Z words
 * on the stack; only the ring is written (full ring: packet dropped). */
.global callback
callback:
    push bp
    mov bp, sp
    push ax
    push bx
    mov bl, byte ptr cs:[head]
    mov al, bl
    inc al
    and al, RING_N - 1
    cmp al, byte ptr cs:[tail]
    je 8f
    xor bh, bh
    shl bx, 2
    mov ah, byte ptr [bp + 12]      /* status */
    mov byte ptr cs:[ring + bx], ah
    mov ah, byte ptr [bp + 10]      /* X */
    mov byte ptr cs:[ring + bx + 1], ah
    mov ah, byte ptr [bp + 8]       /* Y */
    mov byte ptr cs:[ring + bx + 2], ah
    mov byte ptr cs:[head], al
    inc word ptr cs:[packets]
    jmp 9f
8:  inc word ptr cs:[dropped]
9:  pop bx
    pop ax
    pop bp
    .byte 0xcb                      /* retf */

/* IRQ 12 (a real PS/2 mouse: the BIOS reads it and calls the C207h
 * handler) or USOSKBC's software INT 74h: the previous handler first. */
.global int74
int74:
    pushf
    .att_syntax prefix
    lcallw *%cs:old74
    .intel_syntax noprefix
    jmp dispatch

/* Timer: the BIOS (SeaBIOS polls the USB mouse here) first. */
.global int08
int08:
    pushf
    .att_syntax prefix
    lcallw *%cs:old08
    .intel_syntax noprefix

/* Queued packets to USER's event procedure (interrupts off on entry). */
dispatch:
    cmp byte ptr cs:[busy], 0
    jne 1f
    cmp byte ptr cs:[enabled], 0
    je 1f
    push ax
    mov al, byte ptr cs:[head]
    cmp al, byte ptr cs:[tail]
    pop ax
    jne 2f
1:  iret
2:  mov byte ptr cs:[busy], 1
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es
    push cs
    pop ds
3:  cli
    mov bl, byte ptr [tail]
    cmp bl, byte ptr [head]
    je 6f
    xor bh, bh
    shl bx, 2
    mov al, byte ptr [ring + bx]    /* status */
    mov cl, byte ptr [ring + bx + 1]
    mov dl, byte ptr [ring + bx + 2]
    shr bx, 2
    inc bl
    and bl, RING_N - 1
    mov byte ptr [tail], bl
    sti
    test al, 0xc0                   /* overflow: no valid movement */
    jnz 3b
    mov ch, 0                       /* X: 9-bit two's complement */
    test al, 0x10
    jz 4f
    mov ch, 0xff
4:  mov dh, 0                       /* Y: up is positive in PS/2 */
    test al, 0x20
    jz 5f
    mov dh, 0xff
5:  add word ptr [acc_x], cx
    sub word ptr [acc_y], dx
    and al, 3                       /* left, right */
    cmp al, byte ptr [buttons]
    je 3b
    mov ah, byte ptr [buttons]
    mov byte ptr [buttons], al
    call button_flags
    call send
    jmp 3b
6:  sti
    xor ax, ax
    call send
    cli
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    mov byte ptr cs:[busy], 0
    iret

/* AL = new buttons, AH = old -> AX = button flags. */
button_flags:
    xor bx, bx
    mov cl, al
    xor cl, ah                      /* changed */
    test cl, 1
    jz 1f
    mov bx, 4                       /* left up */
    test al, 1
    jz 1f
    mov bx, 2                       /* left down */
1:  test cl, 2
    jz 2f
    or bx, 0x10                     /* right up */
    test al, 2
    jz 2f
    xor bx, 0x18                    /* right down */
2:  mov ax, bx
    ret

/* AX = button flags; the accumulated movement (divided) goes with them.
 * Nothing to report: no call, the movement stays accumulated. DS = CS. */
send:
    mov si, ax
    mov ax, word ptr [acc_x]
    cwd
    idiv word ptr [divisor]
    mov bx, ax
    mov word ptr [acc_x], dx        /* remainder stays for the next event */
    mov ax, word ptr [acc_y]
    cwd
    idiv word ptr [divisor]
    mov cx, ax
    mov word ptr [acc_y], dx
    mov ax, si
    mov dx, bx
    or dx, cx
    jz 1f
    or ax, 1
1:  test ax, ax
    jz 9f
    mov dx, 2                       /* buttons */
    inc word ptr [events]
    push ds
    .att_syntax prefix
    lcallw *event_proc
    .intel_syntax noprefix
    pop ds
9:  ret

.global seg_end
seg_end:
