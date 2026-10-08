/*
 * USOS NT 3.x MBR: E820 filter + XP geometry fix.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-2.0-or-later.
 *
 * The NT 3.51 loaders (SETUPLDR.BIN, NTLDR) turn every INT 15h E820 entry
 * into a loader memory descriptor, reserved ones included, and the 3.51
 * kernel takes MmHighestPhysicalPage from the highest descriptor.  A firmware
 * reserved range near 4 GiB (SeaBIOS: FFFC0000, real boards: APIC/flash/MMIO)
 * makes it 0xFFFFF while the PFN database only covers RAM, so
 * MiInitMachineDependent faults (STOP 0x50, CR2 just above the PFN database)
 * on the first page table entry that maps device memory.
 *
 * This MBR keeps 1 KiB at the top of conventional memory for an INT 15h hook
 * that rewrites E820 results:
 *   - entries above 4 GiB and non-RAM entries at or above 1 MiB become a copy
 *     of the BIOS ROM range F0000-FFFFF (type 2), which is below any RAM top;
 *   - RAM entries are clipped at 4 GiB;
 *   - the RAM entry at address 0 ends below the hook (INT 12h size).
 * Everything else is the XP geometry-fix MBR: boot the active partition and
 * correct the BPB head count from INT 13h AH=08.
 *
 * HPET: the X470 firmware (AMI, booted through CSMWrap) hands over with the
 * HPET enabled in LegacyReplacement mode and timer 0 interrupts off
 * (usosrst 1.3, Win2000: cfg 00000003, t0 00008030).  Then neither the PIT
 * nor the HPET raises IRQ 0 (and the RTC not IRQ 8), so a pre-ACPI HAL gets
 * no clock interrupt.  NT 4.0 and 2000 survive until usosrst clears the bit;
 * NT 3.51 waits on the clock before the first boot driver (hang after
 * "1 System Processor", APIC and Standard PC HAL alike).  This MBR clears
 * LegacyReplacement (general configuration bit 1) itself, through a 4 GiB
 * FS limit (unreal mode), when the HPET at FED00000h (the fixed AMD/Intel
 * address) answers.  -DNT3_HPET_SET_LEGACY builds the opposite (enable +
 * LegacyReplacement) to reproduce the X470 state in QEMU.
 */
.intel_syntax noprefix
.code16
.section .text
.global nt3_e820_mbr_start

.equ RELOC_BASE,      0x0600
.equ BOOT_DRIVE_SLOT, 0x04F0
.equ PART_TABLE_OFF,  446
.equ VBR_LOAD,        0x7C00
.equ HOOK_LEN,        (hook_end - hook_start)
.equ HOOK_SRC,        RELOC_BASE + (hook_start - nt3_e820_mbr_start)

nt3_e820_mbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld

    mov byte ptr [BOOT_DRIVE_SLOT], dl

    mov si, 0x7C00
    mov di, RELOC_BASE
    mov cx, 256
    rep movsw
    .byte 0xEA
    .word RELOC_BASE + (relocated - nt3_e820_mbr_start)
    .word 0x0000

relocated:
    /* Take 1 KiB from the top of conventional memory for the INT 15h hook. */
    dec word ptr [0x0413]
    mov ax, word ptr [0x0413]
    shl ax, 6
    mov es, ax
    xor di, di
    mov si, offset HOOK_SRC
    mov cx, offset HOOK_LEN
    rep movsb
    mov eax, dword ptr [0x15 * 4]
    mov dword ptr es:[0], eax
    cli
    /* FS: flat 4 GiB limit (unreal mode), then the HPET general config. */
    .byte 0x0F, 0x01, 0x16                 /* lgdt [gdtr] (relocated) */
    .word RELOC_BASE + (gdtr - nt3_e820_mbr_start)
    mov eax, cr0
    inc ax
    mov cr0, eax
    mov bx, 8
    mov fs, bx
    dec ax
    mov cr0, eax
    mov ebx, 0xFED00000
    mov eax, dword ptr fs:[ebx]
    inc eax
    jz 1f
#ifdef NT3_HPET_SET_LEGACY
    or dword ptr fs:[ebx + 0x10], 3
#else
    btr dword ptr fs:[ebx + 0x10], 1
#endif
1:
    mov word ptr [0x15 * 4], 4
    mov word ptr [0x15 * 4 + 2], es
    sti
    push ds
    pop es

    mov si, RELOC_BASE + PART_TABLE_OFF
    mov cx, 4
find_active:
    cmp byte ptr [si], 0x80
    je active_found
    add si, 16
    loop find_active
    jmp boot_error

active_found:
    /* INT 13h AH=42 packet on the stack: 1 sector of LBA [si+8] to 0:7C00. */
    .byte 0x66, 0x6A, 0x00                 /* push dword 0 (LBA high) */
    push dword ptr [si + 8]
    .byte 0x6A, 0x00                       /* push word 0 (segment) */
    .byte 0x68
    .word VBR_LOAD                         /* push word 7C00h (offset) */
    .byte 0x6A, 0x01                       /* push word 1 (sectors) */
    .byte 0x6A, 0x10                       /* push word 10h (size) */
    mov si, sp

    mov dl, byte ptr [BOOT_DRIVE_SLOT]
    mov ah, 0x42
    int 0x13
    jc boot_error

    /* Same fail-safe heads correction as xp_geometry_fix_mbr.S. */
    mov dl, byte ptr [BOOT_DRIVE_SLOT]
    mov ah, 0x08
    int 0x13
    jc geometry_fallback
    mov al, cl
    and al, 0x3F
    jz geometry_fallback
    cmp byte ptr [VBR_LOAD + 0x19], 0
    jne geometry_fallback
    cmp al, byte ptr [VBR_LOAD + 0x18]
    jne geometry_fallback
    cmp dh, 1
    jb geometry_fallback
    cmp dh, 254
    ja geometry_fallback
    movzx ax, dh
    inc ax
    mov word ptr [VBR_LOAD + 0x1A], ax

geometry_fallback:
    mov dl, byte ptr [BOOT_DRIVE_SLOT]
    .byte 0xEA
    .word VBR_LOAD
    .word 0x0000

boot_error:
    cli
1:
    hlt
    jmp 1b

/* GDT for the unreal-mode FS: the base points 8 bytes before the flat data
   descriptor, so the (never loaded) null descriptor is the code above. */
gdtr:
    .word 15
    .long RELOC_BASE + (gdt_flat - nt3_e820_mbr_start) - 8
gdt_flat:
    .byte 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00

/* Resident part, copied to (INT 12h top):0000; the old vector is at offset 0,
   the handler (new INT 15h vector) at offset 4. */
hook_start:
    .long 0
    cmp eax, 0xE820
    je 2f
    .byte 0x2E, 0xFF, 0x2E, 0x00, 0x00    /* jmp far cs:[0] (m16:16) */
2:
    pushf
    .byte 0x2E, 0xFF, 0x1E, 0x00, 0x00    /* call far cs:[0] (m16:16) */
    push bp
    mov bp, sp
    jc 8f
    push eax
    cmp dword ptr es:[di + 4], 0
    jne 6f
    cmp dword ptr es:[di + 16], 1
    je 4f
    cmp dword ptr es:[di], 0x100000
    jb 7f
    jmp 6f
4:
    /* RAM: clip at 4 GiB, end the low entry below the hook. */
    cmp dword ptr es:[di + 12], 0
    jne 5f
    mov eax, dword ptr es:[di]
    add eax, dword ptr es:[di + 8]
    jnc 3f
5:
    mov eax, dword ptr es:[di]
    neg eax
    mov dword ptr es:[di + 8], eax
    mov dword ptr es:[di + 12], 0
3:
    cmp dword ptr es:[di], 0
    jne 7f
    push ds
    xor ax, ax
    mov ds, ax
    movzx eax, word ptr [0x0413]
    pop ds
    shl eax, 10
    cmp dword ptr es:[di + 8], eax
    jbe 7f
    mov dword ptr es:[di + 8], eax
    jmp 7f
6:
    mov dword ptr es:[di], 0xF0000
    mov dword ptr es:[di + 4], 0
    mov dword ptr es:[di + 8], 0x10000
    mov dword ptr es:[di + 12], 0
    mov dword ptr es:[di + 16], 2
7:
    pop eax
    and byte ptr [bp + 6], 0xFE
    pop bp
    iret
8:
    or byte ptr [bp + 6], 0x01
    pop bp
    iret
hook_end:
