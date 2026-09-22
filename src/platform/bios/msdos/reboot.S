/* DOS COM helper. /P queues REBOOT without Enter; no arguments restart.
 * All addresses are relative to the PSP's 0100h entry point. */
.intel_syntax noprefix
.section .rodata.dos_reboot,"a",@progbits
.code16
.global dos_reboot_start
dos_reboot_start:
    cld
    xor cx, cx
    mov cl, byte ptr [0x80]
    mov si, 0x81
.skip_space:
    jcxz .restart
    lodsb
    dec cx
    cmp al, ' '
    je .skip_space
    cmp al, '/'
    jne .usage
    cmp cx, 1
    jne .usage
    lodsb
    or al, 0x20
    cmp al, 'p'
    jne .usage

    /* Discard old Enter keys before offering the next command. */
    call .drain_keys
    .byte 0xbe
    .word 0x100 + (.keys - dos_reboot_start)
    mov bx, 6
.queue:
    lodsw
    mov cx, ax
    push si
    push bx
    mov ax, 0x0500
    int 0x16
    pop bx
    pop si
    test al, al
    jnz .queue_failed
    dec bx
    jnz .queue
    mov ax, 0x4c00
    int 0x21

.queue_failed:
    call .drain_keys
.usage:
    .byte 0xba
    .word 0x100 + (.help - dos_reboot_start)
    mov ah, 9
    int 0x21
    mov ax, 0x4c01
    int 0x21

.drain_keys:
    mov ah, 1
    int 0x16
    jz .drained
    xor ah, ah
    int 0x16
    jmp .drain_keys
.drained:
    ret

.restart:
    /* The caller closes its files and flushes SMARTDrive when loaded. */
    mov ah, 0x0d
    int 0x21
    cli
    mov ax, 0x40
    mov ds, ax
    mov word ptr [0x72], 0x1234
    /* Re-enter BIOS POST, not INT 19h with MEMDISK hooks still installed. */
    .byte 0xea
    .word 0, 0xffff
.keys:
    .word 0x1352, 0x1245, 0x3042, 0x184f, 0x184f, 0x1454
.help:
    .ascii "Type REBOOT and press Enter to restart.\r\n$"
.code32
