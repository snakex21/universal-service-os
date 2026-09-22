.intel_syntax noprefix
.code16
.section .text
.global xp_diag_stage2_dispatch

.macro RET16
    .byte 0xC3
.endm

/* Minimal Microsoft NT52 instrumentation used only to capture the exact ABI
 * immediately before its original far jump to 2000:0000. */
xp_diag_stage2_dispatch:
    push ax
    mov ax, word ptr ss:[esp + 2]
    cmp ax, 0x8003
    je regs_2
    cmp ax, 0x8059
    je regs_f
    cmp ax, 0x8089
    je regs_n
    cmp ax, 0x80D9
    je regs_j
    pop ax
    RET16

regs_2:
    pop ax
    movzx eax, byte ptr [bp + 0x10]
    RET16

regs_f:
    pop ax
    .byte 0xE8
    .word 0x7CE0 - (. + 2)
    RET16

regs_n:
    pop ax
    mov si, word ptr [di + 9]
    RET16

regs_j:
    pop ax
    mov dl, byte ptr [bp + 0x40]

    mov dword ptr cs:[0x1000], 0x53474552 /* 'REGS' little-endian */
    mov dword ptr cs:[0x1004], eax
    mov dword ptr cs:[0x1008], ebx
    mov dword ptr cs:[0x100C], ecx
    mov dword ptr cs:[0x1010], edx
    mov dword ptr cs:[0x1014], esi
    mov dword ptr cs:[0x1018], edi
    mov dword ptr cs:[0x101C], ebp
    mov ax, sp
    mov word ptr cs:[0x1020], ax
    mov ax, ds
    mov word ptr cs:[0x1022], ax
    mov ax, es
    mov word ptr cs:[0x1024], ax
    mov ax, fs
    mov word ptr cs:[0x1026], ax
    mov ax, gs
    mov word ptr cs:[0x1028], ax
    mov ax, ss
    mov word ptr cs:[0x102A], ax
    pushf
    pop ax
    mov word ptr cs:[0x102C], ax
    cli
1:
    hlt
    jmp 1b
