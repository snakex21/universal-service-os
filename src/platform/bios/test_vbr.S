.code16
.intel_syntax noprefix
.section .text,"ax",@progbits
.global test_vbr_start

.equ BOOT_BASE, 0x7C00

.macro CALL16 target
    .byte 0xE8
    .word \target - . - 2
.endm

test_vbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, BOOT_BASE
    sti

    mov byte ptr [boot_drive], dl
    mov dx, 0x00E9
    mov al, 'P'
    out dx, al
    CALL16 serial_init
    lea si, [pass_message]
    CALL16 print_string

    mov dx, 0x00F4
    mov al, 0x10
    out dx, al

    cli
.hang:
    hlt
    jmp .hang

serial_init:
    mov dx, 0x03F9
    xor al, al
    out dx, al
    mov dx, 0x03FB
    mov al, 0x80
    out dx, al
    mov dx, 0x03F8
    mov al, 0x01
    out dx, al
    mov dx, 0x03F9
    xor al, al
    out dx, al
    mov dx, 0x03FB
    mov al, 0x03
    out dx, al
    mov dx, 0x03FA
    mov al, 0xC7
    out dx, al
    mov dx, 0x03FC
    mov al, 0x0B
    out dx, al
    .byte 0xC3

serial_putchar:
    push ax
    push dx
    mov ah, al
.wait:
    mov dx, 0x03FD
    in al, dx
    test al, 0x20
    jz .wait
    mov dx, 0x03F8
    mov al, ah
    out dx, al
    pop dx
    pop ax
    .byte 0xC3

put_char:
    CALL16 serial_putchar
    push ax
    push bx
    mov ah, 0x0E
    xor bx, bx
    int 0x10
    pop bx
    pop ax
    .byte 0xC3

print_string:
.next:
    lodsb
    test al, al
    jz .done
    CALL16 put_char
    jmp .next
.done:
    .byte 0xC3

boot_drive:
    .byte 0
pass_message:
    .asciz "CHAINLOAD PASS\r\n"
