.intel_syntax noprefix
.code16
.section .text
.global xp_diag_mbr_start

.equ RELOC_BASE,      0x0600
.equ BOOT_DRIVE_SLOT, 0x04F0
.equ DAP_BASE,        0x0500
.equ PRELUDE_LOAD,    0x8000
.equ PRELUDE_LBA,     1
.equ PRELUDE_SECTORS, 8

xp_diag_mbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld

    mov byte ptr [BOOT_DRIVE_SLOT], dl
    lea si, [msg_m]
    call screen_puts
    mov al, dl
    call screen_hex8
    lea si, [crlf]
    call screen_puts

    /* Relocate before any later code overwrites 0000:7C00. */
    mov si, 0x7C00
    mov di, RELOC_BASE
    mov cx, 256
    rep movsw
    .byte 0xEA
    .word RELOC_BASE + (relocated - xp_diag_mbr_start)
    .word 0x0000

relocated:
    mov byte ptr [DAP_BASE + 0], 0x10
    mov byte ptr [DAP_BASE + 1], 0x00
    mov word ptr [DAP_BASE + 2], PRELUDE_SECTORS
    mov word ptr [DAP_BASE + 4], PRELUDE_LOAD
    mov word ptr [DAP_BASE + 6], 0x0000
    mov dword ptr [DAP_BASE + 8], PRELUDE_LBA
    mov dword ptr [DAP_BASE + 12], 0

    mov dl, byte ptr [BOOT_DRIVE_SLOT]
    mov si, DAP_BASE
    mov ah, 0x42
    int 0x13
    jc mbr_read_error

    mov dl, byte ptr [BOOT_DRIVE_SLOT]
    .byte 0xEA
    .word PRELUDE_LOAD
    .word 0x0000

mbr_read_error:
    mov bl, ah
    lea si, [msg_m_read]
    call screen_puts
    mov al, bl
    call screen_hex8
    lea si, [crlf]
    call screen_puts
    cli
1:
    hlt
    jmp 1b

screen_puts:
    push ax
    push bx
    push si
.put_next:
    lodsb
    test al, al
    jz .put_done
    call screen_putc
    jmp .put_next
.put_done:
    pop si
    pop bx
    pop ax
    ret

screen_putc:
    push bx
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    pop bx
    ret

screen_hex8:
    push ax
    push bx
    mov bl, al
    shr al, 4
    call screen_hex_nibble
    mov al, bl
    and al, 0x0F
    call screen_hex_nibble
    pop bx
    pop ax
    ret

screen_hex_nibble:
    and al, 0x0F
    cmp al, 9
    jbe .digit
    add al, 'A' - 10
    jmp screen_putc
.digit:
    add al, '0'
    jmp screen_putc

msg_m:      .asciz "M DL="
msg_m_read: .asciz "M PRELUDE ERR="
crlf:       .asciz "\r\n"
