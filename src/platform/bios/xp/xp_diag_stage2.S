.intel_syntax noprefix
.code16
.section .text
.global xp_diag_stage2_dispatch

.macro CALL16 target
    .byte 0xE8
    .word \target - (. + 2)
.endm
.macro RET16
    .byte 0xC3
.endm

/* Injected at 0000:8148 into the zero tail of Microsoft NT52 stage2. */
xp_diag_stage2_dispatch:
    /* Read the 16-bit CALL return address without touching BX/DX/SP. */
    push ax
    mov ax, word ptr ss:[esp + 2]
    cmp ax, 0x8003
    je dispatch_2
    cmp ax, 0x8059
    je dispatch_f
    cmp ax, 0x8089
    je dispatch_n
    cmp ax, 0x80D9
    je dispatch_j
    pop ax
    RET16

dispatch_2:
    pop ax
    movzx eax, byte ptr [bp + 0x10]
    push eax
    mov al, '2'
    CALL16 marker
    pop eax
    RET16

dispatch_f:
    pop ax
    CALL16_ORIGINAL_READ:
    .byte 0xE8
    .word 0x7CE0 - (. + 2)
    push eax
    mov al, 'F'
    CALL16 marker
    pop eax
    RET16

dispatch_n:
    pop ax
    mov si, word ptr [di + 9]
    push eax
    mov al, 'N'
    CALL16 marker
    pop eax
    RET16

dispatch_j:
    pop ax
    mov dl, byte ptr [bp + 0x40]
    /* Large J diagnostic lives at 0000:1000, copied there by the prelude.
     * It preserves all Microsoft state, prints CRC evidence, waits five BIOS
     * timer seconds and returns so the untouched far jump at 0000:80D9 runs. */
    CALL16 0x1000
    RET16

/* AL=breadcrumb. Preserve all Microsoft registers and segment registers. */
marker:
    push ds
    push es
    pushad
    mov cl, byte ptr [bp + 0x40]
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    mov al, ' '
    int 0x10
    mov al, 'D'
    int 0x10
    mov al, 'L'
    int 0x10
    mov al, '='
    int 0x10
    mov al, cl
    shr al, 4
    cmp al, 10
    sbb al, 0x69
    das
    int 0x10
    mov al, cl
    and al, 0x0F
    cmp al, 10
    sbb al, 0x69
    das
    int 0x10
    mov al, 13
    int 0x10
    mov al, 10
    int 0x10
    popad
    pop es
    pop ds
    RET16
