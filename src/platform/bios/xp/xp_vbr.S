.intel_syntax noprefix
.code16
.section .text
.global xp_vbr_start

.equ BOOT_BASE,       0x7C00
.equ STAGE2_LOAD,     0x8000
.equ STAGE2_REL_LBA,  8
.equ STAGE2_SECTORS,  24

xp_vbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7B00
    sti
    cld
    mov byte ptr [boot_drive], dl
    call serial_init
    lea si, [msg_start]
    call serial_puts

    /* FAT32 BPB HiddenSectors is populated by mkfs.fat -h. */
    mov eax, dword ptr [BOOT_BASE + 28]
    add eax, STAGE2_REL_LBA
    mov dword ptr [dap_lba], eax
    mov dword ptr [dap_lba + 4], 0
    mov word ptr [dap_count], STAGE2_SECTORS
    mov word ptr [dap_offset], STAGE2_LOAD
    mov word ptr [dap_segment], 0

    mov dl, byte ptr [boot_drive]
    lea si, [dap]
    mov ah, 0x42
    int 0x13
    jc disk_error

    lea si, [msg_read]
    call serial_puts
    mov dl, byte ptr [boot_drive]
    .byte 0xEA
    .word STAGE2_LOAD
    .word 0x0000

disk_error:
    lea si, [msg_disk_serial]
    call serial_puts
    lea si, [msg_disk]
.print:
    lodsb
    test al, al
    jz .halt
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp .print
.halt:
    cli
1:
    hlt
    jmp 1b

serial_init:
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8
    mov al, 0x01
    out dx, al
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x03
    out dx, al
    mov dx, 0x3FA
    mov al, 0xC7
    out dx, al
    mov dx, 0x3FC
    mov al, 0x0B
    out dx, al
    ret

serial_puts:
    push ax
    push dx
.serial_next:
    lodsb
    test al, al
    jz .serial_done
    mov ah, al
.serial_wait:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .serial_wait
    mov dx, 0x3F8
    mov al, ah
    out dx, al
    jmp .serial_next
.serial_done:
    pop dx
    pop ax
    ret

.align 4
dap:
    .byte 0x10, 0x00
dap_count:
    .word 0
dap_offset:
    .word 0
dap_segment:
    .word 0
dap_lba:
    .quad 0
boot_drive:
    .byte 0
msg_start:
    .asciz "[XP-VBR] START\r\n"
msg_read:
    .asciz "[XP-VBR] STAGE2 READ PASS\r\n"
msg_disk_serial:
    .asciz "[XP-VBR] DISK ERROR\r\n"
msg_disk:
    .asciz "USOS XP VBR DISK ERROR"
