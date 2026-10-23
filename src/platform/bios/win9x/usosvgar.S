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
 *
 * Version 2 adds, for the case where all of the above reads back fine:
 * - the CPU memory type of A0000-BFFFF (CPUID, CR0 CD/NW, MTRRcap,
 *   MTRRdefType, fixed MTRRs 250h/258h/259h/268h-26Fh, valid variable
 *   MTRRs, AMD SYSCFG MtrrFixDram bits; raw values plus a decoded line).
 *   Only in real mode (skipped under EMM386/V86) and only with CPUID.MSR.
 * - bulk tests in mode 12h on visible and off-screen memory: a 32 KiB
 *   per-plane pattern, write mode 1 latch copies forward/backward, REP
 *   MOVSB and byte loop, overlapping by 1, 80 and 256 bytes; write modes
 *   2 and 3, GC3 rotate and AND/OR/XOR, set/reset, read mode 1. Each test
 *   is verified per plane and reports its mismatch count and the first
 *   four mismatches (offset, plane, expected, got).
 * - when the fixed MTRRs are on and 259h is not all UC: a temporary
 *   259h = 0 (UC) with interrupts off, caches flushed and MTRRs disabled
 *   during the change, the bulk tests again, then the original 259h is
 *   written back the same way and checked. Nothing stays changed.
 */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    jmp main

sig:    .ascii "USOSVGR2"
omode:  .byte 0
nbad:   .word 0
nlist:  .byte 0
ntest:  .word 0
mbad:   .word 0
lbad:   .word 0

/* --- output buffer ------------------------------------------------------ */
.equ OUTBUF, 0x8000
.equ OUTEND, OUTBUF + 0x5000
/* DI = write pointer into OUTBUF (kept in [optr]) */
optr:   .word OUTBUF

/* putc AL */
putc:
    push di
    push es
    push cs
    pop es
    mov di, word ptr [optr]
    cmp di, OUTEND
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

s_head: .asciz "USOSVGAR 2 (VGA readback + MTRR + bulk latch probe, mode 12h)"
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
s_badb: .asciz "RESULT BULK-BAD"
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
    call msr_probe
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

    /* bulk latch copies and write/read modes, then the UC experiment */
    mov ax, 0xa000
    mov es, ax
    mov si, offset s_nopfx
    call run_bulk
    mov ax, word ptr [bbad]
    mov word ptr [bulk0], ax
    mov si, offset s_btot
    call puts
    call hex16
    call crlf
    call uc_try

    mov si, offset s_okr
    cmp word ptr [nbad], 0
    je 1f
    mov si, offset s_badr
    jmp 2f
1:  mov ax, word ptr [mbad]
    or ax, word ptr [lbad]
    jz 3f
    mov si, offset s_badm
    jmp 2f
3:  cmp word ptr [bulk0], 0
    je 2f
    mov si, offset s_badb
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

/* ======================================================================= */
/* Version 2: CPU memory type of A0000-BFFFF (MTRRs, AMD SYSCFG, CR0) and   */
/* bulk tests of the VGA paths VGA.DRV uses for blits.                      */
/* ======================================================================= */

/* hex dword EAX (EAX kept) */
hex32:
    push eax
    shr eax, 16
    call hex16
    pop eax
    jmp hex16

/* ECX = MSR -> EDX:EAX, printed as "  MSR xxxxxxxx hhhhhhhh:llllllll" */
pmsr:
    rdmsr
    push edx
    push eax
    push si
    mov si, offset s_msr
    call puts
    mov eax, ecx
    call hex32
    call sp_
    mov eax, edx
    call hex32
    mov al, ':'
    call putc
    pop si
    pop eax
    push eax
    call hex32
    call crlf
    pop eax
    pop edx
    ret

s_cpu:   .asciz "CPU: "
s_nocid: .asciz "no CPUID, MSR part skipped"
s_v86:   .asciz "protected/V86 mode (EMM386?), MSR part skipped"
s_nomsr: .asciz " no MSR support, MSR part skipped"
s_nomtr: .asciz " no MTRR support"
s_f1:    .asciz " CPUID1.EDX "
s_cr0:   .asciz "CR0 "
s_cdnw:  .asciz " CD/NW "
s_msr:   .asciz "  MSR "
s_var:   .asciz "  var MTRR "
s_vhit:  .asciz " covers A0000"
s_syscf: .asciz "  AMD SYSCFG MtrrFixDramEn/ModEn/VarDramEn "
s_a0:    .asciz "A0000-BFFFF memory type: "
s_off:   .asciz "UC (MTRRs disabled, 2FFh.E=0)"
s_fix:   .asciz "fixed MTRR 259h "
s_uc:    .asciz "UC"
s_nuc:   .asciz "NOT-UC"
s_rdwr:  .asciz " RDMEM/WRMEM-SET"
s_vuc:   .asciz "variable MTRR UC"
s_vnuc:  .asciz "variable MTRR type "
s_def2:  .asciz "default type "
s_cd:    .asciz " (but CR0.CD=1: caching disabled)"

cpuok:   .byte 0
hasmtrr: .byte 0
amd:     .byte 0
notuc:   .byte 0
rdwr:    .byte 0
canuc:   .byte 0
fe_off:  .byte 0
vhit:    .byte 0
vuc:     .byte 0
vtyp:    .byte 0
vcnt:    .byte 0
vn:      .byte 0
cr0v:    .long 0
dtlo:    .long 0
dthi:    .long 0
m259:    .long 0, 0
vbase:   .long 0
vend:    .long 0, 0, 0
         .byte 0

msr_probe:
    mov si, offset s_cpu
    call puts
    /* CPUID present: EFLAGS.ID toggles */
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 0x200000
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd
    xor eax, ecx
    test eax, 0x200000
    jnz 1f
    mov si, offset s_nocid
    jmp mp_line
1:  smsw ax
    test al, 1
    jz 2f
    mov si, offset s_v86
    jmp mp_line
2:  xor eax, eax
    cpuid
    mov dword ptr [vend], ebx
    mov dword ptr [vend + 4], edx
    mov dword ptr [vend + 8], ecx
    cmp ebx, 0x68747541             /* "Auth" */
    jne 3f
    cmp ecx, 0x444d4163             /* "cAMD" */
    jne 3f
    mov byte ptr [amd], 1
3:  mov si, offset vend
    call puts
    mov eax, 1
    cpuid
    push edx
    mov si, offset s_f1
    call puts
    mov eax, edx
    call hex32
    pop edx
    test dl, 0x20                   /* MSR */
    jnz 4f
    mov si, offset s_nomsr
    jmp mp_line
4:  test dh, 0x10                   /* MTRR (bit 12) */
    jnz 5f
    mov si, offset s_nomtr
    call puts
    jmp 6f
5:  mov byte ptr [hasmtrr], 1
6:  call crlf
    mov byte ptr [cpuok], 1
    mov si, offset s_cr0
    call puts
    mov eax, cr0
    mov dword ptr [cr0v], eax
    call hex32
    mov si, offset s_cdnw
    call puts
    mov eax, dword ptr [cr0v]
    shr eax, 29
    and al, 3
    push ax
    shr al, 1
    call hexd
    pop ax
    and al, 1
    call hexd
    call crlf
    cmp byte ptr [hasmtrr], 0
    je mp_amd
    mov ecx, 0xfe                   /* MTRRcap */
    call pmsr
    mov byte ptr [vcnt], al
    mov ecx, 0x2ff                  /* MTRRdefType */
    call pmsr
    mov dword ptr [dtlo], eax
    mov dword ptr [dthi], edx
    mov ecx, 0x250
    call pmsr
    mov ecx, 0x258
    call pmsr
    mov ecx, 0x259                  /* A0000-BFFFF, 8 x 16 KiB */
    call pmsr
    mov dword ptr [m259], eax
    mov dword ptr [m259 + 4], edx
    mov ecx, 0x268
7:  call pmsr
    inc ecx
    cmp ecx, 0x270
    jb 7b
    /* valid variable MTRRs; does one cover A0000? */
    cmp byte ptr [vcnt], 16
    jbe 8f
    mov byte ptr [vcnt], 16
8:  mov byte ptr [vn], 0
mp_var:
    mov al, byte ptr [vn]
    cmp al, byte ptr [vcnt]
    jae mp_amd
    movzx ecx, al
    shl ecx, 1
    add ecx, 0x200
    rdmsr
    mov dword ptr [vbase], eax
    inc ecx
    rdmsr
    test ah, 0x08                   /* valid */
    jz mp_vnext
    push edx
    push eax
    mov si, offset s_var
    call puts
    mov al, byte ptr [vn]
    call hex8
    call sp_
    mov eax, dword ptr [vbase]
    call hex32
    call sp_
    pop eax
    pop edx
    push edx
    push eax
    mov eax, edx
    call hex32
    mov al, ':'
    call putc
    pop eax
    push eax
    call hex32
    pop eax
    pop edx
    and eax, 0xfffff000
    mov ebx, dword ptr [vbase]
    and ebx, eax
    and eax, 0x000a0000
    cmp eax, ebx
    jne 9f
    mov si, offset s_vhit
    call puts
    mov byte ptr [vhit], 1
    mov al, byte ptr [vbase]
    mov byte ptr [vtyp], al
    or al, al
    jnz 9f
    mov byte ptr [vuc], 1
9:  call crlf
mp_vnext:
    inc byte ptr [vn]
    jmp mp_var

mp_amd:
    cmp byte ptr [amd], 0
    je mp_decode
    mov ecx, 0xc0010010             /* SYSCFG */
    call pmsr
    push eax
    mov si, offset s_syscf
    call puts
    pop eax
    shr eax, 18
    push ax
    and al, 1
    call hexd
    pop ax
    push ax
    shr al, 1
    and al, 1
    call hexd
    pop ax
    shr al, 2
    and al, 1
    call hexd
    call crlf

mp_decode:
    cmp byte ptr [hasmtrr], 0
    je mp_ret
    mov si, offset s_a0
    call puts
    mov eax, dword ptr [dtlo]
    test ah, 0x08                   /* E */
    jnz 1f
    mov si, offset s_off
    call puts
    jmp mp_cd
1:  test ah, 0x04                   /* FE */
    jz mp_varnote
    mov si, offset s_fix
    call puts
    mov bx, offset m259
    mov cx, 8
2:  mov al, byte ptr [bx]
    test al, 0x07
    jz 3f
    mov byte ptr [notuc], 1
3:  test al, 0x18
    jz 4f
    mov byte ptr [rdwr], 1
4:  inc bx
    loop 2b
    mov si, offset s_uc
    cmp byte ptr [notuc], 0
    je 5f
    mov si, offset s_nuc
5:  call puts
    cmp byte ptr [rdwr], 0
    je 6f
    mov si, offset s_rdwr
    call puts
6:  mov eax, dword ptr [m259]
    or eax, dword ptr [m259 + 4]
    jz mp_cd
    mov byte ptr [canuc], 1
    jmp mp_cd
mp_varnote:
    mov byte ptr [fe_off], 1
    cmp byte ptr [vhit], 0
    je 1f
    mov si, offset s_vuc
    cmp byte ptr [vuc], 0
    jne 2f
    mov byte ptr [notuc], 1
    mov si, offset s_vnuc
    call puts
    mov al, byte ptr [vtyp]
    call hex8
    jmp mp_cd
1:  mov si, offset s_def2
    call puts
    mov al, byte ptr [dtlo]
    call hex8
    or al, al
    jz mp_cd
    mov byte ptr [notuc], 1
    jmp mp_cd
2:  call puts
mp_cd:
    test byte ptr [cr0v + 3], 0x40  /* CD */
    jz 1f
    mov si, offset s_cd
    call puts
1:  call crlf
mp_ret:
    ret
mp_line:
    call puts
    call crlf
    ret

/* --- UC experiment ------------------------------------------------------- */
/* Only when the fixed MTRRs are on and 259h is not all zero: set 259h = 0  */
/* (UC, no RdMem/WrMem) with the SDM procedure (CLI, CD=1, WBINVD, MTRRs   */
/* off, write, MTRRs on, WBINVD, CR0 back, STI), run the bulk tests again,  */
/* then restore the original 259h the same way and check it reads back.   */
s_ucx:   .asciz "UC experiment: "
s_ucn1:  .asciz "not needed (A0000-BFFFF already UC)"
s_ucn2:  .asciz "skipped (fixed MTRRs disabled, A0000 type from variable/default MTRRs)"
s_ucn3:  .asciz "skipped (no MTRR access)"
s_ucrun: .asciz "running (259h temporarily 0 = UC, restored afterwards)"
s_ucset: .asciz "UC experiment: 259h set to 0, readback"
s_ucres: .asciz "UC experiment: 259h restored, readback"
s_ucrok: .asciz "UC experiment: restore OK"
s_ucrbd: .asciz "UC experiment: RESTORE-MISMATCH"
s_ucsum: .asciz "UC experiment: bulk mismatches normal "
s_ucwth: .asciz " with 259h=UC "
s_ucfix: .asciz "UC-FIXES-BULK"
s_ucsame: .asciz "UC-NO-FIX"
s_ucpfx: .asciz "UC "
s_nopfx: .asciz ""
newlo:   .long 0
newhi:   .long 0
bulk0:   .word 0
bulk1:   .word 0

set259:
    cli
    mov eax, cr0
    mov dword ptr [cr0v], eax
    or eax, 0x40000000              /* CD=1 */
    and eax, 0xdfffffff             /* NW=0 */
    mov cr0, eax
    wbinvd
    mov ecx, 0x2ff
    mov eax, dword ptr [dtlo]
    mov edx, dword ptr [dthi]
    and eax, 0xfffff7ff             /* MTRRs off */
    wrmsr
    mov ecx, 0x259
    mov eax, dword ptr [newlo]
    mov edx, dword ptr [newhi]
    wrmsr
    wbinvd
    mov ecx, 0x2ff
    mov eax, dword ptr [dtlo]
    mov edx, dword ptr [dthi]
    wrmsr
    wbinvd
    mov eax, dword ptr [cr0v]
    mov cr0, eax
    sti
    ret

uc_try:
    mov si, offset s_ucx
    call puts
    mov si, offset s_ucn3
    cmp byte ptr [hasmtrr], 0
    je 1f
    cmp byte ptr [cpuok], 0
    je 1f
    mov si, offset s_ucn2
    cmp byte ptr [fe_off], 0
    jne 1f
    mov si, offset s_ucn1
    cmp byte ptr [canuc], 0
    jne 2f
    /* E=0: everything is UC already */
1:  call puts
    jmp crlf
2:  mov si, offset s_ucrun
    call puts
    call crlf
    xor eax, eax
    mov dword ptr [newlo], eax
    mov dword ptr [newhi], eax
    call set259
    mov si, offset s_ucset
    call puts
    call crlf
    mov ecx, 0x259
    call pmsr
    mov si, offset s_ucpfx
    call run_bulk
    mov ax, word ptr [bbad]
    mov word ptr [bulk1], ax
    mov eax, dword ptr [m259]
    mov dword ptr [newlo], eax
    mov eax, dword ptr [m259 + 4]
    mov dword ptr [newhi], eax
    call set259
    mov si, offset s_ucres
    call puts
    call crlf
    mov ecx, 0x259
    call pmsr
    mov si, offset s_ucrok
    cmp eax, dword ptr [m259]
    jne 3f
    cmp edx, dword ptr [m259 + 4]
    je 4f
3:  mov si, offset s_ucrbd
4:  call puts
    call crlf
    mov si, offset s_ucsum
    call puts
    mov ax, word ptr [bulk0]
    call hex16
    mov si, offset s_ucwth
    call puts
    mov ax, word ptr [bulk1]
    call hex16
    call sp_
    mov si, offset s_ucsame
    cmp word ptr [bulk0], 0
    je 5f
    cmp word ptr [bulk1], 0
    jne 5f
    mov si, offset s_ucfix
5:  call puts
    jmp crlf

/* --- bulk tests ---------------------------------------------------------- */
/* Pattern P(plane, offset) = (lo + 7*hi) xor pconst[plane]: every plane    */
/* and every 1/80/256-byte shift gives a different byte.                    */
pconst:  .byte 0x00, 0x3b, 0x76, 0xb1
pfx:     .word 0
bbad:    .word 0
vbad:    .word 0
vlist:   .byte 0
vrec:    .space 20
rstart:  .word 0
rlen:    .word 0
vstart:  .word 0
vlen:    .word 0
vfn:     .word 0
delta:   .word 0
o_wm:    .byte 0
o_rot:   .byte 0
o_func:  .byte 0
o_bm:    .byte 0
o_sr:    .byte 0
o_esr:   .byte 0

s_vm:    .asciz " mismatches "
s_at:    .asciz " @"
s_pl:    .asciz " p"
s_ex:    .asciz " exp "
s_got:   .asciz " got "
s_btot:  .asciz "bulk total mismatches "
n_fill:  .asciz "bulk fill 0000-7FFF (WM0, map mask per plane)"

/* copy table: src, dst, len, flags (1 backward/STD, 2 byte loop instead of
 * REP MOVSB, 4 clear destination first), refill start, refill length
 * (0 = none), name. All in write mode 1 (latch copy). */
copytab:
    .word 0x0000, 0x8000, 0x6000, 4, 0, 0, n_c1
    .word 0x0000, 0x8000, 0x6000, 6, 0, 0, n_c2
    .word 0x0000, 0x8000, 0x6000, 5, 0, 0, n_c3
    .word 0x0000, 0x8000, 0x6000, 7, 0, 0, n_c4
    .word 0x0050, 0x0000, 0x4000, 0, 0, 0x4100, n_c5
    .word 0x0000, 0x0050, 0x4000, 1, 0, 0x4100, n_c6
    .word 0x0001, 0x0000, 0x4000, 2, 0, 0x4100, n_c7
    .word 0x0000, 0x0001, 0x4000, 3, 0, 0x4100, n_c8
    .word 0x0100, 0x0000, 0x4000, 0, 0, 0x4100, n_c9
    .word 0x0000, 0x0100, 0x4000, 1, 0, 0x4100, n_c10
    .word 0, 0, 0, 0, 0, 0, 0
n_c1:  .asciz "WM1 fwd  rep movsb 0000->8000 len 6000"
n_c2:  .asciz "WM1 fwd  byte loop 0000->8000 len 6000"
n_c3:  .asciz "WM1 back rep movsb 0000->8000 len 6000"
n_c4:  .asciz "WM1 back byte loop 0000->8000 len 6000"
n_c5:  .asciz "WM1 fwd  rep movsb overlap 0050->0000 len 4000"
n_c6:  .asciz "WM1 back rep movsb overlap 0000->0050 len 4000"
n_c7:  .asciz "WM1 fwd  byte loop overlap 0001->0000 len 4000"
n_c8:  .asciz "WM1 back byte loop overlap 0000->0001 len 4000"
n_c9:  .asciz "WM1 fwd  rep movsb overlap 0100->0000 len 4000"
n_c10: .asciz "WM1 back rep movsb overlap 0000->0100 len 4000"

/* op table (region 9200-99FF, across the visible end 9600): write mode,
 * rotate, function (0 move 1 and 2 or 3 xor), bit mask, set/reset,
 * enable set/reset, name. Data byte = (offset low) xor A5, written with
 * XCHG (latch load and write in one instruction). */
optab:
    .byte 2, 0, 0, 0x3c, 0, 0
    .word n_o1
    .byte 2, 0, 3, 0xff, 0, 0
    .word n_o2
    .byte 3, 0, 0, 0xff, 0x0a, 0
    .word n_o3
    .byte 3, 2, 0, 0x0f, 0x05, 0
    .word n_o4
    .byte 0, 0, 1, 0xff, 0, 0
    .word n_o5
    .byte 0, 0, 2, 0xff, 0, 0
    .word n_o6
    .byte 0, 0, 3, 0xff, 0, 0
    .word n_o7
    .byte 0, 3, 0, 0xff, 0, 0
    .word n_o8
    .byte 0, 3, 3, 0xf0, 0, 0
    .word n_o9
    .byte 0, 0, 0, 0xff, 0x04, 0x05
    .word n_o10
    .byte 0, 0, 0, 0, 0, 0
    .word 0
n_o1:  .asciz "WM2 bit mask 3C"
n_o2:  .asciz "WM2 XOR"
n_o3:  .asciz "WM3 set/reset 0A"
n_o4:  .asciz "WM3 set/reset 05 rot 2 bit mask 0F"
n_o5:  .asciz "WM0 AND"
n_o6:  .asciz "WM0 OR"
n_o7:  .asciz "WM0 XOR"
n_o8:  .asciz "WM0 rot 3"
n_o9:  .asciz "WM0 XOR rot 3 bit mask F0"
n_o10: .asciz "WM0 enable set/reset 05 set/reset 04"

/* read mode 1: color compare, color don't care, name */
rm1tab:
    .byte 0x05, 0x0f
    .word n_r1
    .byte 0x0a, 0x07
    .word n_r2
    .byte 0, 0
    .word 0
n_r1:  .asciz "RM1 compare 05 dont-care 0F"
n_r2:  .asciz "RM1 compare 0A dont-care 07"

/* BL = plane, DI = offset -> AL = P (AH clobbered) */
pat:
    push bx
    push cx
    mov ax, di
    mov cl, ah
    shl ah, 3
    sub ah, cl
    add al, ah
    xor bh, bh
    xor al, byte ptr [pconst + bx]
    pop cx
    pop bx
    ret

exp_copy:
    push di
    add di, word ptr [delta]
    call pat
    pop di
    ret

/* expected plane BL byte at DI after an op test (VGA write path model) */
exp_op:
    push cx
    push dx
    call pat
    mov dl, al                      /* latch */
    mov ch, byte ptr [o_bm]
    mov dh, 1
    mov cl, bl
    shl dh, cl                      /* plane bit */
    mov ax, di
    xor al, 0xa5                    /* CPU data */
    cmp byte ptr [o_wm], 2
    je 2f
    mov cl, byte ptr [o_rot]
    ror al, cl
    cmp byte ptr [o_wm], 3
    je 3f
    test byte ptr [o_esr], dh
    jz 5f
    jmp 4f
2:  test al, dh
    mov al, 0
    jz 5f
    mov al, 0xff
    jmp 5f
3:  and ch, al
4:  test byte ptr [o_sr], dh
    mov al, 0
    jz 5f
    mov al, 0xff
5:  mov cl, byte ptr [o_func]
    cmp cl, 1
    jne 6f
    and al, dl
    jmp 9f
6:  cmp cl, 2
    jne 7f
    or al, dl
    jmp 9f
7:  cmp cl, 3
    jne 9f
    xor al, dl
9:  and al, ch
    not ch
    and dl, ch
    or al, dl
    pop dx
    pop cx
    ret

/* expected read mode 1 byte at DI (o_sr = compare, o_esr = don't care) */
exp_rm1:
    push bx
    push cx
    push dx
    mov dh, 0xff
    xor bl, bl
1:  mov ah, 1
    mov cl, bl
    shl ah, cl
    test byte ptr [o_esr], ah
    jz 3f
    call pat
    mov ah, 1
    mov cl, bl
    shl ah, cl
    test byte ptr [o_sr], ah
    jz 2f
    not al
2:  not al
    and dh, al
3:  inc bl
    cmp bl, 4
    jb 1b
    mov al, dh
    pop dx
    pop cx
    pop bx
    ret

/* AL = got, AH = expected, BL = plane, DI = offset */
chk:
    cmp al, ah
    jne 1f
    ret
1:  add word ptr [vbad], 1
    sbb word ptr [vbad], 0
    cmp byte ptr [vlist], 4
    jae 2f
    push si
    push ax
    mov al, byte ptr [vlist]
    inc byte ptr [vlist]
    mov ah, 5
    mul ah
    mov si, ax
    pop ax
    mov word ptr [vrec + si], di
    mov byte ptr [vrec + si + 2], bl
    mov byte ptr [vrec + si + 3], ah
    mov byte ptr [vrec + si + 4], al
    pop si
2:  ret

vbegin:
    mov word ptr [vbad], 0
    mov byte ptr [vlist], 0
    ret

/* SI = test name: "<pfx><name> mismatches n @off pP exp e got g ..." */
vreport:
    push si
    mov si, word ptr [pfx]
    call puts
    pop si
    call puts
    mov si, offset s_vm
    call puts
    mov ax, word ptr [vbad]
    call hex16
    xor bx, bx
1:  cmp bl, byte ptr [vlist]
    jae 2f
    mov si, offset s_at
    call puts
    mov al, 5
    mul bl
    mov si, ax
    mov ax, word ptr [vrec + si]
    call hex16
    push si
    mov si, offset s_pl
    call puts
    pop si
    mov al, byte ptr [vrec + si + 2]
    call hexd
    push si
    mov si, offset s_ex
    call puts
    pop si
    mov al, byte ptr [vrec + si + 3]
    call hex8
    push si
    mov si, offset s_got
    call puts
    pop si
    mov al, byte ptr [vrec + si + 4]
    call hex8
    inc bl
    jmp 1b
2:  call crlf
    mov ax, word ptr [vbad]
    add word ptr [bbad], ax
    jnc 3f
    mov word ptr [bbad], 0xffff
3:  ret

/* drawing defaults: write mode 0, no rotate/function, no set/reset,
 * compare 0, don't care 0F, bit mask FF, read map 0; map mask 0F */
gcdef:
    mov dx, 0x3ce
    mov ax, 0x0005
    call wrreg
    mov ax, 0x0003
    call wrreg
    mov ax, 0x0001
    call wrreg
    mov ax, 0x0000
    call wrreg
    mov ax, 0x0004
    call wrreg
    mov ax, 0x0002
    call wrreg
    mov ax, 0x0f07
    call wrreg
    mov ax, 0xff08
    call wrreg
    mov dx, 0x3c4
    mov ax, 0x0f02
    jmp wrreg

/* fill [rstart, rstart+rlen) with P, plane by plane */
fill_pat:
    push bx
    call gcdef
    xor bl, bl
1:  mov dx, 0x3c4
    mov ah, 1
    mov cl, bl
    shl ah, cl
    mov al, 2
    call wrreg
    mov di, word ptr [rstart]
    mov cx, word ptr [rlen]
2:  call pat
    mov byte ptr es:[di], al
    inc di
    loop 2b
    inc bl
    cmp bl, 4
    jb 1b
    mov dx, 0x3c4
    mov ax, 0x0f02
    call wrreg
    pop bx
    ret

/* near calls/returns here are 32-bit (66h E8 / 66h C3), so call through
 * a direct call and an indirect JMP, never an indirect 16-bit CALL */
vcall:
    jmp word ptr [vfn]

/* compare [vstart, vstart+vlen) per plane (read map select) with vfn */
verify_planes:
    push bx
    xor bl, bl
1:  mov dx, 0x3ce
    mov ah, bl
    mov al, 4
    call wrreg
    mov di, word ptr [vstart]
    mov cx, word ptr [vlen]
2:  call vcall
    mov ah, al
    mov al, byte ptr es:[di]
    call chk
    inc di
    loop 2b
    inc bl
    cmp bl, 4
    jb 1b
    mov dx, 0x3ce
    mov ax, 0x0004
    call wrreg
    pop bx
    ret

/* SI = prefix for the report lines; bbad = sum of all mismatches */
run_bulk:
    mov word ptr [pfx], si
    mov word ptr [bbad], 0
    mov word ptr [rstart], 0
    mov word ptr [rlen], 0x8000
    call fill_pat
    mov word ptr [vstart], 0
    mov word ptr [vlen], 0x8000
    mov word ptr [delta], 0
    mov word ptr [vfn], offset exp_copy
    call vbegin
    call verify_planes
    mov si, offset n_fill
    call vreport
    mov bx, offset copytab
1:  cmp word ptr [bx + 12], 0
    je 2f
    push bx
    call run_copy
    pop bx
    add bx, 14
    jmp 1b
2:  mov bx, offset optab
3:  cmp word ptr [bx + 6], 0
    je 4f
    push bx
    call run_op
    pop bx
    add bx, 8
    jmp 3b
4:  mov bx, offset rm1tab
5:  cmp word ptr [bx + 2], 0
    je 6f
    push bx
    call run_rm1
    pop bx
    add bx, 4
    jmp 5b
6:  jmp gcdef

run_copy:
    mov ax, word ptr [bx + 10]
    or ax, ax
    jz 1f
    mov word ptr [rlen], ax
    mov ax, word ptr [bx + 8]
    mov word ptr [rstart], ax
    call fill_pat
1:  call gcdef
    test byte ptr [bx + 6], 4
    jz 2f
    mov di, word ptr [bx + 2]
    mov cx, word ptr [bx + 4]
    xor al, al
    rep stosb
2:  mov dx, 0x3ce
    mov ax, 0x0105                  /* write mode 1 */
    call wrreg
    mov si, word ptr [bx]
    mov di, word ptr [bx + 2]
    mov cx, word ptr [bx + 4]
    test byte ptr [bx + 6], 1
    jz 3f
    add si, cx
    dec si
    add di, cx
    dec di
    std
3:  test byte ptr [bx + 6], 2
    jnz 4f
    push ds
    push es
    pop ds
    rep movsb
    pop ds
    jmp 6f
4:  push ds
    push es
    pop ds
5:  lodsb
    stosb
    loop 5b
    pop ds
6:  cld
    call gcdef
    mov ax, word ptr [bx]
    sub ax, word ptr [bx + 2]
    mov word ptr [delta], ax
    mov ax, word ptr [bx + 2]
    mov word ptr [vstart], ax
    mov ax, word ptr [bx + 4]
    mov word ptr [vlen], ax
    mov word ptr [vfn], offset exp_copy
    call vbegin
    push bx
    call verify_planes
    pop bx
    mov si, word ptr [bx + 12]
    jmp vreport

.equ OPBASE, 0x9200
.equ OPLEN, 0x0800

run_op:
    mov al, byte ptr [bx]
    mov byte ptr [o_wm], al
    mov al, byte ptr [bx + 1]
    mov byte ptr [o_rot], al
    mov al, byte ptr [bx + 2]
    mov byte ptr [o_func], al
    mov al, byte ptr [bx + 3]
    mov byte ptr [o_bm], al
    mov al, byte ptr [bx + 4]
    mov byte ptr [o_sr], al
    mov al, byte ptr [bx + 5]
    mov byte ptr [o_esr], al
    mov word ptr [rstart], OPBASE
    mov word ptr [rlen], OPLEN
    call fill_pat
    mov dx, 0x3ce
    mov ah, byte ptr [o_sr]
    mov al, 0
    call wrreg
    mov ah, byte ptr [o_esr]
    mov al, 1
    call wrreg
    mov ah, byte ptr [o_func]
    shl ah, 3
    or ah, byte ptr [o_rot]
    mov al, 3
    call wrreg
    mov ah, byte ptr [o_bm]
    mov al, 8
    call wrreg
    mov ah, byte ptr [o_wm]
    mov al, 5
    call wrreg
    mov di, OPBASE
    mov cx, OPLEN
1:  mov ax, di
    xor al, 0xa5
    xchg al, byte ptr es:[di]
    inc di
    loop 1b
    call gcdef
    mov word ptr [vstart], OPBASE
    mov word ptr [vlen], OPLEN
    mov word ptr [vfn], offset exp_op
    call vbegin
    push bx
    call verify_planes
    pop bx
    mov si, word ptr [bx + 6]
    jmp vreport

run_rm1:
    mov al, byte ptr [bx]
    mov byte ptr [o_sr], al
    mov al, byte ptr [bx + 1]
    mov byte ptr [o_esr], al
    mov word ptr [rstart], OPBASE
    mov word ptr [rlen], OPLEN
    call fill_pat
    mov dx, 0x3ce
    mov ah, byte ptr [o_sr]
    mov al, 2
    call wrreg
    mov ah, byte ptr [o_esr]
    mov al, 7
    call wrreg
    mov ax, 0x0805                  /* read mode 1, write mode 0 */
    call wrreg
    call vbegin
    push bx
    mov bl, 4
    mov di, OPBASE
    mov cx, OPLEN
1:  call exp_rm1
    mov ah, al
    mov al, byte ptr es:[di]
    call chk
    inc di
    loop 1b
    pop bx
    call gcdef
    mov si, word ptr [bx + 2]
    jmp vreport
