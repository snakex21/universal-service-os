/*
 * USOSVGAR.COM - VGA register readback / latch probe for the Windows 3.x
 * redraw problem on the X470 (RX 560 VBIOS under CSMWrap).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Why: Windows 3.0a and 3.1 (VGA.DRV, 640x480x16 planar) leave broken areas
 * when windows are moved on the X470; Windows 1.x/2.x (IBMPS250.DRV) do not,
 * and QEMU's std VGA shows nothing. The 3.x VGA.DRV draws the mouse pointer
 * at interrupt time, also while another drawing call is in progress, and
 * saves the interrupted drawing state by READING the VGA registers back
 * (sequencer map mask through 3C5h with the index left at 2, graphics
 * controller 1/3/8, in 3.1 also 4/5), then stores the latches with a write
 * mode 1 write into off-screen memory and restores everything afterwards.
 * The 2.x driver never reads a VGA register (EGA style, shadows only). So a
 * register that does not read back what was written would corrupt exactly
 * the drawing that runs while the pointer moves.
 *
 * What: sets mode 12h, writes test values into every sequencer and graphics
 * controller register that VGA.DRV reads, reads them back (also with the
 * index left in place, as VGA.DRV does), checks the latch save/restore and
 * per-plane off-screen memory the way VGA.DRV uses them (A000:9B0C-9B0F for
 * 3.1, A000:BFF9-BFFF for 3.0), restores the previous text mode and prints
 * one report to standard output (the start batch appends it to
 * C:\USOS\DIAG\VGAREG.TXT). Reads and writes nothing else; no TSR.
 */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    jmp main

sig:    .ascii "USOSVGR1"
omode:  .byte 0
nbad:   .word 0
nlist:  .byte 0
ntest:  .word 0
mbad:   .word 0
lbad:   .word 0

/* --- output buffer ------------------------------------------------------ */
.equ OUTBUF, 0x1000
/* DI = write pointer into OUTBUF (kept in [optr]) */
optr:   .word OUTBUF

/* putc AL */
putc:
    push di
    push es
    push cs
    pop es
    mov di, word ptr [optr]
    cmp di, OUTBUF + 0xE00
    jae 1f
    stosb
    mov word ptr [optr], di
1:  pop es
    pop di
    ret

/* puts SI (zero terminated) */
puts:
    push ax
1:  lodsb
    or al, al
    jz 2f
    call putc
    jmp 1b
2:  pop ax
    ret

/* hex byte AL */
hex8:
    push ax
    push ax
    shr al, 4
    call hexd
    pop ax
    and al, 0x0f
    call hexd
    pop ax
    ret
hexd:
    add al, '0'
    cmp al, '9'
    jbe 1f
    add al, 'A' - '9' - 1
1:  jmp putc

/* hex word AX */
hex16:
    xchg al, ah
    call hex8
    xchg al, ah
    jmp hex8

sp_:
    push ax
    mov al, ' '
    call putc
    pop ax
    ret

crlf:
    mov al, 13
    call putc
    mov al, 10
    jmp putc

/* --- VGA register helpers ----------------------------------------------- */
/* rd: DX = index port, AL = index -> AL = data (index left at AL) */
rdreg:
    out dx, al
    inc dx
    in al, dx
    dec dx
    ret
/* wr: DX = index port, AL = index, AH = value */
wrreg:
    out dx, al
    inc dx
    xchg al, ah
    out dx, al
    xchg al, ah
    dec dx
    ret

/* Register table for the readback test: port, index, valid-bit mask. */
regtab:
    .word 0x3c4
    .byte 2, 0x0f
    .word 0x3ce
    .byte 0, 0x0f
    .word 0x3ce
    .byte 1, 0x0f
    .word 0x3ce
    .byte 2, 0x0f
    .word 0x3ce
    .byte 3, 0x1f
    .word 0x3ce
    .byte 4, 0x03
    .word 0x3ce
    .byte 5, 0x7b
    .word 0x3ce
    .byte 7, 0x0f
    .word 0x3ce
    .byte 8, 0xff
    .word 0
vals:   .byte 0x00, 0xff, 0x55, 0xaa, 0x01, 0x02, 0x03, 0x08, 0x0f, 0x10, 0x18, 0x41, 0x80
.equ NVALS, 13

s_head: .asciz "USOSVGAR 1 (VGA readback probe, mode 12h)"
s_def:  .asciz "after mode 12h: SEQ0-4"
s_gc:   .asciz " GC0-8"
s_idx:  .asciz "index readback 3C4/3CE:"
s_rb:   .asciz "readback tests "
s_bad:  .asciz " mismatches "
s_one:  .asciz "  bad "
s_w:    .asciz " wrote "
s_r:    .asciz " read "
s_impl: .asciz "implicit index (SEQ2 via 3C5, GC8 via 3CF):"
s_mem:  .asciz "plane memory 9600/9B0C/A000/BFF8/FFF8 mismatches "
s_lat:  .asciz "latch save/restore (9B0F, BFFF) mismatches "
s_okr:  .asciz "RESULT OK"
s_badr: .asciz "RESULT READBACK-BAD"
s_badm: .asciz "RESULT MEMORY-OR-LATCH-BAD"
s_nov:  .asciz "RESULT NO-MODE12 (BIOS did not set mode 12h)"

/* --- main --------------------------------------------------------------- */
main:
    cld
    mov ah, 0x0f
    int 0x10
    and al, 0x7f
    mov byte ptr [omode], al
    mov si, offset s_head
    call puts
    call crlf
    mov ax, 0x0012
    int 0x10
    mov ah, 0x0f
    int 0x10
    and al, 0x7f
    cmp al, 0x12
    je 1f
    mov si, offset s_nov
    call puts
    call crlf
    jmp done

1:  /* defaults after the mode set */
    mov si, offset s_def
    call puts
    mov dx, 0x3c4
    xor bl, bl
2:  call sp_
    mov al, bl
    call rdreg
    call hex8
    inc bl
    cmp bl, 5
    jb 2b
    mov si, offset s_gc
    call puts
    mov dx, 0x3ce
    xor bl, bl
3:  call sp_
    mov al, bl
    call rdreg
    call hex8
    inc bl
    cmp bl, 9
    jb 3b
    call crlf

    /* index register readback: write index, read the index port */
    mov si, offset s_idx
    call puts
    mov dx, 0x3c4
    mov al, 3
    out dx, al
    in al, dx
    call sp_
    call hex8
    mov dx, 0x3ce
    mov al, 6
    out dx, al
    in al, dx
    call sp_
    call hex8
    call crlf

    /* readback of every register x every value */
    mov bx, offset regtab
rb_reg:
    mov dx, word ptr [bx]
    or dx, dx
    jz rb_done
    mov al, byte ptr [bx + 2]
    call rdreg
    mov cl, al                      /* original value */
    mov si, offset vals
    mov ch, NVALS
rb_val:
    lodsb
    and al, byte ptr [bx + 3]
    mov ah, al                      /* AH = value (masked) */
    mov al, byte ptr [bx + 2]
    call wrreg
    call rdreg
    and al, byte ptr [bx + 3]
    inc word ptr [ntest]
    cmp al, ah
    je rb_next
    inc word ptr [nbad]
    cmp byte ptr [nlist], 16
    jae rb_next
    inc byte ptr [nlist]
    push si
    push ax
    mov si, offset s_one
    call puts
    mov ax, dx
    call hex16
    mov al, ':'
    call putc
    mov al, byte ptr [bx + 2]
    call hex8
    mov si, offset s_w
    call puts
    pop ax
    push ax
    mov al, ah
    call hex8
    mov si, offset s_r
    call puts
    pop ax
    call hex8
    call crlf
    pop si
rb_next:
    dec ch
    jnz rb_val
    mov ah, cl                      /* restore the original value */
    mov al, byte ptr [bx + 2]
    call wrreg
    add bx, 4
    jmp rb_reg
rb_done:
    mov si, offset s_rb
    call puts
    mov ax, word ptr [ntest]
    call hex16
    mov si, offset s_bad
    call puts
    mov ax, word ptr [nbad]
    call hex16
    call crlf

    /* implicit index: VGA.DRV reads 3C5h without writing 3C4h first */
    mov si, offset s_impl
    call puts
    mov dx, 0x3c4
    mov ax, 0x0502
    call wrreg                      /* SEQ2 = 05, index stays 2 */
    inc dx
    in al, dx
    dec dx
    call sp_
    call hex8
    mov ax, 0x0f02
    call wrreg
    inc dx
    in al, dx
    dec dx
    call sp_
    call hex8
    mov dx, 0x3ce
    mov ax, 0x3c08
    call wrreg                      /* GC8 = 3C, index stays 8 */
    inc dx
    in al, dx
    dec dx
    call sp_
    call hex8
    mov ax, 0xff08
    call wrreg
    inc dx
    in al, dx
    dec dx
    call sp_
    call hex8
    call crlf

    /* plane memory: distinct byte per plane, read back per plane */
    mov ax, 0xa000
    mov es, ax
    mov si, offset memoffs
mem_off:
    lodsw
    or ax, ax
    jz mem_done
    mov di, ax
    xor bl, bl                      /* plane */
mem_w:
    mov dx, 0x3c4
    mov ah, 1
    mov cl, bl
    shl ah, cl
    mov al, 2
    call wrreg
    mov al, bl
    add al, 0x5a
    xor al, byte ptr [si - 1]
    mov byte ptr es:[di], al
    inc bl
    cmp bl, 4
    jb mem_w
    mov dx, 0x3c4
    mov ax, 0x0f02
    call wrreg
    xor bl, bl
mem_r:
    mov dx, 0x3ce
    mov ah, bl
    mov al, 4
    call wrreg
    mov al, byte ptr es:[di]
    mov ah, bl
    add ah, 0x5a
    xor ah, byte ptr [si - 1]
    cmp al, ah
    je 1f
    inc word ptr [mbad]
1:  inc bl
    cmp bl, 4
    jb mem_r
    mov dx, 0x3ce
    mov ax, 0x0004
    call wrreg
    jmp mem_off
mem_done:
    mov si, offset s_mem
    call puts
    mov ax, word ptr [mbad]
    call hex16
    call crlf

    /* latches: load from a source byte, store with write mode 1 into the
     * save byte (9B0F as 3.1, BFFF as 3.0), reload from there, store into
     * a check byte, compare per plane with the source. */
    mov di, 0x9b0f
    call latch_one
    mov di, 0xbfff
    call latch_one
    mov si, offset s_lat
    call puts
    mov ax, word ptr [lbad]
    call hex16
    call crlf

    mov si, offset s_okr
    cmp word ptr [nbad], 0
    je 1f
    mov si, offset s_badr
    jmp 2f
1:  mov ax, word ptr [mbad]
    or ax, word ptr [lbad]
    jz 2f
    mov si, offset s_badm
2:  call puts
    call crlf

done:
    mov al, byte ptr [omode]
    xor ah, ah
    int 0x10
    /* write the report to standard output */
    mov cx, word ptr [optr]
    sub cx, OUTBUF
    mov dx, OUTBUF
    mov bx, 1
    mov ah, 0x40
    int 0x21
    mov ax, 0x4c00
    int 0x21

memoffs: .word 0x9600, 0x9b0c, 0xa000, 0xbff8, 0xfff8, 0

/* DI = save byte; source = DI-0x100, check = DI-0x80 (both off-screen) */
latch_one:
    push di
    mov bp, di
    sub bp, 0x100                   /* source */
    xor bl, bl
1:  mov dx, 0x3c4
    mov ah, 1
    mov cl, bl
    shl ah, cl
    mov al, 2
    call wrreg
    mov al, bl
    add al, 0xc1
    mov byte ptr es:[bp], al
    inc bl
    cmp bl, 4
    jb 1b
    mov dx, 0x3c4
    mov ax, 0x0f02
    call wrreg
    mov al, byte ptr es:[bp]        /* latches = source */
    mov dx, 0x3ce
    mov ax, 0x0105
    call wrreg                      /* write mode 1 */
    mov byte ptr es:[di], al        /* save latches */
    mov al, byte ptr es:[bp + 0x40] /* clobber latches */
    mov al, byte ptr es:[di]        /* reload saved latches */
    mov byte ptr es:[di - 0x80], al /* store into the check byte */
    mov ax, 0x0005
    call wrreg                      /* write mode 0 */
    xor bl, bl
2:  mov dx, 0x3ce
    mov ah, bl
    mov al, 4
    call wrreg
    mov al, byte ptr es:[di - 0x80]
    mov ah, bl
    add ah, 0xc1
    cmp al, ah
    je 3f
    inc word ptr [lbad]
3:  inc bl
    cmp bl, 4
    jb 2b
    mov ax, 0x0004
    call wrreg
    pop di
    ret
