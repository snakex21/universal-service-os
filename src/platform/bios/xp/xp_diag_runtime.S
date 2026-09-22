.intel_syntax noprefix
.code16
.section .text
.global xp_diag_runtime_start

.equ NTLDR_SEGMENT, 0x2000
.equ BIOS_TICKS_5S, 91
.equ BIOS_DAY_TICKS, 0x001800B0
.equ EXPECTED_CRC_SENTINEL, 0xA17EC0DE
.equ NTLDR_BYTES_SENTINEL, 0xA17E51AE

.macro CALL16 target
    .byte 0xE8
    .word \target - (. + 2)
.endm
.macro RET16
    .byte 0xC3
.endm

xp_diag_runtime_start:
    pushfd
    push ds
    push es
    push fs
    push gs
    pushad

    push cs
    pop ds
    mov byte ptr [boot_dl], dl

    lea si, [msg_j]
    CALL16 puts
    mov al, byte ptr [boot_dl]
    CALL16 hex8
    lea si, [crlf]
    CALL16 puts

    /* Standard IEEE CRC-32 over the exact root NTLDR size patched into this
     * diagnostic copy. Setup's temporary loader and the installed-system NTLDR
     * have different lengths, so the byte count must not be hard-coded. */
    mov ax, NTLDR_SEGMENT
    mov ds, ax
    xor esi, esi
    mov ecx, dword ptr cs:[ntldr_bytes]
    mov eax, 0xFFFFFFFF
.crc_byte:
    mov bl, byte ptr [esi]
    inc esi
    xor al, bl
    mov dx, 8
.crc_bit:
    shr eax, 1
    jnc .crc_no_xor
    xor eax, 0xEDB88320
.crc_no_xor:
    dec dx
    jnz .crc_bit
    dec ecx
    jnz .crc_byte
    not eax

    push cs
    pop ds
    mov dword ptr [computed_crc], eax
    lea si, [msg_crc_ram]
    CALL16 puts
    mov eax, dword ptr [computed_crc]
    CALL16 hex32
    lea si, [msg_crc_expected]
    CALL16 puts
    mov eax, dword ptr [expected_crc]
    CALL16 hex32
    lea si, [msg_crc_same]
    CALL16 puts
    mov eax, dword ptr [computed_crc]
    cmp eax, dword ptr [expected_crc]
    jne .crc_diff
    lea si, [msg_yes]
    CALL16 puts
    jmp .crc_line_done
.crc_diff:
    lea si, [msg_no]
    CALL16 puts
.crc_line_done:
    lea si, [crlf]
    CALL16 puts

    /* Reset persistent test-shim counters immediately before the handoff so
     * any later AH=02/AH=42/AH=08 calls are attributable to SETUPLDR itself. */
    mov word ptr cs:[0x0F00], 0
    mov word ptr cs:[0x0F02], 0
    mov word ptr cs:[0x0F04], 0
    mov word ptr cs:[0x0F06], 1

    lea si, [msg_auto]
    CALL16 puts
    CALL16 wait_5s_bios_timer
    lea si, [msg_continue]
    CALL16 puts

    popad
    pop gs
    pop fs
    pop es
    pop ds
    popfd
    RET16

/* Wait ~5 seconds using BIOS INT 1Ah AH=00 clock ticks (18.2065 Hz).
 * Handle the one possible midnight wrap during the wait. */
wait_5s_bios_timer:
    xor ah, ah
    int 0x1A
    movzx eax, cx
    shl eax, 16
    mov ax, dx
    mov dword ptr [start_ticks], eax
.wait_loop:
    xor ah, ah
    int 0x1A
    movzx eax, cx
    shl eax, 16
    mov ax, dx
    mov edx, eax
    sub edx, dword ptr [start_ticks]
    jnc .delta_ready
    add edx, BIOS_DAY_TICKS
.delta_ready:
    cmp edx, BIOS_TICKS_5S
    jb .wait_loop
    RET16

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
    push ax
    push bx
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    pop bx
    pop ax
    RET16

hex8:
    push ax
    push bx
    mov bl, al
    shr al, 4
    CALL16 hex_nibble
    mov al, bl
    and al, 0x0F
    CALL16 hex_nibble
    pop bx
    pop ax
    RET16

hex32:
    push eax
    push ebx
    push cx
    mov ebx, eax
    mov cx, 8
.hex32_loop:
    rol ebx, 4
    mov al, bl
    and al, 0x0F
    CALL16 hex_nibble
    dec cx
    jnz .hex32_loop
    pop cx
    pop ebx
    pop eax
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

.align 4
computed_crc: .long 0
start_ticks:  .long 0
expected_crc: .long EXPECTED_CRC_SENTINEL
ntldr_bytes:  .long NTLDR_BYTES_SENTINEL
boot_dl:       .byte 0
msg_j:             .asciz "J DL="
msg_crc_ram:       .asciz "CRC RAM="
msg_crc_expected:  .asciz " EXPECT="
msg_crc_same:      .asciz " SAME="
msg_auto:          .asciz "AUTO 5s BIOS TIMER...\r\n"
msg_continue:      .asciz "AUTO CONTINUE -> NTLDR\r\n"
msg_yes:           .asciz "YES"
msg_no:            .asciz "NO"
crlf:              .asciz "\r\n"
