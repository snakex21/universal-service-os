.code16
.intel_syntax noprefix
.section .text,"ax",@progbits
.global stage1_start

.equ BOOT_BASE, 0x7C00
.equ CORE_LOAD_SEGMENT, 0x1000
.equ CORE_LOAD_OFFSET, 0x0000
.equ CORE_BOOTSTRAP_ENTRY, 0x0040
.equ CORE_LBA, 64
.equ CORE_SECTORS, 32

.macro CALL16 target
    .byte 0xE8
    .word \target - . - 2
.endm

stage1_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, BOOT_BASE
    sti

    mov byte ptr [boot_drive], dl
    mov dx, 0x00E9
    mov al, 'S'
    out dx, al
    mov dl, byte ptr [boot_drive]

    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc stage1_fail
    mov dx, 0x00E9
    mov al, 'A'
    out dx, al
    cmp bx, 0xAA55
    jne stage1_fail
    test cx, 0x0001
    jz stage1_fail
    mov dx, 0x00E9
    mov al, 'B'
    out dx, al

    lea si, [disk_packet]
    mov dl, byte ptr [boot_drive]
    mov ah, 0x42
    int 0x13
    jc stage1_read_fail

    mov dx, 0x00E9
    mov al, 'J'
    out dx, al
    mov dl, byte ptr [boot_drive]
    .byte 0xEA
    .word CORE_BOOTSTRAP_ENTRY
    .word CORE_LOAD_SEGMENT

stage1_read_fail:
    mov al, ah
    CALL16 debug_hex8
    jmp stage1_fail

stage1_fail:
    mov dx, 0x00E9
    mov al, 'F'
    out dx, al
    lea si, [fail_message]
.stage1_fail_print:
    lodsb
    test al, al
    jz .stage1_halt
    mov ah, 0x0E
    xor bx, bx
    int 0x10
    jmp .stage1_fail_print
.stage1_halt:
    cli
.stage1_hang:
    hlt
    jmp .stage1_hang

debug_hex8:
    push ax
    push bx
    push dx
    mov bl, al
    shr al, 4
    CALL16 debug_nibble
    mov al, bl
    and al, 0x0F
    CALL16 debug_nibble
    pop dx
    pop bx
    pop ax
    .byte 0xC3

debug_nibble:
    and al, 0x0F
    cmp al, 10
    jb .debug_digit
    add al, 'A' - 10
    jmp .debug_out
.debug_digit:
    add al, '0'
.debug_out:
    mov dx, 0x00E9
    out dx, al
    .byte 0xC3

.align 4
disk_packet:
    .byte 0x10
    .byte 0x00
    .word CORE_SECTORS
    .word CORE_LOAD_OFFSET
    .word CORE_LOAD_SEGMENT
    .long CORE_LBA
    .long 0x00000000

boot_drive:
    .byte 0

fail_message:
    .asciz "USOS BIOS STAGE1 FAIL"
