/*
 * USOSPKT.COM - DOS packet driver (FTP Software Packet Driver Specification
 * 1.11, class 1 = DIX Ethernet) for the Intel igb family: I211 (8086:1539,
 * the X470 Master board), I210 and 82576 (QEMU -device igb).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 *   USOSPKT [vector] [/P] [/M] [/Q] [/?]
 *
 *   vector  software interrupt, 0x60..0x80 (default 0x60), "60" or "0x60"
 *   /P      polled only (timer, INT 08h), never the PCI interrupt
 *   /M      registers through BAR0 MMIO even when an I/O BAR exists (test)
 *   /S      find the NIC with a config-space scan, not the PCI BIOS (test)
 *   /Q      queue mode (INT 2Fh AX=5553h) for a protected-mode client: the
 *           extra block costs 39712 bytes; without /Q
 *           nothing is allocated and INT 2Fh is not touched
 *
 * Errorlevel: 0 installed, 1 no supported NIC (nothing stays resident),
 * 2 vector already in use, 3 no usable register access, 4 NIC did not
 * reset, 5 bad command line, 6 no memory / DMA region.
 *
 * The NIC programming follows the USOS NDIS driver usosnet
 * (tools/nt/usosnet/src/usosnet_igb.c, our own code, written from the public
 * Intel I210/I211 and 82576 datasheets): reset sequence, I210/I211 iNVM MAC
 * and PLL erratum, PHY autonegotiation without PAUSE, advanced one-buffer RX
 * descriptors (2 KiB) and advanced TX data descriptors, legacy INTx causes.
 * docs/dos-usospkt-2026-10-23.md has the design notes and the test results.
 *
 * Register access. The igb parts decode an I/O BAR (32 bytes: IOADDR at +0
 * selects a register, IODATA at +4 reads / writes it). Port I/O works in
 * real mode, under HIMEM.SYS and in V86 mode under EMM386, so it is used
 * whenever a BAR with bit 0 set has a non-zero base. Without one (the BAR is
 * optional, firmware can leave it unassigned) BAR0 MMIO is used: every
 * access loads FS with a flat 4 GiB descriptor (a short protected-mode
 * switch with interrupts off, GDTR saved / restored) and reads FS:[EDI].
 * That needs real mode: in V86 mode (EMM386, Windows) the access is
 * refused (all ones) and the install stops with errorlevel 3.
 *
 * DMA. Rings and buffers are one block in conventional memory directly
 * behind the resident part. Its physical address: Virtual DMA Services
 * (INT 4Bh AX=8103h, no buffer, no remap) when 0040:007B bit 5 says VDS is
 * there (EMM386), otherwise segment * 16 + offset. The rings start on a
 * 128-byte physical boundary.
 *
 * Interrupts. The PCI interrupt line (config 3Ch, written by the BIOS) is
 * used unless /P; the handler claims it only when ICR.INT_ASSERTED is set
 * (shared lines chain), masks the NIC (IMC), sends EOI, polls the RX ring
 * and unmasks (IMS) - so an edge-triggered 8259 input also gets a fresh
 * edge for causes that arrived meanwhile. The timer (INT 08h, after the
 * BIOS handler) polls the RX ring in every mode: the polled fallback and a
 * safety net for a lost edge. Receiver upcalls run on a private stack.
 *
 * Queue mode. A Windows 3.1 DLL in protected mode cannot take a far-call
 * upcall, so there is a second interface: INT 2Fh AX=5553h ("US"). BX=FFFF
 * reports the block, BX=1 (ATTACH) hands it out and turns the upcalls off,
 * BX=2 returns the ring positions, BX=3 sends what the client queued in the
 * TX ring and BX=4 returns to upcall-only. The block sits in its own
 * segment behind the DMA area: header, 16 x 2048 RX, 4 x 1536 TX and a text
 * log the client drains (the driver never calls DOS from an ISR). Without
 * ATTACH the packet-driver interface above works exactly as before.
 * docs/ds-usospkt-queue-2026-10-23.md has the layout and the tests.
 */
.intel_syntax noprefix
.code16
.section .text
.global _start

.set RX_COUNT, 16
.set TX_COUNT, 8
.set BUF_SIZE, 2048
/* DMA block: RX ring (256), TX ring (128), TX buffer at 512, RX buffers */
.set A_RXRING, 0
.set A_TXRING, 256
.set A_TXBUF, 512
.set A_RXBUF, 2048
.set AREA_SIZE, A_RXBUF + RX_COUNT * BUF_SIZE

/* Queue mode (INT 2Fh AX=5553h): one block in its own segment directly
 * behind the DMA area - header, RX ring 16 x 2048, TX ring 4 x 1536 and a
 * text log. Offsets are block-relative, so nothing can cross a 64 KiB
 * segment; the DMA area above keeps its layout for the upcall path. */
.set QF_READY, 1                     /* driver resident and set up */
.set QF_ATTACH, 2                    /* queue client attached */
.set QF_SUPPRESS, 4                  /* no RX upcalls, the client polls */
.set Q_TXCOUNT, 4
.set Q_HDR, 128                      /* header size */
.set Q_MAGIC, 0                      /* 'USQ1' */
.set Q_VERSION, 4                    /* word 0x0100 */
.set Q_HDRSZ, 6
.set Q_FLAGS, 8
.set Q_RXHEAD, 12
.set Q_RXTAIL, 14
.set Q_RXCNT, 16
.set Q_RXSTRIDE, 18
.set Q_RXBASE, 20                    /* dword, offset in the block */
.set Q_TXHEAD, 24
.set Q_TXTAIL, 26
.set Q_TXCNT, 28
.set Q_TXSTRIDE, 30
.set Q_TXBASE, 32                    /* dword */
.set Q_RXDROP, 36                    /* dword counters */
.set Q_TXBUSY, 40
.set Q_TXDONE, 44
.set Q_RXERR, 48
.set Q_TXERR, 52
.set Q_LOGHEAD, 56
.set Q_LOGTAIL, 58
.set Q_LOGSZ, 60
.set Q_LOGBASE, 62                   /* dword */
.set Q_LOGDROP, 66                   /* dword */
.set Q_INT, 70                       /* the packet vector we answer on */
.set Q_MAC, 72
.set Q_SEQ, 78
.set Q_RXBUF, Q_HDR
.set Q_RXBUFSZ, 2048
.set Q_RXSTR, 8 + Q_RXBUFSZ          /* len/flags/seq, then the frame */
.set Q_TXBUF, Q_RXBUF + RX_COUNT * Q_RXSTR
.set Q_TXBUFSZ, 1536
.set Q_TXSTR, 8 + Q_TXBUFSZ
.set Q_LOGOFF, Q_TXBUF + Q_TXCOUNT * Q_TXSTR
.set Q_LOGBUFSZ, 512
.set Q_SIZE, Q_LOGOFF + Q_LOGBUFSZ   /* 39712 bytes */
.set MAX_HANDLES, 4
.set H_USE, 0
.set H_LEN, 1
.set H_TYPE, 2
.set H_RECV, 10
.set H_SIZE, 16
.set IF_TYPE, 0x5553                /* our own if_type ("US") */

/* registers (usosnet_igb.c) */
.set CTRL, 0x0000
.set STATUS, 0x0008
.set EECD, 0x0010
.set EERD, 0x0014
.set CTRL_EXT, 0x0018
.set MDIC, 0x0020
.set ICR, 0x00C0
.set IMS, 0x00D0
.set IMC, 0x00D8
.set IAM, 0x00E0
.set RCTL, 0x0100
.set TCTL, 0x0400
.set MDICNFG, 0x0E04
.set GPIE, 0x1514
.set EIMC, 0x1528
.set EIAC, 0x152C
.set EIAM, 0x1530
.set EICR, 0x1580
.set IVAR0, 0x1700
.set MTA, 0x5200
.set RAL0, 0x5400
.set RAH0, 0x5404
.set WUC, 0x5800
.set MRQC, 0x5818
.set RDBAL0, 0xC000
.set RDBAH0, 0xC004
.set RDLEN0, 0xC008
.set SRRCTL0, 0xC00C
.set RDH0, 0xC010
.set RDT0, 0xC018
.set RXDCTL0, 0xC028
.set TDBAL0, 0xE000
.set TDBAH0, 0xE004
.set TDLEN0, 0xE008
.set TDH0, 0xE010
.set TDT0, 0xE018
.set TXDCTL0, 0xE028
.set EEARBC_I210, 0x12024
.set INVM_DATA, 0x12120

.set RCTL_EN, 0x00000002
.set RCTL_UPE, 0x00000008
.set RCTL_MPE, 0x00000010
.set RCTL_BAM, 0x00008000
.set RCTL_SECRC, 0x04000000
.set IMS_MASK, 0x000000DC           /* LSC RXSEQ RXDMT0 RXO RXT0 */
.set FRAME_ERR, 0x97000000          /* CE SE SEQ CXE RXE */

.set F_EDI, 0                       /* pkt_main frame (push ds, es, pushad) */
.set F_ESI, 4
.set F_EBX, 16
.set F_EDX, 20
.set F_ECX, 24
.set F_EAX, 28
.set F_ES, 32
.set F_DS, 34
.set F_FL, 40

.macro CALLFAR x
    .byte 0x2e, 0xff, 0x1e
    .word \x
.endm
.macro JMPFAR x
    .byte 0x2e, 0xff, 0x2e
    .word \x
.endm

_start:
    jmp install

/* ------------------------------------------------------------------ */
/* resident data                                                       */
    .p2align 2
gdt:     .long 0, 0
         .word 0xFFFF, 0              /* selector 8: flat data, 4 GiB */
         .byte 0, 0x92, 0xCF, 0
gdtr:    .word 15
         .long 0
sv_gdtr: .word 0
         .long 0
mmio:    .long 0
phys:    .long 0                      /* physical address of the DMA block */
old08:   .long 0
oldirq:  .long 0
old2f:   .long 0
upcall:  .long 0
stats:                                /* get_statistics layout */
st_pin:  .long 0
st_pout: .long 0
st_bin:  .long 0
st_bout: .long 0
st_ein:  .long 0
st_eout: .long 0
st_lost: .long 0
area:    .word 0                      /* offset of the DMA block */
qoff:    .word 0                      /* offset of the queue block from CS */
qseg:    .word 0                      /* its segment (0 = not set up) */
iobase:  .word 0
rx_next: .word 0
tx_next: .word 0
rcvmode: .word 3
sv_ss:   .word 0
sv_sp:   .word 0
acc:     .byte 0                      /* 1 I/O BAR, 2 MMIO */
irq:     .byte 0xFF                   /* 0xFF = polled */
busy:    .byte 0
pvec:    .byte 0x60
mac:     .space 6
drvname: .asciz "USOSPKT igb"
qlog_attach: .ascii "ATTACH\r\n"
.set qlog_attach_l, 8
qlog_release: .ascii "RELEASE\r\n"
.set qlog_release_l, 9
qlog_full:   .ascii "RXQ FULL\r\n"
.set qlog_full_l, 10
qlog_txerr:  .ascii "TX ERR\r\n"
.set qlog_txerr_l, 8
qlog_ready:  .ascii "QUEUE ON\r\n"
.set qlog_ready_l, 10
    .p2align 1
handles: .space MAX_HANDLES * H_SIZE

/* ------------------------------------------------------------------ */
/* packet driver entry: "PKT DRVR" at offset 3                          */
pkt_entry:
    .byte 0xE9
    .word pkt_main - (pkt_entry + 3)
    .asciz "PKT DRVR"
    .ascii "USOSPKT"                      /* at +12: our copy (second load) */

pkt_main:
    push ds
    push es
    pushad
    mov bp, sp
    push cs
    pop ds
    cld
    mov ax, [bp + F_EAX]
    cmp ah, 1
    je f_info
    cmp ah, 2
    je f_access
    cmp ah, 3
    je f_release
    cmp ah, 4
    je f_send
    cmp ah, 5
    je f_term
    cmp ah, 6
    je f_getaddr
    cmp ah, 7
    je pk_ok
    cmp ah, 20
    je f_setmode
    cmp ah, 21
    je f_getmode
    cmp ah, 24
    je f_stats
    cmp ah, 25
    je f_setaddr
    mov al, 11                        /* BAD_COMMAND */
pk_err:
    mov [bp + F_EDX + 1], al          /* DH = error code */
    or word ptr [bp + F_FL], 1
    jmp pk_out
pk_ok:
    and word ptr [bp + F_FL], 0xFFFE
pk_out:
    popad
    pop es
    pop ds
    iret

f_info:
    mov word ptr [bp + F_EBX], 1      /* version */
    mov word ptr [bp + F_ECX], 0x0100 /* CH class 1, CL number 0 */
    mov word ptr [bp + F_EDX], IF_TYPE
    mov [bp + F_DS], cs
    mov word ptr [bp + F_ESI], offset drvname
    mov byte ptr [bp + F_EAX], 1      /* AL basic functions */
    jmp pk_ok

/* BX handle (1..MAX) -> SI = entry, CF on a bad one */
handle_ptr:
    mov bx, [bp + F_EBX]
    dec bx
    cmp bx, MAX_HANDLES
    jae 1f
    shl bx, 4
    lea si, [handles + bx]
    cmp byte ptr [si + H_USE], 0
    je 1f
    clc
    ret
1:  stc
    ret

f_access:
    mov al, 2                         /* NO_CLASS */
    cmp byte ptr [bp + F_EAX], 1
    jne pk_err
    mov al, 3                         /* NO_TYPE */
    mov bx, [bp + F_EBX]
    cmp bx, 0xFFFF
    je 1f
    cmp bx, IF_TYPE
    jne pk_err
1:  mov al, 4                         /* NO_NUMBER */
    mov dl, [bp + F_EDX]
    cmp dl, 0
    je 2f
    cmp dl, 0xFF
    jne pk_err
2:  mov al, 5                         /* BAD_TYPE */
    mov cx, [bp + F_ECX]
    cmp cx, 8
    ja pk_err
    /* same type already taken? */
    xor bx, bx
3:  cmp byte ptr [handles + bx + H_USE], 0
    je 4f
    cmp [handles + bx + H_LEN], cl
    jne 4f
    push ds
    push cx
    lea di, [handles + bx + H_TYPE]
    push cs
    pop es
    mov si, [bp + F_ESI]
    mov ds, [bp + F_DS]
    repe cmpsb
    pop cx
    pop ds
    mov al, 10                        /* TYPE_INUSE */
    je pk_err
4:  add bx, H_SIZE
    cmp bx, MAX_HANDLES * H_SIZE
    jb 3b
    /* free slot */
    xor bx, bx
5:  cmp byte ptr [handles + bx + H_USE], 0
    je 6f
    add bx, H_SIZE
    cmp bx, MAX_HANDLES * H_SIZE
    jb 5b
    mov al, 9                         /* NO_SPACE */
    jmp pk_err
6:  mov [handles + bx + H_LEN], cl
    mov ax, [bp + F_EDI]
    mov [handles + bx + H_RECV], ax
    mov ax, [bp + F_ES]
    mov [handles + bx + H_RECV + 2], ax
    lea di, [handles + bx + H_TYPE]
    push cs
    pop es
    push ds
    mov si, [bp + F_ESI]
    mov ds, [bp + F_DS]
    rep movsb
    pop ds
    mov byte ptr [handles + bx + H_USE], 1
    shr bx, 4
    inc bx
    mov [bp + F_EAX], bx              /* AX = handle */
    jmp pk_ok

f_release:
    call handle_ptr
    mov al, 1                         /* BAD_HANDLE */
    jc pk_err
    mov byte ptr [si + H_USE], 0
    jmp pk_ok

f_term:
    call handle_ptr
    mov al, 1
    jc pk_err
    mov byte ptr [si + H_USE], 0
    mov al, 7                         /* CANT_TERMINATE: the driver stays */
    jmp pk_err

f_getaddr:
    mov al, 9                         /* NO_SPACE */
    cmp word ptr [bp + F_ECX], 6
    jb pk_err
    mov es, [bp + F_ES]
    mov di, [bp + F_EDI]
    mov si, offset mac
    mov cx, 6
    rep movsb
    mov word ptr [bp + F_ECX], 6
    jmp pk_ok

f_getmode:
    mov ax, [rcvmode]
    mov [bp + F_EAX], ax
    jmp pk_ok

f_setmode:
    mov al, 8                         /* BAD_MODE */
    mov cx, [bp + F_ECX]
    cmp cx, 1
    jb pk_err
    cmp cx, 6
    ja pk_err
    mov [rcvmode], cx
    call apply_mode
    jmp pk_ok

/* RCTL from rcvmode: 1 off, 2 direct, 3 + broadcast, 4/5 + all multicast,
 * 6 promiscuous */
apply_mode:
    mov ebx, RCTL
    call reg_rd
    and eax, ~(RCTL_EN | RCTL_UPE | RCTL_MPE | RCTL_BAM)
    mov cx, [rcvmode]
    cmp cx, 1
    je 1f
    or eax, RCTL_EN
    cmp cx, 3
    jb 1f
    or eax, RCTL_BAM
    cmp cx, 4
    jb 1f
    or eax, RCTL_MPE
    cmp cx, 6
    jb 1f
    or eax, RCTL_UPE
1:  call reg_wr
    ret

f_stats:
    mov [bp + F_DS], cs
    mov word ptr [bp + F_ESI], offset stats
    jmp pk_ok

f_setaddr:
    mov al, 9                         /* NO_SPACE */
    cmp word ptr [bp + F_ECX], 6
    jne pk_err
    push cs
    pop es
    mov di, offset mac
    push ds
    mov si, [bp + F_ESI]
    mov ds, [bp + F_DS]
    mov cx, 6
    rep movsb
    pop ds
    call set_mac
    jmp pk_ok

set_mac:
    mov eax, dword ptr [mac]
    mov ebx, RAL0
    call reg_wr
    movzx eax, word ptr [mac + 4]
    or eax, 0x80040000                /* AV, pool 0 */
    mov ebx, RAH0
    call reg_wr
    ret

/* send_pkt: DS:SI frame, CX length; copied into the TX buffer, sent and
 * waited for (descriptor done), so the caller may reuse its buffer. */
f_send:
    mov al, 12                        /* CANT_SEND */
    mov cx, [bp + F_ECX]
    cmp cx, 1514
    ja pk_err
    cmp cx, 14
    jb pk_err
    push ds
    mov si, [bp + F_ESI]
    mov ds, [bp + F_DS]
    call tx_frame
    pop ds
    jnc pk_ok
    mov al, 12
    jmp pk_err

/* tx_frame: DS:SI frame of CX bytes (14..1514) in any segment - copied into
 * the TX buffer, one descriptor armed, waited for (DD), so the caller may
 * reuse its buffer. CF = 1 on timeout (st_eout), otherwise st_pout / st_bout
 * grow. Shared by send_pkt and by the queue-mode TX_KICK; no DOS calls, so
 * it also works from the INT 2Fh handler. */
tx_frame:
    push ds
    push es
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov dx, cx
    push cs
    pop es
    mov di, cs:[area]
    add di, A_TXBUF
    shr cx, 1
    rep movsw
    adc cx, cx
    rep movsb
    mov cx, dx
    movzx ecx, cx
    mov bx, cs:[tx_next]
    shl bx, 4
    add bx, cs:[area]
    add bx, A_TXRING
    mov eax, cs:[phys]
    add eax, A_TXBUF
    mov es:[bx], eax
    mov dword ptr es:[bx + 4], 0
    mov eax, ecx
    shl eax, 14
    mov es:[bx + 12], eax             /* PAYLEN */
    mov eax, ecx
    or eax, 0x2B300000                /* DEXT RS IFCS EOP, DTYP data */
    mov es:[bx + 8], eax
    mov ax, cs:[tx_next]
    inc ax
    and ax, TX_COUNT - 1
    mov cs:[tx_next], ax
    push ebx
    movzx eax, ax
    mov ebx, TDT0
    call reg_wr
    pop ebx
    mov dx, 20000                     /* about 20 ms */
1:  test byte ptr es:[bx + 12], 1     /* DD */
    jnz 2f
    out 0x80, al
    dec dx
    jnz 1b
    add dword ptr cs:[st_eout], 1
    stc
    jmp 3f
2:  add dword ptr cs:[st_pout], 1
    movzx ecx, cx
    add dword ptr cs:[st_bout], ecx
    clc
3:  pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    pop es
    pop ds
    ret

/* ------------------------------------------------------------------ */
/* register window: EBX = register, EAX = value; everything else kept   */
reg_rd:
    pushf
    cli
    cmp byte ptr cs:[acc], 1
    jne 1f
    push dx
    mov dx, cs:[iobase]
    mov eax, ebx
    out dx, eax
    add dx, 4
    in eax, dx
    pop dx
    popf
    ret
1:  push fs
    push edi
    call unreal
    jc 2f
    mov edi, cs:[mmio]
    add edi, ebx
    mov eax, fs:[edi]
    call a20_back
    jmp 3f
2:  or eax, -1
3:  pop edi
    pop fs
    popf
    ret

reg_wr:
    pushf
    cli
    cmp byte ptr cs:[acc], 1
    jne 1f
    push dx
    push eax
    mov dx, cs:[iobase]
    mov eax, ebx
    out dx, eax
    add dx, 4
    pop eax
    out dx, eax
    pop dx
    popf
    ret
1:  push fs
    push edi
    call unreal
    jc 2f
    mov edi, cs:[mmio]
    add edi, ebx
    mov fs:[edi], eax
    call a20_back
2:  pop edi
    pop fs
    popf
    ret

/* FS = flat 4 GiB data segment (base 0), interrupts already off; CF in
 * V86 mode (no protected-mode switch possible there). */
unreal:
    push eax
    smsw ax
    test al, 1
    jnz 9f
    sgdt cs:[sv_gdtr]
    lgdt cs:[gdtr]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp 1f
1:  mov ax, 8
    mov fs, ax
    mov eax, cr0
    and al, 0xFE
    mov cr0, eax
    jmp 2f
2:  xor ax, ax
    mov fs, ax
    lgdt cs:[sv_gdtr]
    /* A20 on for the access (HIMEM leaves it off; the BAR may have bit 20
     * set): port 92h bit 1, put back by a20_back. Bit 0 (reset) stays 0. */
    in al, 0x92
    and al, 0xFE
    mov cs:[a20sv], al
    test al, 2
    jnz 3f
    or al, 2
    out 0x92, al
3:  pop eax
    clc
    ret
9:  pop eax
    stc
    ret

a20_back:
    test byte ptr cs:[a20sv], 2
    jnz 1f
    push ax
    in al, 0x92
    and al, 0xFC
    out 0x92, al
    pop ax
1:  ret
a20sv: .byte 0

/* ------------------------------------------------------------------ */
/* RX ring: deliver every finished frame, give the descriptors back.    */
/* Interrupts off, DS = CS, busy set by the caller.                      */
rx_poll:
    mov dx, 0xFFFF                    /* last refilled index */
    mov bp, RX_COUNT
1:  mov bx, [rx_next]
    mov di, bx
    shl di, 4
    add di, [area]                    /* DI = descriptor */
    mov eax, [di + 8]
    test al, 1                        /* DD */
    jz 4f
    movzx ecx, word ptr [di + 12]
    mov si, bx
    shl si, 11
    add si, [area]
    add si, A_RXBUF                   /* SI = buffer */
    test al, 2                        /* EOP */
    jz 2f
    test eax, FRAME_ERR
    jnz 2f
    cmp cx, 14
    jb 2f
    push bx
    push dx
    push di
    push bp
    call rx_dispatch
    pop bp
    pop di
    pop dx
    pop bx
    jmp 3f
2:  add dword ptr [st_ein], 1
    cmp word ptr [qseg], 0            /* the queue client sees the bad frames */
    je 6f
    push es
    mov es, [qseg]
    add dword ptr es:[Q_RXERR], 1
    pop es
6:
3:  movzx eax, bx
    shl eax, 11
    add eax, [phys]
    add eax, A_RXBUF
    mov [di], eax
    xor eax, eax
    mov [di + 4], eax
    mov [di + 8], eax
    mov [di + 12], eax
    mov dx, bx
    inc bx
    and bx, RX_COUNT - 1
    mov [rx_next], bx
    dec bp
    jnz 1b
4:  cmp dx, 0xFFFF
    je 5f
    movzx eax, dx
    mov ebx, RDT0
    call reg_wr
5:  ret

/* SI = frame in our segment, CX = length: first matching handle gets it */
deliver:
    xor bx, bx
1:  cmp byte ptr [handles + bx + H_USE], 0
    je 2f
    movzx ax, byte ptr [handles + bx + H_LEN]
    test ax, ax
    jz 3f
    push si
    push cx
    mov cx, ax
    add si, 12
    lea di, [handles + bx + H_TYPE]
    push ds
    pop es
    repe cmpsb
    pop cx
    pop si
    je 3f
2:  add bx, H_SIZE
    cmp bx, MAX_HANDLES * H_SIZE
    jb 1b
    add dword ptr [st_lost], 1
    ret
3:  mov eax, [handles + bx + H_RECV]
    mov [upcall], eax
    shr bx, 4
    inc bx                            /* BX = handle */
    mov [sv_ss], ss
    mov [sv_sp], sp
    push cs
    pop ss
    mov sp, offset stack_top
    push si
    push cx
    push bx
    xor ax, ax
    CALLFAR upcall                    /* AX=0: ES:DI = buffer or 0:0 */
    pop bx
    pop cx
    pop si
    push cs
    pop ds
    mov ax, es
    or ax, di
    jz 4f
    push es
    push di
    push cx
    cld
    shr cx, 1
    rep movsw
    adc cx, cx
    rep movsb
    pop cx
    pop si
    pop ds                            /* DS:SI = the receiver's copy */
    push cx
    mov ax, 1
    CALLFAR upcall
    pop cx
    push cs
    pop ds
    add dword ptr [st_pin], 1
    movzx ecx, cx
    add dword ptr [st_bin], ecx
    jmp 5f
4:  add dword ptr [st_lost], 1
5:  cli
    mov ss, cs:[sv_ss]
    mov sp, cs:[sv_sp]
    ret

/* ------------------------------------------------------------------ */
/* Queue mode: a frame ring a protected-mode client polls (INT 2Fh     */
/* AX=5553h). The driver writes the heads, the client the tails; no    */
/* upcall, no DOS call from the ISR (the log is a memory ring).         */

/* SI = frame in our segment, CX = length: queue when a client is
 * attached, else the packet-driver upcall. */
rx_dispatch:
    cmp word ptr [qseg], 0
    je 2f
    push es
    mov es, [qseg]
    test byte ptr es:[Q_FLAGS], QF_ATTACH
    pop es
    jz 2f
    jmp q_rx_frame
2:  jmp deliver

/* RX ring: SI = frame, CX = length, all registers and flags kept. */
q_rx_frame:
    pushf
    push ds
    push es
    pushad
    cld
    mov ax, cs:[qseg]
    or ax, ax
    jz 9f
    mov es, ax
    mov dx, es:[Q_RXHEAD]
    mov bx, dx
    inc bx
    and bx, RX_COUNT - 1
    cmp bx, es:[Q_RXTAIL]
    je 8f                             /* ring full: drop, count it */
    movzx eax, dx
    imul eax, Q_RXSTR
    add eax, Q_RXBUF
    mov di, ax
    add di, 8
    push cx
    rep movsb                         /* DS:SI -> ES:DI (DS is ours) */
    pop cx
    mov di, ax                        /* rep does not touch AX */
    mov word ptr es:[di], cx          /* len */
    mov word ptr es:[di + 2], 1       /* flags: complete frame */
    mov ax, es:[Q_SEQ]
    mov word ptr es:[di + 4], ax      /* seq */
    inc ax
    mov es:[Q_SEQ], ax
    mov es:[Q_RXHEAD], bx
    add dword ptr cs:[st_pin], 1
    movzx ecx, cx
    add dword ptr cs:[st_bin], ecx
    jmp 9f
8:  add dword ptr es:[Q_RXDROP], 1
    push ds
    push si
    mov si, offset qlog_full
    mov cx, qlog_full_l
    call q_log
    pop si
    pop ds
9:  popad
    pop es
    pop ds
    popf
    ret

/* TX_KICK: send the slots the client queued, one by one, and give the
 * descriptor back before the next. Runs in the caller's context (INT 2Fh),
 * never in an ISR. AL: 0 sent, 1 nothing queued, 2 no client, 3 send error. */
q_tx_kick:
    push ds
    push es
    push bx
    push cx
    push dx
    push si
    push di
    mov ax, cs:[qseg]
    or ax, ax
    jz 7f
    mov es, ax
    test byte ptr es:[Q_FLAGS], QF_ATTACH
    jz 7f
    mov al, 1
1:  mov bx, es:[Q_TXTAIL]
    cmp bx, es:[Q_TXHEAD]
    je 6f
    movzx eax, bx
    imul eax, Q_TXSTR
    add eax, Q_TXBUF
    mov di, ax
    mov cx, es:[di]                   /* length in the slot header */
    cmp cx, 1514
    ja 4f
    cmp cx, 14
    jb 4f
    push es
    pop ds                            /* DS:SI = the frame in the block */
    mov si, di
    add si, 8
    call tx_frame
    push cs
    pop ds
    jc 4f
    add dword ptr es:[Q_TXDONE], 1
    xor al, al
    jmp 5f
4:  add dword ptr es:[Q_TXERR], 1
    add dword ptr es:[Q_TXBUSY], 1
    mov al, 3
    push si
    mov si, offset qlog_txerr
    mov cx, qlog_txerr_l
    call q_log
    pop si
5:  mov bx, es:[Q_TXTAIL]
    inc bx
    and bx, Q_TXCOUNT - 1
    mov es:[Q_TXTAIL], bx
    cmp al, 3
    je 6f                             /* stop at the first failure */
    jmp 1b
6:  jmp 8f
7:  mov al, 2
8:  pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop es
    pop ds
    ret

/* Text log: CX bytes from DS:SI (our segment) appended to the ring; a full
 * ring counts a drop and writes nothing. Never calls DOS. */
q_log:
    pushf
    push es
    pushad
    cld
    mov ax, cs:[qseg]
    or ax, ax
    jz 9f
    mov es, ax
    mov bx, es:[Q_LOGHEAD]
    mov dx, es:[Q_LOGTAIL]
    mov ax, bx
    sub ax, dx
    and ax, Q_LOGBUFSZ - 1            /* bytes in use */
    mov di, Q_LOGBUFSZ - 1
    sub di, ax                        /* free */
    cmp di, cx
    jb 8f
    mov ax, bx
    add ax, cx
    and ax, Q_LOGBUFSZ - 1
    push ax                           /* new head */
    mov di, bx
    add di, Q_LOGOFF
    mov dx, Q_LOGBUFSZ
    sub dx, bx                        /* room to the end of the ring */
    cmp dx, cx
    jae 1f
    push cx
    mov cx, dx
    rep movsb
    mov di, Q_LOGOFF
    pop cx
    sub cx, dx
1:  rep movsb
    pop ax
    mov es:[Q_LOGHEAD], ax
    jmp 9f
8:  add dword ptr es:[Q_LOGDROP], 1
9:  popad
    pop es
    popf
    ret

/* INT 2Fh: AX=5553h is ours, everything else goes to the previous handler
 * with the caller's registers untouched. */
int2f:
    cmp ax, 0x5553
    jne q_chain
    push ds
    push es
    pushad
    mov bp, sp
    push cs
    pop ds
    cmp bx, 0xFFFF
    je q_query
    cmp bx, 1
    je q_attach
    cmp bx, 2
    je q_state
    cmp bx, 3
    je q_kick
    cmp bx, 4
    je q_free
    popad                             /* unknown subfunction: pass it on */
    pop es
    pop ds
q_chain:
    JMPFAR old2f
q_out:
    popad
    pop es
    pop ds
    iret

/* query: AL=0xFF present, ES:DI = block, CX version, DX flags */
q_query:
    mov ax, [qseg]
    or ax, ax
    jz 1f
    mov [bp + F_ES], ax
    mov word ptr [bp + F_EDI], 0
    mov byte ptr [bp + F_EAX], 0xFF
    mov word ptr [bp + F_ECX], 0x0100
    mov es, ax
    mov dx, es:[Q_FLAGS]
    mov [bp + F_EDX], dx
    jmp q_out
1:  mov byte ptr [bp + F_EAX], 0
    jmp q_out

/* ATTACH: AL=0 ok (block in ES:DI, CX version, DX flags), 1 no driver,
 * 2 already owned by somebody. Kills the upcalls, empties the rings. */
q_attach:
    mov ax, [qseg]
    or ax, ax
    jz q_nodrv
    mov es, ax
    test byte ptr es:[Q_FLAGS], QF_ATTACH
    jnz q_busy
    or byte ptr es:[Q_FLAGS], QF_ATTACH + QF_SUPPRESS
    mov word ptr es:[Q_RXHEAD], 0
    mov word ptr es:[Q_RXTAIL], 0
    mov word ptr es:[Q_TXHEAD], 0
    mov word ptr es:[Q_TXTAIL], 0
    mov [bp + F_ES], ax
    mov word ptr [bp + F_EDI], 0
    mov byte ptr [bp + F_EAX], 0
    mov word ptr [bp + F_ECX], 0x0100
    mov dx, es:[Q_FLAGS]
    mov [bp + F_EDX], dx
    mov si, offset qlog_attach
    mov cx, qlog_attach_l
    call q_log
    jmp q_out
q_nodrv:
    mov byte ptr [bp + F_EAX], 1
    jmp q_out
q_busy:
    mov byte ptr [bp + F_EAX], 2
    jmp q_out

/* GET_STATE: AL=0, ES:DI = block, CX = frames waiting in the RX ring,
 * DX = frames waiting in the TX ring; the counters live in the header. */
q_state:
    mov ax, [qseg]
    or ax, ax
    jz 1f
    mov byte ptr [bp + F_EAX], 0
    mov [bp + F_ES], ax
    mov word ptr [bp + F_EDI], 0
    mov es, ax
    mov cx, es:[Q_RXHEAD]
    sub cx, es:[Q_RXTAIL]
    and cx, RX_COUNT - 1
    mov [bp + F_ECX], cx
    mov dx, es:[Q_TXHEAD]
    sub dx, es:[Q_TXTAIL]
    and dx, Q_TXCOUNT - 1
    mov [bp + F_EDX], dx
    jmp q_out
1:  mov byte ptr [bp + F_EAX], 1
    jmp q_out

/* TX_KICK: the return code of q_tx_kick lands in AL */
q_kick:
    call q_tx_kick
    /* STANDARD Windows need not reflect the TSR's timer/PCI interrupt while
     * a protected client is running. Poll RX in this real-mode call too.
     * Use the same busy exclusion as the ISR, with IF already clear, and
     * preserve BP (the saved interrupt frame) across the RX walker. */
    mov [bp + F_EAX], al
    cmp byte ptr [busy], 0
    jne q_out
    mov byte ptr [busy], 1
    push bp
    push es
    call rx_poll
    pop es
    pop bp
    mov byte ptr [busy], 0
    jmp q_out

/* RELEASE: AL=0 back to upcall-only (or 1 nothing attached); pending frames
 * are abandoned, the packet driver handles the next frames itself again. */
q_free:
    mov ax, [qseg]
    or ax, ax
    jz 1f
    mov es, ax
    test byte ptr es:[Q_FLAGS], QF_ATTACH
    jz 1f
    and byte ptr es:[Q_FLAGS], 0xFF - (QF_ATTACH + QF_SUPPRESS)
    mov ax, es:[Q_RXHEAD]
    mov es:[Q_RXTAIL], ax
    mov ax, es:[Q_TXHEAD]
    mov es:[Q_TXTAIL], ax
    mov si, offset qlog_release
    mov cx, qlog_release_l
    call q_log
    mov byte ptr [bp + F_EAX], 0
    jmp q_out
1:  mov byte ptr [bp + F_EAX], 1
    jmp q_out

/* timer: BIOS first, then poll */
int08:
    pushf
    CALLFAR old08
    push ds
    push es
    pushad
    push cs
    pop ds
    cli
    cmp byte ptr [busy], 0
    jne 1f
    mov byte ptr [busy], 1
    call rx_poll
    mov byte ptr [busy], 0
1:  popad
    pop es
    pop ds
    iret

/* PCI INTx */
irq_isr:
    push ds
    push es
    pushad
    push cs
    pop ds
    mov ebx, ICR
    call reg_rd                       /* reading acknowledges the causes */
    test eax, 0x80000000              /* INT_ASSERTED: ours */
    jnz 1f
    popad
    pop es
    pop ds
    JMPFAR oldirq
1:  mov ebx, IMC
    or eax, -1
    call reg_wr
    mov ebx, STATUS
    call reg_rd                       /* flush: INTx drops */
    mov al, 0x20
    cmp byte ptr [irq], 8
    jb 2f
    out 0xA0, al
2:  out 0x20, al
    cmp byte ptr [busy], 0
    jne 3f
    mov byte ptr [busy], 1
    call rx_poll
    mov byte ptr [busy], 0
3:  mov ebx, IMS
    mov eax, IMS_MASK
    call reg_wr
    popad
    pop es
    pop ds
    iret

    .p2align 1
stack:   .space 1024
stack_top:
resident_end:

/* ================================================================== */
/* install (not resident)                                              */
    .p2align 2
pci_addr: .word 0                     /* bus:devfn */
chipflag: .byte 0                     /* 1 82576, 2 I210 family, 4 I211 */
pcibios:  .byte 0
opt_p:    .byte 0
opt_m:    .byte 0
opt_s:    .byte 0
opt_q:    .byte 0
v86:      .byte 0
vds:      .byte 0
plltries: .byte 0
macsrc:   .byte 0
bar0:     .long 0
cmdreg:   .long 0
phyid:    .long 0
dds:      .long 0                     /* VDS DMA descriptor: size */
          .long 0                     /* offset */
          .word 0                     /* segment */
          .word 0                     /* buffer id */
          .long 0                     /* physical address */
pmsave:   .space 28

/* device id, flags */
chips:
    .word 0x1539, 6
    .word 0x1533, 2
    .word 0x1536, 2
    .word 0x1537, 2
    .word 0x1538, 2
    .word 0x157B, 2
    .word 0x157C, 2
    .word 0x10C9, 1
    .word 0x10E6, 1
    .word 0x10E7, 1
    .word 0x10E8, 1
    .word 0x1526, 1
    .word 0x150A, 1
    .word 0x1518, 1
    .word 0
nchip_names:
nm_i211:  .ascii "Intel I211$"
nm_i210:  .ascii "Intel I210$"
nm_82576: .ascii "Intel 82576$"

msg_banner: .ascii "USOSPKT 0.1 - packet driver for Intel I211/I210/82576 (igb), GPL-3.0-or-later\r\n$"
msg_help:   .ascii "Usage: USOSPKT [vector 0x60..0x80] [/P polled] [/M force MMIO] [/S PCI scan, no BIOS]\r\n$"
msg_iofail: .ascii "\r\nI/O BAR reads all ones, trying MMIO$"
msg_inuse:  .ascii "USOSPKT: a packet driver already uses this vector; nothing loaded.\r\n$"
msg_again:  .ascii "USOSPKT: already resident (one copy per NIC); nothing loaded.\r\n$"
msg_none:  .ascii "USOSPKT: no Intel I211/I210/82576 network controller found; nothing loaded.\r\n$"
msg_noacc:  .ascii "\r\nUSOSPKT: no I/O BAR and MMIO is not usable (V86 mode / EMM386, BAR unassigned or above 4 GiB); nothing loaded.\r\n$"
msg_reset:  .ascii "\r\nUSOSPKT: the controller did not come out of reset; nothing loaded.\r\n$"
msg_mem:    .ascii "\r\nUSOSPKT: no memory / DMA region for the rings; nothing loaded.\r\n$"
msg_nic:    .ascii "NIC 8086:$"
msg_at:     .ascii " at PCI $"
msg_bios:   .ascii " (PCI BIOS)$"
msg_scan:   .ascii " (config scan)$"
msg_cfg:    .ascii "\r\nPCI status/command $"
msg_bar0:   .ascii " BAR0 $"
msg_bario:  .ascii " I/O BAR $"
msg_line:   .ascii " pin/line $"
msg_io:     .ascii "\r\nRegisters: I/O BAR port $"
msg_io2:    .ascii " (IOADDR/IODATA)$"
msg_mm:     .ascii "\r\nRegisters: MMIO $"
msg_mm2:    .ascii " (flat FS, real mode)$"
msg_irq:    .ascii "\r\nInterrupt: IRQ $"
msg_irq2:   .ascii " (PCI INTx) + timer poll$"
msg_poll:   .ascii "\r\nInterrupt: none, polled from the timer (INT 08h)$"
msg_dma:    .ascii "\r\nDMA block: phys $"
msg_vds:    .ascii " (VDS)$"
msg_queue:  .ascii "\r\nQueue block: $"
msg_queue2: .ascii "h:0000, size $"
msg_mac:    .ascii "\r\nMAC $"
msg_msrc:   .ascii " source $"
msg_pll:    .ascii " PLL $"
msg_phy:    .ascii "\r\nPHY $"
msg_link:   .ascii " link up $"
msg_mbps:   .ascii " Mb/s$"
msg_full:   .ascii " full duplex$"
msg_half:   .ascii " half duplex$"
msg_down:   .ascii " link down (the network may come up later)$"
msg_inst:   .ascii "\r\nInstalled at INT $"
msg_res:    .ascii "h, resident paragraphs $"
msg_crlf:   .ascii "\r\n$"

print:                                /* DX = '$' string */
    push ax
    mov ah, 9
    int 0x21
    pop ax
    ret

/* EAX value, CL hex digits */
print_hex:
    push eax
    push ebx
    push cx
    push dx
    mov ebx, eax
    mov ch, cl
    shl cl, 2
    ror ebx, cl                       /* rotate so the first digit is on top */
    mov cl, ch
1:  rol ebx, 4
    mov dl, bl
    and dl, 15
    add dl, '0'
    cmp dl, '9'
    jbe 2f
    add dl, 7
2:  mov ah, 2
    int 0x21
    dec cl
    jnz 1b
    pop dx
    pop cx
    pop ebx
    pop eax
    ret

putc:                                 /* DL */
    push ax
    mov ah, 2
    int 0x21
    pop ax
    ret

/* microseconds (approximately: one port 80h write each), CX */
udelay:
    push cx
1:  out 0x80, al
    loop 1b
    pop cx
    ret
mdelay:                               /* CX ms */
    push cx
1:  push cx
    mov cx, 1000
    call udelay
    pop cx
    loop 1b
    pop cx
    ret

/* PCI config, mechanism 1: DI = register; EAX in / out */
cfg_addr:
    push eax
    movzx eax, word ptr [pci_addr]
    shl eax, 8
    or eax, 0x80000000
    mov dx, di
    and dl, 0xFC
    or al, dl
    mov dx, 0xCF8
    out dx, eax
    pop eax
    mov dx, di
    and dx, 3
    add dx, 0xCFC
    ret
cfg_rd32:
    push dx
    call cfg_addr
    in eax, dx
    pop dx
    ret
cfg_wr32:
    push dx
    call cfg_addr
    out dx, eax
    pop dx
    ret
cfg_wr16:
    push dx
    call cfg_addr
    out dx, ax
    pop dx
    ret

/* DS:SI -> next non-blank; AL = char, 0 at the end */
skipbl:
1:  lodsb
    cmp al, ' '
    je 1b
    cmp al, 9
    je 1b
    cmp al, 13
    jne 2f
    xor al, al
2:  ret

install:
    cld
    mov dx, offset msg_banner
    call print
    /* no CPU check: an igb controller sits on PCI Express (Pentium 4 era
     * or later); the 32-bit instructions below need a 386 */
    /* command line */
    mov si, 0x81
    mov bl, [0x80]
    xor bh, bh
    mov byte ptr [si + bx], 13
arg_next:
    call skipbl
    test al, al
    jz args_done
    cmp al, '/'
    je arg_opt
    cmp al, '-'
    je arg_opt
    /* vector: hex, optional 0x */
    dec si
    cmp word ptr [si], 0x7830         /* "0x" */
    je 1f
    cmp word ptr [si], 0x5830         /* "0X" */
    jne 2f
1:  add si, 2
2:  xor bx, bx
3:  lodsb
    mov ah, al
    or ah, 0x20
    sub al, '0'
    cmp al, 9
    jbe 4f
    mov al, ah
    sub al, 'a' - 10
    cmp al, 10
    jb arg_bad
    cmp al, 15
    ja arg_bad
4:  shl bx, 4
    or bl, al
    mov al, [si]
    cmp al, ' '
    je 5f
    cmp al, 13
    je 5f
    cmp al, 9
    jne 3b
5:  cmp bx, 0x60
    jb arg_bad
    cmp bx, 0x80
    ja arg_bad
    mov [pvec], bl
    jmp arg_next
arg_opt:
    lodsb
    or al, 0x20
    cmp al, 'p'
    jne 1f
    mov byte ptr [opt_p], 1
    jmp arg_next
1:  cmp al, 'm'
    jne 2f
    mov byte ptr [opt_m], 1
    jmp arg_next
2:  cmp al, 's'
    jne 3f
    mov byte ptr [opt_s], 1
    jmp arg_next
3:  cmp al, 'q'                         /* /Q or -Q, case-insensitive */
    jne arg_bad
    mov byte ptr [opt_q], 1
    jmp arg_next
arg_bad:
    mov dx, offset msg_help
    call print
    mov ax, 0x4C05
    int 0x21
args_done:
    /* USOSPKT already resident on any vector (it would grab the same NIC),
     * or another packet driver on ours (signature at offset 3) */
    mov bx, 0x60 * 4
1:  xor ax, ax
    mov es, ax
    les di, es:[bx]
    mov ax, es
    or ax, di
    jz 3f
    add di, 3
    mov si, offset sig
    mov cx, 8
    repe cmpsb
    jne 3f
    inc di                            /* +12 */
    mov cx, 7
    repe cmpsb
    je 2f
    movzx ax, byte ptr [pvec]
    shl ax, 2
    cmp ax, bx
    jne 3f
    mov dx, offset msg_inuse
    jmp 4f
2:  mov dx, offset msg_again
4:  call print
    mov ax, 0x4C02
    int 0x21
3:  add bx, 4
    cmp bx, 0x80 * 4
    jbe 1b
    jmp vec_free
sig: .ascii "PKT DRVRUSOSPKT"
vec_free:
    push cs
    pop es
    smsw ax
    and al, 1
    mov [v86], al

    /* find the controller: PCI BIOS, else a mechanism-1 scan */
    cmp byte ptr [opt_s], 0
    jne scan
    mov ax, 0xB101
    xor edi, edi
    int 0x1A
    jc scan
    test ah, ah
    jnz scan
    cmp edx, 0x20494350               /* "PCI " */
    jne scan
    mov byte ptr [pcibios], 1
    mov bx, offset chips
1:  mov cx, [bx]
    jcxz scan
    push bx
    mov ax, 0xB102
    mov dx, 0x8086
    xor si, si
    int 0x1A
    mov dx, bx                        /* BH bus, BL device/function */
    pop bx
    jc 4f
    test ah, ah
    jnz 4f
    mov [pci_addr], dx
    mov al, [bx + 2]
    mov [chipflag], al
    jmp found
4:  add bx, 4
    jmp 1b
scan:
    mov byte ptr [pcibios], 0
    xor ax, ax
5:  mov [pci_addr], ax
    xor di, di
    call cfg_rd32
    cmp ax, 0x8086
    jne 7f
    shr eax, 16
    mov bx, offset chips
6:  mov cx, [bx]
    jcxz 7f
    cmp ax, cx
    je 8f
    add bx, 4
    jmp 6b
8:  mov al, [bx + 2]
    mov [chipflag], al
    jmp found
7:  mov ax, [pci_addr]
    inc ax
    jnz 5b
    mov dx, offset msg_none
    call print
    mov ax, 0x4C01
    int 0x21

found:
    mov dx, offset msg_nic
    call print
    xor di, di
    call cfg_rd32
    shr eax, 16
    mov cl, 4
    call print_hex
    mov dl, ' '
    call putc
    mov dx, offset nm_82576
    test byte ptr [chipflag], 1
    jnz 1f
    mov dx, offset nm_i210
    test byte ptr [chipflag], 4
    jz 1f
    mov dx, offset nm_i211
1:  call print
    mov dx, offset msg_at
    call print
    movzx eax, byte ptr [pci_addr + 1]
    mov cl, 2
    call print_hex
    mov dl, ':'
    call putc
    movzx eax, byte ptr [pci_addr]
    shr al, 3
    call print_hex
    mov dl, '.'
    call putc
    movzx eax, byte ptr [pci_addr]
    and al, 7
    mov cl, 1
    call print_hex
    mov dx, offset msg_scan
    cmp byte ptr [pcibios], 0
    je 2f
    mov dx, offset msg_bios
2:  call print

    /* BARs: the first I/O BAR with a base, BAR0 for MMIO */
    mov di, 0x10
    call cfg_rd32
    mov [bar0], eax
    mov di, 0x10
3:  call cfg_rd32
    test al, 1
    jz 4f
    and ax, 0xFFFC
    jz 5f
    mov [iobase], ax
    jmp 6f
4:  and al, 6
    cmp al, 4                         /* 64-bit memory BAR: skip the high half */
    jne 5f
    add di, 4
5:  add di, 4
    cmp di, 0x28
    jb 3b
6:  mov dx, offset msg_cfg
    call print
    mov di, 4
    call cfg_rd32
    mov cl, 8
    call print_hex
    mov dx, offset msg_bar0
    call print
    mov eax, [bar0]
    call print_hex
    mov dx, offset msg_bario
    call print
    movzx eax, word ptr [iobase]
    mov cl, 4
    call print_hex
    mov dx, offset msg_line
    call print
    mov di, 0x3C
    call cfg_rd32
    call print_hex
    mov di, 4
    call cfg_rd32
    mov [cmdreg], eax
    cmp word ptr [iobase], 0
    je try_mmio
    cmp byte ptr [opt_m], 0
    jne try_mmio
    mov byte ptr [acc], 1
    or ax, 5                          /* I/O decode + bus master */
    jmp acc_set
try_mmio:
    mov byte ptr [acc], 0
    mov eax, [bar0]
    test al, 1
    jnz no_acc
    cmp byte ptr [v86], 0
    jne no_acc
    and eax, 0xFFFFFFF0
    jz no_acc
    mov [mmio], eax
    mov eax, [bar0]
    and al, 6
    cmp al, 4
    jne 8f
    mov di, 0x14
    call cfg_rd32
    test eax, eax
    jnz no_acc
8:  mov byte ptr [acc], 2
    mov eax, [cmdreg]
    or ax, 6                          /* memory decode + bus master */
acc_set:
    and ax, 0xFBFF                    /* INTx allowed (bit 10 clear) */
    and eax, 0x0000FFFF               /* status bits are RW1C: write 0 */
    mov di, 4
    call cfg_wr16
    jmp acc_ok
no_acc:
    mov dx, offset msg_noacc
    call print
    mov ax, 0x4C03
    int 0x21
acc_ok:
    cmp byte ptr [acc], 1
    jne 1f
    mov ebx, STATUS
    call reg_rd
    cmp eax, -1
    jne 3f
    mov dx, offset msg_iofail
    call print
    jmp try_mmio
3:
    mov dx, offset msg_io
    call print
    movzx eax, word ptr [iobase]
    mov cl, 4
    call print_hex
    mov dx, offset msg_io2
    call print
    jmp 2f
1:  mov dx, offset msg_mm
    call print
    mov eax, [mmio]
    mov cl, 8
    call print_hex
    mov dx, offset msg_mm2
    call print
2:
    /* GDT base for the MMIO path */
    xor eax, eax
    mov ax, cs
    shl eax, 4
    add eax, offset gdt
    mov [gdtr + 2], eax

    /* DMA block behind the image, 128-byte aligned physically */
    xor eax, eax
    mov ax, cs
    shl eax, 4
    mov ebx, eax
    add eax, offset image_end + 127
    and eax, 0xFFFFFF80
    sub eax, ebx
    mov [area], ax
    add eax, AREA_SIZE
    cmp eax, 0xF000
    jb 1f
    mov dx, offset msg_mem
    call print
    mov ax, 0x4C06
    int 0x21
1:  mov di, [area]
    mov cx, AREA_SIZE / 2
    xor ax, ax
    rep stosw
    xor eax, eax
    mov ax, cs
    shl eax, 4
    movzx ebx, word ptr [area]
    add eax, ebx
    mov [phys], eax
    /* VDS (EMM386 sets 0040:007B bit 5) */
    push es
    xor ax, ax
    mov es, ax
    test byte ptr es:[0x47B], 0x20
    pop es
    jz 2f
    mov dword ptr [dds], AREA_SIZE
    movzx eax, word ptr [area]
    mov dword ptr [dds + 4], eax
    mov [dds + 8], cs
    mov di, offset dds
    mov ax, 0x8103
    mov dx, 0x000C                    /* no buffer, no remap: contiguous or fail */
    int 0x4B
    jnc 3f
    mov dx, offset msg_mem
    call print
    mov ax, 0x4C06
    int 0x21
3:  mov eax, [dds + 12]
    mov [phys], eax
    mov byte ptr [vds], 1
2:  /* Queue-mode block (INT 2Fh AX=5553h) only with /Q: its own segment
     * directly behind the DMA area, so the client gets one contiguous,
     * 16-byte aligned segment and the DMA block keeps the layout mTCP
     * already uses. Without /Q nothing is reserved and INT 2Fh is left
     * alone (the driver is then exactly the packet driver above). */
    cmp byte ptr [opt_q], 0
    je no_q_block
    mov ax, [area]
    add ax, AREA_SIZE
    add ax, 15
    and ax, 0xFFF0
    mov [qoff], ax
    mov bx, ax
    shr bx, 4
    mov dx, cs
    add dx, bx
    mov [qseg], dx
    /* it must fit in the memory DOS gave us (PSP:0002 = first free para) */
    xor eax, eax
    mov ax, cs
    shl eax, 4
    movzx ebx, word ptr [qoff]
    add eax, ebx
    add eax, Q_SIZE
    xor ebx, ebx
    mov bx, [0x0002]
    shl ebx, 4
    cmp eax, ebx
    jb 1f
    mov dx, offset msg_mem
    call print
    mov ax, 0x4C06
    int 0x21
1:  mov es, [qseg]
    xor di, di
    mov cx, Q_SIZE / 2
    xor ax, ax
    rep stosw
    mov dword ptr es:[Q_MAGIC], 0x31515355   /* "USQ1" */
    mov word ptr es:[Q_VERSION], 0x0100
    mov word ptr es:[Q_HDRSZ], Q_HDR
    mov word ptr es:[Q_FLAGS], QF_READY
    mov word ptr es:[Q_RXCNT], RX_COUNT
    mov word ptr es:[Q_RXSTRIDE], Q_RXSTR
    mov dword ptr es:[Q_RXBASE], Q_RXBUF
    mov word ptr es:[Q_TXCNT], Q_TXCOUNT
    mov word ptr es:[Q_TXSTRIDE], Q_TXSTR
    mov dword ptr es:[Q_TXBASE], Q_TXBUF
    mov word ptr es:[Q_LOGSZ], Q_LOGBUFSZ
    mov dword ptr es:[Q_LOGBASE], Q_LOGOFF
    mov al, [pvec]
    mov es:[Q_INT], al
    push cs
    pop es
    mov si, offset qlog_ready          /* the log says the mode is on */
    mov cx, qlog_ready_l
    call q_log
no_q_block:
    call nic_reset
    jnc 1f
    mov dx, offset msg_reset
    call print
    mov ax, 0x4C04
    int 0x21
1:  call nic_mac
    call set_mac
    /* nic_mac populates mac only after reset. Publishing it before this
     * point gives the protected client an all-zero Ethernet address. */
    cmp word ptr [qseg], 0
    je 1f
    push es
    mov es, [qseg]
    mov si, offset mac
    mov di, Q_MAC
    mov cx, 3
    rep movsw
    pop es
1:
    call phy_init
    call nic_start

    /* interrupt line */
    mov di, 0x3C
    call cfg_rd32
    cmp byte ptr [opt_p], 0
    jne 2f
    test ah, ah                       /* interrupt pin */
    jz 2f
    cmp al, 3                         /* 0-2: timer, keyboard, cascade */
    jb 2f
    cmp al, 15
    ja 2f
    mov [irq], al
2:
    /* hook: timer, IRQ, packet vector */
    cli
    xor ax, ax
    mov es, ax
    mov eax, es:[0x08 * 4]
    mov [old08], eax
    mov word ptr es:[0x08 * 4], offset int08
    mov es:[0x08 * 4 + 2], cs
    cmp byte ptr [opt_q], 0            /* /Q: the queue multiplex handler */
    je hook_done
    mov eax, es:[0x2F * 4]
    mov [old2f], eax
    mov word ptr es:[0x2F * 4], offset int2f
    mov es:[0x2F * 4 + 2], cs
hook_done:
    movzx bx, byte ptr [irq]
    cmp bl, 0xFF
    je 4f
    mov cx, bx
    add bx, 8
    cmp cl, 8
    jb 3f
    add bx, 0x70 - 16
3:  shl bx, 2
    mov eax, es:[bx]
    mov [oldirq], eax
    mov word ptr es:[bx], offset irq_isr
    mov es:[bx + 2], cs
    /* unmask in the 8259(s) */
    mov dx, 0x21
    cmp cl, 8
    jb 5f
    in al, 0x21
    and al, 0xFB                      /* cascade */
    out 0x21, al
    mov dx, 0xA1
    sub cl, 8
5:  mov ah, 1
    shl ah, cl
    not ah
    in al, dx
    and al, ah
    out dx, al
    mov ebx, IMS
    mov eax, IMS_MASK
    call reg_wr
4:  movzx bx, byte ptr [pvec]
    shl bx, 2
    mov word ptr es:[bx], offset pkt_entry
    mov es:[bx + 2], cs
    push cs
    pop es
    sti

    /* report */
    cmp byte ptr [irq], 0xFF
    je 1f
    mov dx, offset msg_irq
    call print
    movzx eax, byte ptr [irq]
    mov cl, 2
    call print_hex
    mov dx, offset msg_irq2
    call print
    jmp 2f
1:  mov dx, offset msg_poll
    call print
2:  mov dx, offset msg_dma
    call print
    mov eax, [phys]
    mov cl, 8
    call print_hex
    cmp byte ptr [vds], 0
    je 3f
    mov dx, offset msg_vds
    call print
3:  cmp byte ptr [opt_q], 0
    je no_q_report
    mov dx, offset msg_queue
    call print
    mov eax, [qseg]
    mov cl, 4
    call print_hex
    mov dx, offset msg_queue2
    call print
    mov eax, Q_SIZE
    mov cl, 4
    call print_hex
no_q_report:
    mov dx, offset msg_mac
    call print
    mov si, offset mac
    mov bx, 6
4:  lodsb
    movzx eax, al
    mov cl, 2
    call print_hex
    dec bx
    jz 5f
    mov dl, ':'
    call putc
    jmp 4b
5:  mov dx, offset msg_msrc
    call print
    movzx eax, byte ptr [macsrc]
    mov cl, 1
    call print_hex
    test byte ptr [chipflag], 2
    jz 6f
    mov dx, offset msg_pll
    call print
    movzx eax, byte ptr [plltries]
    mov cl, 2
    call print_hex
6:  mov dx, offset msg_phy
    call print
    mov eax, [phyid]
    mov cl, 8
    call print_hex
    /* link: up to about 5 s */
    xor ax, ax
    mov es, ax
    mov si, es:[0x46C]
7:  mov ebx, STATUS
    call reg_rd
    test al, 2
    jnz 8f
    mov ax, es:[0x46C]
    sub ax, si
    cmp ax, 91
    jb 7b
    mov dx, offset msg_down
    call print
    jmp 9f
8:  push eax
    mov dx, offset msg_link
    call print
    pop eax
    mov ebx, eax
    shr eax, 6
    and al, 3
    mov dx, offset s10
    cmp al, 1
    jb 1f
    mov dx, offset s100
    je 1f
    mov dx, offset s1000
1:  call print
    mov dx, offset msg_mbps
    call print
    mov dx, offset msg_full
    test bl, 1
    jnz 2f
    mov dx, offset msg_half
2:  call print
9:  push cs
    pop es
    mov dx, offset msg_inst
    call print
    movzx eax, byte ptr [pvec]
    mov cl, 2
    call print_hex
    mov dx, offset msg_res
    call print
    cmp byte ptr [opt_q], 0            /* the block is the only extra memory */
    je res_area
    movzx eax, word ptr [qoff]
    add eax, Q_SIZE
    jmp res_size
res_area:
    movzx eax, word ptr [area]
    add eax, AREA_SIZE
res_size:
    add eax, 15
    shr eax, 4
    push ax
    mov cl, 4
    call print_hex
    mov dx, offset msg_crlf
    call print
    /* environment away, handles closed (a redirected log is complete),
     * stay resident */
    mov es, [0x2C]
    mov ah, 0x49
    int 0x21
    xor bx, bx
1:  mov ah, 0x3E
    int 0x21
    inc bx
    cmp bx, 5
    jb 1b
    pop dx
    mov ax, 0x3100
    int 0x21

s10:   .ascii "10$"
s100:  .ascii "100$"
s1000: .ascii "1000$"

/* ------------------------------------------------------------------ */
/* NIC bring-up (install time); usosnet_igb.c IgbReset / IgbReadMac /   */
/* IgbPhyInit / IgbStart / IgbPllCheck                                   */
irq_off:
    mov ebx, IMC
    or eax, -1
    call reg_wr
    mov ebx, EIMC
    call reg_wr
    mov ebx, STATUS
    call reg_rd
    ret

/* EBX register, EDX mask: wait (ms in CX) until (reg & mask) == 0 */
wait_clear:
1:  call reg_rd
    test eax, edx
    jz 2f
    push cx
    mov cx, 1
    call mdelay
    pop cx
    loop 1b
2:  ret
/* ... until (reg & mask) != 0 */
wait_set:
1:  call reg_rd
    test eax, edx
    jnz 2f
    push cx
    mov cx, 1
    call mdelay
    pop cx
    loop 1b
2:  ret

nic_reset:
    call irq_off
    mov ebx, RCTL
    xor eax, eax
    call reg_wr
    mov ebx, TCTL
    mov eax, 8                        /* PSP */
    call reg_wr
    mov ebx, STATUS
    call reg_rd
    mov cx, 10
    call mdelay
    mov ebx, CTRL
    call reg_rd
    or eax, 4                         /* GIO master disable */
    call reg_wr
    mov ebx, STATUS
    mov edx, 1 << 19
    mov cx, 800
    call wait_clear
    mov ebx, CTRL
    call reg_rd
    or eax, 1 << 26                   /* RST */
    call reg_wr
    mov cx, 5
    call mdelay
    mov cx, 100
1:  call reg_rd
    cmp eax, -1
    je 2f
    test eax, 1 << 26
    jz 3f
2:  push cx
    mov cx, 1
    call mdelay
    pop cx
    loop 1b
3:  mov ebx, EECD
    mov edx, 1 << 9                   /* auto-read done */
    mov cx, 100
    call wait_set
    mov ebx, STATUS
    mov edx, 1 << 21                  /* PF_RST_DONE */
    mov cx, 100
    call wait_set
    call reg_rd
    cmp eax, -1
    jne 4f
    stc
    ret
4:  call pll_check
    call irq_off
    mov ebx, ICR
    call reg_rd
    mov ebx, EICR
    call reg_rd
    xor eax, eax
    mov ebx, GPIE
    call reg_wr
    mov ebx, IAM
    call reg_wr
    mov ebx, EIAC
    call reg_wr
    mov ebx, EIAM
    call reg_wr
    mov ebx, CTRL_EXT
    call reg_rd
    or eax, 1 << 28                   /* DRV_LOAD */
    call reg_wr
    clc
    ret

/* MDIC: CX = PHY register; read -> AX (CF on error); write AX */
mdic_rd:
    movzx eax, cx
    shl eax, 16
    or eax, (1 << 21) | (2 << 26)
    jmp mdic_go
mdic_wr:
    push ax
    movzx eax, cx
    shl eax, 16
    or eax, (1 << 21) | (1 << 26)
    pop ax
mdic_go:
    push ebx
    push cx
    mov ebx, MDIC
    call reg_wr
    mov cx, 2000
1:  push cx
    mov cx, 5
    call udelay
    pop cx
    call reg_rd
    test eax, 1 << 28
    jnz 2f
    loop 1b
    stc
    jmp 3f
2:  test eax, 1 << 30
    stc
    jnz 3f
    clc
3:  pop cx
    pop ebx
    ret

/* iNVM word CX -> AX, CF if not found (type 1 records, the last wins) */
invm_word:
    push ebx
    push edx
    push si
    xor si, si                        /* found flag */
    mov ebx, INVM_DATA
1:  cmp ebx, INVM_DATA + 256
    jae 5f
    call reg_rd
    mov edx, eax
    and dl, 7
    jz 5f                             /* end of records */
    cmp dl, 2
    jne 2f
    add ebx, 4
    jmp 4f
2:  cmp dl, 4
    jne 3f
    add ebx, 32
    jmp 4f
3:  cmp dl, 1
    jne 4f
    mov edx, eax
    shr edx, 9
    and dx, 0x7F
    cmp dx, cx
    jne 4f
    shr eax, 16
    mov di, ax
    mov si, 1
4:  add ebx, 4
    jmp 1b
5:  mov ax, di
    cmp si, 1
    pop si
    pop edx
    pop ebx
    ret                               /* CF from cmp: si=0 -> CF set */

/* MAC into mac[], source into macsrc (1 RAL/RAH, 2 EERD, 3 iNVM, 5 raw, 6 made up) */
nic_mac:
    mov ebx, RAL0
    call reg_rd
    mov dword ptr [mac], eax
    mov ebx, RAH0
    call reg_rd
    mov word ptr [mac + 4], ax
    mov byte ptr [macsrc], 1
    test eax, eax
    jns 1f
    call mac_valid
    jnc 9f
1:  test byte ptr [chipflag], 2
    jz 3f
    mov ebx, EECD
    call reg_rd
    test eax, 1 << 19
    jnz 3f
    mov byte ptr [macsrc], 3
    xor cx, cx
2:  call invm_word
    jc 6f
    mov bx, cx
    shl bx, 1
    mov word ptr [mac + bx], ax
    inc cx
    cmp cx, 3
    jb 2b
    call mac_valid
    jnc 9f
    jmp 6f
3:  mov byte ptr [macsrc], 2
    xor cx, cx
4:  movzx eax, cx
    shl eax, 2
    or al, 1
    mov ebx, EERD
    call reg_wr
    push cx
    mov cx, 10000
5:  call reg_rd
    test al, 2
    jnz 7f
    push cx
    mov cx, 5
    call udelay
    pop cx
    loop 5b
    pop cx
    jmp 6f
7:  pop cx
    shr eax, 16
    mov bx, cx
    shl bx, 1
    mov word ptr [mac + bx], ax
    inc cx
    cmp cx, 3
    jb 4b
    test byte ptr [chipflag], 1
    jz 8f
    mov ebx, STATUS
    call reg_rd
    shr eax, 2
    and al, 3
    cmp al, 1
    jne 8f
    xor byte ptr [mac + 5], 1         /* 82576 second port */
8:  call mac_valid
    jnc 9f
6:  mov byte ptr [macsrc], 5
    mov ebx, RAL0
    call reg_rd
    mov dword ptr [mac], eax
    mov ebx, RAH0
    call reg_rd
    mov word ptr [mac + 4], ax
    call mac_valid
    jnc 9f
    mov byte ptr [macsrc], 6
    mov dword ptr [mac], 0x4F535502
    mov word ptr [mac + 4], 0x0153
9:  ret

/* CF if mac[] is all 00, all FF or multicast */
mac_valid:
    test byte ptr [mac], 1
    jnz 1f
    mov eax, dword ptr [mac]
    mov dx, word ptr [mac + 4]
    test eax, eax
    jnz 2f
    test dx, dx
    jz 1f
2:  cmp eax, -1
    jne 3f
    cmp dx, -1
    je 1f
3:  clc
    ret
1:  stc
    ret

phy_init:
    mov ebx, CTRL
    call reg_rd
    and eax, ~((1 << 11) | (1 << 12) | (1 << 31) | (1 << 27) | (1 << 28))
    or eax, 1 << 6                    /* SLU */
    call reg_wr
    mov cx, 1
    call mdelay
    mov cx, 2
    call mdic_rd
    jc 1f
    mov word ptr [phyid + 2], ax
    mov cx, 3
    call mdic_rd
    jc 1f
    mov word ptr [phyid], ax
1:  xor cx, cx
    call mdic_rd
    jc 2f
    push ax
    mov cx, 4
    mov ax, 0x01E1                    /* 10/100 half + full, no PAUSE */
    call mdic_wr
    mov cx, 9
    mov ax, 0x0300                    /* 1000BASE-T half + full */
    call mdic_wr
    pop ax
    and ax, 0xF7FF                    /* power up */
    or ax, 0x1200                     /* autoneg enable + restart */
    xor cx, cx
    call mdic_wr
2:  ret

nic_start:
    mov ebx, RCTL
    xor eax, eax
    call reg_wr
    mov ebx, MRQC
    call reg_wr
    mov ebx, MTA
1:  call reg_wr
    add ebx, 4
    cmp ebx, MTA + 512
    jb 1b
    /* TX ring */
    mov ebx, TXDCTL0
    call reg_wr
    mov eax, [phys]
    add eax, A_TXRING
    mov ebx, TDBAL0
    call reg_wr
    xor eax, eax
    mov ebx, TDBAH0
    call reg_wr
    mov eax, TX_COUNT * 16
    mov ebx, TDLEN0
    call reg_wr
    xor eax, eax
    mov ebx, TDH0
    call reg_wr
    mov ebx, TDT0
    call reg_wr
    mov word ptr [tx_next], 0
    mov ebx, TXDCTL0
    mov eax, (1 << 25) | 8 | (1 << 8) | (1 << 16)
    call reg_wr
    mov edx, 1 << 25
    mov cx, 10
    call wait_set
    mov ebx, TCTL
    mov eax, 2 | 8 | (0x0F << 4) | (0x3F << 12) | (1 << 24)
    call reg_wr
    /* RX ring: descriptors point at the buffers */
    mov ebx, RXDCTL0
    xor eax, eax
    call reg_wr
    mov di, [area]
    mov eax, [phys]
    add eax, A_RXBUF
    mov cx, RX_COUNT
2:  mov [di], eax
    add eax, BUF_SIZE
    add di, 16
    loop 2b
    mov eax, [phys]
    mov ebx, RDBAL0
    call reg_wr
    xor eax, eax
    mov ebx, RDBAH0
    call reg_wr
    mov eax, RX_COUNT * 16
    mov ebx, RDLEN0
    call reg_wr
    mov eax, 2 | (1 << 25) | (1 << 31)  /* 2 KiB, advanced one buffer, drop */
    mov ebx, SRRCTL0
    call reg_wr
    xor eax, eax
    mov ebx, RDH0
    call reg_wr
    mov ebx, RDT0
    call reg_wr
    mov word ptr [rx_next], 0
    mov ebx, RXDCTL0
    mov eax, (1 << 25) | 8 | (8 << 8) | (1 << 16)
    call reg_wr
    mov edx, 1 << 25
    mov cx, 10
    call wait_set
    mov ebx, RDT0
    mov eax, RX_COUNT - 1
    call reg_wr
    xor eax, eax
    mov ebx, IVAR0
    call reg_wr
    mov ebx, RCTL
    mov eax, RCTL_EN | RCTL_BAM | RCTL_SECRC
    call reg_wr
    ret

/* I210 / I211 without flash: PLL erratum (usosnet_igb.c IgbPllCheck) */
pll_check:
    mov byte ptr [plltries], 0
    test byte ptr [chipflag], 2
    jz 9f
    mov ebx, EECD
    call reg_rd
    test eax, 1 << 19
    jnz 9f
    mov ebx, WUC
    call reg_rd
    push eax                          /* [sp+?] wuc */
    mov ebx, MDICNFG
    call reg_rd
    push eax                          /* mdicnfg */
    and eax, 0x7FFFFFFF
    call reg_wr
    mov cx, 0x0A
    call invm_word
    jnc 1f
    mov ax, 0x202F
1:  mov [pll_al], ax
    mov byte ptr [plltries], 1
2:  call pll_ok
    jnc 8f
    cmp byte ptr [plltries], 5
    jb 3f
    or byte ptr [plltries], 0x80
    jmp 8f
3:  mov ebx, CTRL
    call reg_rd
    or eax, 1 << 31                   /* PHY reset */
    call reg_wr
    mov ebx, CTRL_EXT
    call reg_rd
    or eax, (1 << 20) | (1 << 18)
    call reg_wr
    mov ebx, WUC
    xor eax, eax
    call reg_wr
    movzx eax, word ptr [pll_al]
    or ax, 0x0010
    shl eax, 16
    or al, 0x0A << 4
    mov ebx, EEARBC_I210
    call reg_wr
    /* D3hot and back; command + BARs saved */
    mov si, offset pmsave
    mov di, 4
    call cfg_rd32
    mov [si], eax
    mov di, 0x10
4:  call cfg_rd32
    add si, 4
    mov [si], eax
    add di, 4
    cmp di, 0x28
    jb 4b
    call pm_offset                    /* DI = PMCSR */
    call cfg_rd32
    and ax, 0x7FFC
    or ax, 3
    call cfg_wr16
    mov cx, 1
    call mdelay
    call cfg_rd32
    and ax, 0x7FFC
    call cfg_wr16
    mov cx, 10
    call mdelay
    mov di, 0x10
    call cfg_rd32
    /* always put BARs + command back (D0 may have reset them; the I/O
     * decode bit matters for the IOADDR/IODATA path) */
    mov si, offset pmsave + 4
    mov di, 0x10
5:  mov eax, [si]
    call cfg_wr32
    add si, 4
    add di, 4
    cmp di, 0x28
    jb 5b
    mov eax, [pmsave]
    mov di, 4
    call cfg_wr16
6:  mov ebx, EECD
    mov edx, 1 << 9
    mov cx, 100
    call wait_set
    mov ebx, CTRL
    call reg_rd
    and eax, 0x7FFFFFFF
    call reg_wr
    mov cx, 5
    call mdelay
    movzx eax, word ptr [pll_al]
    shl eax, 16
    or al, 0x0A << 4
    mov ebx, EEARBC_I210
    call reg_wr
    mov bp, sp
    mov eax, [bp + 4]                 /* wuc */
    mov ebx, WUC
    call reg_wr
    inc byte ptr [plltries]
    jmp 2b
8:  pop eax
    mov ebx, MDICNFG
    call reg_wr
    pop eax                           /* wuc */
9:  ret
pll_al: .word 0

/* CF clear when the PHY PLL reads configured (page 0xFC reg 14 low byte != FF) */
pll_ok:
    mov cx, 22
    mov ax, 0xFC
    call mdic_wr
    push cx
    mov cx, 20
    call udelay
    pop cx
    mov cx, 14
    call mdic_rd
    pushf
    push ax
    mov cx, 20
    call udelay
    mov cx, 22
    xor ax, ax
    call mdic_wr
    pop ax
    popf
    jc 1f
    cmp al, 0xFF
    je 1f
    clc
    ret
1:  stc
    ret

/* DI = PMCSR offset (power management capability + 4), default 0x44 */
pm_offset:
    mov di, 4
    call cfg_rd32
    test eax, 1 << 20
    jz 3f
    mov di, 0x34
    call cfg_rd32
    movzx di, al
    and di, 0xFC
    mov cx, 48
1:  cmp di, 0x40
    jb 3f
    call cfg_rd32
    cmp al, 1
    je 2f
    movzx di, ah
    and di, 0xFC
    loop 1b
    jmp 3f
2:  add di, 4
    ret
3:  mov di, 0x44
    ret

image_end:
