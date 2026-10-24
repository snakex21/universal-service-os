/*
 * USOSKBC.COM - USB keyboard through the 8042 and scripted Setup answers
 * for Windows 1.0x, 2.x and 3.0 (and the text pages of WfW 3.11 Setup).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 *   USOSKBC [/R] [/M] [script.key]
 *
 * /R (relay): under CSMWrap SeaBIOS serves the USB keyboard from its timer
 * interrupt and hands every raw set-1 byte to INT 15h AH=4Fh before its own
 * processing. KEYBOARD.DRV of Windows 1.0x-3.0 reads port 60h in its own
 * INT 09h handler, so it never sees those bytes. With an 8042 present (port
 * 64h does not read FFh; the X470 has one) this TSR takes the bytes that did
 * NOT come through INT 09h, tells SeaBIOS to drop them (CF clear) and writes
 * them back through the controller with command D2h ("write keyboard output
 * buffer"): the 8042 raises IRQ 1 and whoever owns INT 09h (SeaBIOS in DOS,
 * KEYBOARD.DRV in Windows) reads the byte from port 60h as if a PS/2
 * keyboard had sent it. One byte per timer tick, only when the controller's
 * input and output buffers are empty. At install /R also sets the keyboard
 * interrupt bit of the controller command byte (SeaBIOS leaves it off when
 * no PS/2 keyboard answered its reset).
 *
 * /M (mouse): the PS/2 path of MOUSE.DRV in Windows 2.x and 3.0 starts the
 * BIOS pointing device (INT 15h C205h/C201h/C203h/C207h/C200h), but its
 * C207h callback only stores the packet; the driver hands it to Windows
 * from its own INT 74h (IRQ 12) handler, after chaining the previous one.
 * Under CSMWrap SeaBIOS serves the USB mouse from its timer interrupt and
 * calls the callback there; IRQ 12 never comes, so the pointer never moves.
 * With /M this TSR registers its own trampoline for every C207h call (the
 * caller's handler is called from it with the same stack words) and, after
 * the BIOS timer interrupt delivered a packet, issues INT 74h itself when
 * someone hooked INT 74h above this TSR's own stub. That stub sits under
 * the driver's handler (MOUSE.DRV chains to it): for this software INT 74h
 * it returns at once (no BIOS IRQ 12 code, no EOI); a real IRQ 12 goes on
 * to the BIOS. No 8042 needed. Windows 1.0x has no PS/2 mouse driver; USOS
 * gives it USOSMS1.DRV (src/platform/win1/usosms1.S), which hooks INT 74h
 * the same way and so also gets these software interrupts.
 *
 * Script (built by tools/usos_keyscript.py; header "UKS1"): steps run from
 * the timer interrupt, so Setup programs get their answers without a person
 * at the keyboard. Ops: 0 end, 1 wait for text on the text screen, 2 delay
 * (ticks), 3 key (set-1 bytes + BIOS word), 4 wait for a graphics mode,
 * 5 wait until a text is gone, 6 wait for a picture in VGA mode 12h
 * (hash of a plane-0 rectangle, with a timeout). Keys go through the 8042 when there is one
 * (also into Windows), otherwise into the BIOS keyboard buffer (text Setup
 * pages only). A missing text simply stops the script: the keyboard keeps
 * working, a person can answer.
 *
 * Shared block (INT 2Fh AX=D710h -> AL=FFh, BX=segment, CX=offset,
 * DX='KB'): "UKBC", version, flags (1 relay, 2 8042 present, 4 script
 * running, 8 mouse), queue head/tail, counters, version 2: the C207h
 * handler, packets, INT 74h kicks; docs/windows-early-2026-10-07.md.
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
    .ascii "UKBC"
    .word 2
kflags:  .byte 0                  /* 1 relay, 2 8042, 4 script, 8 mouse */
busy:    .byte 0
qhead:   .byte 0
qtail:   .byte 0
in9:     .byte 0
tick:    .byte 0
spos:    .word 0                  /* script position (offset) */
swait:   .word 0                  /* ticks left in a delay */
relayed: .long 0
captured: .long 0
qfull:   .word 0
fed:     .word 0                  /* script keys */
step:    .word 0                  /* script steps done */
queue:   .space 64
old08:   .long 0
old09:   .long 0
old15:   .long 0
old2f:   .long 0
/* version 2: /M */
mcb:     .long 0                  /* caller's INT 15h C207h handler */
mpackets: .long 0                 /* packets passed to it */
mkicks:  .long 0                  /* software INT 74h issued */
old74:   .long 0
mpend:   .byte 0                  /* packet delivered, INT 74h due */
msoft:   .byte 0                  /* inside the software INT 74h */
/* op 6 (pix): checks of the current step, for its timeout */
pcount:  .word 0

/* INT 08h: the BIOS first (SeaBIOS polls USB there and sends the EOI),
 * then one queued byte to the 8042 and one script step. */
int08:
    pushf
    .att_syntax prefix
    lcallw *%cs:old08
    .intel_syntax noprefix
    cli
    cmp byte ptr cs:[busy], 0
    jne 9f
    inc byte ptr cs:[busy]
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    push cs
    pop ds
    call drain
    test byte ptr [kflags], 4
    jz 1f
    call script
1:  test byte ptr [kflags], 8
    jz 2f
    call kick
2:  pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    dec byte ptr cs:[busy]
9:  iret

/* One byte from the queue to the 8042 (DS = CS). */
drain:
    test byte ptr [kflags], 2
    jz 9f
    mov bl, byte ptr [qtail]
    cmp bl, byte ptr [qhead]
    je 9f
    in al, 0x64
    test al, 3                      /* input or output buffer full: later */
    jnz 9f
    mov al, 0xd2
    out 0x64, al
    mov cx, 0x4000
1:  in al, 0x64
    test al, 2
    loopnz 1b
    xor bh, bh
    mov al, byte ptr [queue + bx]
    out 0x60, al
    inc bl
    and bl, 63
    mov byte ptr [qtail], bl
    inc dword ptr [relayed]
9:  ret

/* /M: after a packet went to the C207h handler, INT 74h for the driver
 * that hooked it (DS = CS). Nothing above our own stub: nobody to wake. */
kick:
    cmp byte ptr [mpend], 0
    je 9f
    mov byte ptr [mpend], 0
    xor ax, ax
    mov es, ax
    cmp word ptr es:[0x74 * 4], offset int74
    jne 1f
    mov ax, cs
    cmp word ptr es:[0x74 * 4 + 2], ax
    je 9f
1:  mov byte ptr [msoft], 1
    int 0x74
    mov byte ptr cs:[msoft], 0
    inc dword ptr cs:[mkicks]
9:  ret

/* INT 74h: the software one from kick returns at once; IRQ 12 to the BIOS. */
int74:
    cmp byte ptr cs:[msoft], 0
    jne 1f
    .att_syntax prefix
    ljmpw *%cs:old74
    .intel_syntax noprefix
1:  iret

/* The BIOS far-calls this with status, X, Y, Z words on the stack (as for
 * any C207h handler): the same words to the caller's handler, then mark
 * the INT 74h as due. */
mtramp:
    push bp
    mov bp, sp
    cmp word ptr cs:[mcb + 2], 0
    je 1f
    push word ptr [bp + 12]
    push word ptr [bp + 10]
    push word ptr [bp + 8]
    push word ptr [bp + 6]
    .att_syntax prefix
    lcallw *%cs:mcb
    .intel_syntax noprefix
    add sp, 8
    mov byte ptr cs:[mpend], 1
    inc dword ptr cs:[mpackets]
1:  pop bp
    .byte 0xcb                      /* retf (16-bit far return) */

/* Append AL to the queue (DS = CS); CF set when full. */
enqueue:
    push bx
    mov bl, byte ptr [qhead]
    mov bh, bl
    inc bh
    and bh, 63
    cmp bh, byte ptr [qtail]
    je 1f
    push si
    mov si, bx
    and si, 0x00ff
    mov byte ptr [queue + si], al
    pop si
    mov byte ptr [qhead], bh
    pop bx
    clc
    ret
1:  inc word ptr [qfull]
    pop bx
    stc
    ret

/* One script step (DS = CS). */
script:
    inc byte ptr [tick]
    cmp word ptr [swait], 0
    je 1f
    dec word ptr [swait]
    ret
1:  mov si, word ptr [spos]
    mov al, byte ptr [si]
    cmp al, 1
    je op_wait
    cmp al, 2
    je op_delay
    cmp al, 3
    je op_key
    cmp al, 4
    je op_gfx
    cmp al, 5
    je op_gone
    cmp al, 6
    je op_pix
    and byte ptr [kflags], 0xfb      /* 0 (or unknown): script done */
    ret
op_wait:
    test byte ptr [tick], 3
    jnz 9f
    call findtext
    jnc 9f
    jmp skiptext
op_gone:
    test byte ptr [tick], 3
    jnz 9f
    call findtext
    jc 9f
skiptext:
    mov al, byte ptr [si + 1]
    xor ah, ah
    add si, ax
    add si, 2
    jmp next
/* 6, word plane-0 offset, byte rows, byte bytes per row, dword hash,
 * word timeout (checks, 4 ticks each): a picture in VGA mode 12h (the
 * Windows 3.0 Setup dialogs have no text-mode page to wait for). Plane 0
 * of the rectangle hashed (h = rol(h, 5) xor byte); equal -> next op. Past
 * the timeout the step ends as well (the old timed behaviour), so a
 * picture that never matches cannot hold the script forever. */
op_pix:
    test byte ptr [tick], 3
    jnz 9f
    inc word ptr [pcount]
    mov ax, word ptr [pcount]
    cmp ax, word ptr [si + 9]
    jae 1f
    mov ax, 0x40
    mov es, ax
    cmp byte ptr es:[0x49], 0x12
    jne 9f
    call pixhash
    jnc 9f
1:  mov word ptr [pcount], 0
    add si, 11
    jmp next
op_delay:
    mov ax, word ptr [si + 1]
    mov word ptr [swait], ax
    add si, 3
    jmp next
op_gfx:
    mov ax, 0x40
    mov es, ax
    mov al, byte ptr es:[0x49]
    cmp al, 7
    je 9f
    cmp al, 3
    jbe 9f
    inc si
    jmp next
op_key:
    /* [si+1] n, n set-1 bytes, then the BIOS word (scan:ascii). */
    mov al, byte ptr [qtail]
    cmp al, byte ptr [qhead]
    jne 9f                          /* previous key still going out */
    mov cl, byte ptr [si + 1]
    xor ch, ch
    lea di, [si + 2]
    test byte ptr [kflags], 2
    jz key_bios
    jcxz key_done
2:  mov al, byte ptr [di]
    call enqueue
    inc di
    loop 2b
    jmp key_done
key_bios:
    add di, cx
    mov dx, word ptr [di]
    sub di, cx
    or dx, dx
    jz key_done
    mov ax, 0x40
    mov es, ax
    mov bx, word ptr es:[0x1c]
    mov ax, bx
    add ax, 2
    cmp ax, word ptr es:[0x82]
    jb 3f
    mov ax, word ptr es:[0x80]
3:  cmp ax, word ptr es:[0x1a]
    je 9f                           /* BIOS buffer full: retry */
    mov word ptr es:[bx], dx
    mov word ptr es:[0x1c], ax
key_done:
    inc word ptr [fed]
    mov cl, byte ptr [si + 1]
    xor ch, ch
    add si, cx
    add si, 4
next:
    mov word ptr [spos], si
    inc word ptr [step]
9:  ret

/* CF set = the hash of the op-6 rectangle at [si] (plane 0, read mode 0)
 * is the one of the op; all 32-bit registers kept (the interrupted code
 * may use the upper halves). The
 * graphics controller index, read map select and mode registers are put
 * back; the latches are not (one read in the middle of a latched write of
 * the display driver can spoil a few pixels of Setup's screen, nothing
 * else). Keeps SI; DS = CS. */
pixhash:
    push eax
    push bx
    push cx
    push dx
    push di
    push bp
    mov dx, 0x3ce
    in al, dx
    mov bl, al                      /* index register */
    mov al, 4
    out dx, al
    inc dx
    in al, dx
    mov bh, al                      /* read map select */
    dec dx
    mov al, 5
    out dx, al
    inc dx
    in al, dx
    mov bp, ax                      /* mode (low byte) */
    and al, 0xf7                    /* read mode 0 */
    out dx, al
    dec dx
    mov al, 4
    out dx, al
    inc dx
    xor al, al                      /* plane 0 */
    out dx, al
    mov ax, 0xa000
    mov es, ax
    mov di, word ptr [si + 1]
    mov ch, byte ptr [si + 3]       /* rows */
    xor eax, eax
1:  mov cl, byte ptr [si + 4]       /* bytes per row */
    push di
2:  rol eax, 5
    xor al, byte ptr es:[di]
    inc di
    dec cl
    jnz 2b
    pop di
    add di, 80
    dec ch
    jnz 1b
    cmp eax, dword ptr [si + 5]
    pushf
    mov dx, 0x3ce
    mov al, 5
    out dx, al
    inc dx
    mov ax, bp
    out dx, al
    dec dx
    mov al, 4
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    dec dx
    mov al, bl
    out dx, al
    popf
    pop bp
    pop di
    pop dx
    pop cx
    pop bx
    pop eax
    stc
    je 3f
    clc
3:  ret

/* Is the counted string at [si+1] on the text screen? CF set = yes.
 * Keeps SI; DS = CS. */
findtext:
    push si
    mov ax, 0x40
    mov es, ax
    mov al, byte ptr es:[0x49]
    mov dx, 0xb800
    cmp al, 7
    jne 1f
    mov dx, 0xb000
    jmp 2f
1:  cmp al, 3
    ja nf
2:  mov al, byte ptr es:[0x84]      /* rows - 1 (0 on old BIOSes) */
    or al, al
    jnz 3f
    mov al, 24
3:  inc al
    mov bl, byte ptr es:[0x4a]      /* columns */
    mul bl                          /* AX = cells */
    /* Page start from the CRT controller (start address registers 0Ch/0Dh,
     * in characters): Windows 1.0x Setup flips pages without telling the
     * BIOS, so the BDA word 0040:004Eh can name the hidden page. */
    push ax
    push dx
    mov dx, 0x3d4
    cmp byte ptr es:[0x49], 7
    jne 7f
    mov dx, 0x3b4
7:  in al, dx
    mov cl, al                      /* the program's index register value */
    mov al, 0x0c
    out dx, al
    inc dx
    in al, dx
    mov ah, al
    dec dx
    mov al, 0x0d
    out dx, al
    inc dx
    in al, dx
    dec dx
    xchg ax, cx
    out dx, al                      /* index register back */
    mov di, cx
    shl di, 1                       /* byte offset in the text buffer */
    pop dx
    pop ax
    mov bx, word ptr es:[0x4e]      /* the BIOS's idea of the page start */
    mov es, dx
    mov cl, byte ptr [si + 1]
    xor ch, ch
    jcxz found
    sub ax, cx
    jb nf
    inc ax
    inc si
    inc si                          /* SI = first character */
    push ax
    call scan
    pop ax
    jc found
    cmp bx, di
    je nf
    mov di, bx                      /* CRTC page did not have it: BDA page */
    call scan
    jc found
    jmp nf

/* Search ES:DI (text cells) at AX start positions for the CX characters
 * at DS:SI. CF set = found. Keeps CX, SI, DI. */
scan:
    push di
    mov dx, ax
4:  push di
    push si
    push cx
5:  mov al, byte ptr es:[di]
    cmp al, byte ptr [si]
    jne 6f
    inc si
    add di, 2
    loop 5b
    pop cx
    pop si
    pop di
    pop di
    stc
    ret
6:  pop cx
    pop si
    pop di
    add di, 2
    dec dx
    jnz 4b
    pop di
    clc
    ret
nf: pop si
    clc
    ret
found:
    pop si
    stc
    ret

/* INT 09h: mark keyboard-IRQ context, so INT 15h/4Fh from it passes. */
int09:
    inc byte ptr cs:[in9]
    pushf
    .att_syntax prefix
    lcallw *%cs:old09
    .intel_syntax noprefix
    dec byte ptr cs:[in9]
    iret

/* INT 15h AH=4Fh: USB bytes (not from INT 09h) go to the 8042 queue.
 * AX=C207h with /M: the BIOS gets the trampoline, the caller keeps ES:BX
 * and gets the BIOS's AH and CF. 0:0 (remove) goes straight through. */
int15:
    cmp ax, 0xc207
    jne 3f
    test byte ptr cs:[kflags], 8
    jz chain15
    mov word ptr cs:[mcb], bx
    mov word ptr cs:[mcb + 2], es
    push bx
    mov bx, es
    or bx, word ptr cs:[mcb]
    pop bx
    jz chain15
    push es
    push bx
    push cs
    pop es
    mov bx, offset mtramp
    pushf
    .att_syntax prefix
    lcallw *%cs:old15
    .intel_syntax noprefix
    pop bx
    pop es
    push bp
    mov bp, sp
    jc 2f
    and byte ptr [bp + 6], 0xfe
    pop bp
    iret
2:  or byte ptr [bp + 6], 1
    pop bp
    iret
3:  cmp ah, 0x4f
    jne chain15
    test byte ptr cs:[kflags], 1
    jz chain15
    cmp byte ptr cs:[in9], 0
    jne chain15
    push ds
    push cs
    pop ds
    call enqueue
    pop ds
    jc chain15                      /* queue full: SeaBIOS keeps it */
    inc dword ptr cs:[captured]
    push bp
    mov bp, sp
    and byte ptr [bp + 6], 0xfe     /* CF clear in the caller's FLAGS: drop */
    pop bp
    iret
chain15:
    .att_syntax prefix
    ljmpw *%cs:old15
    .intel_syntax noprefix

/* INT 2Fh AX=D710h: installation check and shared block address. */
int2f:
    cmp ax, 0xd710
    jne 1f
    mov al, 0xff
    mov bx, cs
    mov cx, offset shared
    mov dx, 0x4b42
    iret
1:  .att_syntax prefix
    ljmpw *%cs:old2f
    .intel_syntax noprefix

/* ---------------------------------------------------------------- install */
    .set SCRIPT_MAX, 3072
install:
    mov ax, 0xd710
    int 0x2f
    cmp al, 0xff
    jne 1f
    cmp dx, 0x4b42
    jne 1f
    mov dx, offset msg_already
    jmp say_exit
1:  /* Command tail: /R and an optional script file name. */
    mov si, 0x81
    mov word ptr [resend], offset scriptbuf
parse:
    lodsb
    cmp al, 0x0d
    je parsed
    cmp al, ' '
    je parse
    cmp al, 9
    je parse
    cmp al, '/'
    jne fname
    lodsb
    or al, 0x20
    cmp al, 'm'
    jne 1f
    or byte ptr [kflags], 8
    jmp parse
1:  cmp al, 'r'
    jne bad_args
    or byte ptr [kflags], 1
    jmp parse
fname:
    dec si
    mov dx, si                      /* DS:DX = name */
2:  lodsb
    cmp al, ' '
    je 3f
    cmp al, 9
    je 3f
    cmp al, 0x0d
    jne 2b
3:  mov byte ptr [si - 1], 0
    mov byte ptr [term], al
    push si
    mov ax, 0x3d00
    int 0x21
    jc no_file
    mov bx, ax
    mov dx, offset scriptbuf
    mov cx, SCRIPT_MAX
    mov ah, 0x3f
    int 0x21
    pushf
    push ax
    mov ah, 0x3e
    int 0x21
    pop ax
    popf
    jc no_file
    cmp ax, 6
    jb bad_file
    cmp ax, SCRIPT_MAX
    jae bad_file
    cmp word ptr [scriptbuf], 0x4b55       /* "UK" */
    jne bad_file
    cmp word ptr [scriptbuf + 2], 0x3153   /* "S1" */
    jne bad_file
    mov bx, offset scriptbuf
    add bx, ax
    mov byte ptr [bx], 0            /* end op after the last step */
    inc bx
    mov word ptr [resend], bx
    mov word ptr [spos], offset scriptbuf + 4
    or byte ptr [kflags], 4
    pop si
    cmp byte ptr [term], 0x0d
    je parsed
    jmp parse
no_file:
    pop si
    mov dx, offset msg_nofile
    jmp say_exit
bad_file:
    pop si
    mov dx, offset msg_badfile
    jmp say_exit
bad_args:
    mov dx, offset msg_usage
    jmp say_exit
parsed:
    /* 8042 present? Port 64h reads FFh without a controller. */
    in al, 0x64
    cmp al, 0xff
    je no_kbc
    or byte ptr [kflags], 2
    test byte ptr [kflags], 1
    jz kbc_done
    /* /R: keyboard interrupt on in the command byte (bit 0). */
    cli
    call kbc_wait_in
    mov al, 0x20
    out 0x64, al
    mov cx, 0xffff
4:  in al, 0x64
    test al, 1
    loopz 4b
    jcxz 5f
    in al, 0x60
    or al, 1
    mov ah, al
    call kbc_wait_in
    mov al, 0x60
    out 0x64, al
    call kbc_wait_in
    mov al, ah
    out 0x60, al
5:  sti
    jmp kbc_done
no_kbc:
    and byte ptr [kflags], 0xfe      /* no relay without a controller */
kbc_done:
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
    mov ax, 0x352f
    int 0x21
    mov word ptr [old2f], bx
    mov word ptr [old2f + 2], es
    test byte ptr [kflags], 8
    jz 8f
    mov ax, 0x3574
    int 0x21
    mov word ptr [old74], bx
    mov word ptr [old74 + 2], es
    mov dx, offset int74
    mov ax, 0x2574
    int 0x21
8:  mov dx, offset int09
    mov ax, 0x2509
    int 0x21
    mov dx, offset int15
    mov ax, 0x2515
    int 0x21
    mov dx, offset int2f
    mov ax, 0x252f
    int 0x21
    mov dx, offset int08
    mov ax, 0x2508
    int 0x21
    mov es, word ptr [0x2c]
    mov ah, 0x49
    int 0x21
    mov dx, offset msg_ok
    mov ah, 9
    int 0x21
    test byte ptr [kflags], 1
    jz 6f
    mov dx, offset msg_relay
    mov ah, 9
    int 0x21
6:  test byte ptr [kflags], 8
    jz 5f
    mov dx, offset msg_mouse
    mov ah, 9
    int 0x21
5:  test byte ptr [kflags], 4
    jz 7f
    mov dx, offset msg_script
    mov ah, 9
    int 0x21
7:  mov dx, offset msg_nl
    mov ah, 9
    int 0x21
    mov dx, word ptr [resend]
    add dx, 15
    shr dx, 4
    mov ax, 0x3100
    int 0x21

kbc_wait_in:
    push cx
    mov cx, 0xffff
1:  in al, 0x64
    test al, 2
    loopnz 1b
    pop cx
    ret

say_exit:
    mov ah, 9
    int 0x21
    mov ax, 0x4c01
    int 0x21

resend: .word 0
term:   .byte 0
msg_ok:
    .ascii "USOSKBC: installed$"
msg_relay:
    .ascii ", USB keyboard through the 8042$"
msg_mouse:
    .ascii ", USB mouse for MOUSE.DRV (INT 74h)$"
msg_script:
    .ascii ", Setup answers$"
msg_nl:
    .ascii ".\r\n$"
msg_already:
    .ascii "USOSKBC: already installed.\r\n$"
msg_nofile:
    .ascii "USOSKBC: cannot read the script file.\r\n$"
msg_badfile:
    .ascii "USOSKBC: not a USOS key script.\r\n$"
msg_usage:
    .ascii "USOSKBC [/R] [/M] [script.key]\r\n$"

    /* The script is read to here and stays resident with the code above
     * (the install part is small; reading over it would overwrite the
     * running code). */
    .p2align 1
scriptbuf:
