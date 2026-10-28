/*
 * U9V10STK.COM - resident INT 10h stack shim for DOS programs that call the
 * video BIOS on a tiny stack (Windows 9x SETUP.EXE runs on 128 bytes) on a
 * PC without a firmware CSM, where CSMWrap runs the graphics card's own
 * legacy option ROM (for example an AMD AtomBIOS VBIOS that needs far more
 * stack than a 1990s VGA BIOS).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Provenance: the idea (run INT 10h on a private stack) comes from
 * SeaVGABIOS's "extra stack" (entry_10_extrastack in seabios/vgasrc/
 * vgaentry.S, LGPL-3.0, read as reference in the CSMWrap 3.1.2 sources).
 * This file is our own code written from that idea; no SeaBIOS code is
 * copied. SeaVGABIOS saves a full register frame and calls its C handler;
 * this shim instead chains to whatever INT 10h was installed before it.
 *
 * Behaviour of the INT 10h handler:
 *   - nested call (the old handler, or an IRQ handler running on our
 *     stack, calls INT 10h again): plain jmp far to the old vector
 *   - otherwise: save the caller's SS:SP, switch to a private 2 KiB stack
 *     (paragraph aligned, pre-filled with 5Ah), load FLAGS from the
 *     caller's INT frame, pushf + cli + call far old INT 10h (an exact INT
 *     emulation: the old handler gets the caller's FLAGS in its frame and
 *     runs with IF=0) with every register (AX..BP, DS, ES) untouched,
 *     then copy CF PF AF ZF SF OF from the returned FLAGS into the
 *     caller's saved FLAGS (IF, TF, DF stay the caller's), switch back and
 *     IRET. Output registers are returned as the old handler left them.
 *   - nothing is ever pushed on the caller's stack besides the INT frame
 *     the CPU itself pushed.
 * The pattern in the stack lets a later probe read the deepest stack use
 * (first non-5Ah byte from stkbase); the signature "U9V10STK" sits at
 * offset 0103h of the resident segment.
 *
 * Why: Windows 95 RTM (4.00.950) SETUP.EXE runs its DOS stub on a 128-byte
 * stack and sets text mode 3 / loads its font (INT 10h AX=0003h, AX=1100h)
 * from there. The RX 560 AtomBIOS option ROM under CSMWrap needs more, so
 * the call overwrote SETUP's data and Setup hung before its mini-Windows
 * (X470, 2026-10-26). With this TSR loaded before SETUP.EXE native phase 1
 * ran to the end on the X470 (Kingston B261026-170810, hotpatched Micron).
 * INSTALL.BAT (src/platform/bios/dos_startup.cmd) and the RESUME.BAT it
 * writes load it right before SETUP.EXE for every 9x; in QEMU (SeaVGABIOS)
 * it only adds the stack switch. USOSV10.COM (usosv10.S, Windows 1.x/2.x)
 * is the older sibling with a register-keeping policy for WIN.COM's logo.
 *
 * Built with zig cc + ld.lld at 0100h (src/platform/bios/msdos/com.ld) by
 * tools/build_win9x_support.py; test: tools/tests/legacy_bios/test_u9v10stk.py.
 */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    jmp init
sig:    .ascii "U9V10STK"
old10:  .long 0
savsp:  .word 0         /* savsp/savss adjacent: lds bx, [savsp] */
savss:  .word 0
stkseg: .word 0
busy:   .byte 0

.equ FLMASK, 0x08d5     /* OF SF ZF AF PF CF */

int10:
    cmp byte ptr cs:[busy], 0
    jne chain
    mov byte ptr cs:[busy], 1
    mov word ptr cs:[savss], ss
    mov word ptr cs:[savsp], sp
    mov ss, word ptr cs:[stkseg]    /* interrupts held for one insn */
    mov sp, offset stktop
    push ds
    push bx
    lds bx, dword ptr cs:[savsp]    /* DS:BX = caller's INT frame */
    push word ptr [bx+4]            /* caller's FLAGS */
    popf
    pop bx
    pop ds
    pushf
    cli
    .att_syntax prefix
    lcallw *%cs:old10
    .intel_syntax noprefix
    /* registers and FLAGS = what the old handler returned */
    pushf
    push ax
    push bx
    push ds
    mov bx, sp
    mov ax, word ptr ss:[bx+6]      /* returned FLAGS */
    and ax, FLMASK
    lds bx, dword ptr cs:[savsp]
    and word ptr [bx+4], ~FLMASK
    or word ptr [bx+4], ax
    pop ds
    pop bx
    pop ax
    cli
    mov ss, word ptr cs:[savss]
    mov sp, word ptr cs:[savsp]
    mov byte ptr cs:[busy], 0
    iret                            /* FLAGS from the merged frame */
chain:
    .att_syntax prefix
    ljmpw *%cs:old10
    .intel_syntax noprefix

    .balign 16
stkbase:
    .fill 2048, 1, 0x5a
stktop:
resident_end:

/* ---- transient part ---- */
init:
    cld
    push cs
    pop ds
    mov word ptr [stkseg], cs
    mov ax, 0x3510
    int 0x21
    mov word ptr [old10], bx
    mov word ptr [old10+2], es
    mov ax, 0x2510
    mov dx, offset int10
    int 0x21
    mov ah, 0x09
    mov dx, offset msg
    int 0x21
    /* free the environment block */
    mov es, word ptr [0x2c]
    mov ah, 0x49
    int 0x21
    mov word ptr [0x2c], 0
    mov dx, offset resident_end + 15
    shr dx, 4
    mov ax, 0x3100
    int 0x21

msg: .ascii "U9V10STK 1.0 resident (INT 10h on a private 2 KiB stack)\r\n$"
