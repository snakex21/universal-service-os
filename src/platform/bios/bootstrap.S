.code16
.intel_syntax noprefix
.section .text,"ax",@progbits
.global bootstrap_start

.equ CORE_LBA, 64
.equ BOOTSTRAP_BYTES, 16384
.equ BOOTSTRAP_SECTORS, 32
.equ SLOT_BYTES, 262144
.equ SLOT_SECTORS, 512
.equ HEADER_BYTES, 64
.equ FORMAT_VERSION, 1
.equ CORE_LOAD_SEGMENT, 0x2000
.equ CORE_LOAD_ADDRESS, 0x00020000
.equ CORE_ENTRY_OFFSET, 0
.equ BOOTSTRAP_PHYS_BASE, 0x00010000
.equ MAX_READ_SECTORS, 32

/* Mutable runtime state lives outside the checksummed Core image. */
.equ SCRATCH_SEGMENT, 0x0900
.equ SCR_BOOT_DRIVE, 0
.equ SCR_REMAINING_SECTORS, 2
.equ SCR_DESTINATION_SEGMENT, 4
.equ SCR_CURRENT_LBA, 8
.equ SCR_CRC_REMAINING, 12
.equ SCR_CRC_SEGMENT, 16
.equ SCR_CRC_CHUNK, 18
.equ SCR_A20_RESULT, 20
.equ SCR_A20_92_WRITE_COUNT, 21
.equ SCR_A20_92_BEFORE, 22
.equ SCR_A20_92_AFTER, 23
.equ SCR_DAP, 32
.equ SCR_DAP_COUNT, SCR_DAP + 2
.equ SCR_DAP_OFFSET, SCR_DAP + 4
.equ SCR_DAP_SEGMENT, SCR_DAP + 6
.equ SCR_DAP_LBA, SCR_DAP + 8
.equ SCR_DAP_LBA_HI, SCR_DAP + 12

/* Versioned bootstrap -> PM32 handoff. Physical address 0x00009100. */
.equ SCR_CONTEXT, 0x0100
.equ CTX_MAGIC, SCR_CONTEXT + 0
.equ CTX_VERSION, SCR_CONTEXT + 4
.equ CTX_SIZE, SCR_CONTEXT + 6
.equ CTX_BIOS_DRIVE, SCR_CONTEXT + 8
.equ CTX_RESERVED, SCR_CONTEXT + 9
.equ CTX_SECTOR_BYTES, SCR_CONTEXT + 12
.equ CTX_CORE_SLOT_LBA, SCR_CONTEXT + 16
.equ CONTEXT_PHYS, 0x00009100
.equ CONTEXT_MAGIC, 0x43425355
.equ CONTEXT_VERSION, 1
.equ CONTEXT_BYTES, 24

.equ HDR_MAGIC0, 0
.equ HDR_MAGIC1, 4
.equ HDR_VERSION, 8
.equ HDR_SIZE, 10
.equ HDR_SLOT_BYTES, 12
.equ HDR_BOOTSTRAP_BYTES, 16
.equ HDR_IMAGE_SIZE, 20
.equ HDR_PAYLOAD_OFFSET, 24
.equ HDR_PAYLOAD_SIZE, 28
.equ HDR_LOAD_ADDRESS, 32
.equ HDR_ENTRY_OFFSET, 36
.equ HDR_CONTENT_CRC32, 40
.equ HDR_HEADER_CRC32, 44
.equ HDR_RESERVED, 48

.equ MAGIC_USOS, 0x534F5355
.equ MAGIC_CORE, 0x45524F43

.macro CALL16 target
    .byte 0xE8
    .word \target - . - 2
.endm

/*
 * Fixed 64-byte on-disk ABI header. tools/pack_legacy_core_slot.py replaces
 * these zero bytes after linking. Stage 1 always jumps to offset 64, so future
 * format versions may change semantics but must preserve this entry ABI.
 */
bootstrap_header:
    .space HEADER_BYTES, 0

bootstrap_start:
    cli
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ax, SCRATCH_SEGMENT
    mov fs, ax
    xor ax, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov byte ptr fs:[SCR_BOOT_DRIVE], dl
    mov byte ptr fs:[SCR_A20_92_WRITE_COUNT], 0
    mov byte ptr fs:[SCR_A20_92_BEFORE], 0
    mov byte ptr fs:[SCR_A20_92_AFTER], 0
    CALL16 serial_init
    lea si, [bootstrap_banner]
    CALL16 print_serial_string

    CALL16 validate_header
    jc header_fail
    lea si, [header_ok_message]
    CALL16 print_serial_string

    CALL16 load_payload
    jc payload_read_fail
    lea si, [payload_loaded_message]
    CALL16 print_serial_string

    CALL16 validate_content_crc
    jc content_crc_fail
    lea si, [crc_ok_message]
    CALL16 print_serial_string

    CALL16 enable_and_verify_a20
    jc a20_fail
    lea si, [a20_ok_message]
    CALL16 print_serial_string

    CALL16 write_boot_context

    lea si, [pm_enter_message]
    CALL16 print_serial_string
    cli
    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 0x00000001
    mov cr0, eax

    /* 32-bit far jump, code selector base=0. */
    .byte 0x66, 0xEA
    .long BOOTSTRAP_PHYS_BASE + protected_entry
    .word 0x0008

header_fail:
    lea si, [header_fail_message]
    jmp fatal_message
payload_read_fail:
    lea si, [payload_read_fail_message]
    jmp fatal_message
content_crc_fail:
    lea si, [content_crc_fail_message]
    jmp fatal_message
a20_fail:
    lea si, [a20_fail_message]

fatal_message:
    CALL16 print_string
    cli
.fatal_hang:
    hlt
    jmp .fatal_hang

validate_header:
    cmp dword ptr [HDR_MAGIC0], MAGIC_USOS
    jne .bad
    cmp dword ptr [HDR_MAGIC1], MAGIC_CORE
    jne .bad
    cmp word ptr [HDR_VERSION], FORMAT_VERSION
    jne .bad
    cmp word ptr [HDR_SIZE], HEADER_BYTES
    jne .bad
    cmp dword ptr [HDR_SLOT_BYTES], SLOT_BYTES
    jne .bad
    cmp dword ptr [HDR_BOOTSTRAP_BYTES], BOOTSTRAP_BYTES
    jne .bad
    cmp dword ptr [HDR_PAYLOAD_OFFSET], BOOTSTRAP_BYTES
    jne .bad
    cmp dword ptr [HDR_LOAD_ADDRESS], CORE_LOAD_ADDRESS
    jne .bad
    cmp dword ptr [HDR_ENTRY_OFFSET], CORE_ENTRY_OFFSET
    jne .bad

    mov eax, dword ptr [HDR_PAYLOAD_SIZE]
    test eax, eax
    jz .bad
    cmp eax, SLOT_BYTES - BOOTSTRAP_BYTES
    ja .bad
    add eax, BOOTSTRAP_BYTES
    jc .bad
    cmp eax, dword ptr [HDR_IMAGE_SIZE]
    jne .bad
    cmp eax, SLOT_BYTES
    ja .bad

    mov si, HDR_RESERVED
    mov cx, HEADER_BYTES - HDR_RESERVED
.check_reserved:
    cmp byte ptr [si], 0
    jne .bad
    inc si
    loop .check_reserved

    mov si, 0
    mov cx, HDR_HEADER_CRC32
    CALL16 crc32_ds
    cmp eax, dword ptr [HDR_HEADER_CRC32]
    jne .bad
    clc
    .byte 0xC3
.bad:
    stc
    .byte 0xC3

load_payload:
    mov eax, dword ptr [HDR_PAYLOAD_SIZE]
    add eax, 511
    jc .read_fail
    shr eax, 9
    test eax, eax
    jz .read_fail
    cmp eax, SLOT_SECTORS - BOOTSTRAP_SECTORS
    ja .read_fail
    mov word ptr fs:[SCR_REMAINING_SECTORS], ax
    mov word ptr fs:[SCR_DESTINATION_SEGMENT], CORE_LOAD_SEGMENT
    mov dword ptr fs:[SCR_CURRENT_LBA], CORE_LBA + BOOTSTRAP_SECTORS

.read_loop:
    mov ax, word ptr fs:[SCR_REMAINING_SECTORS]
    test ax, ax
    jz .done
    cmp ax, MAX_READ_SECTORS
    jbe .chunk_ready
    mov ax, MAX_READ_SECTORS
.chunk_ready:
    mov word ptr fs:[SCR_DAP_COUNT], ax
    mov word ptr fs:[SCR_DAP_OFFSET], 0
    mov dx, word ptr fs:[SCR_DESTINATION_SEGMENT]
    mov word ptr fs:[SCR_DAP_SEGMENT], dx
    mov edx, dword ptr fs:[SCR_CURRENT_LBA]
    mov dword ptr fs:[SCR_DAP_LBA], edx
    mov dword ptr fs:[SCR_DAP_LBA_HI], 0
    mov byte ptr fs:[SCR_DAP + 0], 0x10
    mov byte ptr fs:[SCR_DAP + 1], 0x00

    mov dl, byte ptr fs:[SCR_BOOT_DRIVE]
    push ds
    mov ax, SCRATCH_SEGMENT
    mov ds, ax
    mov si, SCR_DAP
    mov ah, 0x42
    int 0x13
    pop ds
    jc .read_fail

    movzx eax, word ptr fs:[SCR_DAP_COUNT]
    sub word ptr fs:[SCR_REMAINING_SECTORS], ax
    add dword ptr fs:[SCR_CURRENT_LBA], eax
    shl ax, 5
    add word ptr fs:[SCR_DESTINATION_SEGMENT], ax
    jmp .read_loop
.done:
    clc
    .byte 0xC3
.read_fail:
    stc
    .byte 0xC3

validate_content_crc:
    mov eax, 0xFFFFFFFF

    /* CRC the fixed bootstrap area after the header, including zero padding. */
    mov si, HEADER_BYTES
    mov cx, BOOTSTRAP_BYTES - HEADER_BYTES
    CALL16 crc32_update_ds

    mov edx, dword ptr [HDR_PAYLOAD_SIZE]
    mov dword ptr fs:[SCR_CRC_REMAINING], edx
    mov word ptr fs:[SCR_CRC_SEGMENT], CORE_LOAD_SEGMENT
.payload_crc_outer:
    mov edx, dword ptr fs:[SCR_CRC_REMAINING]
    test edx, edx
    jz .finish
    mov cx, 0x4000
    cmp edx, 0x4000
    jae .chunk_set
    mov cx, dx
.chunk_set:
    mov word ptr fs:[SCR_CRC_CHUNK], cx
    mov bx, word ptr fs:[SCR_CRC_SEGMENT]
    mov es, bx
    xor si, si
.payload_crc_byte:
    xor al, byte ptr es:[si]
    mov bl, 8
.payload_crc_bit:
    shr eax, 1
    jnc .payload_crc_no_poly
    xor eax, 0xEDB88320
.payload_crc_no_poly:
    dec bl
    jnz .payload_crc_bit
    inc si
    loop .payload_crc_byte

    movzx edx, word ptr fs:[SCR_CRC_CHUNK]
    sub dword ptr fs:[SCR_CRC_REMAINING], edx
    add word ptr fs:[SCR_CRC_SEGMENT], 0x0400
    jmp .payload_crc_outer
.finish:
    xor eax, 0xFFFFFFFF
    cmp eax, dword ptr [HDR_CONTENT_CRC32]
    jne .content_bad
    clc
    .byte 0xC3
.content_bad:
    stc
    .byte 0xC3

/* CRC32/IEEE over DS:SI, CX bytes. crc32_update_ds keeps the running state. */
crc32_ds:
    mov eax, 0xFFFFFFFF
    CALL16 crc32_update_ds
    xor eax, 0xFFFFFFFF
    .byte 0xC3

crc32_update_ds:
    test cx, cx
    jz .crc_update_done
.crc_update_byte:
    xor al, byte ptr [si]
    mov bl, 8
.crc_update_bit:
    shr eax, 1
    jnc .crc_update_no_poly
    xor eax, 0xEDB88320
.crc_update_no_poly:
    dec bl
    jnz .crc_update_bit
    inc si
    loop .crc_update_byte
.crc_update_done:
    .byte 0xC3

enable_and_verify_a20:
    CALL16 check_a20
    jnc .ok

    /*
     * Fast A20 only. Do not call INT 15h AX=2401 here: a legacy BIOS may
     * implement that service through the 8042 and leave an old controller in
     * an unexpected command/data state. Port 0x92 does not touch the keyboard
     * controller. Bit 0 is forced clear to avoid asserting fast reset.
     */
    mov dx, 0x0092
    in al, dx
    mov byte ptr fs:[SCR_A20_92_BEFORE], al
    or al, 0x02
    and al, 0xFE
    mov byte ptr fs:[SCR_A20_92_AFTER], al
    inc byte ptr fs:[SCR_A20_92_WRITE_COUNT]
    out dx, al
    CALL16 check_a20
    jc .fail
.ok:
    clc
    .byte 0xC3
.fail:
    stc
    .byte 0xC3

check_a20:
    pushf
    cli
    push ax
    push bx
    push ds
    push es
    push si
    push di

    mov byte ptr fs:[SCR_A20_RESULT], 0
    xor ax, ax
    mov ds, ax
    mov si, 0x0500
    mov ax, 0xFFFF
    mov es, ax
    mov di, 0x0510

    mov al, byte ptr [si]
    xor ah, ah
    push ax
    mov al, byte ptr es:[di]
    xor ah, ah
    push ax

    mov byte ptr [si], 0x00
    mov byte ptr es:[di], 0xFF
    cmp byte ptr [si], 0xFF
    je .restore
    mov byte ptr fs:[SCR_A20_RESULT], 1
.restore:
    pop ax
    mov byte ptr es:[di], al
    pop ax
    mov byte ptr [si], al

    pop di
    pop si
    pop es
    pop ds
    pop bx
    pop ax
    popf

    cmp byte ptr fs:[SCR_A20_RESULT], 1
    jne .off
    clc
    .byte 0xC3
.off:
    stc
    .byte 0xC3

write_boot_context:
    mov dword ptr fs:[CTX_MAGIC], CONTEXT_MAGIC
    mov word ptr fs:[CTX_VERSION], CONTEXT_VERSION
    mov word ptr fs:[CTX_SIZE], CONTEXT_BYTES
    mov al, byte ptr fs:[SCR_BOOT_DRIVE]
    mov byte ptr fs:[CTX_BIOS_DRIVE], al
    mov byte ptr fs:[CTX_RESERVED + 0], 0
    mov byte ptr fs:[CTX_RESERVED + 1], 0
    mov byte ptr fs:[CTX_RESERVED + 2], 0
    mov dword ptr fs:[CTX_SECTOR_BYTES], 512
    mov dword ptr fs:[CTX_CORE_SLOT_LBA + 0], CORE_LBA
    mov dword ptr fs:[CTX_CORE_SLOT_LBA + 4], 0
    .byte 0xC3

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
.serial_wait:
    mov dx, 0x03FD
    in al, dx
    test al, 0x20
    jz .serial_wait
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

/* Successful boot diagnostics remain on serial; failures still use VGA. */
print_serial_string:
.serial_next:
    lodsb
    test al, al
    jz .serial_done
    CALL16 serial_putchar
    jmp .serial_next
.serial_done:
    .byte 0xC3

print_string:
.print_next:
    lodsb
    test al, al
    jz .print_done
    CALL16 put_char
    jmp .print_next
.print_done:
    .byte 0xC3

bootstrap_banner:
    .asciz "USOS LEGACY BOOTSTRAP\r\n"
header_ok_message:
    .asciz "CORE HEADER OK\r\n"
payload_loaded_message:
    .asciz "CORE LOAD OK\r\n"
crc_ok_message:
    .asciz "CORE CRC OK\r\n"
a20_ok_message:
    .asciz "A20 OK\r\n"
pm_enter_message:
    .asciz "ENTERING PROTECTED MODE\r\n"
header_fail_message:
    .asciz "CORE HEADER FAIL\r\n"
payload_read_fail_message:
    .asciz "CORE LOAD FAIL\r\n"
content_crc_fail_message:
    .asciz "CORE CRC FAIL\r\n"
a20_fail_message:
    .asciz "A20 FAIL\r\n"

.align 8
gdt_start:
    .quad 0x0000000000000000
    .quad 0x00CF9A000000FFFF
    .quad 0x00CF92000000FFFF
gdt_end:

gdt_descriptor:
    .word gdt_end - gdt_start - 1
    .long BOOTSTRAP_PHYS_BASE + gdt_start

.code32
protected_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x0009E000
    mov esi, CONTEXT_PHYS
    cld
    mov eax, CORE_LOAD_ADDRESS + CORE_ENTRY_OFFSET
    jmp eax
