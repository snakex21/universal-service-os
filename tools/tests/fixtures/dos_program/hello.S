/* A real DOS COM program reads its companion file and writes to the console. */
.intel_syntax noprefix
.code16
.section .text,"ax",@progbits
.global start
start:
    mov ax, 0x3d00
    mov dx, offset filename
    int 0x21
    jc failed
    mov bx, ax
    push bx
    mov ah, 0x3f
    mov cx, 128
    mov dx, offset buffer
    int 0x21
    pushf
    push ax
    pop cx
    popf
    pop bx
    jc failed
    push cx
    mov ah, 0x3e
    int 0x21
    pop cx
    mov ah, 0x40
    mov bx, 1
    mov dx, offset buffer
    int 0x21
    jc failed
    mov ax, 0x4c00
    int 0x21
failed:
    mov ax, 0x4c01
    int 0x21
filename:
    .asciz "INPUT.TXT"
buffer:
    .zero 128
