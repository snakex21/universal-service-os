.intel_syntax noprefix
.code16
.section .text
.global xp_stage2_start

.equ BOOT_BASE,       0x7C00
.equ FAT_BUFFER,      0x5000
.equ DIR_BUFFER,      0x5200
.equ NTLDR_SEGMENT,   0x2000

xp_stage2_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    sti
    cld
    mov byte ptr [boot_drive], dl

    call serial_init
    lea si, [msg_stage2]
    call serial_puts

    cmp word ptr [BOOT_BASE + 11], 512
    jne fs_error
    cmp byte ptr [BOOT_BASE + 16], 0
    je fs_error
    cmp dword ptr [BOOT_BASE + 36], 0
    je fs_error

    mov eax, dword ptr [BOOT_BASE + 28]
    mov dword ptr [part_lba], eax
    movzx ecx, word ptr [BOOT_BASE + 14]
    add eax, ecx
    mov dword ptr [fat_lba], eax

    mov eax, dword ptr [BOOT_BASE + 36]
    movzx ecx, byte ptr [BOOT_BASE + 16]
    imul eax, ecx
    add eax, dword ptr [fat_lba]
    mov dword ptr [data_lba], eax

    mov eax, dword ptr [BOOT_BASE + 44]
    mov dword ptr [scan_cluster], eax

find_root_cluster:
    mov eax, dword ptr [scan_cluster]
    cmp eax, 2
    jb fs_error
    call cluster_to_lba
    mov dword ptr [cluster_lba], eax
    mov word ptr [sector_index], 0

scan_cluster_sector:
    movzx ecx, byte ptr [BOOT_BASE + 13]
    movzx edx, word ptr [sector_index]
    cmp edx, ecx
    jae root_next_cluster
    mov eax, dword ptr [cluster_lba]
    add eax, edx
    xor dx, dx
    mov es, dx
    mov bx, DIR_BUFFER
    call read_sector
    jc disk_error

    mov si, DIR_BUFFER
    mov cx, 16
scan_entry:
    cmp byte ptr [si], 0x00
    je file_not_found
    cmp byte ptr [si], 0xE5
    je next_entry
    mov al, byte ptr [si + 11]
    cmp al, 0x0F
    je next_entry
    test al, 0x08
    jnz next_entry

    push si
    push cx
    lea di, [ntldr_name]
    mov cx, 11
    repe cmpsb
    pop cx
    pop si
    je ntldr_found

next_entry:
    add si, 32
    loop scan_entry
    inc word ptr [sector_index]
    jmp scan_cluster_sector

root_next_cluster:
    mov eax, dword ptr [scan_cluster]
    call fat_next
    jc disk_error
    cmp eax, 0x0FFFFFF8
    jae file_not_found
    mov dword ptr [scan_cluster], eax
    jmp find_root_cluster

ntldr_found:
    movzx eax, word ptr [si + 20]
    shl eax, 16
    mov ax, word ptr [si + 26]
    mov dword ptr [file_cluster], eax
    mov eax, dword ptr [si + 28]
    mov dword ptr [file_remaining], eax
    test eax, eax
    jz fs_error

    lea si, [msg_found]
    call serial_puts
    mov word ptr [dest_segment], NTLDR_SEGMENT

load_cluster:
    mov eax, dword ptr [file_cluster]
    call cluster_to_lba
    mov dword ptr [cluster_lba], eax
    mov word ptr [sector_index], 0

load_sector:
    cmp dword ptr [file_remaining], 0
    je ntldr_jump
    movzx ecx, byte ptr [BOOT_BASE + 13]
    movzx edx, word ptr [sector_index]
    cmp edx, ecx
    jae load_next_cluster
    mov eax, dword ptr [cluster_lba]
    add eax, edx
    mov dx, word ptr [dest_segment]
    mov es, dx
    xor bx, bx
    call read_sector
    jc disk_error
    add word ptr [dest_segment], 0x20
    cmp dword ptr [file_remaining], 512
    jbe load_last_accounted
    sub dword ptr [file_remaining], 512
    inc word ptr [sector_index]
    jmp load_sector

load_last_accounted:
    mov dword ptr [file_remaining], 0
    jmp ntldr_jump

load_next_cluster:
    mov eax, dword ptr [file_cluster]
    call fat_next
    jc disk_error
    cmp eax, 0x0FFFFFF8
    jae fs_error
    mov dword ptr [file_cluster], eax
    jmp load_cluster

ntldr_jump:
    lea si, [msg_jump]
    call serial_puts

#ifdef XP_STAGE2_CAPTURE_REGS
    /* Test-only ABI capture immediately before production handoff setup. */
    mov dword ptr cs:[0x1000], 0x53474552
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
#endif

#ifdef XP_STAGE2_DIAG_HOOK
    /* Test-only: the mismatch fixture loaded the verified CRC/timer runtime at
     * 0000:1000. Call it immediately before the production NTLDR handoff so
     * the regression can prove the EDD loader placed the exact 262400 bytes in
     * RAM. Raw encoding forces the 16-bit near-call ABI used by real mode. */
    mov dl, byte ptr [boot_drive]
    .byte 0xE8
    .word 0x1000 - (. + 2)
#endif

    /* Match the exact register/segment/flags state measured from the working
     * Microsoft NT52 FAT32 stage2 immediately after its final
     * `mov dl,[bp+0x40]` and before `jmp 2000:0000`. The register values are
     * part of the observed SETUPLDR handoff contract for this local-source
     * path; do not substitute the unrelated CDBOOT ABI. */
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, 0x7BF4
    mov bp, 0x7C00
    mov eax, 0x0FFFFFFF
    mov ebx, 0x000001A0
    mov ecx, 0x00000200
    mov edx, 0x00000100
    mov dl, byte ptr [BOOT_BASE + 64]
    mov esi, 0x00000002
    mov edi, 0x00007E00
    push 0x0246
    popf
    .byte 0xEA
    .word 0x0000
    .word NTLDR_SEGMENT

/* EAX=cluster -> EAX=first sector absolute LBA. */
cluster_to_lba:
    sub eax, 2
    movzx ecx, byte ptr [BOOT_BASE + 13]
    imul eax, ecx
    add eax, dword ptr [data_lba]
    ret

/* EAX=cluster -> EAX=next FAT32 cluster, CF on disk failure. */
fat_next:
    push bx
    push cx
    push dx
    push es
    mov edx, eax
    shl edx, 2
    mov ecx, edx
    and ecx, 0x1FF
    shr edx, 9
    mov eax, dword ptr [fat_lba]
    add eax, edx
    xor dx, dx
    mov es, dx
    mov bx, FAT_BUFFER
    call read_sector
    jc .fat_fail
    mov bx, cx
    mov eax, dword ptr [FAT_BUFFER + bx]
    and eax, 0x0FFFFFFF
    clc
    jmp .fat_done
.fat_fail:
    stc
.fat_done:
    pop es
    pop dx
    pop cx
    pop bx
    ret

/* EAX=LBA, ES:BX=512-byte destination. Preserves all except AX/flags. */
read_sector:
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

disk_error:
    lea si, [msg_disk]
    call serial_puts
    jmp halt
fs_error:
    lea si, [msg_fs]
    call serial_puts
    jmp halt
file_not_found:
    lea si, [msg_missing]
    call serial_puts
halt:
    cli
1:
    hlt
    jmp 1b

.align 4
dap:
    .byte 0x10, 0x00
dap_count:
    .word 1
dap_offset:
    .word 0
dap_segment:
    .word 0
dap_lba:
    .quad 0

boot_drive:     .byte 0
.align 2
dest_segment:   .word 0
sector_index:   .word 0
.align 4
part_lba:       .long 0
fat_lba:        .long 0
data_lba:       .long 0
scan_cluster:   .long 0
cluster_lba:    .long 0
file_cluster:   .long 0
file_remaining: .long 0

ntldr_name: .ascii "NTLDR      "
msg_stage2: .asciz "[XP-BOOT] STAGE2\r\n"
msg_found:  .asciz "[XP-BOOT] NTLDR FOUND\r\n"
msg_jump:   .asciz "[XP-BOOT] NTLDR JUMP\r\n"
msg_disk:   .asciz "[XP-BOOT] DISK ERROR\r\n"
msg_fs:     .asciz "[XP-BOOT] FAT32 ERROR\r\n"
msg_missing:.asciz "[XP-BOOT] NTLDR MISSING\r\n"
