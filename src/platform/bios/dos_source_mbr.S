.intel_syntax noprefix
.section .rodata.dos_source_mbr,"a",@progbits
.code16
.global dos_source_mbr_start
.equ DOS_SOURCE_RELOC, 0x600 + (.dos_source_relocated - dos_source_mbr_start)
.equ DOS_SOURCE_DAP, 0x600 + (.dos_source_dap - dos_source_mbr_start)
/* Keep the RAM source as BIOS 81h, but start MS-DOS from the prepared 80h.
 * MS-DOS 6.22's own second-hard-disk remapper must not swap these drives. */
dos_source_mbr_start:
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
    .word DOS_SOURCE_RELOC
    .byte 0xcb
.dos_source_relocated:
    sti
    mov dl, 0x80
    .byte 0xbe
    .word DOS_SOURCE_DAP
    mov ah, 0x42
    int 0x13
    jc .dos_source_fail
    cmp word ptr [0x7dfe], 0xaa55
    jne .dos_source_fail
    .byte 0xea
    .word 0x7c00,0
.dos_source_fail:
    mov ax, 0x0e45
    xor bx, bx
    int 0x10
    cli
.dos_source_stop:
    hlt
    jmp .dos_source_stop
.balign 4
.dos_source_dap:
    .byte 16,0
    .word 1,0x7c00,0
    .quad 0
.org 440
    .long 0
    .word 0
    .fill 64,1,0
    .word 0xaa55
.code32
