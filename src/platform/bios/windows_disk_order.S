/* Native Windows handoff only. Keep the USOS USB last in BIOS hard-disk
 * numbering when firmware booted it as 80h. No disk sectors are changed.
 * Lives in the pinned wimboot prefix's unused 0400h..05ffh padding.
 */
.intel_syntax noprefix
.section .rodata.windows_disk_order,"a",@progbits
.code16
.global windows_disk_order_start
windows_disk_order_start:
    cli
    cld
    pushad
    push ds
    push es
    cmp byte ptr cs:[0x5fa], 0x80
    jne .order_done
    xor ax, ax
    mov ds, ax
    mov al, byte ptr [0x475]
    cmp al, 2
    jb .order_done
    cmp al, 16
    ja .order_done
    add al, 0x7f
    mov byte ptr cs:[0x5f4], al
    mov eax, dword ptr [0x4c]
    mov dword ptr cs:[0x5f0], eax
    /* The lasting hook sits below wimboot's bss16 at physical 20a00h.
     * Prefix code itself is not relocated over these reserved bytes. */
    mov ax, cs
    mov ds, ax
    mov ax, 0x2000
    mov es, ax
    mov si, 0x500
    mov di, 0x500
    mov cx, 0x100
    rep movsb
    xor ax, ax
    mov ds, ax
    mov word ptr [0x4c], 0x500
    mov word ptr [0x4e], 0x2000
.order_done:
    pop es
    pop ds
    popad
    push cs
    push word ptr cs:[0x5fc]
    .byte 0xcb /* 16-bit retf; LLVM Intel 'retf' defaults to a 32-bit pop */

.org 0x100
.order_int13:
    cmp dl, 0x80
    jb .order_chain
    cmp dl, byte ptr cs:[0x5f4]
    ja .order_chain
    push bp
    mov bp, sp
    push ax
    push dx
    cmp dl, byte ptr cs:[0x5f4]
    je .order_usb
    inc dl
    jmp .order_call
.order_usb:
    mov dl, 0x80
.order_call:
    .byte 0x9c /* 16-bit FLAGS frame for the firmware IRET */
    .byte 0x2e,0xff,0x1e,0xf0,0x05 /* call far cs:[05f0] */
    jc .order_failed
    and word ptr ss:[bp+6], 0xfffe
    jmp .order_result
.order_failed:
    or word ptr ss:[bp+6], 1
.order_result:
    /* AH=08 returns drive count in DL, AH=15 returns size in CX:DX.
     * Other calls must return the caller's virtual DL, not the mapped one. */
    cmp byte ptr ss:[bp-1], 8
    je .order_return
    cmp byte ptr ss:[bp-1], 0x15
    je .order_return
    mov dl, byte ptr ss:[bp-4]
.order_return:
    mov sp, bp
    pop bp
    .byte 0xcf /* 16-bit IRET */
.order_chain:
    .byte 0x2e,0xff,0x2e,0xf0,0x05 /* jmp far cs:[05f0] */

.org 0x1f0
    .long 0  /* original INT13 vector */
    .byte 0  /* last BIOS hard disk */
.org 0x1fa
    .byte 0xff /* USOS boot drive, set by Core */
    .byte 0
    .word 0 /* original wimboot real-mode continuation, set by Core */
    .word 0
.code32
