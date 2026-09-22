/* DOS sees only the user-selected destination, as BIOS drive 80h. The
 * resident handler is allocated from conventional RAM before MEMDISK starts.
 * No source USB or other hard disk can be addressed through this INT13 view.
 */
.intel_syntax noprefix
.section .rodata.dos_filter,"a",@progbits
.code16
.global dos_filter_start
dos_filter_start:
    cmp dl, 0x80
    jb .dos_filter_chain
    cmp byte ptr cs:[0xf4], 0xff
    je .dos_filter_missing
    cmp dl, 0x80
    jne .dos_filter_missing
    push bp
    mov bp, sp
    push ax
    push dx
    mov dl, byte ptr cs:[0xf4]
    .byte 0x9c
    .byte 0x2e,0xff,0x1e,0xf0,0x00
    jc .dos_filter_error
    and word ptr ss:[bp+6], 0xfffe
    jmp .dos_filter_result
.dos_filter_error:
    or word ptr ss:[bp+6], 1
.dos_filter_result:
    cmp byte ptr ss:[bp-1], 8
    jne .dos_filter_not_geometry
    /* MEMDISK can append its RAM source as 81h and increments the BDA
     * count. Preserve that virtual count so DOS enumerates the RAM disk. */
    push ds
    push ax
    xor ax, ax
    mov ds, ax
    mov dl, byte ptr [0x475]
    pop ax
    pop ds
    jmp .dos_filter_return
.dos_filter_not_geometry:
    cmp byte ptr ss:[bp-1], 0x15
    je .dos_filter_return
    mov dl, byte ptr ss:[bp-4]
.dos_filter_return:
    mov sp, bp
    pop bp
    .byte 0xcf
.dos_filter_missing:
    push bp
    mov bp, sp
    or word ptr ss:[bp+6], 1
    mov ah, 1
    pop bp
    .byte 0xcf
.dos_filter_chain:
    .byte 0x2e,0xff,0x2e,0xf0,0x00
.org 0xf0
    .long 0
    .byte 0x80
.org 0x100
.code32
