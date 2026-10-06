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
 *   version 2 (diagnostics for USOSDBG.EXE, src/platform/bios/win9x):
 *   +84 polls: USOSKEY.DRV timer polls (the DRV writes it only from v2 on)
 *   +86 last INT 15h/4Fh byte (AL), +87 its in9 state
 *   +88 INT 08h hits seen in the real-mode/V86 vector chain (dword)
 *   +92 INT 1Ch hits (dword)    +96 INT 15h/4Fh calls, all (dword)
 *   +100 INT 15h/4Fh calls not from INT 09h, i.e. USB (dword)
 *   +104 SS:SP (+104 SP, +106 SS) at the last INT 08h
 *   +108 SS:SP (+108 SP, +110 SS) at the last USB INT 15h/4Fh
 *   version 3 (2026-10-06 X470 98 SE: Ctrl+C/V/Z dead, F5 once):
 *   +112 INT 16h guard counters, 10 words: [0] AH=00h chained, [1] AH=01h
 *        answered (BIOS buffer empty), [2] AH=01h chained (key waiting),
 *        [3] AH=02h answered, [4] AH=10h chained, [5] AH=11h answered,
 *        [6] AH=11h chained, [7] AH=12h answered, [8] other AH chained,
 *        all while the consumer is alive; [9] any INT 16h while it is not
 *   +132 AX, +134 IP, +136 CS of the last INT 16h while alive
 *   +138 keybd_event log sequence (USOSKEY.DRV): entry = seq & 31
 *   +140 32 entries of 8 bytes, written by USOSKEY.DRV: VK, AH (80h key
 *        up), scan (BL), BH (1 = extended), GetAsyncKeyState(VK_CONTROL)
 *        and (VK_SHIFT) right after (80h down, 01h pressed since the last
 *        call), 0040:0017 and 0040:0018 after the call
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
    .word 3
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
polls:   .word 0                  /* written by USOSKEY.DRV (v2) */
last4f:  .byte 0
last4f9: .byte 0
c08:     .long 0
c1c:     .long 0
c4f:     .long 0
c4fusb:  .long 0
sp08:    .word 0
ss08:    .word 0
sp4f:    .word 0
ss4f:    .word 0
c16:     .space 20                /* v3: INT 16h guard counters */
last16ax: .word 0
last16ip: .word 0
last16cs: .word 0
evseq:   .word 0                  /* v3: written by USOSKEY.DRV */
evlog:   .space 256
in9:     .byte 0
         .byte 0
old08:   .long 0
old09:   .long 0
old15:   .long 0
old1c:   .long 0
old2f:   .long 0
old16:   .long 0

/* INT 08h: count the timer ticks that reach the real-mode/V86 chain. */
int08:
    inc dword ptr cs:[c08]
    mov word ptr cs:[sp08], sp
    mov word ptr cs:[ss08], ss
    .att_syntax prefix
    ljmpw *%cs:old08
    .intel_syntax noprefix

/* INT 09h: mark keyboard-IRQ context, so INT 15h/4Fh from it passes. */
int09:
    inc byte ptr cs:[in9]
    pushf
    .att_syntax prefix
    lcallw *%cs:old09
    .intel_syntax noprefix
    dec byte ptr cs:[in9]
    iret

/* INT 16h guard. SeaBIOS's handle_16 (kbd.c) runs set_leds() first, then
 * yield() for AH=01h/02h/11h/12h; KEYBOARD.DRV of Windows 9x calls INT 16h
 * whenever a key gives no character (F5, Ctrl, ...). While Windows owns the
 * keyboard (consumer alive) the shift-status and empty-buffer checks are
 * answered here from the BIOS data area without entering SeaBIOS; a waiting
 * key (DOS box: VKD's INT 09h filled the buffer) and everything else go
 * down the chain. In plain DOS (not alive) the guard does nothing. */
int16:
    cmp byte ptr cs:[alive], 0
    jne 1f
    inc word ptr cs:[c16 + 18]
    jmp chain16
1:  push bp
    mov bp, sp
    push ds
    push bx
    mov word ptr cs:[last16ax], ax
    mov bx, word ptr [bp + 2]
    mov word ptr cs:[last16ip], bx
    mov bx, word ptr [bp + 4]
    mov word ptr cs:[last16cs], bx
    mov bx, 0x40
    mov ds, bx
    cmp ah, 0x02
    je g02
    cmp ah, 0x12
    je g12
    cmp ah, 0x01
    je g01
    cmp ah, 0x11
    je g11
    mov bx, 0
    cmp ah, 0x00
    je gchain
    mov bx, 8
    cmp ah, 0x10
    je gchain
    mov bx, 16
gchain:
    inc word ptr cs:[c16 + bx]
    pop bx
    pop ds
    pop bp
chain16:
    .att_syntax prefix
    ljmpw *%cs:old16
    .intel_syntax noprefix
g02:
    mov al, byte ptr ds:[0x17]
    mov bx, 6
    jmp gdone
g12:
    mov al, byte ptr ds:[0x18]
    and al, 0xf3
    mov ah, byte ptr ds:[0x96]
    and ah, 0x0c
    or ah, al
    mov al, byte ptr ds:[0x17]
    mov bx, 14
    jmp gdone
g01:
    mov bx, 2
    jmp gpeek
g11:
    mov bx, 10
gpeek:
    push ax
    mov ax, word ptr ds:[0x1a]
    cmp ax, word ptr ds:[0x1c]
    pop ax
    je gempty
    add bx, 2                       /* key waiting: SeaBIOS returns it */
    jmp gchain
gempty:
    or byte ptr [bp + 6], 0x40      /* ZF set in the caller's FLAGS: no key */
gdone:
    inc word ptr cs:[c16 + bx]
    pop bx
    pop ds
    pop bp
    iret

/* INT 1Ch: the consumer's heartbeat runs down. */
int1c:
    inc dword ptr cs:[c1c]
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
    inc dword ptr cs:[c4f]
    mov byte ptr cs:[last4f], al
    push ax
    mov al, byte ptr cs:[in9]
    mov byte ptr cs:[last4f9], al
    pop ax
    cmp byte ptr cs:[in9], 0
    jne pass15                      /* came through INT 09h: 8042 / VKD */
    inc dword ptr cs:[c4fusb]
    mov word ptr cs:[sp4f], sp
    mov word ptr cs:[ss4f], ss
    cmp byte ptr cs:[alive], 0
    je pass15
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
    mov ax, 0x3508
    int 0x21
    mov word ptr [old08], bx
    mov word ptr [old08 + 2], es
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
    mov ax, 0x3516
    int 0x21
    mov word ptr [old16], bx
    mov word ptr [old16 + 2], es
    push cs
    pop ds
    mov dx, offset int08
    mov ax, 0x2508
    int 0x21
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
    mov dx, offset int16
    mov ax, 0x2516
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
