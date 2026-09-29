/*
 * USOSKEY.COM - USB keyboard bridge for Windows 3.x under CSMWrap.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Under CSMWrap (UEFI PC without a CSM) the keyboard is USB and SeaBIOS
 * serves it from its timer interrupt: every raw set-1 byte (make, break,
 * E0/E1 prefixes) goes through SeaBIOS's process_key(), which calls the
 * INT 15h AH=4Fh keyboard intercept first. Windows 3.x KEYBOARD.DRV reads
 * the 8042 port and never sees those bytes. This TSR hooks INT 15h/4Fh and,
 * while the Windows side (USOSKEY.DRV) is polling, moves the bytes that did
 * NOT arrive through INT 09h (i.e. from USB) into a ring buffer and tells
 * SeaBIOS to drop them (CF clear). USOSKEY.DRV feeds them to Windows:
 * VKD_API_Force_Key in 386 enhanced mode, keybd_event in standard mode.
 * With no consumer (plain DOS, a full-screen DOS program in standard mode,
 * Windows gone) nothing is captured and SeaBIOS handles the keys as before.
 *
 * Shared block (found with INT 2Fh AX=D700h -> AL=FFh, BX=segment,
 * CX=offset, DX='UK'):
 *   +0  "USKY"      +4  version (1)
 *   +6  head (TSR)  +7  tail (consumer)     ring of 64 bytes at +16
 *   +8  alive: the consumer sets it on every poll; INT 1Ch counts it down,
 *       capture only while it is nonzero (about 1 s without a poll)
 *   +10 dropped (ring full)  +12 captured  +14 passed
 *   +80 forced / +82 refused: USOSKEY.DRV's VKD_API_Force_Key counters
 * Built with tools/build_win3_usb_keyboard.py (zig cc, linked at 0100h).
 */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    jmp install

    .p2align 1
shared:
    .ascii "USKY"
    .word 1
head:    .byte 0
tail:    .byte 0
alive:   .byte 0
         .byte 0
dropped: .word 0
captured: .word 0
passed:  .word 0
ring:    .space 64
forced:  .word 0                  /* written by USOSKEY.DRV (diagnostics) */
refused: .word 0
in9:     .byte 0
         .byte 0
old09:   .long 0
old15:   .long 0
old1c:   .long 0
old2f:   .long 0

/* INT 09h: mark keyboard-IRQ context, so INT 15h/4Fh from it passes. */
int09:
    inc byte ptr cs:[in9]
    pushf
    .att_syntax prefix
    lcallw *%cs:old09
    .intel_syntax noprefix
    dec byte ptr cs:[in9]
    iret

/* INT 1Ch: the consumer's heartbeat runs down. */
int1c:
    cmp byte ptr cs:[alive], 0
    je 1f
    dec byte ptr cs:[alive]
1:  .att_syntax prefix
    ljmpw *%cs:old1c
    .intel_syntax noprefix

/* INT 2Fh AX=D700h: installation check and shared block address. */
int2f:
    cmp ax, 0xd700
    jne 1f
    mov al, 0xff
    mov bx, cs
    mov cx, offset shared
    mov dx, 0x554b
    iret
1:  .att_syntax prefix
    ljmpw *%cs:old2f
    .intel_syntax noprefix

/* INT 15h AH=4Fh: capture USB-originated bytes while Windows polls. */
int15:
    cmp ah, 0x4f
    jne chain15
    /* No CF test on entry: SeaBIOS's USB path (call16 on CSMWrap's helper
     * core) arrives with CF clear and relies on the BIOS's own AH=4Fh
     * handler to set it; passed bytes go down the chain unchanged. */
    cmp byte ptr cs:[alive], 0
    je pass15
    cmp byte ptr cs:[in9], 0
    jne pass15                      /* came through INT 09h: 8042 / VKD */
    push bx
    push si
    mov bl, byte ptr cs:[head]
    mov bh, bl
    inc bh
    and bh, 63
    cmp bh, byte ptr cs:[tail]
    je full15
    mov si, bx
    and si, 0x00ff
    mov byte ptr cs:[ring + si], al
    mov byte ptr cs:[head], bh
    inc word ptr cs:[captured]
    pop si
    pop bx
    push bp
    mov bp, sp
    and byte ptr [bp + 6], 0xfe     /* CF clear in the caller's FLAGS: drop */
    pop bp
    iret
full15:
    inc word ptr cs:[dropped]
    pop si
    pop bx
pass15:
    inc word ptr cs:[passed]
chain15:
    .att_syntax prefix
    ljmpw *%cs:old15
    .intel_syntax noprefix

resident_end:

/* ---------------------------------------------------------------- install */
install:
    mov ax, 0xd700
    int 0x2f
    cmp al, 0xff
    jne 1f
    cmp dx, 0x554b
    jne 1f
    mov dx, offset msg_already
    mov ah, 9
    int 0x21
    mov ax, 0x4c00
    int 0x21
1:
    mov ax, 0x3509
    int 0x21
    mov word ptr [old09], bx
    mov word ptr [old09 + 2], es
    mov ax, 0x3515
    int 0x21
    mov word ptr [old15], bx
    mov word ptr [old15 + 2], es
    mov ax, 0x351c
    int 0x21
    mov word ptr [old1c], bx
    mov word ptr [old1c + 2], es
    mov ax, 0x352f
    int 0x21
    mov word ptr [old2f], bx
    mov word ptr [old2f + 2], es
    push cs
    pop ds
    mov dx, offset int09
    mov ax, 0x2509
    int 0x21
    mov dx, offset int15
    mov ax, 0x2515
    int 0x21
    mov dx, offset int1c
    mov ax, 0x251c
    int 0x21
    mov dx, offset int2f
    mov ax, 0x252f
    int 0x21
    /* Free the environment copy; keep the PSP and the resident part. */
    mov es, word ptr [0x2c]
    mov ah, 0x49
    int 0x21
    mov dx, offset msg_ok
    mov ah, 9
    int 0x21
    mov dx, offset resident_end
    add dx, 15
    shr dx, 4
    mov ax, 0x3100
    int 0x21

msg_ok:
    .ascii "USOSKEY: USB keyboard bridge for Windows 3.x installed (CSMWrap).\r\n$"
msg_already:
    .ascii "USOSKEY: already installed.\r\n$"
