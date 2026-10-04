/*
 * U9FIX.COM - keeps the USOS memory settings in a Windows 95/98/Me SYSTEM.INI.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 *   U9FIX C:\WINDOWS\SYSTEM.INI
 *
 * Runs from C:\AUTOEXEC.BAT before every Windows start (the USOS Windows
 * 9x installer puts it there; docs/win9x-modern-2026-09-30.md). For each
 * rule below, when the key is missing from the file, it inserts the line
 * right after the section header (or appends the section). Keys that are
 * already there, with any value, are left alone: a value the user changed
 * wins. Nothing to do: the file is not touched. Otherwise the new text goes
 * to SYSTEM.U9$ next to it, the original is deleted and SYSTEM.U9$ renamed,
 * so a failed write never leaves a half file behind.
 *
 *   [386Enh] MaxPhysPage=40000     at most 1 GiB of RAM for VMM (more RAM,
 *                                  a large video aperture or both exhaust
 *                                  the 9x system address space)
 *   [vcache] MaxFileCache=262144   VCACHE at most 256 MiB (above that it
 *                                  overruns its address space)
 *
 *   U9FIX /VGA C:\WIN98\USOSVESA.INF
 *
 * The same, with one rule per PCI display controller (class 03h, subclass
 * 00h) found by configuration mechanism #1 on function 0 of every bus and
 * device: under [Mfg.VM] the line
 *   "vesa (vmdisp9x) vvvv:dddd"=VESA, PCI\VEN_vvvv&DEV_dddd
 * so Setup picks the VESA driver by hardware ID for the card of this PC
 * (Microsoft's "Standard PCI Graphics Adapter (VGA)" only has the
 * compatible ID PCI\CC_0300, which a hardware ID outranks). At most 4 cards.
 *
 *   U9FIX /CSM C:\WINDOWS\SYSTEM.INI
 *
 * The memory rules, and for a PC without a firmware CSM (CSMWrap: USB
 * keyboard reaches DOS only through the SeaBIOS services) in [boot]:
 *   drivers=... usoskey.drv    USOSKEY.DRV feeds the USB keys that
 *                              USOSKEY.COM collected to VKD (Windows 3.x
 *                              bridge, docs/design/bios-via-csmwrap.md 8.5)
 * The token is appended to an existing drivers= line. No mouse line: VBADOS's
 * VBMOUSE.EXE next to Windows 98's own PS/2 mouse VxD stops the installed
 * system with a protection error at KERNEL init (docs/win9x-modern-2026-09-30.md);
 * a USB mouse in Windows 9x under CSMWrap is open.
 *
 * No file, a file above 48 KiB or any DOS error: exit code 1, file unchanged.
 * Built with tools/build_win9x_support.py (zig cc, linked at 0100h).
 */
.intel_syntax noprefix
.code16
.equ max_file, 49152
.equ max_result, 57344
.equ rule_size, 16
.section .text
.global _start
_start:
    cld
    /* file name from the command tail (PSP 80h), NUL-terminated in place */
    mov si, 0x81
    xor bx, bx
    mov bl, byte ptr [0x80]
    mov byte ptr [0x81 + bx], 0
skip_blank:
    lodsb
    cmp al, ' '
    je skip_blank
    cmp al, 9
    je skip_blank
    dec si
    cmp byte ptr [si], 0
    je fail
    /* "/VGA" or "/CSM" (any case) before the file name */
    mov bp, offset rules
    cmp byte ptr [si], '/'
    jne file_arg
    mov al, byte ptr [si + 1]
    or al, 0x20
    cmp al, 'c'
    jne vga_option
    mov byte ptr [csm_mode], 1
    jmp option_done
vga_option:
    call vga_rules
option_done:
    add si, 4
vga_blank:
    lodsb
    cmp al, ' '
    je vga_blank
    dec si
    cmp byte ptr [si], 0
    je fail
file_arg:
    mov word ptr [rule_table], bp
    mov word ptr [name], si
    mov di, si
find_end:
    mov al, byte ptr [di]
    cmp al, 0
    je name_done
    cmp al, ' '
    je cut_name
    cmp al, 13
    je cut_name
    inc di
    jmp find_end
cut_name:
    mov byte ptr [di], 0
name_done:
    mov word ptr [name_end], di
    /* read the file */
    mov dx, word ptr [name]
    mov ax, 0x3d00
    int 0x21
    jc fail
    mov bx, ax
    mov ah, 0x3f
    mov cx, max_file + 1
    mov dx, offset buffer
    int 0x21
    pushf
    push ax
    mov ah, 0x3e
    int 0x21
    pop ax
    popf
    jc fail
    cmp ax, max_file
    ja fail
    mov word ptr [length], ax
    mov byte ptr [changed], 0

    mov bp, word ptr [rule_table]
rule_loop:
    cmp word ptr [bp], 0
    je rules_done
    /* key present at a line start, followed by blanks and '='? */
    mov si, word ptr [bp + 2]
    mov cx, word ptr [bp + 4]
    call find_line
    jc key_missing
    add di, cx
key_blank:
    cmp di, word ptr [limit]
    jae key_missing_again
    mov al, byte ptr [di]
    cmp al, ' '
    je key_next
    cmp al, 9
    je key_next
    cmp al, '='
    je rule_next
    jmp key_missing_again
key_next:
    inc di
    jmp key_blank
key_missing_again:
    /* "MaxPhysPageX" or similar: look further */
    mov si, word ptr [bp + 2]
    mov cx, word ptr [bp + 4]
    call find_line_after
    jc key_missing
    add di, cx
    jmp key_blank
key_missing:
    mov si, word ptr [bp]
    mov cx, word ptr [bp + 6]
    call find_line
    jc section_missing
    /* after the header line */
    add di, cx
header_eol:
    cmp di, word ptr [limit]
    jae header_at_end
    mov al, byte ptr [di]
    inc di
    cmp al, 10
    jne header_eol
    jmp insert_line
header_at_end:
    call ensure_newline
    mov di, word ptr [limit]
insert_line:
    mov si, word ptr [bp + 8]
    mov cx, word ptr [bp + 10]
    call insert
    jc fail
    jmp rule_next
section_missing:
    call ensure_newline
    mov di, word ptr [limit]
    mov si, word ptr [bp + 12]
    mov cx, word ptr [bp + 14]
    call insert
    jc fail
    mov di, word ptr [limit]
    mov si, word ptr [bp + 8]
    mov cx, word ptr [bp + 10]
    call insert
    jc fail
rule_next:
    add bp, rule_size
    jmp rule_loop

rules_done:
    cmp byte ptr [csm_mode], 0
    je rules_write
    call csm_boot
    jc fail
rules_write:
    cmp byte ptr [changed], 0
    je done
    /* temp name: same folder, SYSTEM.U9$ -> replace the last component */
    mov si, word ptr [name]
    mov di, offset temp
    mov bx, di
copy_dir:
    lodsb
    stosb
    cmp al, '\\'
    je mark_dir
    cmp al, ':'
    je mark_dir
    cmp al, 0
    jne copy_dir
    jmp copy_temp
mark_dir:
    mov bx, di
    jmp copy_dir
copy_temp:
    mov di, bx
    mov si, offset temp_name
copy_temp_loop:
    lodsb
    stosb
    cmp al, 0
    jne copy_temp_loop
    mov dx, offset temp
    mov ah, 0x3c
    xor cx, cx
    int 0x21
    jc fail
    mov bx, ax
    mov ah, 0x40
    mov cx, word ptr [length]
    mov dx, offset buffer
    int 0x21
    jc write_failed
    cmp ax, word ptr [length]
    jne write_failed
    mov ah, 0x3e
    int 0x21
    jc fail
    mov dx, word ptr [name]
    mov ah, 0x41
    int 0x21
    jc fail
    push ds
    pop es
    mov dx, offset temp
    mov di, word ptr [name]
    mov ah, 0x56
    int 0x21
    jc fail
    mov dx, offset msg_done
    mov ah, 9
    int 0x21
done:
    mov ax, 0x4c00
    int 0x21
write_failed:
    mov ah, 0x3e
    int 0x21
    mov dx, offset temp
    mov ah, 0x41
    int 0x21
fail:
    mov ax, 0x4c01
    int 0x21

/* vga_rules: BP = a table of one rule per PCI display controller (BP =
 * vga_table, terminated). SI kept. */
vga_rules:
    push si
    mov bp, offset vga_table
    mov di, bp
    mov si, offset vga_store
    xor cx, cx                      /* bus:device, function 0: (bus<<8)|(dev<<3) */
vga_scan:
    movzx eax, cx
    shl eax, 8
    or eax, 0x80000000
    mov dx, 0xcf8
    out dx, eax
    mov dx, 0xcfc
    in eax, dx
    cmp ax, 0xffff
    je vga_next
    mov ebx, eax                    /* device << 16 | vendor */
    mov eax, 0x80000008
    push cx
    movzx ecx, cx
    shl ecx, 8
    or eax, ecx
    pop cx
    mov dx, 0xcf8
    out dx, eax
    mov dx, 0xcfc
    in eax, dx
    shr eax, 16
    cmp ax, 0x0300
    jne vga_next
    cmp di, offset vga_table + 4 * rule_size
    jae vga_next
    call vga_entry
vga_next:
    add cx, 8
    jnz vga_scan
    mov word ptr [di], 0
    mov dx, 0xcf8
    xor eax, eax
    out dx, eax
    pop si
    ret

/* vga_entry: EBX = device:vendor; SI = free string store, DI = the rule
 * to fill. Advances both. */
vga_entry:
    push cx
    push di
    mov di, si
    /* pattern: "vesa (vmdisp9x) vvvv:dddd" */
    push si
    mov si, offset vga_prefix
    mov cx, word ptr [vga_prefix_len]
    rep movsb
    pop si
    mov ax, bx
    call hex4
    mov al, ':'
    stosb
    mov eax, ebx
    shr eax, 16
    call hex4
    mov al, '"'
    stosb
    mov dx, di                      /* pattern end = line text start */
    /* line: the pattern again, then =VESA, PCI\VEN_vvvv&DEV_dddd CR LF */
    push si
    mov cx, di
    sub cx, si
    rep movsb
    mov si, offset vga_model
    mov cx, word ptr [vga_model_len]
    rep movsb
    pop si
    mov ax, bx
    call hex4
    push si
    mov si, offset vga_dev
    mov cx, word ptr [vga_dev_len]
    rep movsb
    pop si
    mov eax, ebx
    shr eax, 16
    call hex4
    mov ax, 0x0a0d
    stosw
    /* rule: section, key, key length, section length, line, line length, header, length */
    pop bx                          /* the rule */
    mov word ptr [bx], offset sec_mfg
    mov word ptr [bx + 2], si
    mov ax, dx
    sub ax, si
    mov word ptr [bx + 4], ax
    mov ax, word ptr [head_mfg_len]
    mov word ptr [bx + 14], ax
    dec ax
    dec ax
    mov word ptr [bx + 6], ax
    mov word ptr [bx + 8], dx
    mov ax, di
    sub ax, dx
    mov word ptr [bx + 10], ax
    mov word ptr [bx + 12], offset head_mfg
    mov si, di
    lea di, [bx + rule_size]
    pop cx
    ret

/* hex4: AX as four lower-case hex digits at ES:DI */
hex4:
    push cx
    mov cx, 4
hex4_loop:
    rol ax, 4
    push ax
    and al, 0x0f
    add al, '0'
    cmp al, '9'
    jbe hex4_digit
    add al, 'a' - '9' - 1
hex4_digit:
    stosb
    pop ax
    loop hex4_loop
    pop cx
    ret

/* csm_boot: the [boot] lines of /CSM. CF set when the file would not fit. */
csm_boot:
    mov si, offset sec_boot
    mov cx, 6
    call find_line
    jc csm_ok                       /* no [boot]: nothing to adjust */
    add di, cx
csm_header_eol:
    cmp di, word ptr [limit]
    jae csm_header_end
    mov al, byte ptr [di]
    inc di
    cmp al, 10
    jne csm_header_eol
    jmp csm_section
csm_header_end:
    call ensure_newline
    mov di, word ptr [limit]
csm_section:
    mov word ptr [sec_start], di
    /* drivers=: append " usoskey.drv" unless the line has it */
    mov si, offset key_drivers
    mov cx, 8
    call find_key_in_section
    jc csm_drivers_new
    add di, cx
    mov bx, di                      /* scan the value for the token */
csm_token:
    cmp bx, word ptr [limit]
    jae csm_token_end
    mov al, byte ptr [bx]
    cmp al, 13
    je csm_token_end
    cmp al, 10
    je csm_token_end
    mov di, bx
    mov si, offset tok_usoskey
    mov cx, 11
    call match_at
    je csm_mouse
    inc bx
    jmp csm_token
csm_token_end:
    mov di, bx
    mov si, offset add_usoskey
    mov cx, 12
    call insert
    jc csm_full
    jmp csm_mouse
csm_drivers_new:
    mov di, word ptr [sec_start]
    mov si, offset line_drivers
    mov cx, word ptr [line_drivers_len]
    call insert
    jc csm_full
csm_mouse:
csm_ok:
    clc
    ret
csm_full:
    stc
    ret

/* find_key_in_section: SI = lower-case key (with '='), CX = length, lines
 * from [sec_start] up to the next line starting with '['. DI = the line,
 * CF set when none. SI, CX kept. */
find_key_in_section:
    call set_limit
    mov di, word ptr [sec_start]
fks_line:
    mov ax, word ptr [limit]
    sub ax, di
    cmp ax, cx
    jb fks_none
    cmp byte ptr [di], '['
    je fks_none
    call match_at
    je fks_found
fks_next:
    cmp di, word ptr [limit]
    jae fks_none
    mov al, byte ptr [di]
    inc di
    cmp al, 10
    jne fks_next
    jmp fks_line
fks_found:
    clc
    ret
fks_none:
    stc
    ret

/* match_at: ZF set when the CX bytes at DI equal the lower-case pattern at
 * SI, ignoring case (and staying inside the file). SI, DI, CX kept. */
match_at:
    push si
    push di
    push cx
    mov ax, word ptr [limit]
    sub ax, di
    cmp ax, cx
    jb match_no
match_char:
    mov al, byte ptr [di]
    cmp al, 'A'
    jb match_lower
    cmp al, 'Z'
    ja match_lower
    or al, 0x20
match_lower:
    cmp al, byte ptr [si]
    jne match_no
    inc si
    inc di
    loop match_char
    xor ax, ax                      /* ZF = 1 */
    jmp match_done
match_no:
    or al, 1
    mov ax, 1
    or ax, ax                       /* ZF = 0 */
match_done:
    pop cx
    pop di
    pop si
    ret

/* delete: CX bytes at DI (inside the buffer) */
delete:
    push si
    push di
    push cx
    push ds
    pop es
    mov si, di
    add si, cx
    mov ax, word ptr [limit]
    sub ax, si
    xchg ax, cx
    sub word ptr [length], ax
    rep movsb
    mov byte ptr [changed], 1
    call set_limit
    pop cx
    pop di
    pop si
    ret

/* limit = buffer + length */
set_limit:
    mov ax, offset buffer
    add ax, word ptr [length]
    mov word ptr [limit], ax
    ret

/* find_line: SI = lower-case pattern, CX = length. DI = first match at a line
 * start (case-insensitive), CF set when none. find_line_after continues after
 * the match in DI. SI, CX kept. */
find_line:
    mov di, offset buffer
    jmp find_at
find_line_after:
    inc di
find_at:
    call set_limit
find_try:
    mov ax, word ptr [limit]
    sub ax, di
    cmp ax, cx
    jb find_none
    cmp di, offset buffer
    je find_compare
    cmp byte ptr [di - 1], 10
    jne find_skip
find_compare:
    push si
    push di
    push cx
find_char:
    mov al, byte ptr [di]
    cmp al, 'A'
    jb find_lower
    cmp al, 'Z'
    ja find_lower
    or al, 0x20
find_lower:
    cmp al, byte ptr [si]
    jne find_differs
    inc si
    inc di
    loop find_char
    pop cx
    pop di
    pop si
    clc
    ret
find_differs:
    pop cx
    pop di
    pop si
find_skip:
    inc di
    jmp find_try
find_none:
    stc
    ret

/* ensure_newline: a CR LF at the end unless the file is empty or ends in LF */
ensure_newline:
    call set_limit
    cmp word ptr [length], 0
    je ensure_done
    mov di, word ptr [limit]
    cmp byte ptr [di - 1], 10
    je ensure_done
    mov si, offset crlf
    mov cx, 2
    call insert
ensure_done:
    ret

/* insert: CX bytes from SI at DI (inside or at the end of the buffer).
 * CF set when the result would not fit. */
insert:
    mov ax, word ptr [length]
    add ax, cx
    cmp ax, max_result
    ja insert_full
    push si
    push cx
    push di
    push ds
    pop es
    /* move [DI, limit) up by CX, from the end */
    call set_limit
    mov si, word ptr [limit]
    mov ax, si
    sub ax, di
    dec si
    mov di, si
    add di, cx
    mov cx, ax
    std
    rep movsb
    cld
    pop di
    pop cx
    pop si
    add word ptr [length], cx
    rep movsb
    mov byte ptr [changed], 1
    call set_limit
    clc
    ret
insert_full:
    stc
    ret

    .p2align 1
/* section pattern, key pattern, key length, section length, line, line
 * length, section header, header length */
rules:
    .word sec_386, key_mpp, 11, 8, line_mpp, line_mpp_end - line_mpp, head_386, head_386_end - head_386
    .word sec_vc, key_mfc, 12, 8, line_mfc, line_mfc_end - line_mfc, head_vc, head_vc_end - head_vc
    .word 0
sec_386: .ascii "[386enh]"
key_mpp: .ascii "maxphyspage"
line_mpp: .ascii "MaxPhysPage=40000\r\n"
line_mpp_end:
head_386: .ascii "[386Enh]\r\n"
head_386_end:
sec_vc: .ascii "[vcache]"
key_mfc: .ascii "maxfilecache"
line_mfc: .ascii "MaxFileCache=262144\r\n"
line_mfc_end:
head_vc: .ascii "[vcache]\r\n"
head_vc_end:
sec_mfg: .ascii "[mfg.vm]"
head_mfg: .ascii "[Mfg.VM]\r\n"
head_mfg_end:
vga_prefix: .ascii "\"vesa (vmdisp9x) "
vga_prefix_end:
vga_model: .ascii "=VESA, PCI\\VEN_"
vga_model_end:
vga_dev: .ascii "&DEV_"
vga_dev_end:
crlf: .ascii "\r\n"
sec_boot: .ascii "[boot]"
key_drivers: .ascii "drivers="
tok_usoskey: .ascii "usoskey.drv"
add_usoskey: .ascii " usoskey.drv"
line_drivers: .ascii "drivers=usoskey.drv\r\n"
line_drivers_end:
temp_name: .asciz "SYSTEM.U9$"
msg_done: .ascii "USOS: settings added (U9FIX)\r\n$"
    .p2align 1
name: .word 0
name_end: .word 0
length: .word 0
limit: .word 0
changed: .byte 0
    .p2align 1
line_drivers_len: .word line_drivers_end - line_drivers
sec_start: .word 0
csm_mode: .byte 0
    .p2align 1
vga_prefix_len: .word vga_prefix_end - vga_prefix
vga_model_len: .word vga_model_end - vga_model
vga_dev_len: .word vga_dev_end - vga_dev
head_mfg_len: .word head_mfg_end - head_mfg
rule_table: .word 0
vga_table: .space 4 * rule_size + 2
vga_store: .space 4 * 96
temp: .space 128
    .p2align 4
buffer:
