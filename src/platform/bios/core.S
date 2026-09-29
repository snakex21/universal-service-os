.intel_syntax noprefix
.section .text.early,"ax",@progbits
.code32
.global core_start
.global bios_read_sector
.global bios_read_sector_drive
.global bios_read_sectors
.global bios_drive_info
.global bios_read_key
.global bios_read_key_timeout
.global bios_poll_key
.global bios_power_off
.global bios_restart
.global bios_vbe_probe
.global bios_vbe_mode_info
.global bios_vbe_set_mode
.global bios_vbe_text_mode
.global bios_vbe_current_mode
.global bios_e820_probe
.global core_vbe_stage
.global core_vbe_last_ax
.global core_e820_stage
.global core_e820_last_eax
.global core_e820_last_ecx
.global core_e820_last_ebx
.global core_a20_state
.global core_pic1_mask
.global core_pic1_irr_isr
.global core_8042_status
.global core_idtr_base
.global core_idtr_limit
.global core_bda_keyboard_offsets
.global core_poll_scancode
.global core_scancode_count
.global core_last_scancode
.global core_keyboard_poll_count
.global core_last_keyboard_status
.global core_int13_read_count
.global core_int13_8042_before
.global core_int13_8042_after
.global core_a20_92_write_count
.global core_a20_92_before
.global core_a20_92_after
.global core_pit_counter
.global core_cmos_read
.global core_cpu_has_long_mode
.global core_linux_jump
.global core_chainload_vbr
.global core_wimboot_jump
.global core_dos_jump
.global bios_write_sectors_drive
.global bios_write_sector_drive
.global core_clear_screen
.global core_putc
.global core_serial_putc
.global memcpy
.global memmove
.global memset
.extern core_main

.equ CORE_PHYS_BASE, 0x00020000
.equ CONTEXT_PHYS, 0x00009100
.equ CONTEXT_BIOS_DRIVE, CONTEXT_PHYS + 8
.equ BOOTSTRAP_A20_92_WRITE_COUNT, 0x00009015
.equ BOOTSTRAP_A20_92_BEFORE, 0x00009016
.equ BOOTSTRAP_A20_92_AFTER, 0x00009017
.equ THUNK_STATE, 0x00009400
.equ THUNK_SAVED_ESP, THUNK_STATE + 0
.equ THUNK_LBA_LOW, THUNK_STATE + 4
.equ THUNK_LBA_HIGH, THUNK_STATE + 8
.equ THUNK_DEST, THUNK_STATE + 12
.equ THUNK_STATUS, THUNK_STATE + 16
.equ THUNK_CURSOR, THUNK_STATE + 20
.equ THUNK_DAP, THUNK_STATE + 32
.equ THUNK_DAP_COUNT, THUNK_DAP + 2
.equ THUNK_DAP_OFFSET, THUNK_DAP + 4
.equ THUNK_DAP_SEGMENT, THUNK_DAP + 6
.equ THUNK_DAP_LBA, THUNK_DAP + 8
.equ THUNK_DAP_LBA_HI, THUNK_DAP + 12
.equ THUNK_GDTR, THUNK_STATE + 48
.equ THUNK_OP, THUNK_STATE + 60
.equ THUNK_KEY, THUNK_STATE + 64
.equ THUNK_KEY_START_TICK, THUNK_STATE + 68
.equ THUNK_KEY_TIMEOUT_TICKS, THUNK_STATE + 72
.equ THUNK_SCANCODE_COUNT, THUNK_STATE + 76
.equ THUNK_LAST_SCANCODE, THUNK_STATE + 80
.equ THUNK_KEYBOARD_POLL_COUNT, THUNK_STATE + 84
.equ THUNK_LAST_KEYBOARD_STATUS, THUNK_STATE + 88
.equ THUNK_INT13_READ_COUNT, THUNK_STATE + 92
.equ THUNK_INT13_8042_BEFORE, THUNK_STATE + 96
.equ THUNK_INT13_8042_AFTER, THUNK_STATE + 97
.equ THUNK_VBE_MODE, THUNK_STATE + 100
.equ THUNK_DEST2, THUNK_STATE + 104
.equ THUNK_VBE_MODE_COUNT, THUNK_STATE + 108
.equ THUNK_VBE_LAST_AX, THUNK_STATE + 110
.equ THUNK_VBE_STAGE, THUNK_STATE + 112
.equ THUNK_E820_COUNT, THUNK_STATE + 116
.equ THUNK_E820_STAGE, THUNK_STATE + 118
.equ THUNK_E820_LAST_EAX, THUNK_STATE + 120
.equ THUNK_E820_LAST_ECX, THUNK_STATE + 124
.equ THUNK_E820_LAST_EBX, THUNK_STATE + 128
.equ THUNK_E820_CALL_COUNT, THUNK_STATE + 132
.equ THUNK_LINUX_ENTRY, THUNK_STATE + 136
.equ THUNK_LINUX_ENTRY_SEL, THUNK_LINUX_ENTRY + 4
.equ THUNK_BIOS_DRIVE, THUNK_STATE + 142
.equ THUNK_EDD_RESULT, THUNK_STATE + 143
.equ THUNK_GEOM_CYLINDERS, THUNK_STATE + 144
.equ THUNK_GEOM_HEADS, THUNK_STATE + 146
.equ THUNK_GEOM_SPT, THUNK_STATE + 148
.equ DRIVE_PARAMS, 0x00009500
.equ VBE_CONTROLLER_INFO, 0x00009600
.equ VBE_MODE_INFO, 0x00009800
.equ VBE_MODE_LIST, 0x00009900
.equ VBE_MAX_MODES, 256
.equ E820_LIST, 0x0000A000
.equ E820_ENTRY_BYTES, 24
.equ E820_MAX_ENTRIES, 128
.equ E820_MAX_CALLS, 256
/* The bootstrap is no longer executing once Core calls a BIOS thunk. Reuse
 * its 64 KiB window below Core for disk I/O. 0x80000 overlapped the live menu
 * and filesystem stack, allowing a successful batch read to corrupt it.
 * enter_bios installs Core's own GDT before firmware writes this buffer. */
.equ BOUNCE_PHYS, 0x00010000
.equ BOUNCE_SEGMENT, 0x1000
.equ REAL_STACK, 0x7A00
.equ VGA_TEXT, 0x000B8000
.equ VGA_ATTR, 0x07
.equ VGA_COLS, 80
.equ VGA_CELLS, 2000

core_start:
    cld
    mov dword ptr [THUNK_SCANCODE_COUNT], 0
    mov byte ptr [THUNK_LAST_SCANCODE], 0
    mov dword ptr [THUNK_KEYBOARD_POLL_COUNT], 0
    mov byte ptr [THUNK_LAST_KEYBOARD_STATUS], 0
    mov dword ptr [THUNK_INT13_READ_COUNT], 0
    mov byte ptr [THUNK_INT13_8042_BEFORE], 0
    mov byte ptr [THUNK_INT13_8042_AFTER], 0
    mov word ptr [THUNK_VBE_LAST_AX], 0
    mov byte ptr [THUNK_VBE_STAGE], 0
    mov word ptr [THUNK_E820_COUNT], 0
    mov byte ptr [THUNK_E820_STAGE], 0
    mov dword ptr [THUNK_E820_LAST_EAX], 0
    mov dword ptr [THUNK_E820_LAST_ECX], 0
    mov dword ptr [THUNK_E820_LAST_EBX], 0
    mov word ptr [THUNK_E820_CALL_COUNT], 0
    call core_clear_screen
    push esi
    call core_main
    add esp, 4
.halt:
    cli
    hlt
    jmp .halt

/* cdecl: void core_clear_screen(void). */
core_clear_screen:
    push edi
    mov dword ptr [THUNK_CURSOR], 0
    mov edi, VGA_TEXT
    mov ax, (VGA_ATTR << 8) | ' '
    mov ecx, VGA_CELLS
    cld
    rep stosw
    pop edi
    ret

/* cdecl: void core_putc(u8 byte). Serial + VGA text mode. */
core_serial_putc:
    mov al, byte ptr [esp + 4]
    push eax
    push edx
    mov ah, al
.quiet_serial_wait:
    mov dx, 0x03FD
    in al, dx
    test al, 0x20
    jz .quiet_serial_wait
    mov dx, 0x03F8
    mov al, ah
    out dx, al
    pop edx
    pop eax
    ret

core_putc:
    mov al, byte ptr [esp + 4]
    push eax
    push edx
    mov ah, al
.serial_wait:
    mov dx, 0x03FD
    in al, dx
    test al, 0x20
    jz .serial_wait
    mov dx, 0x03F8
    mov al, ah
    out dx, al
    cmp al, 13
    je .done
    cmp al, 10
    je .newline
    mov edx, dword ptr [THUNK_CURSOR]
    cmp edx, VGA_CELLS
    jae .done
    mov byte ptr [VGA_TEXT + edx * 2], al
    mov byte ptr [VGA_TEXT + edx * 2 + 1], VGA_ATTR
    inc edx
    mov dword ptr [THUNK_CURSOR], edx
    jmp .done
.newline:
    mov eax, dword ptr [THUNK_CURSOR]
    xor edx, edx
    mov ecx, VGA_COLS
    div ecx
    inc eax
    imul eax, VGA_COLS
    cmp eax, VGA_CELLS
    jb .store_newline
    mov eax, VGA_CELLS
.store_newline:
    mov dword ptr [THUNK_CURSOR], eax
.done:
    pop edx
    pop eax
    ret

/* cdecl: void *memcpy(void *dest, const void *src, usize count). */
memcpy:
    push edi
    push esi
    mov edi, dword ptr [esp + 12]
    mov esi, dword ptr [esp + 16]
    mov ecx, dword ptr [esp + 20]
    mov eax, edi
    cld
    rep movsb
    pop esi
    pop edi
    ret

/* cdecl: void *memmove(void *dest, const void *src, usize count). */
memmove:
    push edi
    push esi
    mov edi, dword ptr [esp + 12]
    mov esi, dword ptr [esp + 16]
    mov ecx, dword ptr [esp + 20]
    mov eax, edi
    cld
    cmp edi, esi
    jbe .move_forward
    test ecx, ecx
    jz .move_done
    lea edi, [edi + ecx - 1]
    lea esi, [esi + ecx - 1]
    std
.move_forward:
    rep movsb
    cld
.move_done:
    pop esi
    pop edi
    ret

/* cdecl: void *memset(void *dest, int value, usize count). */
memset:
    push edi
    mov edi, dword ptr [esp + 8]
    mov eax, dword ptr [esp + 12]
    mov ecx, dword ptr [esp + 16]
    mov edx, edi
    cld
    rep stosb
    mov eax, edx
    pop edi
    ret

/*
 * cdecl: u32 bios_read_sector(u64 lba, u8 *destination512)
 * One-sector EDD read through a fixed <1 MiB bounce buffer. The switch back
 * to real mode is deliberately isolated here; FAT32/GPT never know about it.
 */
bios_read_sector:
    cmp dword ptr [THUNK_INT13_READ_COUNT], 0xFFFFFFFF
    je .int13_count_done
    inc dword ptr [THUNK_INT13_READ_COUNT]
.int13_count_done:
    xor eax, eax
    in al, 0x64
    mov byte ptr [THUNK_INT13_8042_BEFORE], al

    mov eax, dword ptr [esp + 4]
    mov dword ptr [THUNK_LBA_LOW], eax
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_LBA_HIGH], eax
    mov eax, dword ptr [esp + 12]
    mov dword ptr [THUNK_DEST], eax

    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp

    mov byte ptr [THUNK_DAP + 0], 0x10
    mov byte ptr [THUNK_DAP + 1], 0x00
    mov word ptr [THUNK_DAP_COUNT], 1
    mov word ptr [THUNK_DAP_OFFSET], 0
    mov word ptr [THUNK_DAP_SEGMENT], BOUNCE_SEGMENT
    mov eax, dword ptr [THUNK_LBA_LOW]
    mov dword ptr [THUNK_DAP_LBA], eax
    mov eax, dword ptr [THUNK_LBA_HIGH]
    mov dword ptr [THUNK_DAP_LBA_HI], eax
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 0
    jmp enter_bios

/*
 * cdecl: u32 bios_read_sector_drive(u32 drive, u64 lba, u8 *destination512)
 * Same EDD/bounce path, but with an explicit BIOS DL for scanning/chainloading
 * a target disk that is not the USOS boot device.
 */
bios_read_sector_drive:
    mov eax, dword ptr [esp + 4]
    mov byte ptr [THUNK_BIOS_DRIVE], al
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_LBA_LOW], eax
    mov eax, dword ptr [esp + 12]
    mov dword ptr [THUNK_LBA_HIGH], eax
    mov eax, dword ptr [esp + 16]
    mov dword ptr [THUNK_DEST], eax

    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp

    mov byte ptr [THUNK_DAP + 0], 0x10
    mov byte ptr [THUNK_DAP + 1], 0x00
    mov word ptr [THUNK_DAP_COUNT], 1
    mov word ptr [THUNK_DAP_OFFSET], 0
    mov word ptr [THUNK_DAP_SEGMENT], BOUNCE_SEGMENT
    mov eax, dword ptr [THUNK_LBA_LOW]
    mov dword ptr [THUNK_DAP_LBA], eax
    mov eax, dword ptr [THUNK_LBA_HIGH]
    mov dword ptr [THUNK_DAP_LBA_HI], eax
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 10
    jmp enter_bios

/* One-sector write used only to consume an already allocated ESP marker.
 * The caller validates its FAT extent and exact sector contents first. */
bios_write_sector_drive:
    mov ecx, 1
    jmp .write_sector_count_ready
bios_write_sectors_drive:
    mov ecx, dword ptr [esp + 20]
    test ecx, ecx
    jz .write_invalid
    cmp ecx, 127
    ja .write_invalid
.write_sector_count_ready:
    mov word ptr [THUNK_DAP_COUNT], cx
    mov eax, dword ptr [esp + 4]
    mov byte ptr [THUNK_BIOS_DRIVE], al
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_DAP_LBA], eax
    mov eax, dword ptr [esp + 12]
    mov dword ptr [THUNK_DAP_LBA_HI], eax
    mov eax, dword ptr [esp + 16]
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov esi, eax
    mov edi, BOUNCE_PHYS
    shl ecx, 7
    cld
    rep movsd
    mov byte ptr [THUNK_DAP], 0x10
    mov byte ptr [THUNK_DAP + 1], 0
    mov word ptr [THUNK_DAP_OFFSET], 0
    mov word ptr [THUNK_DAP_SEGMENT], BOUNCE_SEGMENT
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 13
    jmp enter_bios
.write_invalid:
    mov eax, 1
    ret

/*
 * cdecl: u32 bios_read_sectors(u64 lba, u32 count, u8 *destination).
 * EDD batch path for large sequential files. Count is deliberately capped at
 * 127 sectors so the transfer stays below 64 KiB in the fixed 0x1000:0000
 * bounce window and remains compatible with conservative legacy BIOSes.
 */
bios_read_sectors:
    mov ecx, dword ptr [esp + 12]
    test ecx, ecx
    jz .batch_invalid
    cmp ecx, 127
    ja .batch_invalid

    cmp dword ptr [THUNK_INT13_READ_COUNT], 0xFFFFFFFF
    je .batch_count_done
    inc dword ptr [THUNK_INT13_READ_COUNT]
.batch_count_done:
    xor eax, eax
    in al, 0x64
    mov byte ptr [THUNK_INT13_8042_BEFORE], al

    mov eax, dword ptr [esp + 4]
    mov dword ptr [THUNK_LBA_LOW], eax
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_LBA_HIGH], eax
    mov eax, dword ptr [esp + 16]
    mov dword ptr [THUNK_DEST], eax

    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp

    mov byte ptr [THUNK_DAP + 0], 0x10
    mov byte ptr [THUNK_DAP + 1], 0x00
    mov word ptr [THUNK_DAP_COUNT], cx
    mov word ptr [THUNK_DAP_OFFSET], 0
    mov word ptr [THUNK_DAP_SEGMENT], BOUNCE_SEGMENT
    mov eax, dword ptr [THUNK_LBA_LOW]
    mov dword ptr [THUNK_DAP_LBA], eax
    mov eax, dword ptr [THUNK_LBA_HIGH]
    mov dword ptr [THUNK_DAP_LBA_HI], eax
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 0
    jmp enter_bios
.batch_invalid:
    mov eax, 1
    ret

/*
 * cdecl: u32 bios_drive_info(u32 drive, BiosDriveInfoRaw *output).
 * Read-only EDD enumeration used only for Legacy XP staging diagnostics.
 * Returns 0 on AH=48 success, 1 when BIOS reports no drive, 2 when a drive
 * exists but INT 13h Extensions are unavailable, and 3 when EDD exists but
 * AH=48 drive parameters cannot be read.
 */
bios_drive_info:
    mov eax, dword ptr [esp + 4]
    mov byte ptr [THUNK_BIOS_DRIVE], al
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_DEST], eax
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 12
    jmp enter_bios

/* cdecl: u32 bios_read_key(void). Returns BIOS scan code in AH, ASCII in AL. */
bios_read_key:
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 1
    jmp enter_bios

/*
 * cdecl: u32 bios_read_key_timeout(u32 timeout_ticks).
 * Returns BIOS scan code in AH / ASCII in AL, or 0xFFFFFFFF on timeout.
 * BIOS tick source is the BDA dword at 0x046C (~18.2 Hz), so this timeout
 * still works when IRQ1 is masked but the timer IRQ remains alive.
 */
bios_read_key_timeout:
    mov eax, dword ptr [esp + 4]
    mov dword ptr [THUNK_KEY_TIMEOUT_TICKS], eax
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 2
    jmp enter_bios

/*
 * cdecl: u32 bios_poll_key(void). Non-blocking INT 16h poll for firmware
 * without 8042 emulation of USB keyboards (SeaBIOS, also as CSMWrap's CSM):
 * returns scan code in AH / ASCII in AL, or 0xFFFFFFFF when no key is ready.
 * IRQ1 and IRQ12 stay masked meanwhile, so PS/2 keyboard and mouse bytes are
 * left in the 8042 for core_poll_scancode (docs/design/bios-via-csmwrap.md).
 */
bios_poll_key:
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 16
    jmp enter_bios

/*
 * cdecl: u32 bios_power_off(void).
 * Uses the real-mode APM interface. Success does not return because firmware
 * removes power; any return to PM32 is reported as failure so the UI can tell
 * the user to switch the machine off manually.
 */
bios_power_off:
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 3
    jmp enter_bios

/* cdecl: noreturn void bios_restart(void). Triple fault for a real CPU reset. */
bios_restart:
    cli
    sub esp, 8
    mov word ptr [esp], 0
    mov dword ptr [esp + 2], 0
    lidt [esp]
    int 3
.restart_halt:
    hlt
    jmp .restart_halt

/*
 * cdecl: u32 bios_vbe_probe(u8 *controller512, u16 *modes256).
 * Returns the number of mode IDs copied from the VBE controller list, or 0 on
 * failure. BIOS-owned far pointers are consumed only in real mode; PM32 sees
 * copies in caller-owned buffers.
 */
bios_vbe_probe:
    mov eax, dword ptr [esp + 4]
    mov dword ptr [THUNK_DEST], eax
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_DEST2], eax
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 4
    jmp enter_bios

/* cdecl: u32 bios_vbe_mode_info(u32 mode, u8 *mode_info256). */
bios_vbe_mode_info:
    mov eax, dword ptr [esp + 4]
    mov word ptr [THUNK_VBE_MODE], ax
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_DEST], eax
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 5
    jmp enter_bios

/* cdecl: u32 bios_vbe_set_mode(u32 mode). Requests the linear framebuffer. */
bios_vbe_set_mode:
    mov eax, dword ptr [esp + 4]
    mov word ptr [THUNK_VBE_MODE], ax
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 6
    jmp enter_bios

/* cdecl: u32 bios_vbe_text_mode(void). Restores VGA mode 03h for fallback. */
bios_vbe_text_mode:
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 7
    jmp enter_bios

/*
 * cdecl: u32 bios_e820_probe(void *entries24).
 * Collects up to 128 valid INT 15h E820 entries in low memory, then copies
 * them to caller-owned PM32 memory. Returns entry count or 0xFFFFFFFF on
 * malformed BIOS output / overflow. No kernel is started by this operation.
 */
/* cdecl: u32 bios_vbe_current_mode(void). Returns raw BX from VBE 4F03. */
bios_vbe_current_mode:
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 9
    jmp enter_bios

bios_e820_probe:
    mov eax, dword ptr [esp + 4]
    mov dword ptr [THUNK_DEST], eax
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 8
    jmp enter_bios

enter_bios:
    mov word ptr [THUNK_GDTR], 39
    lea eax, [core_gdt]
    mov dword ptr [THUNK_GDTR + 2], eax
    cli
    lgdt [THUNK_GDTR]
    /* Enter 16-bit protected code; selector 0x18 has base CORE_PHYS_BASE. */
    .byte 0xEA
    .long pm16_entry - core_start
    .word 0x0018

.code16
pm16_entry:
    mov ax, 0x0020
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, REAL_STACK
    mov eax, cr0
    and eax, 0xFFFFFFFE
    mov cr0, eax
    /* Flush into real mode at segment 0x2000. */
    .byte 0xEA
    .word real_entry - core_start
    .word 0x2000

real_entry:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, REAL_STACK
    cmp byte ptr [THUNK_OP], 1
    je .keyboard_read
    cmp byte ptr [THUNK_OP], 2
    je .keyboard_read_timeout
    cmp byte ptr [THUNK_OP], 3
    je .power_off
    cmp byte ptr [THUNK_OP], 4
    je .vbe_probe
    cmp byte ptr [THUNK_OP], 5
    je .vbe_mode_info
    cmp byte ptr [THUNK_OP], 6
    je .vbe_set_mode
    cmp byte ptr [THUNK_OP], 7
    je .vbe_text_mode
    cmp byte ptr [THUNK_OP], 8
    je .e820_probe
    cmp byte ptr [THUNK_OP], 9
    je .vbe_current_mode
    cmp byte ptr [THUNK_OP], 10
    je .disk_read_explicit
    cmp byte ptr [THUNK_OP], 11
    je .chainload_vbr
    cmp byte ptr [THUNK_OP], 12
    je .drive_info
    cmp byte ptr [THUNK_OP], 13
    je .disk_write_explicit
    cmp byte ptr [THUNK_OP], 14
    je .wimboot_jump
    cmp byte ptr [THUNK_OP], 15
    je .dos_jump
    cmp byte ptr [THUNK_OP], 16
    je .keyboard_poll_masked
    mov dl, byte ptr [CONTEXT_BIOS_DRIVE]
    jmp .disk_read_common
.disk_read_explicit:
    mov dl, byte ptr [THUNK_BIOS_DRIVE]
    jmp .disk_read_common
.disk_write_explicit:
    mov dl, byte ptr [THUNK_BIOS_DRIVE]
    mov si, THUNK_DAP
    mov ax, 0x4300
    sti
    nop
    int 0x13
    cli
    jc .bios_done
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done
.chainload_vbr:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7B00
    cld
    mov dl, byte ptr [THUNK_BIOS_DRIVE]
    sti
    .byte 0xEA
    .word 0x7C00
    .word 0x0000
.dos_jump:
    /* A permanent 1 KiB reservation survives DOS and MEMDISK relocation. */
    xor ax, ax
    mov ds, ax
    mov ax, word ptr [0x413]
    dec ax
    mov word ptr [0x413], ax
    shl ax, 6
    mov es, ax
    mov eax, dword ptr [0x4c]
    mov dword ptr es:[0xf0], eax
    mov al, byte ptr [THUNK_BIOS_DRIVE]
    mov byte ptr es:[0xf4], al
    /* Filter code was staged after the MEMDISK prefix. */
    mov ax, 0x9000
    mov ds, ax
    mov si, 0xa00
    xor di, di
    mov cx, 0xf0
    rep movsb
    xor ax, ax
    mov ds, ax
    mov word ptr [0x4c], 0
    mov word ptr [0x4e], es
    mov byte ptr [0x475], 1
    cmp byte ptr [THUNK_BIOS_DRIVE], 0xff
    jne .wimboot_jump
    mov byte ptr [0x475], 0
.wimboot_jump:
    cli
    mov ax, 0x9000
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xf000
    cld
    .byte 0xEA
    .word 0x0000
    .word 0x9020
.drive_info:
    /* Capture the exact legacy geometry exposed by this BIOS. Microsoft MBR
     * code may choose AH=02/CHS for low-LBA active partitions even when EDD is
     * available, so XP staging must not derive CHS from a Windows-side guess. */
    mov word ptr [THUNK_GEOM_CYLINDERS], 0
    mov word ptr [THUNK_GEOM_HEADS], 0
    mov word ptr [THUNK_GEOM_SPT], 0
    call .drive_geometry_probe

    /* Prefer EDD detection. Some USB BIOSes implement AH=41/48 reliably even
     * when legacy AH=08 geometry is incomplete for the same boot drive. */
    mov byte ptr [THUNK_EDD_RESULT], 1
    mov dl, byte ptr [THUNK_BIOS_DRIVE]
    mov bx, 0x55AA
    mov ah, 0x41
    sti
    nop
    int 0x13
    cli
    jc .drive_info_legacy_probe
    cmp bx, 0xAA55
    jne .drive_info_legacy_probe
    test cx, 0x0001
    jz .drive_info_legacy_probe

    /* EDD exists. Ask for the standard 0x1E-byte drive parameter block. */
    mov byte ptr [THUNK_EDD_RESULT], 3
    xor ax, ax
    mov es, ax
    mov di, DRIVE_PARAMS
    mov cx, 15
    rep stosw
    mov word ptr [DRIVE_PARAMS], 0x001E
    mov si, DRIVE_PARAMS
    mov dl, byte ptr [THUNK_BIOS_DRIVE]
    mov ah, 0x48
    sti
    nop
    int 0x13
    cli
    jc .drive_info_done
    cmp word ptr [DRIVE_PARAMS], 0x001A
    jb .drive_info_done
    mov eax, dword ptr [DRIVE_PARAMS + 16]
    mov edx, dword ptr [DRIVE_PARAMS + 20]
    or eax, edx
    jz .drive_info_done
    cmp word ptr [DRIVE_PARAMS + 24], 0
    je .drive_info_done
    mov byte ptr [THUNK_EDD_RESULT], 0
    jmp .drive_info_done
.drive_info_legacy_probe:
    /* No EDD response: the geometry probe above distinguishes an old BIOS
     * drive from an absent number without issuing AH=08 a second time. */
    mov byte ptr [THUNK_EDD_RESULT], 1
    cmp word ptr [THUNK_GEOM_SPT], 0
    je .drive_info_done
    cmp word ptr [THUNK_GEOM_HEADS], 0
    je .drive_info_done
    mov byte ptr [THUNK_EDD_RESULT], 2
    jmp .drive_info_done

.drive_geometry_probe:
    push ax
    push bx
    push cx
    push dx
    mov dl, byte ptr [THUNK_BIOS_DRIVE]
    mov ah, 0x08
    sti
    nop
    int 0x13
    cli
    jc .drive_geometry_done

    xor ax, ax
    mov al, cl
    and ax, 0x003F
    test ax, ax
    jz .drive_geometry_done
    mov word ptr [THUNK_GEOM_SPT], ax

    xor ax, ax
    mov al, dh
    inc ax
    mov word ptr [THUNK_GEOM_HEADS], ax

    xor ax, ax
    mov al, ch
    xor bx, bx
    mov bl, cl
    and bx, 0x00C0
    shl bx, 2
    or ax, bx
    inc ax
    mov word ptr [THUNK_GEOM_CYLINDERS], ax
.drive_geometry_done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

.drive_info_done:
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done
.disk_read_common:
    mov si, THUNK_DAP
    mov ah, 0x42
    sti
    nop
    int 0x13
    in al, 0x64
    mov byte ptr [THUNK_INT13_8042_AFTER], al
    cli
    jc .bios_done
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done
.keyboard_read:
    /*
     * Some legacy BIOS/USB keyboard implementations do not behave reliably
     * when AH=00 is entered directly after repeated protected-mode BIOS disk
     * thunks. Poll the BIOS buffer with AH=01 while real-mode interrupts are
     * enabled, then dequeue the ready key with AH=00.
     */
.keyboard_poll:
    sti
    nop
    mov ah, 0x01
    int 0x16
    jz .keyboard_poll
    xor ah, ah
    int 0x16
    cli
    mov word ptr [THUNK_KEY], ax
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done

.power_off:
    /* APM BIOS services are allowed to use firmware IRQ handlers. */
    sti
    nop
    /* APM installation check. */
    mov ax, 0x5300
    xor bx, bx
    int 0x15
    jc .bios_done
    cmp bx, 0x504D
    jne .bios_done

    /* Connect the real-mode APM interface. Already-connected is harmless. */
    mov ax, 0x5301
    xor bx, bx
    int 0x15

    /* Enable power management for all devices when the BIOS implements it. */
    mov ax, 0x5308
    mov bx, 0x0001
    mov cx, 0x0001
    int 0x15

    /* Set system power state to OFF. A working BIOS never returns from this. */
    mov ax, 0x5307
    mov bx, 0x0001
    mov cx, 0x0003
    int 0x15
    cli
    jmp .bios_done

.vbe_probe:
    /* Request a VBE2 controller block and copy the BIOS far mode list now,
     * while its segment:offset pointer is meaningful. */
    mov byte ptr [THUNK_VBE_STAGE], 1
    xor ax, ax
    mov es, ax
    mov di, VBE_CONTROLLER_INFO
    mov cx, 256
    rep stosw
    mov dword ptr [VBE_CONTROLLER_INFO], 0x32454256 /* "VBE2" */
    mov ax, 0x4F00
    mov di, VBE_CONTROLLER_INFO
    sti
    nop
    int 0x10
    cli
    mov word ptr [THUNK_VBE_LAST_AX], ax
    cmp ax, 0x004F
    jne .bios_done
    mov byte ptr [THUNK_VBE_STAGE], 2
    cmp dword ptr [VBE_CONTROLLER_INFO], 0x41534556 /* "VESA" */
    jne .bios_done

    mov byte ptr [THUNK_VBE_STAGE], 3
    /* Normalize the BIOS far pointer to segment:(offset 0..15). This keeps
     * the bounded 512-byte scan away from a 64 KiB offset wrap. */
    movzx eax, word ptr [VBE_CONTROLLER_INFO + 16]
    shl eax, 4
    movzx edx, word ptr [VBE_CONTROLLER_INFO + 14]
    add eax, edx
    test eax, eax
    jz .bios_done
    cmp eax, 0x000FFFFF
    ja .bios_done
    mov edx, eax
    and dx, 0x000F
    mov si, dx
    shr eax, 4
    mov fs, ax
    mov di, VBE_MODE_LIST
    xor cx, cx
.vbe_copy_mode:
    cmp cx, VBE_MAX_MODES
    jae .vbe_modes_done
    mov ax, word ptr fs:[si]
    cmp ax, 0xFFFF
    je .vbe_modes_done
    mov word ptr es:[di], ax
    add si, 2
    add di, 2
    inc cx
    jmp .vbe_copy_mode
.vbe_modes_done:
    mov word ptr [THUNK_VBE_MODE_COUNT], cx
    mov byte ptr [THUNK_VBE_STAGE], 4
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done

.vbe_mode_info:
    xor ax, ax
    mov es, ax
    mov di, VBE_MODE_INFO
    mov cx, 128
    rep stosw
    mov cx, word ptr [THUNK_VBE_MODE]
    mov ax, 0x4F01
    mov di, VBE_MODE_INFO
    sti
    nop
    int 0x10
    cli
    cmp ax, 0x004F
    jne .bios_done
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done

.vbe_set_mode:
    mov bx, word ptr [THUNK_VBE_MODE]
    or bx, 0x4000
    mov ax, 0x4F02
    sti
    nop
    int 0x10
    cli
    cmp ax, 0x004F
    jne .bios_done
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done

.vbe_text_mode:
    mov ax, 0x0003
    sti
    nop
    int 0x10
    cli
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done

.vbe_current_mode:
    mov ax, 0x4F03
    sti
    nop
    int 0x10
    cli
    mov word ptr [THUNK_VBE_LAST_AX], ax
    cmp ax, 0x004F
    jne .bios_done
    mov word ptr [THUNK_VBE_MODE], bx
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done

.e820_probe:
    xor ax, ax
    mov es, ax
    mov di, E820_LIST
    xor ebx, ebx
    xor bp, bp
    mov word ptr [THUNK_E820_COUNT], 0
    mov word ptr [THUNK_E820_CALL_COUNT], 0
    mov byte ptr [THUNK_E820_STAGE], 1
.e820_next:
    cmp bp, E820_MAX_ENTRIES
    jae .e820_overflow
    cmp word ptr [THUNK_E820_CALL_COUNT], E820_MAX_CALLS
    jae .e820_overflow
    inc word ptr [THUNK_E820_CALL_COUNT]

    /* ACPI 3.0 convention: initialize extended attributes to valid=1. */
    mov dword ptr es:[di + 0], 0
    mov dword ptr es:[di + 4], 0
    mov dword ptr es:[di + 8], 0
    mov dword ptr es:[di + 12], 0
    mov dword ptr es:[di + 16], 0
    mov dword ptr es:[di + 20], 1

    mov eax, 0x0000E820
    mov edx, 0x534D4150 /* "SMAP" */
    mov ecx, E820_ENTRY_BYTES
    sti
    nop
    int 0x15
    cli
    mov dword ptr [THUNK_E820_LAST_EAX], eax
    mov dword ptr [THUNK_E820_LAST_ECX], ecx
    mov dword ptr [THUNK_E820_LAST_EBX], ebx
    jc .e820_carry
    cmp eax, 0x534D4150
    jne .e820_bad_signature
    mov byte ptr [THUNK_E820_STAGE], 2
    cmp ecx, 20
    jb .e820_bad_size
    mov byte ptr [THUNK_E820_STAGE], 3

    /* Ignore zero-length entries and ACPI 3.x entries marked invalid. */
    cmp dword ptr es:[di + 8], 0
    jne .e820_nonzero
    cmp dword ptr es:[di + 12], 0
    je .e820_continue
.e820_nonzero:
    cmp ecx, 20
    jbe .e820_accept
    test dword ptr es:[di + 20], 1
    jz .e820_continue
.e820_accept:
    add di, E820_ENTRY_BYTES
    inc bp
.e820_continue:
    test ebx, ebx
    jnz .e820_next
    jmp .e820_success

.e820_carry:
    /* Some BIOSes use CF=1 to terminate after returning valid entries. */
    test bp, bp
    jnz .e820_success
    mov byte ptr [THUNK_E820_STAGE], 6
    jmp .bios_done
.e820_bad_signature:
    mov byte ptr [THUNK_E820_STAGE], 7
    jmp .bios_done
.e820_bad_size:
    mov byte ptr [THUNK_E820_STAGE], 8
    jmp .bios_done
.e820_overflow:
    mov byte ptr [THUNK_E820_STAGE], 9
    jmp .bios_done
.e820_success:
    mov word ptr [THUNK_E820_COUNT], bp
    mov byte ptr [THUNK_E820_STAGE], 4
    mov byte ptr [THUNK_STATUS], 0
    jmp .bios_done

.keyboard_poll_masked:
    /* Pending IRQ0 runs SeaBIOS's timer handler, which polls USB HID and
     * queues keys in the BDA; AH=01 then reports them without waiting. */
    in al, 0x21
    mov bl, al
    in al, 0xA1
    mov bh, al
    mov al, bl
    or al, 0x02
    out 0x21, al
    mov al, bh
    or al, 0x10
    out 0xA1, al
    mov byte ptr [THUNK_STATUS], 2
    sti
    nop
    nop
    mov ah, 0x01
    int 0x16
    jz .keyboard_poll_masked_done
    xor ah, ah
    int 0x16
    mov word ptr [THUNK_KEY], ax
    mov byte ptr [THUNK_STATUS], 0
.keyboard_poll_masked_done:
    cli
    mov al, bl
    out 0x21, al
    mov al, bh
    out 0xA1, al
    jmp .bios_done

.keyboard_read_timeout:
    mov eax, dword ptr [0x046C]
    mov dword ptr [THUNK_KEY_START_TICK], eax
.keyboard_timeout_poll:
    sti
    nop
    mov ah, 0x01
    int 0x16
    jnz .keyboard_timeout_ready
    mov eax, dword ptr [0x046C]
    sub eax, dword ptr [THUNK_KEY_START_TICK]
    cmp eax, dword ptr [THUNK_KEY_TIMEOUT_TICKS]
    jb .keyboard_timeout_poll
    cli
    mov byte ptr [THUNK_STATUS], 2
    jmp .bios_done
.keyboard_timeout_ready:
    xor ah, ah
    int 0x16
    cli
    mov word ptr [THUNK_KEY], ax
    mov byte ptr [THUNK_STATUS], 0
.bios_done:
    cli
    /* BIOS may have used its own GDT; reload ours from low-memory scratch. */
    lgdt [THUNK_GDTR]
    mov eax, cr0
    or eax, 0x00000001
    mov cr0, eax
    .byte 0x66, 0xEA
    .long pm32_resume
    .word 0x0008

.code32
pm32_resume:
    mov ax, 0x0010
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, dword ptr [THUNK_SAVED_ESP]
    cmp byte ptr [THUNK_STATUS], 2
    je .return_timeout
    cmp byte ptr [THUNK_STATUS], 0
    jne .return_failure
    cmp byte ptr [THUNK_OP], 1
    je .return_key
    cmp byte ptr [THUNK_OP], 2
    je .return_key
    cmp byte ptr [THUNK_OP], 16
    je .return_key
    cmp byte ptr [THUNK_OP], 3
    je .return_failure
    cmp byte ptr [THUNK_OP], 4
    je .return_vbe_probe
    cmp byte ptr [THUNK_OP], 5
    je .return_vbe_mode_info
    cmp byte ptr [THUNK_OP], 6
    je .return_success
    cmp byte ptr [THUNK_OP], 7
    je .return_success
    cmp byte ptr [THUNK_OP], 8
    je .return_e820_probe
    cmp byte ptr [THUNK_OP], 9
    je .return_vbe_current_mode
    cmp byte ptr [THUNK_OP], 12
    je .return_drive_info
    cmp byte ptr [THUNK_OP], 13
    je .return_success
    mov esi, BOUNCE_PHYS
    mov edi, dword ptr [THUNK_DEST]
    movzx ecx, word ptr [THUNK_DAP_COUNT]
    shl ecx, 7 /* sectors * 512 / 4 */
    cld
    rep movsd
    xor eax, eax
    jmp .restore
.return_key:
    movzx eax, word ptr [THUNK_KEY]
    jmp .restore
.return_vbe_probe:
    mov esi, VBE_CONTROLLER_INFO
    mov edi, dword ptr [THUNK_DEST]
    mov ecx, 128
    cld
    rep movsd
    mov esi, VBE_MODE_LIST
    mov edi, dword ptr [THUNK_DEST2]
    movzx ecx, word ptr [THUNK_VBE_MODE_COUNT]
    rep movsw
    movzx eax, word ptr [THUNK_VBE_MODE_COUNT]
    jmp .restore
.return_vbe_mode_info:
    mov esi, VBE_MODE_INFO
    mov edi, dword ptr [THUNK_DEST]
    mov ecx, 64
    cld
    rep movsd
    jmp .return_success
.return_vbe_current_mode:
    movzx eax, word ptr [THUNK_VBE_MODE]
    jmp .restore
.return_drive_info:
    movzx eax, byte ptr [THUNK_EDD_RESULT]
    mov edi, dword ptr [THUNK_DEST]
    test eax, eax
    jne .return_drive_geometry
    mov edx, dword ptr [DRIVE_PARAMS + 16]
    mov dword ptr [edi + 0], edx
    mov edx, dword ptr [DRIVE_PARAMS + 20]
    mov dword ptr [edi + 4], edx
    movzx edx, word ptr [DRIVE_PARAMS + 24]
    mov word ptr [edi + 8], dx
.return_drive_geometry:
    movzx edx, word ptr [THUNK_GEOM_CYLINDERS]
    mov word ptr [edi + 10], dx
    movzx edx, word ptr [THUNK_GEOM_HEADS]
    mov word ptr [edi + 12], dx
    movzx edx, word ptr [THUNK_GEOM_SPT]
    mov word ptr [edi + 14], dx
    jmp .restore
.return_e820_probe:
    mov esi, E820_LIST
    mov edi, dword ptr [THUNK_DEST]
    movzx ecx, word ptr [THUNK_E820_COUNT]
    imul ecx, 6 /* 24 bytes / 4 */
    cld
    rep movsd
    movzx eax, word ptr [THUNK_E820_COUNT]
    jmp .restore
.return_success:
    xor eax, eax
    jmp .restore
.return_timeout:
    mov eax, 0xFFFFFFFF
    jmp .restore
.return_failure:
    cmp byte ptr [THUNK_OP], 4
    je .return_probe_failure
    cmp byte ptr [THUNK_OP], 8
    je .return_probe_failure
    cmp byte ptr [THUNK_OP], 9
    je .return_probe_failure
    mov eax, 1
    jmp .restore
.return_probe_failure:
    mov eax, 0xFFFFFFFF
.restore:
    pop edi
    pop esi
    pop ebx
    pop ebp
    ret

/* cdecl: u32 core_vbe_stage(void). 1=4F00, 2=signature, 3=mode pointer, 4=list copied. */
core_vbe_stage:
    movzx eax, byte ptr [THUNK_VBE_STAGE]
    ret

/* cdecl: u32 core_vbe_last_ax(void). Last AX returned by a VBE BIOS call. */
core_vbe_last_ax:
    movzx eax, word ptr [THUNK_VBE_LAST_AX]
    ret

/* E820 probe diagnostics for serial/physical bring-up. */
core_e820_stage:
    movzx eax, byte ptr [THUNK_E820_STAGE]
    ret

core_e820_last_eax:
    mov eax, dword ptr [THUNK_E820_LAST_EAX]
    ret

core_e820_last_ecx:
    mov eax, dword ptr [THUNK_E820_LAST_ECX]
    ret

core_e820_last_ebx:
    mov eax, dword ptr [THUNK_E820_LAST_EBX]
    ret

/* cdecl: u32 core_a20_state(void). Returns 1 when A20 is enabled, else 0. */
core_a20_state:
    pushfd
    cli
    push ebx
    mov bl, byte ptr [0x00000500]
    mov bh, byte ptr [0x00100500]
    mov byte ptr [0x00000500], 0x00
    mov byte ptr [0x00100500], 0xFF
    xor eax, eax
    cmp byte ptr [0x00000500], 0xFF
    setne al
    mov byte ptr [0x00100500], bh
    mov byte ptr [0x00000500], bl
    pop ebx
    popfd
    ret

/* cdecl: u32 core_pic1_mask(void). Returns master 8259 IMR from port 0x21. */
core_pic1_mask:
    xor eax, eax
    in al, 0x21
    ret

/*
 * cdecl: u32 core_pic1_irr_isr(void).
 * Returns IRR in low 8 bits and ISR in bits 8..15. OCW3 selection is
 * restored to IRR before returning; no mask/EOI state is changed.
 */
core_pic1_irr_isr:
    pushfd
    cli
    push ebx
    xor ebx, ebx
    mov al, 0x0A
    out 0x20, al
    nop
    in al, 0x20
    mov bl, al
    mov al, 0x0B
    out 0x20, al
    nop
    in al, 0x20
    mov bh, al
    mov al, 0x0A
    out 0x20, al
    movzx eax, bx
    pop ebx
    popfd
    ret

/* cdecl: u32 core_8042_status(void). Non-destructive read of port 0x64. */
core_8042_status:
    xor eax, eax
    in al, 0x64
    ret

/* cdecl: u32 core_idtr_base(void). */
core_idtr_base:
    sub esp, 8
    sidt [esp]
    mov eax, dword ptr [esp + 2]
    add esp, 8
    ret

/* cdecl: u32 core_idtr_limit(void). Returns 16-bit limit in low bits. */
core_idtr_limit:
    sub esp, 8
    sidt [esp]
    movzx eax, word ptr [esp]
    add esp, 8
    ret

/*
 * cdecl: u32 core_bda_keyboard_offsets(void).
 * Returns BDA keyboard head in low 16 bits and tail in high 16 bits.
 */
core_bda_keyboard_offsets:
    movzx eax, word ptr [0x0000041A]
    movzx edx, word ptr [0x0000041C]
    shl edx, 16
    or eax, edx
    ret

/*
 * cdecl: u32 core_poll_scancode(void).
 * Polls only the 8042 output buffer. BIOS BDA keyboard entries are deliberately
 * ignored so one physical keystroke cannot be observed through two sources.
 * Returns one raw keyboard byte in AL, or 0xFFFFFFFF when none is available.
 * Auxiliary bytes are returned with bit 8 set for the mouse decoder.
 */
core_poll_scancode:
.poll_8042:
    cmp dword ptr [THUNK_KEYBOARD_POLL_COUNT], 0xFFFFFFFF
    je .poll_count_done
    inc dword ptr [THUNK_KEYBOARD_POLL_COUNT]
.poll_count_done:
    mov dx, 0x0064
    in al, dx
    mov byte ptr [THUNK_LAST_KEYBOARD_STATUS], al
    /* 0xFF = no 8042 at all (floating bus, e.g. i8042-less UEFI machines
     * under CSMWrap): nothing to read, keep the INT 16h fallback usable. */
    cmp al, 0xFF
    je .no_scancode
    test al, 0x01
    jz .no_scancode
    mov cl, al
    mov dx, 0x0060
    in al, dx
    test cl, 0x20
    jnz .aux_byte

    mov byte ptr [THUNK_LAST_SCANCODE], al
    cmp dword ptr [THUNK_SCANCODE_COUNT], 0xFFFFFFFF
    je .count_done
    inc dword ptr [THUNK_SCANCODE_COUNT]
.count_done:
    movzx eax, al
    ret
.aux_byte:
    movzx eax, al
    or eax, 0x100
    ret
.no_scancode:
    mov eax, 0xFFFFFFFF
    ret

/*
 * cdecl: u32 core_cmos_read(u32 index).
 * Read one CMOS/RTC register while briefly disabling maskable interrupts and
 * NMI. Re-enable NMI before returning; Legacy Core otherwise leaves NMI alone.
 */
core_cmos_read:
    pushfd
    cli
    push edx
    mov eax, dword ptr [esp + 12]
    and al, 0x7F
    or al, 0x80
    mov dx, 0x0070
    out dx, al
    jmp 1f
1:
    mov dx, 0x0071
    in al, dx
    mov ah, al
    xor al, al
    mov dx, 0x0070
    out dx, al
    movzx eax, ah
    pop edx
    popfd
    ret

/* cdecl: u32 core_scancode_count(void). */
core_scancode_count:
    mov eax, dword ptr [THUNK_SCANCODE_COUNT]
    ret

/* cdecl: u32 core_last_scancode(void). */
core_last_scancode:
    movzx eax, byte ptr [THUNK_LAST_SCANCODE]
    ret

/* cdecl: u32 core_keyboard_poll_count(void). */
core_keyboard_poll_count:
    mov eax, dword ptr [THUNK_KEYBOARD_POLL_COUNT]
    ret

/* cdecl: u32 core_last_keyboard_status(void). */
core_last_keyboard_status:
    movzx eax, byte ptr [THUNK_LAST_KEYBOARD_STATUS]
    ret

/* cdecl: u32 core_int13_read_count(void). */
core_int13_read_count:
    mov eax, dword ptr [THUNK_INT13_READ_COUNT]
    ret

/* cdecl: u32 core_int13_8042_before(void). */
core_int13_8042_before:
    movzx eax, byte ptr [THUNK_INT13_8042_BEFORE]
    ret

/* cdecl: u32 core_int13_8042_after(void). */
core_int13_8042_after:
    movzx eax, byte ptr [THUNK_INT13_8042_AFTER]
    ret

/* Bootstrap Fast-A20 telemetry. */
core_a20_92_write_count:
    movzx eax, byte ptr [BOOTSTRAP_A20_92_WRITE_COUNT]
    ret

core_a20_92_before:
    movzx eax, byte ptr [BOOTSTRAP_A20_92_BEFORE]
    ret

core_a20_92_after:
    movzx eax, byte ptr [BOOTSTRAP_A20_92_AFTER]
    ret

/*
 * cdecl: u32 core_pit_counter(void).
 * Latches PIT channel 0 and returns its current 16-bit down-counter. This
 * advances independently of IF, unlike the BIOS BDA tick while PM32 IRQs are
 * disabled.
 */
core_pit_counter:
    xor eax, eax
    mov dx, 0x0043
    out dx, al
    mov dx, 0x0040
    in al, dx
    mov ah, al
    in al, dx
    xchg al, ah
    movzx eax, ax
    ret

/* cdecl: u32 core_cpu_has_long_mode(void). */
core_cpu_has_long_mode:
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 0x00200000
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd
    xor eax, ecx
    test eax, 0x00200000
    jz .no_long_mode

    push ebx
    push ecx
    push edx
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no_long_mode_saved
    mov eax, 0x80000001
    cpuid
    bt edx, 29
    setc al
    movzx eax, al
    pop edx
    pop ecx
    pop ebx
    ret
.no_long_mode_saved:
    pop edx
    pop ecx
    pop ebx
.no_long_mode:
    xor eax, eax
    ret

/* cdecl: noreturn void core_chainload_vbr(u32 drive).
 * The selected VBR is already staged at physical 0000:7C00. Reuse the same
 * protected->real-mode transition as BIOS thunks, then enter it with DL set
 * to the BIOS number of the target disk.
 */
core_chainload_vbr:
    mov eax, dword ptr [esp + 4]
    mov byte ptr [THUNK_BIOS_DRIVE], al
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 11
    jmp enter_bios
core_wimboot_jump:
    cli
    cld
    mov esi, 0x00200000
    mov edi, 0x00090000
    mov ecx, 640
    rep movsd
    mov byte ptr [THUNK_OP], 14
    jmp enter_bios
core_dos_jump:
    mov eax, dword ptr [esp + 4]
    mov byte ptr [THUNK_BIOS_DRIVE], al
    cli
    cld
    mov esi, 0x00200000
    mov edi, 0x00090000
    mov ecx, 768
    rep movsd
    mov byte ptr [THUNK_OP], 15
    jmp enter_bios
.chainload_halt:
    cli
    hlt
    jmp .chainload_halt

/*
 * cdecl: noreturn void core_linux_jump(u32 entry, u32 boot_params).
 * Linux x86 32-bit boot protocol requires CS=0x10, DS/ES/SS=0x18, paging
 * disabled, IF clear, ESI=boot_params and EBX/EBP/EDI=0.
 */
core_linux_jump:
    mov eax, dword ptr [esp + 4]
    mov dword ptr [THUNK_LINUX_ENTRY], eax
    mov word ptr [THUNK_LINUX_ENTRY_SEL], 0x0010
    mov esi, dword ptr [esp + 8]

    sub esp, 8
    mov word ptr [esp], 31
    lea edx, [linux_gdt]
    mov dword ptr [esp + 2], edx
    cli
    lgdt [esp]
    add esp, 8

    mov eax, cr0
    and eax, 0x7FFFFFFF
    mov cr0, eax
    mov ax, 0x0018
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x0009E000
    cld
    xor ebx, ebx
    xor ebp, ebp
    xor edi, edi
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    ljmp [THUNK_LINUX_ENTRY]
.linux_halt:
    hlt
    jmp .linux_halt

.align 8
linux_gdt:
    .quad 0x0000000000000000
    .quad 0x0000000000000000
    .quad 0x00CF9A000000FFFF /* __BOOT_CS = 0x10 */
    .quad 0x00CF92000000FFFF /* __BOOT_DS = 0x18 */

.align 8
core_gdt:
    .quad 0x0000000000000000
    .quad 0x00CF9A000000FFFF
    .quad 0x00CF92000000FFFF
    /* 16-bit code: base 0x00020000, limit 64 KiB. */
    .quad 0x00009A020000FFFF
    /* 16-bit data: base 0, limit 64 KiB. */
    .quad 0x000092000000FFFF
core_gdt_end:
#include "windows_disk_order.S"
#include "dos_disk_filter.S"
#include "dos_target_mbr.S"
#include "dos_source_mbr.S"
