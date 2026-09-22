.intel_syntax noprefix
.code16
.section .text
.global xp_diag_vbr_helper

.macro CALL16 target
    .byte 0xE8
    .word \target - (. + 2)
.endm
.macro RET16
    .byte 0xC3
.endm

/* Injected at 0000:7D7B. The entry jump skips the original offsets 00h..10h;
 * reproduce those exact setup instructions, print the incoming BIOS DL, then
 * return to the untouched Microsoft instruction at 0000:7C6B.
 */
xp_diag_vbr_helper:
    xor cx, cx
    mov ss, cx
    mov sp, 0x7BF4
    mov es, cx
    mov ds, cx
    mov bp, 0x7C00
    mov byte ptr [bp + 2], cl

    push ds
    push es
    pushad
    mov cl, dl
    lea si, [msg_v]
    CALL16 puts
    mov al, cl
    shr al, 4
    CALL16 hex_nibble
    mov al, cl
    and al, 0x0F
    CALL16 hex_nibble
    mov al, 13
    CALL16 putc
    mov al, 10
    CALL16 putc
    popad
    pop es
    pop ds

    .byte 0xEA
    .word 0x7C6B
    .word 0x0000

puts:
.next:
    lodsb
    test al, al
    jz .done
    CALL16 putc
    jmp .next
.done:
    RET16

putc:
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    RET16

hex_nibble:
    and al, 0x0F
    cmp al, 9
    jbe .digit
    add al, 'A' - 10
    jmp putc
.digit:
    add al, '0'
    jmp putc

msg_v: .asciz "V DL="
