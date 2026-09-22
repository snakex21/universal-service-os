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
