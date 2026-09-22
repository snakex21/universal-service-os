.intel_syntax noprefix
.section .rodata.dos_mbr,"a",@progbits
.code16
.global dos_mbr_start
.equ DOS_MBR_RELOC, 0x600 + (.dos_mbr_relocated - dos_mbr_start)
.equ DOS_MBR_DAP, 0x600 + (.dos_mbr_dap - dos_mbr_start)
dos_mbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    cld
    mov si, 0x7c00
    mov di, 0x600
    mov cx, 256
    rep movsw
    push 0
    .byte 0x68
    .word DOS_MBR_RELOC
    .byte 0xcb
.dos_mbr_relocated:
    sti
    mov eax, dword ptr [0x600 + 454]
    mov dword ptr [DOS_MBR_DAP + 8], eax
    .byte 0xbe
    .word DOS_MBR_DAP
    mov ah, 0x42
    int 0x13
    jc .dos_mbr_fail
    cmp word ptr [0x7dfe], 0xaa55
    jne .dos_mbr_fail
    .byte 0xea
    .word 0x7c00,0
.dos_mbr_fail:
    mov ax, 0x0e45
    xor bx, bx
    int 0x10
    cli
.dos_mbr_stop:
    hlt
    jmp .dos_mbr_stop
.balign 4
.dos_mbr_dap:
    .byte 16,0
    .word 1,0x7c00,0
    .quad 0
.org 440
    .long 0
    .word 0
    .fill 64,1,0
    .word 0xaa55
.code32
