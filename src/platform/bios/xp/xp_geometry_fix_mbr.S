/*
 * USOS_W2K_ACPI (w2k-acpi-mbr-440.bin, Windows 2000 with the ACPI HAL behind
 * CSMWrap, docs/windows-2000-acpi-x470-2026-10-12.md).  Own code,
 * GPL-2.0-or-later, from the ACPI specification and the IA-PC HPET
 * specification only.  Before the VBR runs this build:
 *   1. clears HPET LegacyReplacement (general configuration bit 1 at
 *      FED00000h+10h).  The X470 firmware hands over with it set and HPET
 *      timer 0 interrupts off, so IRQ 0 / IRQ 8 never fire; the 2000 ACPI
 *      HALs calibrate KeStallExecutionProcessor on IRQ 0 and hang right
 *      after SETUPLDR (X470 run 5, 2026-10-04).  The board's own DSDT turns
 *      the HPET off only for _OSI("Windows 2006") and later.
 *   2. walks RSDP (E0000h-FFFFFh) -> RSDT -> FACP.DSDT and every SSDT and
 *      rewrites each Name(xxxx, QWordConst) into Name(xxxx, DWordConst) plus
 *      four NoopOps (same length, so no package length moves), then fixes
 *      the table checksum.  QWordConst (0Eh) is ACPI 2.0; the 1.0b-era
 *      acpi.sys of Windows 2000 cannot load a table that uses it outside a
 *      method (X470 DSDT: \_SB.PCI0 MAB/MAL/MAM).  A value above 4 GiB
 *      becomes 0 (no 64-bit window for a 32-bit OS).
 * Physical memory is reached through FS with a 4 GiB limit (unreal mode).
 */
.intel_syntax noprefix
.code16
.section .text
.global xp_geometry_fix_mbr_start

.equ RELOC_BASE,      0x0600
.equ BOOT_DRIVE_SLOT, 0x04F0
.equ HEADS_SLOT,      0x04F2
.equ DAP_BASE,        0x0500
.equ PART_TABLE_OFF,  446
.equ VBR_LOAD,        0x7C00

xp_geometry_fix_mbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld

    mov byte ptr [BOOT_DRIVE_SLOT], dl

    /* Relocate the complete sector because the VBR will replace 0000:7C00. */
    mov si, 0x7C00
    mov di, RELOC_BASE
    mov cx, 256
    rep movsw
    .byte 0xEA
    .word RELOC_BASE + (relocated - xp_geometry_fix_mbr_start)
    .word 0x0000

relocated:
#ifdef USOS_W2K_ACPI
    call w2k_acpi_fix
#endif
    /* Find the active primary partition in the preserved MBR table. */
    mov si, RELOC_BASE + PART_TABLE_OFF
    mov cx, 4
find_active:
    cmp byte ptr [si], 0x80
    je active_found
    add si, 16
    loop find_active
    jmp boot_error

active_found:
    /* Build an EDD Disk Address Packet for one VBR sector at its start LBA. */
    mov byte ptr [DAP_BASE + 0], 0x10
    mov byte ptr [DAP_BASE + 1], 0x00
    mov word ptr [DAP_BASE + 2], 1
    mov word ptr [DAP_BASE + 4], VBR_LOAD
    mov word ptr [DAP_BASE + 6], 0x0000
    mov eax, dword ptr [si + 8]
    mov dword ptr [DAP_BASE + 8], eax
    mov dword ptr [DAP_BASE + 12], 0

    mov dl, byte ptr [BOOT_DRIVE_SLOT]
    mov si, DAP_BASE
    mov ah, 0x42
    int 0x13
    jc boot_error

    /*
     * Ask for the geometry only after the VBR is safely in RAM.  If AH=08
     * fails or returns obviously unusable HDD geometry, leave the on-disk BPB
     * value intact.  That makes the correction fail-safe: a strange BIOS can
     * lose the runtime fix, but it cannot make us write a bogus divisor into
     * the Microsoft VBR or crash in this MBR.
     *
     * For the HDD target accept 2..255 heads and 1..63 sectors/track.  DH is
     * the maximum zero-based head, so valid accepted DH is 1..254.
     */
    mov dl, byte ptr [BOOT_DRIVE_SLOT]
    mov ah, 0x08
    int 0x13
    jc geometry_fallback
    mov al, cl
    and al, 0x3F
    jz geometry_fallback
    /* Heads-only correction is safe only when BIOS and BPB agree on SPT. */
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
    mov word ptr [HEADS_SLOT], ax
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

#ifdef USOS_W2K_ACPI
.equ W2K_REL, RELOC_BASE - 0x7C00

/* Runs in 32-bit protected mode (flat, interrupts off), then back to real
   mode with DS = ES = 0.  Clobbers the general registers. */
w2k_acpi_fix:
    cli
    .byte 0x0F, 0x01, 0x16                 /* lgdt [w2k_gdt] (relocated) */
    .word w2k_gdt + W2K_REL
    mov eax, cr0
    inc ax
    mov cr0, eax
    .byte 0x66, 0xEA                       /* ljmp 08h:w2k_pm32 */
    .long w2k_pm32 + W2K_REL
    .word 0x08

.code32
w2k_pm32:
    push 0x10
    .byte 0x1F                             /* pop ds (32-bit pop) */

    /* 1. HPET: all-ones = nothing decodes there. */
    mov ebx, 0xFED00000
    mov eax, dword ptr [ebx]
    inc eax
    jz 1f
    and dword ptr [ebx + 0x10], 0xFFFFFFFD
1:
    /* 2. RSDP in E0000h-FFFFFh, 16-byte steps ("RSD ", then the RSDT
       signature confirms it; no room for the whole "RSD PTR "). */
    mov esi, 0x000E0000
2:
    cmp dword ptr [esi], 0x20445352        /* "RSD " */
    je 4f
    add esi, 16
    cmp esi, 0x00100000
    jb 2b
    jmp 9f
4:
    mov esi, dword ptr [esi + 16]          /* RsdtAddress */
    cmp dword ptr [esi], 0x54445352        /* "RSDT" */
    jne 9f
    mov ecx, dword ptr [esi + 4]
    sub ecx, 36
    shr ecx, 2
    jz 9f
5:
    mov edi, dword ptr [esi + 36]
    cmp dword ptr [edi], 0x50434146        /* "FACP" */
    jne 6f
    mov edi, dword ptr [edi + 40]          /* DSDT */
    test edi, edi
    jnz 7f
6:
    cmp dword ptr [edi], 0x54445353        /* "SSDT" */
    jne 8f
7:
    call w2k_aml_patch
8:
    add esi, 4
    loop 5b
9:
    .byte 0xEA                             /* ljmp 18h:w2k_pm16 */
    .long w2k_pm16 + W2K_REL
    .word 0x18

/* EDI = DSDT/SSDT: Name(NNNN, QWordConst) -> Name(NNNN, DWordConst) + 4 x
   NoopOp, then the checksum is made valid again.  Keeps every register. */
w2k_aml_patch:
    pushad
    mov ebp, dword ptr [edi + 4]
    lea ebp, [edi + ebp - 14]              /* last start of 08 NNNN 0E qqqqqqqq */
    lea esi, [edi + 36]
1:
    cmp esi, ebp
    ja 5f
    cmp byte ptr [esi], 0x08               /* NameOp */
    jne 4f
    cmp byte ptr [esi + 5], 0x0E           /* QWordPrefix */
    jne 4f
    cmp byte ptr [esi + 1], 0x41           /* NameSeg: lead [A-Z_], */
    jb 4f
    test dword ptr [esi + 1], 0x80808080   /* all four ASCII */
    jnz 4f
    mov byte ptr [esi + 5], 0x0C           /* DWordPrefix */
    xor eax, eax
    cmp dword ptr [esi + 10], eax
    je 6f
    mov dword ptr [esi + 6], eax           /* above 4 GiB: 0 */
6:
    mov dword ptr [esi + 10], 0xA3A3A3A3   /* 4 x NoopOp */
4:
    inc esi
    jmp 1b
5:
    /* Checksum: subtract the byte sum (0 when nothing changed). */
    mov ecx, dword ptr [edi + 4]
    xor eax, eax
8:
    add al, byte ptr [edi + ecx - 1]
    loop 8b
    sub byte ptr [edi + 9], al
    popad
    ret

.code16
w2k_pm16:
    mov eax, cr0
    dec ax
    mov cr0, eax
    .byte 0xEA                             /* ljmp 0000h:w2k_real */
    .word w2k_real + W2K_REL
    .word 0x0000
w2k_real:
    xor ax, ax
    mov ds, ax
    sti
    ret

w2k_gdt:                                   /* the null slot holds the GDTR */
    .word 31
    .long w2k_gdt + W2K_REL
    .word 0
    .quad 0x00CF9A000000FFFF               /* 08h code32, flat */
    .quad 0x00CF92000000FFFF               /* 10h data32, flat */
    .quad 0x00009A000000FFFF               /* 18h code16, base 0, 64 KiB */
#endif
