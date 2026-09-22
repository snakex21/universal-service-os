.intel_syntax noprefix
.code16
.section .text
.global xp_diag_int13_shim_install

/* Test-only persistent INT13 shim linked at physical 0000:1200.
 * AH=08 advertises 1023/240/63. AH=02 accepts coordinates produced by a stale
 * 255/63 BPB, interprets them under 240/63, then asks the real SeaBIOS AH=02
 * for the sector at that resulting LBA. Other services chain unchanged. */
xp_diag_int13_shim_install:
    cli
    xor ax, ax
    mov ds, ax
    mov ax, word ptr [0x004C]
    mov word ptr [old13_off], ax
    mov ax, word ptr [0x004E]
    mov word ptr [old13_seg], ax
    lea ax, [int13_shim]
    mov word ptr [0x004C], ax
    mov word ptr [0x004E], 0x0000
    sti
    .byte 0xC3 /* RET16 */

int13_shim:
    cmp dl, 0x80
    jne chain_old13
    cmp ah, 0x08
    je ah08
    cmp ah, 0x02
    je ah02

chain_old13:
    push word ptr cs:[old13_seg]
    push word ptr cs:[old13_off]
    .byte 0xCB /* RETF16 */

ah08:
    mov ch, 0xFE
    mov cl, 0xFF
    mov dh, 0xEF
    xor ah, ah
    push bp
    mov bp, sp
    and word ptr ss:[bp + 6], 0xFFFE
    pop bp
    iret

ah02:
    mov byte ptr cs:[req_count], al
    mov byte ptr cs:[req_drive], dl
    mov byte ptr cs:[req_ch], ch
    mov byte ptr cs:[req_cl], cl
    mov byte ptr cs:[req_dh], dh
    mov word ptr cs:[req_off], bx
    push ax
    mov ax, es
    mov word ptr cs:[req_seg], ax
    pop ax

    push ds
    push es
    pushad
    xor ax, ax
    mov ds, ax

    /* caller CHS -> deliberately wrong LBA under 240/63 */
    movzx eax, byte ptr [req_ch]
    movzx ecx, byte ptr [req_cl]
    and ecx, 0x00C0
    shl ecx, 2
    or eax, ecx
    imul eax, eax, 240
    movzx ecx, byte ptr [req_dh]
    add eax, ecx
    imul eax, eax, 63
    movzx ecx, byte ptr [req_cl]
    and ecx, 0x003F
    test ecx, ecx
    jz range_error
    dec ecx
    add eax, ecx

    /* wrong LBA -> real SeaBIOS 255/63 CHS */
    xor edx, edx
    mov ecx, 63
    div ecx
    inc dl
    mov byte ptr [xlat_sector], dl
    xor edx, edx
    mov ecx, 255
    div ecx
    cmp eax, 1023
    ja range_error
    mov word ptr [xlat_cylinder], ax
    mov byte ptr [xlat_head], dl

    mov cx, word ptr [xlat_cylinder]
    mov ch, cl
    mov al, byte ptr [xlat_sector]
    mov cl, al
    mov ax, word ptr [xlat_cylinder]
    shr ax, 2
    and al, 0xC0
    or cl, al
    mov dh, byte ptr [xlat_head]
    mov ax, word ptr [req_seg]
    mov es, ax
    mov bx, word ptr [req_off]
    mov dl, byte ptr [req_drive]
    mov al, byte ptr [req_count]
    test al, al
    jz range_error
    mov ah, 0x02

    /* temporarily expose the original vector and perform a real INT 13h */
    cli
    xor ax, ax
    mov ds, ax
    mov ax, word ptr [old13_off]
    mov word ptr [0x004C], ax
    mov ax, word ptr [old13_seg]
    mov word ptr [0x004E], ax
    mov ax, word ptr [req_seg]
    mov es, ax
    mov bx, word ptr [req_off]
    mov dl, byte ptr [req_drive]
    mov al, byte ptr [req_count]
    mov ah, 0x02
    int 0x13
    mov byte ptr cs:[status_ah], ah
    pushf
    pop ax
    and al, 1
    mov byte ptr cs:[status_cf], al

    cli
    xor ax, ax
    mov ds, ax
    lea ax, [int13_shim]
    mov word ptr [0x004C], ax
    mov word ptr [0x004E], 0x0000
    jmp restore

range_error:
    mov byte ptr cs:[status_ah], 0x01
    mov byte ptr cs:[status_cf], 1

restore:
    popad
    pop es
    pop ds
    cmp byte ptr cs:[status_cf], 0
    jne fail
    xor ah, ah
    mov al, byte ptr cs:[req_count]
    push bp
    mov bp, sp
    and word ptr ss:[bp + 6], 0xFFFE
    pop bp
    iret

fail:
    mov ah, byte ptr cs:[status_ah]
    push bp
    mov bp, sp
    or word ptr ss:[bp + 6], 0x0001
    pop bp
    iret

.align 2
old13_off: .word 0
old13_seg: .word 0
req_off: .word 0
req_seg: .word 0
req_count: .byte 0
req_drive: .byte 0
req_ch: .byte 0
req_cl: .byte 0
req_dh: .byte 0
status_ah: .byte 0
status_cf: .byte 0
xlat_sector: .byte 0
xlat_head: .byte 0
.align 2
xlat_cylinder: .word 0
