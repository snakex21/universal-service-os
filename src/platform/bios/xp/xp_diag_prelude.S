.intel_syntax noprefix
.code16
.section .text
.global xp_diag_prelude_start

.equ MBR_BASE,          0x7C00
.equ ORIGINAL_MBR_COPY, 0x8C00
.equ DIAG_RUNTIME_SRC,  0x8E00
.equ DIAG_RUNTIME_DST,  0x1000
.equ DIAG_RUNTIME_BYTES, 512
.equ CMP_EDD_BUFFER,    0x5000
.equ CMP_AH08_BUFFER,   0x5200
.equ CMP_BPB_BUFFER,    0x5400

xp_diag_prelude_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    sti
    cld
    mov byte ptr [boot_drive], dl

    /* Keep the larger J/CRC/timer helper outside Microsoft stage2.  LBA8 is
     * already resident at 0000:8E00 because the diagnostic MBR loaded LBA1..8.
     * Copy it to low memory that the Microsoft MBR/VBR/stage2 path does not use. */
    mov si, DIAG_RUNTIME_SRC
    mov di, DIAG_RUNTIME_DST
    mov cx, DIAG_RUNTIME_BYTES / 2
    rep movsw

#ifdef XP_DIAG_EXTERNAL_240
    /* Gate 2+ uses a persistent shim outside 0x8000..0xAFFF because the EDD
     * production VBR loads 24 stage2 sectors there. LBA9 is test-only fixture
     * space before XPSETUP. Load the shim to 0000:1200, then install it. */
    mov eax, 9
    xor dx, dx
    mov es, dx
    mov bx, 0x1200
    call read_sector_edd
    jc halt
    .byte 0xE8
    .word 0x1200 - (. + 2) /* CALL16 xp_diag_int13_shim_install */
#endif

#ifdef XP_DIAG_FORCE_240
    /* Gate 1 Microsoft NT52 fixture can keep the compact inline shim because
     * that loader overwrites only 0000:8000..81FF. */
    call install_int13_shim
#endif

    call query_geometry
    jc geometry_error
    call print_geometry
    call load_bpb_geometry
    jc bpb_error
    call print_bpb_geometry

    mov eax, 2048
    lea si, [msg_lba2048]
    call compare_lba
    mov eax, 2060
    lea si, [msg_lba2060]
    call compare_lba
    mov eax, 1123648
    lea si, [msg_lba1123648]
    call compare_lba

    /* Measurement ends here. Restore the exact original 440-byte MBR code
     * captured from this target into 0000:7C00, keep the untouched Disk ID /
     * partition table / 55AA already resident at 7DB8..7DFF, and execute the
     * original MBR with the BIOS-supplied DL. */
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov si, ORIGINAL_MBR_COPY
    mov di, MBR_BASE
    mov cx, 220
    rep movsw
    mov dl, byte ptr [boot_drive]
    sti
    .byte 0xEA
    .word MBR_BASE
    .word 0x0000

query_geometry:
    mov dl, byte ptr [boot_drive]
    mov ah, 0x08
    int 0x13
    jc .geom_fail
    mov byte ptr [raw_ch], ch
    mov byte ptr [raw_cl], cl
    mov byte ptr [raw_dh], dh

    xor ax, ax
    mov al, cl
    and al, 0x3F
    mov word ptr [bios_spt], ax

    xor ax, ax
    mov al, dh
    inc ax
    mov word ptr [bios_heads], ax

    xor ax, ax
    mov al, ch
    xor bx, bx
    mov bl, cl
    and bx, 0x00C0
    shl bx, 2
    or ax, bx
    mov word ptr [bios_cmax], ax

    cmp word ptr [bios_spt], 0
    je .synthetic_fail
    cmp word ptr [bios_heads], 0
    je .synthetic_fail
    clc
    ret
.synthetic_fail:
    mov ah, 0xFF
    stc
.geom_fail:
    mov byte ptr [geometry_error_ah], ah
    ret

load_bpb_geometry:
    mov eax, 2048
    xor dx, dx
    mov es, dx
    mov bx, CMP_EDD_BUFFER
    call read_sector_edd
    jc .bpb_read_fail
    mov ax, word ptr [CMP_EDD_BUFFER + 24]
    mov word ptr [bpb_spt], ax
    mov ax, word ptr [CMP_EDD_BUFFER + 26]
    mov word ptr [bpb_heads], ax
    cmp word ptr [bpb_spt], 0
    je .invalid
    cmp word ptr [bpb_spt], 63
    ja .invalid
    cmp word ptr [bpb_heads], 0
    je .invalid
    cmp word ptr [bpb_heads], 256
    ja .invalid
    clc
    ret
.invalid:
    mov ah, 0xFD
    stc
.bpb_read_fail:
    mov byte ptr [bpb_error_ah], ah
    ret

print_geometry:
    lea si, [msg_geom_c]
    call screen_puts
    mov ax, word ptr [bios_cmax]
    call screen_u16
    lea si, [msg_geom_h]
    call screen_puts
    mov ax, word ptr [bios_heads]
    call screen_u16
    lea si, [msg_geom_s]
    call screen_puts
    mov ax, word ptr [bios_spt]
    call screen_u16
    lea si, [msg_geom_raw]
    call screen_puts
    mov al, byte ptr [raw_ch]
    call screen_hex8
    mov al, '/'
    call screen_putc
    mov al, byte ptr [raw_cl]
    call screen_hex8
    mov al, '/'
    call screen_putc
    mov al, byte ptr [raw_dh]
    call screen_hex8
    lea si, [crlf]
    call screen_puts
    ret

print_bpb_geometry:
    lea si, [msg_bpb_h]
    call screen_puts
    mov ax, word ptr [bpb_heads]
    call screen_u16
    lea si, [msg_bpb_s]
    call screen_puts
    mov ax, word ptr [bpb_spt]
    call screen_u16
    lea si, [crlf]
    call screen_puts
    ret

/* EAX=LBA, SI=label. Compare three paths:
 *   EDD/LBA, legacy CHS using current AH=08 geometry, and legacy CHS using
 *   the FAT32 BPB geometry that the Microsoft NT52 VBR actually uses. */
compare_lba:
    mov dword ptr [compare_lba_value], eax
    mov byte ptr [edd_ok], 0
    mov byte ptr [ah08_ok], 0
    mov byte ptr [bpb_ok], 0
    mov byte ptr [same_ah08], 0
    mov byte ptr [same_bpb], 0
    mov byte ptr [edd_error_ah], 0
    mov byte ptr [ah08_error_ah], 0
    mov byte ptr [bpb_error_io_ah], 0
    call screen_puts
    lea si, [crlf]
    call screen_puts

    mov eax, dword ptr [compare_lba_value]
    xor dx, dx
    mov es, dx
    mov bx, CMP_EDD_BUFFER
    call read_sector_edd
    jc .edd_failed
    mov byte ptr [edd_ok], 1
    jmp .edd_done
.edd_failed:
    mov byte ptr [edd_error_ah], ah
.edd_done:

    mov eax, dword ptr [compare_lba_value]
    call compute_chs_ah08
    jc .ah08_failed
    xor dx, dx
    mov es, dx
    mov bx, CMP_AH08_BUFFER
    call read_sector_chs_ah08
    jc .ah08_failed
    mov byte ptr [ah08_ok], 1
    jmp .ah08_done
.ah08_failed:
    mov byte ptr [ah08_error_ah], ah
.ah08_done:

    mov eax, dword ptr [compare_lba_value]
    call compute_chs_bpb
    jc .bpb_failed
    xor dx, dx
    mov es, dx
    mov bx, CMP_BPB_BUFFER
    call read_sector_chs_bpb
    jc .bpb_failed
    mov byte ptr [bpb_ok], 1
    jmp .bpb_done
.bpb_failed:
    mov byte ptr [bpb_error_io_ah], ah
.bpb_done:

    cmp byte ptr [edd_ok], 1
    jne .comparisons_done
    cmp byte ptr [ah08_ok], 1
    jne .skip_ah08_compare
    mov si, CMP_EDD_BUFFER
    mov di, CMP_AH08_BUFFER
    call compare_512
    jne .skip_ah08_compare
    mov byte ptr [same_ah08], 1
.skip_ah08_compare:
    cmp byte ptr [bpb_ok], 1
    jne .comparisons_done
    mov si, CMP_EDD_BUFFER
    mov di, CMP_BPB_BUFFER
    call compare_512
    jne .comparisons_done
    mov byte ptr [same_bpb], 1
.comparisons_done:

    lea si, [msg_edd]
    call screen_puts
    mov al, byte ptr [edd_ok]
    mov ah, byte ptr [edd_error_ah]
    call print_io_status
    lea si, [crlf]
    call screen_puts

    lea si, [msg_ah08]
    call screen_puts
    mov ax, word ptr [ah08_cylinder]
    call screen_u16
    lea si, [msg_h]
    call screen_puts
    xor ax, ax
    mov al, byte ptr [ah08_head]
    call screen_u16
    lea si, [msg_s]
    call screen_puts
    xor ax, ax
    mov al, byte ptr [ah08_sector]
    call screen_u16
    lea si, [msg_io]
    call screen_puts
    mov al, byte ptr [ah08_ok]
    mov ah, byte ptr [ah08_error_ah]
    call print_io_status
    lea si, [msg_same]
    call screen_puts
    mov al, byte ptr [same_ah08]
    call print_yes_no
    lea si, [crlf]
    call screen_puts

    lea si, [msg_bpb]
    call screen_puts
    mov ax, word ptr [bpb_cylinder]
    call screen_u16
    lea si, [msg_h]
    call screen_puts
    xor ax, ax
    mov al, byte ptr [bpb_head]
    call screen_u16
    lea si, [msg_s]
    call screen_puts
    xor ax, ax
    mov al, byte ptr [bpb_sector]
    call screen_u16
    lea si, [msg_io]
    call screen_puts
    mov al, byte ptr [bpb_ok]
    mov ah, byte ptr [bpb_error_io_ah]
    call print_io_status
    lea si, [msg_same]
    call screen_puts
    mov al, byte ptr [same_bpb]
    call print_yes_no
    lea si, [crlf]
    call screen_puts
    ret

compare_512:
    push ds
    push es
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov cx, 256
    repe cmpsw
    pop es
    pop ds
    ret

print_io_status:
    cmp al, 1
    jne .err
    lea si, [msg_ok]
    call screen_puts
    ret
.err:
    push ax
    lea si, [msg_err]
    call screen_puts
    pop ax
    mov al, ah
    call screen_hex8
    ret

print_yes_no:
    cmp al, 1
    jne .no
    lea si, [msg_yes]
    call screen_puts
    ret
.no:
    lea si, [msg_no]
    call screen_puts
    ret

read_sector_edd:
    push si
    push dx
    mov dword ptr [dap_lba], eax
    mov dword ptr [dap_lba + 4], 0
    mov word ptr [dap_count], 1
    mov word ptr [dap_offset], bx
    mov word ptr [dap_segment], es
    mov dl, byte ptr [boot_drive]
    lea si, [dap]
    mov ah, 0x42
    int 0x13
    pop dx
    pop si
    ret

compute_chs_ah08:
    mov word ptr [ah08_cylinder], 0
    mov byte ptr [ah08_head], 0
    mov byte ptr [ah08_sector], 0
    xor edx, edx
    movzx ecx, word ptr [bios_spt]
    test ecx, ecx
    jz .ah08_range_error
    div ecx
    inc dl
    mov byte ptr [ah08_sector], dl
    xor edx, edx
    movzx ecx, word ptr [bios_heads]
    test ecx, ecx
    jz .ah08_range_error
    div ecx
    cmp eax, 1023
    ja .ah08_range_error
    mov word ptr [ah08_cylinder], ax
    mov byte ptr [ah08_head], dl
    clc
    ret
.ah08_range_error:
    mov ah, 0xFE
    stc
    ret

compute_chs_bpb:
    mov word ptr [bpb_cylinder], 0
    mov byte ptr [bpb_head], 0
    mov byte ptr [bpb_sector], 0
    xor edx, edx
    movzx ecx, word ptr [bpb_spt]
    test ecx, ecx
    jz .bpb_range_error
    div ecx
    inc dl
    mov byte ptr [bpb_sector], dl
    xor edx, edx
    movzx ecx, word ptr [bpb_heads]
    test ecx, ecx
    jz .bpb_range_error
    div ecx
    cmp eax, 1023
    ja .bpb_range_error
    mov word ptr [bpb_cylinder], ax
    mov byte ptr [bpb_head], dl
    clc
    ret
.bpb_range_error:
    mov ah, 0xFE
    stc
    ret

read_sector_chs_ah08:
    mov cx, word ptr [ah08_cylinder]
    mov ch, cl
    mov al, byte ptr [ah08_sector]
    mov cl, al
    mov ax, word ptr [ah08_cylinder]
    shr ax, 2
    and al, 0xC0
    or cl, al
    mov dh, byte ptr [ah08_head]
    jmp read_sector_chs_common

read_sector_chs_bpb:
    mov cx, word ptr [bpb_cylinder]
    mov ch, cl
    mov al, byte ptr [bpb_sector]
    mov cl, al
    mov ax, word ptr [bpb_cylinder]
    shr ax, 2
    and al, 0xC0
    or cl, al
    mov dh, byte ptr [bpb_head]

read_sector_chs_common:
    mov dl, byte ptr [boot_drive]
    mov ax, 0x0201
    int 0x13
    ret

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

screen_u16:
    push ax
    push bx
    push cx
    push dx
    test ax, ax
    jnz .convert
    mov al, '0'
    call screen_putc
    jmp .done
.convert:
    xor cx, cx
    mov bx, 10
.div_loop:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .div_loop
.print_loop:
    pop ax
    add al, '0'
    call screen_putc
    loop .print_loop
.done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

#ifdef XP_DIAG_FORCE_240
install_int13_shim:
    cli
    xor ax, ax
    mov ds, ax
    mov word ptr [0x0F00], 0
    mov word ptr [0x0F02], 0
    mov word ptr [0x0F04], 0
    mov word ptr [0x0F06], 0
    mov ax, word ptr [0x004C]
    mov word ptr [shim_old13_off], ax
    mov ax, word ptr [0x004E]
    mov word ptr [shim_old13_seg], ax
    lea ax, [xp_diag_int13_shim]
    mov word ptr [0x004C], ax
    mov word ptr [0x004E], 0x0000
    sti
    ret

/* Persistent test-only INT13 hook. The handler lives above 0x8200 so the
 * Microsoft 512-byte stage2 loaded at 0000:8000 does not overwrite it. */
xp_diag_int13_shim:
    cmp dl, 0x80
    jne shim_chain_old13
    cmp ah, 0x08
    je shim_ah08
    cmp ah, 0x02
    je shim_ah02
    cmp ah, 0x42
    je shim_ah42

shim_chain_old13:
    push word ptr cs:[shim_old13_seg]
    push word ptr cs:[shim_old13_off]
    .byte 0xCB /* RETF16 */

shim_ah08:
    inc word ptr cs:[0x0F04]
    cmp word ptr cs:[0x0F06], 1
    je shim_ah08_virtual
    /* Pre-J physical-failure model: Cmax=1022, heads=240, sectors=63. */
    mov ch, 0xFE
    mov cl, 0xFF
    mov dh, 0xEF
    jmp shim_ah08_done
shim_ah08_virtual:
    /* Post-J virtual geometry matches the on-disk BPB: 1023/255/63. */
    mov ch, 0xFE
    mov cl, 0xFF
    mov dh, 0xFE
shim_ah08_done:
    xor ah, ah
    push bp
    mov bp, sp
    and word ptr ss:[bp + 6], 0xFFFE
    pop bp
    iret

shim_ah02:
    inc word ptr cs:[0x0F00]
    mov byte ptr cs:[shim_req_count], al
    mov byte ptr cs:[shim_req_drive], dl
    mov byte ptr cs:[shim_req_ch], ch
    mov byte ptr cs:[shim_req_cl], cl
    mov byte ptr cs:[shim_req_dh], dh
    mov word ptr cs:[shim_req_off], bx
    push ax
    mov ax, es
    mov word ptr cs:[shim_req_seg], ax
    pop ax

    push ds
    push es
    pushad
    xor ax, ax
    mov ds, ax
    cmp word ptr cs:[0x0F06], 1
    je shim_ah02_virtual_edd

    /* Decode caller CHS, then deliberately interpret it under 240/63:
     * LBA = ((C * 240) + H) * 63 + (S - 1).
     * Heads 240..255 are accepted instead of rejected, matching the physical
     * failure where the BIOS returned CF=0 but delivered the wrong sectors. */
    movzx eax, byte ptr [shim_req_ch]
    movzx ecx, byte ptr [shim_req_cl]
    and ecx, 0x00C0
    shl ecx, 2
    or eax, ecx
    imul eax, eax, 240
    movzx ecx, byte ptr [shim_req_dh]
    add eax, ecx
    imul eax, eax, 63
    movzx ecx, byte ptr [shim_req_cl]
    and ecx, 0x003F
    test ecx, ecx
    jz shim_ah02_range_error
    dec ecx
    add eax, ecx

    /* Re-encode that deliberately wrong LBA for the underlying SeaBIOS
     * 255/63 CHS implementation. This keeps the old BIOS call itself AH=02
     * while still returning exactly the bytes addressed by the synthetic
     * 240/63 interpretation above. */
    xor edx, edx
    mov ecx, 63
    div ecx
    inc dl
    mov byte ptr [shim_xlat_sector], dl
    xor edx, edx
    mov ecx, 255
    div ecx
    cmp eax, 1023
    ja shim_ah02_range_error
    mov word ptr [shim_xlat_cylinder], ax
    mov byte ptr [shim_xlat_head], dl

    mov cx, word ptr [shim_xlat_cylinder]
    mov ch, cl
    mov al, byte ptr [shim_xlat_sector]
    mov cl, al
    mov ax, word ptr [shim_xlat_cylinder]
    shr ax, 2
    and al, 0xC0
    or cl, al
    mov dh, byte ptr [shim_xlat_head]
    mov dl, byte ptr [shim_req_drive]
    mov ax, word ptr [shim_req_seg]
    mov es, ax
    mov bx, word ptr [shim_req_off]
    mov al, byte ptr [shim_req_count]
    test al, al
    jz shim_ah02_range_error
    mov ah, 0x02

    /* Invoke the real BIOS through a real INT instruction. Temporarily restore
     * the original IVT vector so this nested AH=02 cannot recurse into us. */
    cli
    xor ax, ax
    mov ds, ax
    mov ax, word ptr [shim_old13_off]
    mov word ptr [0x004C], ax
    mov ax, word ptr [shim_old13_seg]
    mov word ptr [0x004E], ax

    mov ax, word ptr [shim_req_seg]
    mov es, ax
    mov bx, word ptr [shim_req_off]
    mov dl, byte ptr [shim_req_drive]
    mov al, byte ptr [shim_req_count]
    mov ah, 0x02
    int 0x13

    mov byte ptr cs:[shim_status_ah], ah
    pushf
    pop ax
    and al, 1
    mov byte ptr cs:[shim_status_cf], al

    cli
    xor ax, ax
    mov ds, ax
    lea ax, [xp_diag_int13_shim]
    mov word ptr [0x004C], ax
    mov word ptr [0x004E], 0x0000
    jmp shim_ah02_restore

shim_ah02_virtual_edd:
    /* Post-J compatibility mode: caller CHS is defined by virtual 255/63.
     * Convert it to absolute LBA and execute the transfer through the real
     * BIOS EDD AH=42 path. No physical CHS translation participates. */
    movzx eax, byte ptr [shim_req_ch]
    movzx ecx, byte ptr [shim_req_cl]
    and ecx, 0x00C0
    shl ecx, 2
    or eax, ecx
    imul eax, eax, 255
    movzx ecx, byte ptr [shim_req_dh]
    add eax, ecx
    imul eax, eax, 63
    movzx ecx, byte ptr [shim_req_cl]
    and ecx, 0x003F
    test ecx, ecx
    jz shim_ah02_range_error
    dec ecx
    add eax, ecx
    mov dword ptr [shim_virtual_lba], eax

    mov byte ptr [shim_dap + 0], 0x10
    mov byte ptr [shim_dap + 1], 0x00
    xor cx, cx
    mov cl, byte ptr [shim_req_count]
    test cx, cx
    jz shim_ah02_range_error
    mov word ptr [shim_dap + 2], cx
    mov ax, word ptr [shim_req_off]
    mov word ptr [shim_dap + 4], ax
    mov ax, word ptr [shim_req_seg]
    mov word ptr [shim_dap + 6], ax
    mov eax, dword ptr [shim_virtual_lba]
    mov dword ptr [shim_dap + 8], eax
    mov dword ptr [shim_dap + 12], 0

    cli
    xor ax, ax
    mov ds, ax
    mov ax, word ptr [shim_old13_off]
    mov word ptr [0x004C], ax
    mov ax, word ptr [shim_old13_seg]
    mov word ptr [0x004E], ax
    lea si, [shim_dap]
    mov dl, byte ptr [shim_req_drive]
    mov ah, 0x42
    int 0x13
    mov byte ptr cs:[shim_status_ah], ah
    pushf
    pop ax
    and al, 1
    mov byte ptr cs:[shim_status_cf], al

    cli
    xor ax, ax
    mov ds, ax
    lea ax, [xp_diag_int13_shim]
    mov word ptr [0x004C], ax
    mov word ptr [0x004E], 0x0000
    jmp shim_ah02_restore

shim_ah02_range_error:
    mov byte ptr cs:[shim_status_ah], 0x01
    mov byte ptr cs:[shim_status_cf], 1

shim_ah02_restore:
    popad
    pop es
    pop ds
    cmp byte ptr cs:[shim_status_cf], 0
    jne shim_ah02_fail
    xor ah, ah
    mov al, byte ptr cs:[shim_req_count]
    push bp
    mov bp, sp
    and word ptr ss:[bp + 6], 0xFFFE
    pop bp
    iret

shim_ah42:
    inc word ptr cs:[0x0F02]
    jmp shim_chain_old13

shim_ah02_fail:
    mov ah, byte ptr cs:[shim_status_ah]
    push bp
    mov bp, sp
    or word ptr ss:[bp + 6], 0x0001
    pop bp
    iret

.align 4
shim_old13_off: .word 0
shim_old13_seg: .word 0
shim_req_off: .word 0
shim_req_seg: .word 0
shim_req_count: .byte 0
shim_req_drive: .byte 0
shim_req_ch: .byte 0
shim_req_cl: .byte 0
shim_req_dh: .byte 0
shim_status_ah: .byte 0
shim_status_cf: .byte 0
shim_xlat_sector: .byte 0
shim_xlat_head: .byte 0
.align 2
shim_xlat_cylinder: .word 0
.align 4
shim_virtual_lba: .long 0
shim_dap:
    .byte 0x10, 0x00
    .word 1
    .word 0
    .word 0
    .quad 0
#endif

geometry_error:
    lea si, [msg_geom_err]
    call screen_puts
    mov al, byte ptr [geometry_error_ah]
    call screen_hex8
    lea si, [crlf]
    call screen_puts
    jmp halt
bpb_error:
    lea si, [msg_bpb_err]
    call screen_puts
    mov al, byte ptr [bpb_error_ah]
    call screen_hex8
    lea si, [crlf]
    call screen_puts
halt:
    cli
1:
    hlt
    jmp 1b

.align 4
dap:
    .byte 0x10,0x00
dap_count:   .word 1
dap_offset:  .word 0
dap_segment: .word 0
dap_lba:     .quad 0

boot_drive: .byte 0
raw_ch: .byte 0
raw_cl: .byte 0
raw_dh: .byte 0
geometry_error_ah: .byte 0
bpb_error_ah: .byte 0
edd_ok: .byte 0
ah08_ok: .byte 0
bpb_ok: .byte 0
same_ah08: .byte 0
same_bpb: .byte 0
edd_error_ah: .byte 0
ah08_error_ah: .byte 0
bpb_error_io_ah: .byte 0
ah08_sector: .byte 0
ah08_head: .byte 0
bpb_sector: .byte 0
bpb_head: .byte 0
.align 2
bios_spt: .word 0
bios_heads: .word 0
bios_cmax: .word 0
bpb_spt: .word 0
bpb_heads: .word 0
ah08_cylinder: .word 0
bpb_cylinder: .word 0
.align 4
compare_lba_value: .long 0

msg_geom_c: .asciz "G Cmax="
msg_geom_h: .asciz " H="
msg_geom_s: .asciz " S="
msg_geom_raw: .asciz " RAW="
msg_geom_err: .asciz "G ERR="
msg_bpb_h: .asciz "B BPB H="
msg_bpb_s: .asciz " S="
msg_bpb_err: .asciz "B BPB ERR="
msg_lba2048: .asciz "LBA2048"
msg_lba2060: .asciz "LBA2060"
msg_lba1123648: .asciz "LBA1123648"
msg_edd: .asciz " EDD="
msg_ah08: .asciz " AH08 C="
msg_bpb: .asciz " BPB  C="
msg_h: .asciz " H="
msg_s: .asciz " S="
msg_io: .asciz " IO="
msg_same: .asciz " SAME="
msg_ok: .asciz "OK"
msg_err: .asciz "ERR/"
msg_yes: .asciz "YES"
msg_no: .asciz "NO"
crlf: .asciz "\r\n"
