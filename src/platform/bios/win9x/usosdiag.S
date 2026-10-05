/*
 * USOSDIAG.COM / USOSHPET.COM - real-hardware diagnostics for Windows 9x
 * Setup under DOS on a PC without a firmware CSM (CSMWrap/SeaBIOS).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 *   USOSDIAG [tag]     report only
 *   USOSHPET [tag]     clear HPET LegacyReplacement, then report the clock
 *
 * One source, two programs (USOSHPET is built with -DUSOSHPET). Every line
 * goes to the screen and is appended to C:\USOS9X\DIAG.LOG (created when
 * missing). The log is written after each section, so after a hang the
 * last line shows how far it got. [tag] (for example %CONFIG%) is copied
 * into the first line.
 *
 * USOSDIAG sections:
 *   DOS   DOS version, CPU mode (SMSW PE), XMS driver (version, free KiB,
 *         A20 state from XMS), A20 by the 0000:0500 / FFFF:0510 wrap test,
 *         INT 08h, 1Ch, 13h and 15h vectors (who owns the disk and memory
 *         services: HIMEM hooks INT 15h and then answers 88h/E801h itself)
 *   CPU   CR0, CR4 (when CPUID exists) and EFER (when CPUID 80000001h EDX
 *         has LM, NX or SYSCALL) read directly in real mode; skipped under
 *         a V86 memory manager. CR0 bits 30/29 (CD/NW) set = caches off,
 *         which makes everything crawl; CREGFIX.SYS clears them
 *   TICK  PIC master mask (IRQ0 = bit 0), whether 8254 channel 0 counts,
 *         BIOS tick count (0040:006Ch) increments over one CMOS RTC second
 *         and the busy-loop count of that second. "NO-TICK" = IRQ0 never
 *         reaches the BIOS, so anything that waits for the tick count to
 *         move waits forever.
 *   MEM   INT 15h E801h, 88h and the E820h map
 *   CMOS  memory-size registers 17/18h, 30/31h, 34/35h, 5B-5Dh and the
 *         10h-2Dh checksum (stored 2E/2Fh vs computed)
 *   DISK  INT 13h 41h (extensions), 08h (geometry), 48h (sector count)
 *         for drive 80h
 *   DRV   BDA 0040:0075 (hard disk count) and INT 13h 08h for 80h-8Fh,
 *         CF ("!" when set) and DL (count) per drive
 *   HPET  RSDP (EBDA, E0000-FFFFF) -> RSDT/XSDT -> HPET table -> base;
 *         capabilities, general configuration (bit 0 enable, bit 1
 *         LegacyReplacement = "leg"), timer 0 configuration, whether the
 *         main counter runs
 *
 * USOSHPET: the HPET section; when LegacyReplacement is set it clears
 * general configuration bit 1 (one 32-bit write, read back: "leg:1>0"),
 * the same as usosrst's /USOSHPETLEGOFF for Windows 2000
 * (docs/windows-2000-modern-2026-09-30.md). The 8254 PIT and the RTC then
 * drive IRQ 0 and IRQ 8 again. Then the TICK section, to show the effect.
 * Exit code 0 = cleared or already clear, 1 = no HPET found or not in real
 * mode (nothing written).
 *
 * Physical memory above 1 MiB (ACPI tables, HPET registers) is read with
 * FS in "unreal" mode (a 4 GiB data descriptor loaded for one instruction
 * in protected mode, interrupts off). That needs real mode: under a V86
 * memory manager (EMM386) the HPET section is skipped. A20 is enabled for
 * the accesses (XMS local enable, else port 92h) and put back afterwards.
 *
 * Built with tools/build_win9x_support.py (zig cc, linked at 0100h).
 */
.intel_syntax noprefix
.code16
.equ OUTBUF, 0x7000
.equ OUTEND, 0x7f00
.equ E820BUF, 0x6f00
.equ EDDBUF, 0x6f40
.section .text
.global _start
_start:
    cld
    mov word ptr [outp], OUTBUF
    /* linear address of the GDT for unreal mode */
    xor eax, eax
    mov ax, cs
    shl eax, 4
    add eax, offset gdt
    mov dword ptr [gdtr + 2], eax
#ifdef USOSHPET
    call pr
    .asciz "USOSHPET 1.0"
#else
    call pr
    .asciz "USOSDIAG 1.1"
#endif
    call tag_and_rtc
    call flush
#ifdef USOSHPET
    call sec_hpet
    call flush
    call sec_tick
    call flush
    mov al, byte ptr [hpet_rc]
#else
    call sec_dos
    call flush
    call sec_cpu
    call flush
    call sec_tick
    call flush
    call sec_mem
    call flush
    call sec_cmos
    call flush
    call sec_disk
    call flush
    call sec_drv
    call flush
    call sec_hpet
    call flush
    xor al, al
#endif
    mov ah, 0x4c
    int 0x21

/* ---------------------------------------------------------------- */
/* banner: tag from the command tail, CMOS date/time (raw)           */
tag_and_rtc:
    xor bx, bx
    mov bl, byte ptr [0x80]
    mov si, 0x81
    mov byte ptr [si + bx], 0
1:  lodsb
    cmp al, ' '
    je 1b
    dec si
    cmp byte ptr [si], 0
    je 2f
    call pr
    .asciz " tag:"
    call puts
2:  call pr
    .asciz " rtc:"
    mov al, 0x32
    call cmos_hex
    mov al, 0x09
    call cmos_hex
    mov al, '-'
    call putc
    mov al, 0x08
    call cmos_hex
    mov al, '-'
    call putc
    mov al, 0x07
    call cmos_hex
    mov al, ' '
    call putc
    mov al, 0x04
    call cmos_hex
    mov al, ':'
    call putc
    mov al, 0x02
    call cmos_hex
    mov al, ':'
    call putc
    mov al, 0x00
    call cmos_hex
    call pr
    .asciz " regB:"
    mov al, 0x0b
    call cmos_hex
    jmp nl

/* al = CMOS index -> two hex digits */
cmos_hex:
    call cmos_read
    movzx edx, al
    jmp hex2

cmos_read:
    pushf
    cli
    out 0x70, al
    in al, 0x71
    popf
    ret

/* ---------------------------------------------------------------- */
#ifndef USOSHPET
sec_dos:
    call pr
    .asciz "DOS ver:"
    mov ax, 0x3000
    int 0x21
    push ax
    movzx edx, al
    call dec
    mov al, '.'
    call putc
    pop ax
    movzx edx, ah
    call dec
    call pr
    .asciz " pe:"
    smsw ax
    movzx edx, al
    and dl, 1
    call hex1
    call pr
    .asciz " xms:"
    mov ax, 0x4300
    int 0x2f
    cmp al, 0x80
    je 1f
    call pr
    .asciz "none"
    jmp 2f
1:  push es
    mov ax, 0x4310
    int 0x2f
    mov word ptr [xms_entry], bx
    mov word ptr [xms_entry + 2], es
    pop es
    mov byte ptr [xms_ok], 1
    mov ah, 0x00
    call xms
    movzx edx, ax
    call hex4
    call pr
    .asciz " free:"
    mov ah, 0x08
    xor bl, bl
    call xms
    push dx
    movzx edx, ax
    call dec
    mov al, '/'
    call putc
    pop dx
    movzx edx, dx
    call dec
    call pr
    .asciz "K a20(xms):"
    mov ah, 0x07
    call xms
    movzx edx, ax
    call hex1
2:  call pr
    .asciz " a20(wrap):"
    call a20_test
    movzx edx, al
    call hex1
    call pr
    .asciz " int08:"
    mov bx, 0x08 * 4
    call vec
    call pr
    .asciz " int1C:"
    mov bx, 0x1c * 4
    call vec
    call pr
    .asciz " int13:"
    mov bx, 0x13 * 4
    call vec
    call pr
    .asciz " int15:"
    mov bx, 0x15 * 4
    call vec
    jmp nl

/* CR0 / CR4 / EFER, real mode only */
sec_cpu:
    call pr
    .asciz "CPU msw:"
    smsw ax
    movzx edx, ax
    call hex4
    test al, 1
    jz 1f
    call pr
    .asciz " cr:skipped (not real mode)"
    jmp nl
1:  call pr
    .asciz " cr0:"
    mov eax, cr0
    mov edx, eax
    call hex8
    test eax, 0x60000000
    jz 2f
    call pr
    .asciz "(CD/NW!)"
2:  /* CPUID present when EFLAGS.ID (bit 21) can be toggled */
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
    jnz 3f
    call pr
    .asciz " cpuid:none"
    jmp nl
3:  call pr
    .asciz " cr4:"
    .byte 0x0f, 0x20, 0xe0          /* mov eax, cr4 */
    mov edx, eax
    call hex8
    mov eax, 0x80000000
    .byte 0x0f, 0xa2                /* cpuid */
    cmp eax, 0x80000001
    jb 4f
    mov eax, 0x80000001
    .byte 0x0f, 0xa2
    test edx, 0x20100800            /* LM | NX | SYSCALL */
    jz 4f
    call pr
    .asciz " efer:"
    mov ecx, 0xc0000080
    .byte 0x0f, 0x32                /* rdmsr */
    mov edx, eax
    call hex8
    jmp nl
4:  call pr
    .asciz " efer:none"
    jmp nl

vec:
    push es
    xor ax, ax
    mov es, ax
    movzx edx, word ptr es:[bx + 2]
    call hex4
    mov al, ':'
    call putc
    movzx edx, word ptr es:[bx]
    call hex4
    pop es
    ret
#endif

/* far call to the XMS driver (FF /3, disp16) */
xms:
    .byte 0xff, 0x1e
    .word xms_entry
    ret

/* al = 1 when A20 is enabled (no wrap at 1 MiB) */
a20_test:
    pushf
    cli
    push es
    push gs
    push si
    xor ax, ax
    mov es, ax
    not ax
    mov gs, ax
    mov si, 0x500
    mov ah, byte ptr es:[si]
    mov al, byte ptr gs:[si + 0x10]
    push ax
    mov byte ptr es:[si], 0x00
    mov byte ptr gs:[si + 0x10], 0xff
    mov bl, byte ptr es:[si]
    pop ax
    mov byte ptr gs:[si + 0x10], al
    mov byte ptr es:[si], ah
    mov al, 1
    cmp bl, 0xff
    jne 1f
    xor al, al
1:  pop si
    pop gs
    pop es
    popf
    ret

/* ---------------------------------------------------------------- */
sec_tick:
    sti
    call pr
    .asciz "TICK imr:"
    in al, 0x21
    movzx edx, al
    call hex2
    call pr
    .asciz " pit:"
    call pit_read
    movzx edx, ax
    push dx
    call hex4
    mov cx, 4000
1:  in al, 0x61
    loop 1b
    call pit_read
    pop dx
    push ax
    mov al, '>'
    call putc
    pop ax
    cmp ax, dx
    movzx edx, ax
    pushf
    call hex4
    popf
    jne 2f
    call pr
    .asciz "(stopped)"
2:  call pr
    .asciz " bda:"
    call ticks
    call hex8
    call flush_keep
    /* sync to an RTC second edge */
    call rtc_sec
    mov bl, al
    mov ecx, 5000000
3:  call rtc_sec
    cmp al, bl
    jne 4f
    dec ecx
    jnz 3b
    call pr
    .asciz " rtc:stuck"
    jmp 6f
4:  mov bl, al
    call ticks
    mov dword ptr [t1], edx
    xor ebp, ebp
5:  inc ebp
    call rtc_sec
    cmp al, bl
    jne 7f
    cmp ebp, 5000000
    jb 5b
    call pr
    .asciz " rtc:stuck2"
    jmp 6f
7:  call ticks
    sub edx, dword ptr [t1]
    push edx
    call pr
    .asciz " ticks/s:"
    call dec
    call pr
    .asciz " loops/s:"
    mov edx, ebp
    call dec
    pop edx
    test edx, edx
    jnz 6f
    call pr
    .asciz " NO-TICK"
6:  jmp nl

ticks:
    push es
    push 0x40
    pop es
    mov edx, dword ptr es:[0x6c]
    pop es
    ret

pit_read:
    pushf
    cli
    mov al, 0
    out 0x43, al
    in al, 0x40
    mov ah, al
    in al, 0x40
    xchg al, ah
    popf
    ret

rtc_sec:
    mov al, 0x0a
    call cmos_read
    test al, 0x80
    jnz rtc_sec
    mov al, 0x00
    jmp cmos_read

/* ---------------------------------------------------------------- */
#ifndef USOSHPET
sec_mem:
    call pr
    .asciz "MEM e801:"
    xor cx, cx
    xor dx, dx
    mov ax, 0xe801
    int 0x15
    call cf_mark
    movzx edx, ax
    call hex4
    mov al, ' '
    call putc
    movzx edx, bx
    call hex4
    mov al, ' '
    call putc
    movzx edx, cx
    call hex4
    mov al, ' '
    call putc
    movzx edx, dx
    call hex4
    call pr
    .asciz " 88h:"
    mov ah, 0x88
    clc
    int 0x15
    call cf_mark
    movzx edx, ax
    call hex4
    call nl
    call flush
    xor ebx, ebx
    mov word ptr [count], 0
1:  mov dword ptr [E820BUF + 20], 1
    mov eax, 0xe820
    mov edx, 0x534d4150
    mov ecx, 24
    mov di, E820BUF
    push ebx
    int 0x15
    pop esi
    jc 3f
    cmp eax, 0x534d4150
    jne 3f
    push ebx
    call pr
    .asciz "E820 "
    mov edx, dword ptr [E820BUF + 4]
    call hex8
    mov edx, dword ptr [E820BUF]
    call hex8
    mov al, ' '
    call putc
    mov edx, dword ptr [E820BUF + 12]
    call hex8
    mov edx, dword ptr [E820BUF + 8]
    call hex8
    mov al, ' '
    call putc
    mov edx, dword ptr [E820BUF + 16]
    call hex2
    call nl
    pop ebx
    inc word ptr [count]
    cmp word ptr [count], 64
    jae 3f
    test ebx, ebx
    jnz 1b
3:  call pr
    .asciz "E820 entries:"
    movzx edx, word ptr [count]
    call dec
    jmp nl

/* CF set -> "!" */
cf_mark:
    pushf
    push ax
    jnc 1f
    mov al, '!'
    call putc
1:  pop ax
    popf
    ret

/* CMOS memory-size registers and checksum */
sec_cmos:
    call pr
    .asciz "CMOS 17/18:"
    mov ax, 0x1817
    call cmos_word
    call pr
    .asciz " 30/31:"
    mov ax, 0x3130
    call cmos_word
    call pr
    .asciz " 34/35:"
    mov ax, 0x3534
    call cmos_word
    call pr
    .asciz " 5B-5D:"
    mov al, 0x5d
    call cmos_hex
    mov al, 0x5c
    call cmos_hex
    mov al, 0x5b
    call cmos_hex
    call pr
    .asciz " sum:"
    mov ax, 0x2f2e
    call cmos_word
    mov al, '/'
    call putc
    xor edx, edx
    mov cl, 0x10
1:  mov al, cl
    call cmos_read
    movzx ax, al
    add dx, ax
    inc cl
    cmp cl, 0x2e
    jb 1b
    call hex4
    jmp nl

/* al = low index, ah = high index -> four hex digits (high:low) */
cmos_word:
    push ax
    mov al, ah
    call cmos_read
    mov dh, al
    pop ax
    call cmos_read
    mov dl, al
    movzx edx, dx
    jmp hex4

/* BDA hard disk count, then INT 13h 08h on 80h-8Fh: CF and DL */
sec_drv:
    call pr
    .asciz "DRV bda75:"
    push es
    push 0x40
    pop es
    movzx edx, byte ptr es:[0x75]
    pop es
    call hex2
    call flush_keep
    mov byte ptr [drv], 0x80
1:  mov al, ' '
    call putc
    movzx edx, byte ptr [drv]
    call hex2
    push es
    mov ah, 0x08
    mov dl, byte ptr [drv]
    xor di, di
    mov es, di
    int 0x13
    pop es
    mov al, ':'
    jnc 2f
    mov al, '!'
2:  call putc
    movzx edx, dl
    call hex2
    inc byte ptr [drv]
    cmp byte ptr [drv], 0x90
    jb 1b
    jmp nl

sec_disk:
    call pr
    .asciz "DISK 41h:"
    mov ah, 0x41
    mov bx, 0x55aa
    mov dl, 0x80
    int 0x13
    call cf_mark
    movzx edx, bx
    call hex4
    mov al, ' '
    call putc
    movzx edx, cx
    call hex4
    call pr
    .asciz " 08h:"
    push es
    mov ah, 0x08
    mov dl, 0x80
    xor di, di
    int 0x13
    pop es
    call cf_mark
    push dx                         /* 1.0 printed CX twice here */
    movzx edx, cx
    call hex4
    mov al, ' '
    call putc
    pop dx
    movzx edx, dx
    call hex4
    call pr
    .asciz " 48h:"
    mov word ptr [EDDBUF], 0x1a
    mov si, EDDBUF
    mov ah, 0x48
    mov dl, 0x80
    int 0x13
    call cf_mark
    mov edx, dword ptr [EDDBUF + 0x14]
    call hex8
    mov edx, dword ptr [EDDBUF + 0x10]
    call hex8
    mov al, '/'
    call putc
    movzx edx, word ptr [EDDBUF + 0x18]
    call dec
    jmp nl
#endif

/* ---------------------------------------------------------------- */
sec_hpet:
    mov byte ptr [hpet_rc], 1
    call pr
    .asciz "HPET "
    smsw ax
    test al, 1
    jz 1f
    call pr
    .asciz "skipped: not real mode (V86 memory manager?)"
    jmp nl
1:  call a20_on
    call pr
    .asciz "a20:"
    movzx edx, byte ptr [a20_how]
    call hex1
    call flush_keep
    call find_rsdp
    jnz 2f
    call pr
    .asciz " rsdp:none"
    jmp 9f
2:  push ebx
    call pr
    .asciz " rsdp:"
    pop edx
    push edx
    call hex8
    pop ebx
    /* RSDT (rev 0/1) or XSDT below 4 GiB (rev 2+) */
    lea ebx, [ebx + 15]
    call rd32
    mov cl, al
    add ebx, 1
    mov dword ptr [entsz], 4
    call rd32
    mov esi, eax
    cmp cl, 2
    jb 3f
    add ebx, 8
    call rd32
    mov edi, eax
    add ebx, 4
    call rd32
    test eax, eax
    jnz 3f
    test edi, edi
    jz 3f
    mov esi, edi
    mov dword ptr [entsz], 8
3:  call pr
    .asciz " sdt:"
    mov edx, esi
    call hex8
    mov al, '/'
    call putc
    mov edx, dword ptr [entsz]
    call hex1
    test esi, esi
    jz 9f
    mov ebx, esi
    add ebx, 4
    call rd32
    cmp eax, 36
    jb 9f
    cmp eax, 0x10000
    ja 9f
    lea edi, [esi + eax]
    lea ebx, [esi + 36]
    mov dword ptr [hpet_tbl], 0
4:  mov eax, ebx
    add eax, dword ptr [entsz]
    cmp eax, edi
    ja 6f
    push ebx
    cmp dword ptr [entsz], 8
    jne 5f
    add ebx, 4
    call rd32
    sub ebx, 4
    test eax, eax
    jnz 55f
5:  call rd32
    mov edx, eax
    mov ebx, eax
    call rd32
    cmp eax, 0x54455048
    jne 55f
    mov dword ptr [hpet_tbl], edx
55: pop ebx
    add ebx, dword ptr [entsz]
    jmp 4b
6:  call pr
    .asciz " tbl:"
    mov edx, dword ptr [hpet_tbl]
    call hex8
    mov ebx, edx
    test ebx, ebx
    jz 9f
    /* base: address space (byte 40) memory, address 44/48 below 4 GiB */
    add ebx, 4
    call rd32
    cmp eax, 56
    jb 9f
    add ebx, 36
    call rd32
    test al, al
    jnz 9f
    add ebx, 8
    call rd32
    test eax, eax
    jnz 9f
    sub ebx, 4
    call rd32
    test eax, eax
    jz 9f
    mov dword ptr [hpet_base], eax
    call pr
    .asciz " base:"
    mov edx, eax
    call hex8
    call flush_keep
    call pr
    .asciz " cap:"
    mov ebx, dword ptr [hpet_base]
    call rd32
    mov edx, eax
    call hex8
    call pr
    .asciz " cfg:"
    add ebx, 0x10
    call rd32
    mov dword ptr [hpet_cfg], eax
    mov edx, eax
    call hex8
    call pr
    .asciz " t0:"
    add ebx, 0xf0
    call rd32
    mov edx, eax
    call hex8
    mov ebx, dword ptr [hpet_base]
    add ebx, 0xf0
    call rd32
    mov esi, eax
    mov cx, 2000
7:  in al, 0x61
    loop 7b
    call rd32
    cmp eax, esi
    jne 8f
    call pr
    .asciz " stop"
    jmp 80f
8:  call pr
    .asciz " run"
80: call pr
    .asciz " leg:"
    mov edx, dword ptr [hpet_cfg]
    shr edx, 1
    and edx, 1
    call hex1
    mov byte ptr [hpet_rc], 0
#ifdef USOSHPET
    test byte ptr [hpet_cfg], 2
    jz 9f
    call flush_keep
    mov ebx, dword ptr [hpet_base]
    add ebx, 0x10
    mov eax, dword ptr [hpet_cfg]
    and eax, 0xfffffffd
    call wr32
    call rd32
    mov edx, eax
    test al, 2
    jnz 81f
    call pr
    .asciz ">0 cfg:"
    jmp 82f
81: call pr
    .asciz ">FAILED cfg:"
    mov byte ptr [hpet_rc], 1
82: call hex8
#endif
9:  call a20_off
    jmp nl

/* RSDP: EBDA first KiB, then E0000-FFFFF. ZF clear + ebx = address */
find_rsdp:
    push es
    push 0x40
    pop es
    movzx ebx, word ptr es:[0x0e]
    pop es
    shl ebx, 4
    cmp ebx, 0x80000
    jb 2f
    cmp ebx, 0xa0000
    jae 2f
    lea edi, [ebx + 0x400]
    call scan_rsdp
    jnz 3f
2:  mov ebx, 0xe0000
    mov edi, 0x100000
    call scan_rsdp
3:  ret

scan_rsdp:
1:  call rd32
    cmp eax, 0x20445352
    jne 2f
    add ebx, 4
    call rd32
    sub ebx, 4
    cmp eax, 0x20525450
    jne 2f
    or al, 1
    ret
2:  add ebx, 16
    cmp ebx, edi
    jb 1b
    xor al, al
    ret

/* A20 on for the physical accesses; a20_how: 0 was on, 1 XMS, 2 port
   92h, 3 could not */
a20_on:
    mov byte ptr [a20_how], 0
    call a20_test
    test al, al
    jnz 2f
    mov ax, 0x4300
    int 0x2f
    cmp al, 0x80
    jne 1f
    push es
    mov ax, 0x4310
    int 0x2f
    mov word ptr [xms_entry], bx
    mov word ptr [xms_entry + 2], es
    pop es
    mov ah, 0x05
    call xms
    mov byte ptr [a20_how], 1
    call a20_test
    test al, al
    jnz 2f
1:  in al, 0x92
    mov byte ptr [port92], al
    or al, 2
    and al, 0xfe
    out 0x92, al
    mov byte ptr [a20_how], 2
    call a20_test
    test al, al
    jnz 2f
    mov byte ptr [a20_how], 3
2:  ret

a20_off:
    cmp byte ptr [a20_how], 1
    jne 1f
    mov ah, 0x06
    call xms
    ret
1:  cmp byte ptr [a20_how], 2
    jne 2f
    mov al, byte ptr [port92]
    and al, 0xfe
    out 0x92, al
2:  ret

/* ebx = physical address -> eax (32-bit read) */
rd32:
    pushf
    cli
    call unreal
    mov eax, dword ptr fs:[ebx]
    popf
    ret

/* ebx = physical address, eax = value (32-bit write) */
wr32:
    pushf
    cli
    call unreal
    mov dword ptr fs:[ebx], eax
    popf
    ret

/* FS: base 0, limit 4 GiB (interrupts must be off) */
unreal:
    push eax
    push cx
    lgdt [gdtr]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp 1f
1:  mov cx, 8
    mov fs, cx
    and al, 0xfe
    mov cr0, eax
    jmp 2f
2:  xor cx, cx
    mov fs, cx
    pop cx
    pop eax
    ret

/* ---------------------------------------------------------------- */
/* output: buffer, flushed to the screen and appended to the log      */
putc:
    push di
    mov di, word ptr [outp]
    cmp di, OUTEND
    jae 1f
    mov byte ptr [di], al
    inc di
    mov word ptr [outp], di
1:  pop di
    ret

puts:
    lodsb
    test al, al
    jz 1f
    call putc
    jmp puts
1:  ret

/* inline string after the call */
pr:
    push bp
    mov bp, sp
    push si
    push ax
    mov si, word ptr [bp + 2]
    call puts
    mov word ptr [bp + 2], si
    pop ax
    pop si
    pop bp
    ret

nl:
    mov al, 13
    call putc
    mov al, 10
    jmp putc

hex1:
    mov cx, 1
    jmp hex
hex2:
    mov cx, 2
    jmp hex
hex4:
    mov cx, 4
    jmp hex
hex8:
    mov cx, 8
/* edx = value, cx = digits */
hex:
    pushad
    mov ax, 8
    sub ax, cx
    shl ax, 2
    push cx
    mov cx, ax
    rol edx, cl
    pop cx
1:  rol edx, 4
    mov al, dl
    and al, 15
    add al, '0'
    cmp al, '9'
    jbe 2f
    add al, 7
2:  call putc
    loop 1b
    popad
    ret

/* edx = unsigned decimal */
dec:
    pushad
    mov eax, edx
    xor cx, cx
    mov ebx, 10
1:  xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz 1b
2:  pop ax
    add al, '0'
    call putc
    loop 2b
    popad
    ret

/* flush without ending the line (before a step that might hang) */
flush_keep:
    pushad
    call pr
    .asciz " ..."
    call nl
    call flush
    popad
    ret

flush:
    pushad
    mov cx, word ptr [outp]
    sub cx, OUTBUF
    jz 2f
    push cx
    mov ah, 0x40
    mov bx, 1
    mov dx, OUTBUF
    int 0x21
    mov dx, offset logname
    mov ax, 0x3d01
    int 0x21
    jnc 1f
    mov ah, 0x3c
    xor cx, cx
    int 0x21
    jc 3f
1:  mov bx, ax
    mov ax, 0x4202
    xor cx, cx
    xor dx, dx
    int 0x21
    pop cx
    push cx
    mov ah, 0x40
    mov dx, OUTBUF
    int 0x21
    mov ah, 0x3e
    int 0x21
3:  pop cx
2:  mov word ptr [outp], OUTBUF
    popad
    ret

/* ---------------------------------------------------------------- */
logname:
    .asciz "C:\\USOS9X\\DIAG.LOG"
.balign 8
gdt:
    .quad 0
    .word 0xffff, 0
    .byte 0, 0x92, 0xcf, 0
gdtr:
    .word 15
    .long 0
outp:       .word 0
count:      .word 0
xms_entry:  .long 0
xms_ok:     .byte 0
a20_how:    .byte 0
port92:     .byte 0
hpet_rc:    .byte 1
drv:        .byte 0
.balign 4
t1:         .long 0
entsz:      .long 4
hpet_tbl:   .long 0
hpet_base:  .long 0
hpet_cfg:   .long 0
