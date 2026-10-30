/*
 * USOS NT 3.x MBR: E820 filter, HPET legacy off, PCI BIOS hiding, XP geometry fix.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-2.0-or-later.
 *
 * The NT 3.51 loaders (SETUPLDR.BIN, NTLDR) turn every INT 15h E820 entry
 * into a loader memory descriptor, reserved ones included, and the 3.51
 * kernel takes MmHighestPhysicalPage from the highest descriptor.  A firmware
 * reserved range near 4 GiB (SeaBIOS: FFFC0000, real boards: APIC/flash/MMIO)
 * makes it 0xFFFFF while the PFN database only covers RAM, so
 * MiInitMachineDependent faults (STOP 0x50, CR2 just above the PFN database)
 * on the first page table entry that maps device memory.
 *
 * This MBR keeps 1 KiB at the top of conventional memory for an INT 15h hook
 * that rewrites E820 results:
 *   - entries above 4 GiB and every non-RAM entry that ends above A0000h
 *     become a copy of the BIOS ROM range F0000-FFFFF (type 2), which is
 *     below any RAM top; only a non-RAM entry ending at or below A0000h (the
 *     EBDA) stays.  CSMWrap reports A0000-FFFFF as one reserved entry (plain
 *     SeaBIOS: F0000-FFFFF): as a loader descriptor it overlaps the VGA
 *     window, so the 3.51 vga.sys claim of A0000-BFFFF conflicts
 *     (VideoPortVerifyAccessRanges), no \Device\Video0 is created and text-mode
 *     Setup stops "while initializing your computer's video" (0, C0000034);
 *     the installed system then lacks a display (STOP C0000143);
 *   - RAM entries are clipped at 4 GiB (and at the RAM cap, below);
 *   - the RAM entry at address 0 ends below the hook (INT 12h size).
 * Everything else is the XP geometry-fix MBR: boot the active partition and
 * correct the BPB head count from INT 13h AH=08.
 *
 * The resident hooks do not fit next to the boot code: they are their own
 * section (.hook, nt3-e820-hook-512.bin, "U3" in its last two bytes) that
 * nt4_csmwrap_target.sh writes to sector 1 (unused: the partition starts at
 * sector 63).  This MBR reads it into the reserved 1 KiB; without the sector
 * it boots without any hook.
 *
 * Old memory sizes: the NT 3.1 NTLDR / SETUPLDR know no E820.  They size the
 * memory above 1 MiB with INT 15h AH=88h and take AX=E801h only when its AX
 * equals the AH=88h value (then BX 64 KiB blocks from 16 MiB on).  SeaBIOS
 * (CSMWrap) answers both from the end of the first contiguous RAM above
 * 1 MiB: OVMF's reserved range at 8 MiB left NT 3.1 with 8128 KB (QEMU
 * 2026-10-10), and above 64 MiB AH=88h (63 MiB) and E801h AX (15 MiB)
 * disagree.  The hook answers AH=88h and AX=E801h alike: AX (CX) = the BIOS
 * E801h AX (contiguous RAM 1-16 MiB), BX (DX) = the E820 RAM entry that
 * covers 16 MiB, up to its end (at most 4 GiB).
 *
 * HPET: the X470 firmware (AMI, booted through CSMWrap) hands over with the
 * HPET enabled in LegacyReplacement mode and timer 0 interrupts off
 * (usosrst 1.3, Win2000: cfg 00000003, t0 00008030).  Then neither the PIT
 * nor the HPET raises IRQ 0 (and the RTC not IRQ 8), so a pre-ACPI HAL gets
 * no clock interrupt until usosrst clears the bit.  This MBR clears
 * LegacyReplacement (general configuration bit 1) already, through a 4 GiB
 * FS limit (unreal mode), when the HPET at FED00000h (the fixed AMD/Intel
 * address) answers.  -DNT3_HPET_SET_LEGACY builds the opposite (enable +
 * LegacyReplacement) to reproduce the X470 state in QEMU.
 *
 * PCI: NTDETECT 3.51 takes the PCI bus count from INT 1Ah B101h (last bus +
 * 1) but caps it at 8.  The 3.51 HAL (HalReportResourceUsage) then scans the
 * PCI-to-PCI bridges on those buses and, for a bus-master bridge whose
 * secondary bus has no bus handler, raises the count to that secondary bus
 * number -- not past it -- and scans again, forever: the hang after
 * "1 System Processor" on the X470, whose GPP bridges lead to buses >= 8
 * (QEMU q35 + 12 pcie-root-ports under OVMF + CSMWrap hangs the same way).
 * When the PCI BIOS reports a last bus >= 8, this MBR hooks INT 1Ah and turns
 * B101h into the unsupported B1FFh (AH = 81h, CF = 1): NTDETECT then records
 * no PCI bus and the HAL sets up none.  The USOS NT 3.51 drivers (AHCINT,
 * usosrst, usosusb) reach PCI configuration space through ports CF8h/CFCh
 * themselves.  With a last bus <= 7 every bridge lies below the count
 * NTDETECT reports and nothing is hooked (Setup VM, small QEMU machines).
 * Native NT 4.0 (docs/nt-native-plan.md) takes the same MBR and hook sector
 * with bit 0 of the sector's options byte (offset 509) set: the PCI BIOS
 * stays visible.  The NT 4.0 HAL has no such bridge loop (the installed NT
 * 4.0 runs on the X470 with every bus) and its PCI bus handler is what the
 * NT 4.0 AHCINT build and the display path rely on.
 *
 * RAM cap: byte 508 of the hook sector (HOOK_RAM_CAP) is a RAM limit in
 * 16 MiB units, 0 = none.  E820 RAM entries that start at or above it become
 * the F0000-FFFFF copy, the others end at it; AH=88h / AX=E801h report at
 * most (cap - 16 MiB) above 16 MiB.  Native NT 3.5 gets 8 (128 MiB): its
 * kernel loses the boot disk (0x7B, C0000034) with more than 128 MiB
 * (docs/nt35-2026-10-09.md: 64 / 128 MiB boot, 256 MiB / 2 GiB stop; 2 GiB
 * with BOOT.INI /MAXMEM=128 boots), and its text-mode SETUPLDR ignores
 * /MAXMEM.  The 3.5 SETUPLDR sizes memory with AH=88h + AX=E801h and with
 * E820 (both are covered).  Native NT 3.51 gets 64 (1024 MiB): text mode
 * writes Setup's BOOT.INI entry without /MAXMEM and its memory manager
 * stopped with 0x0A (working-set list growth) on 3 GB during GUI Setup
 * (X470 B261029-161430).  NT 4.0 keeps the byte 0.
 *
 * CMOS century: the pre-ACPI x86 HALs (NT 3.x, NT 4.0 hal.dll) read the
 * century from CMOS 32h only when the classic checksum (bytes 10h-2Dh in
 * 2Eh/2Fh) matches; otherwise (a "PS/1") from 37h.  CSMWrap rewrites the
 * memory size bytes 15h-18h without the checksum, so on the X470 the HAL
 * took 37h (00h) and HalQueryRealTimeClock returned Year = 26: the system
 * time was invalid (event log 1970/2033, Winlogon "Invalid System Time",
 * nt351fresh2 2026-10-29; usosrst RtcDiag: CMOS 32h = 20h, HAL year 26).
 * When CMOS 32h holds a BCD century (19h-21h) and 37h is unused (00h or
 * FFh), this MBR copies the century to 37h -- the byte the same HAL writes
 * whenever the system time is set.
 *
 * E820 record: every boot writes the firmware's E820 map (CSMWrap/SeaBIOS,
 * before the hook) to disk sector 2 (unused, zeroed by nt4_csmwrap_target.sh;
 * the partition starts at 63): up to 25 entries of 20 bytes, zero-filled
 * behind the last one, "E8" in bytes 510-511.  Read offline, never shown;
 * what the loader saw follows from it through the (tested) hook rules.
 *
 * Bus-master quiesce: sector 3 ("Q3" in its last two bytes, the .quiesce
 * section, nt3-e820-quiesce-512.bin) is read to 0000:7C00 and called
 * right before the active partition's boot sector.  With bit 1 of the hook
 * sector's options byte (OPT_QUIESCE, set by nt4_csmwrap_target.sh for native
 * NT 3.x) it clears PCI Bus Master Enable on every network controller (class
 * 02h) through CF8h/CFCh.  A warm reset (HAL keyboard-controller reset after
 * a bugcheck or a restart) does not necessarily reset the PCIe devices, and
 * neither the AMI firmware nor SeaBIOS (CSMWrap) touches the Intel I211 when
 * no PXE boot runs: a NIC whose receive ring the last NT boot programmed
 * could keep writing frames into memory the next NT boot's loader and kernel
 * reuse until usosnet351n resets the chip (late, as a network driver).  The
 * xHCI controllers are left alone: SeaBIOS resets and drives them (USB
 * keyboard in the NTLDR menu, USB disks behind INT 13h) and usosusb halts and
 * resets each one before it programs it.  Without the sector, the signature
 * or the option bit nothing changes.
 *
 * Shutdown log (with the same sector and option bit): disk sector 4 (unused,
 * before the partition at 63) records how each boot ended, without any user
 * action.  Layout: "USOSSHUT" at 0, the boot count at 8 (DWORD), the trail at
 * 16 (32 ASCII stage letters), stage times at 48 (8 WORDs, seconds since
 * usosrst loaded), then 7 history slots of 64 bytes at 64..511 (slot 1 = the
 * previous boot, each one a copy of bytes 0..63).  At every boot the quiesce
 * code moves the current record into slot 1 (the oldest slot drops out),
 * increments the count and starts a new trail "B".  usosrst (NT 3.51 build)
 * appends its stage letters while Windows runs and shuts down; see
 * tools/w2k/usosrst/src/usosrst.c.  A sector that is neither zero nor a log
 * is never written.  CMOS bytes were not used: the free-looking ones are
 * firmware-owned or checksummed on the X470, and CSMWrap re-arms the RTC
 * alarm bytes at every start (docs/dos-mouse-2026-10-18.md).
 */
.intel_syntax noprefix
.code16
.section .text
.global nt3_e820_mbr_start

.equ RELOC_BASE,      0x0600
.equ PART_TABLE_OFF,  446
.equ VBR_LOAD,        0x7C00
/* Resident layout (sector 1 at the INT 12h top, segment = CS of the hooks):
   0 = INT 15h handler, H1A = INT 1Ah handler, then the two old vectors. */
.equ H1A,             (hook_1a - hook_start)
.equ OLD15,           (hook_end - hook_start)
.equ OLD1A,           (hook_end - hook_start) + 4
/* Options byte of the hook sector (after the code, before "U3"); the target
   script sets it per system (nt4_csmwrap_target.sh). */
.equ HOOK_OPTIONS,    509
.equ OPT_KEEP_PCI_BIOS, 1
.equ OPT_QUIESCE,     2
/* NT 3.1 text-mode key answerer (sector 5, "K3", see the .keys section). */
.equ OPT_KEYS31,      4
.equ KEYS_LBA,        5
.equ KEYS_AT,         0x200
/* Bus-master quiesce sector (see the header). */
.equ QUIESCE_LBA,     3
/* Shutdown log sector and its buffer (the E820 buffer, free by then). */
.equ SL_LBA,          4
.equ SL_BUF,          0x1000
/* RAM cap in 16 MiB units (0 = none), read by the resident hook as cs:[508]. */
.equ HOOK_RAM_CAP,    508
/* E820 record buffer (two sectors) and the sectors it goes to. */
.equ E820_BUF,        0x1000
.equ E820_LBA,        2
.equ E820_MAX,        25

nt3_e820_mbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld

    /* BP keeps the boot drive (INT 1Ah B101h returns EDX = "PCI "). */
    mov bp, dx

    mov si, sp
    mov di, RELOC_BASE
    mov cx, 256
    rep movsw
    .byte 0xEA
    .word RELOC_BASE + (relocated - nt3_e820_mbr_start)
    .word 0x0000

relocated:
    /* CMOS century 32h -> 37h for the pre-ACPI HAL (see the header). */
    mov al, 0x32
    out 0x70, al
    in al, 0x71
    mov ah, al
    cmp al, 0x19
    je 1f
    sub al, 0x20
    cmp al, 1
    ja 2f
1:
    mov al, 0x37
    out 0x70, al
    in al, 0x71
    inc al                                 /* FFh -> 0, 00h -> 1 */
    cmp al, 1
    ja 2f
    mov al, 0x37
    out 0x70, al
    mov al, ah
    out 0x71, al
2:
    /* E820 record (see the header): the firmware map to sector 2. */
    mov di, E820_BUF
    push di
    mov cx, 256
    xor ax, ax
    rep stosw
    mov word ptr [E820_BUF + 510], 0x3845
    pop di
    xor ebx, ebx
    mov si, E820_MAX
4:
    mov eax, 0xE820
    mov ecx, 20
    mov edx, 0x534D4150
    int 0x15
    jc 5f
    add di, 20
    test ebx, ebx
    jz 5f
    dec si
    jnz 4b
5:
    mov cx, 0x4300
    mov eax, E820_LBA
    mov bx, E820_BUF
    call disk_io

    /* Take 1 KiB from the top of conventional memory for the hooks and read
       them there (sector 1, "U3" at its end; without it no hooks). */
    dec word ptr [0x0413]
    mov ax, word ptr [0x0413]
    shl ax, 6
    mov es, ax
    xor bx, bx
    mov eax, 1
    call read_sector
    jc 2f
    cmp word ptr es:[510], 0x3355
    je 3f
2:
    inc word ptr [0x0413]
    jmp boot_partition
3:
    mov eax, dword ptr [0x15 * 4]
    mov dword ptr es:[OLD15], eax
    cli
    /* FS: flat 4 GiB limit (unreal mode), then the HPET general config. */
    .byte 0x0F, 0x01, 0x16                 /* lgdt [gdtr] (relocated) */
    .word RELOC_BASE + (gdtr - nt3_e820_mbr_start)
    mov eax, cr0
    inc ax
    mov cr0, eax
    push 8
    pop fs
    dec ax
    mov cr0, eax
    mov ebx, 0xFED00000
    mov eax, dword ptr fs:[ebx]
    inc eax
    jz 1f
#ifdef NT3_HPET_SET_LEGACY
    or dword ptr fs:[ebx + 0x10], 3
#else
    and dword ptr fs:[ebx + 0x10], 0xFFFFFFFD
#endif
1:
    and word ptr [0x15 * 4], 0
    mov word ptr [0x15 * 4 + 2], es
    sti

    /* PCI BIOS last bus >= 8: hide B101h from NTDETECT (see above),
       unless the hook sector's options byte keeps the PCI BIOS. */
    test byte ptr es:[HOOK_OPTIONS], OPT_KEEP_PCI_BIOS
    jnz boot_partition
    mov ax, 0xB101
    int 0x1A
    jc boot_partition
    cmp cl, 8
    jb boot_partition
    mov eax, dword ptr [0x1A * 4]
    mov dword ptr es:[OLD1A], eax
    mov word ptr [0x1A * 4], offset H1A
    mov word ptr [0x1A * 4 + 2], es

boot_partition:
    push ds
    pop es

    /* Bus-master quiesce (sector 3, "Q3"; see the header). */
    xor eax, eax
    mov al, QUIESCE_LBA
    mov bx, VBR_LOAD
    call read_sector
    cmp word ptr [VBR_LOAD + 510], 0x3351
    jne 1f
    /* near call to 0000:7C00 (CS = 0; this code runs at RELOC_BASE but is
       linked at 0x7C00) */
    .byte 0xE8
    .word VBR_LOAD - RELOC_BASE - (quiesce_back - nt3_e820_mbr_start)
quiesce_back:
1:

    mov si, RELOC_BASE + PART_TABLE_OFF
    mov cx, 4
find_active:
    cmp byte ptr [si], 0x80
    je active_found
    add si, 16
    loop find_active
    jmp boot_error

active_found:
    mov eax, dword ptr [si + 8]
    /* BX = VBR_LOAD still (quiesce read above; read_sector and the quiesce
       code keep it) */
    call read_sector
    jc boot_error

    /* Same fail-safe heads correction as xp_geometry_fix_mbr.S. */
    mov dx, bp
    mov ah, 0x08
    int 0x13
    jc geometry_fallback
    mov al, cl
    and al, 0x3F
    jz geometry_fallback
    cmp byte ptr [VBR_LOAD + 0x19], 0
    jne geometry_fallback
    cmp al, byte ptr [VBR_LOAD + 0x18]
    jne geometry_fallback
    test dh, dh
    jz geometry_fallback
    cmp dh, 254
    ja geometry_fallback
    /* AH = 0 after a successful AH=08h. */
    mov al, dh
    inc ax
    mov word ptr [VBR_LOAD + 0x1A], ax

geometry_fallback:
    mov dx, bp
    .byte 0xEA
    .word VBR_LOAD
    .word 0x0000

boot_error:
    cli
1:
    hlt
    jmp 1b

/* One sector of LBA EAX to ES:BX (INT 13h AH=42h, packet on the stack,
   drive in BP). CF = error.  disk_io: AX = CX (4300h writes ES:BX). */
read_sector:
    mov cx, 0x4200
disk_io:
    .byte 0x66, 0x6A, 0x00                 /* push dword 0 (LBA high) */
    push eax
    push es
    push bx
    .byte 0x6A, 0x01                       /* push word 1 (sectors) */
    .byte 0x6A, 0x10                       /* push word 10h (size) */
    mov si, sp
    mov dx, bp
    mov ax, cx
    int 0x13
    lea sp, [si + 16]
    ret

/* GDT for the unreal-mode FS: the base points 8 bytes before the flat data
   descriptor, so the (never loaded) null descriptor is the code above. */
gdtr:
    .word 15
    .long RELOC_BASE + (gdt_flat - nt3_e820_mbr_start) - 8
gdt_flat:
    .byte 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00

/* Resident part: sector 1, read to (INT 12h top):0000; INT 15h handler at 0. */
.section .hook, "ax"
.global hook_start
hook_start:
    cmp ax, 0xE820
    je 2f
    cmp ah, 0x88
    je mem_sizes
    cmp ax, 0xE801
    je mem_sizes
9:
    .byte 0x2E, 0xFF, 0x2E                 /* jmp far cs:[OLD15] (m16:16) */
    .word OLD15
8:
    or byte ptr [bp + 6], 0x01
    pop bp
    iret
2:
    pushf
    .byte 0x2E, 0xFF, 0x1E                 /* call far cs:[OLD15] (m16:16) */
    .word OLD15
    push bp
    mov bp, sp
    jc 8b
    push eax
    cmp dword ptr es:[di + 4], 0
    jne 6f
    cmp dword ptr es:[di + 16], 1
    je 4f
    /* Non-RAM: kept only when it ends at or below A0000h (EBDA). */
    cmp dword ptr es:[di + 12], 0
    jne 6f
    mov eax, dword ptr es:[di]
    add eax, dword ptr es:[di + 8]
    jc 6f
    cmp eax, 0xA0000
    jbe 7f
    jmp 6f
4:
    /* RAM: clip at 4 GiB, end the low entry below the hook. */
    cmp dword ptr es:[di + 12], 0
    jne 5f
    mov eax, dword ptr es:[di]
    add eax, dword ptr es:[di + 8]
    jnc 3f
5:
    mov eax, dword ptr es:[di]
    neg eax
    mov dword ptr es:[di + 8], eax
    and dword ptr es:[di + 12], 0
3:
    /* RAM cap (HOOK_RAM_CAP, 16 MiB units): at or above it -> ROM copy,
       across it -> ends at it.  The entry lies below 4 GiB here. */
    movzx eax, byte ptr cs:[HOOK_RAM_CAP]
    shl eax, 24
    jz 10f
    sub eax, dword ptr es:[di]
    jbe 6f
    cmp dword ptr es:[di + 8], eax
    jbe 10f
    mov dword ptr es:[di + 8], eax
10:
    cmp dword ptr es:[di], 0
    jne 7f
    /* The hook segment (CS) starts at the INT 12h top. */
    xor eax, eax
    mov ax, cs
    shl eax, 4
    cmp dword ptr es:[di + 8], eax
    jbe 7f
    mov dword ptr es:[di + 8], eax
    jmp 7f
6:
    /* A copy of the BIOS ROM range: F0000h, length 10000h, type 2. */
    xor eax, eax
    mov dword ptr es:[di + 4], eax
    mov dword ptr es:[di + 12], eax
    mov al, 2
    mov dword ptr es:[di + 16], eax
    shl eax, 15
    mov dword ptr es:[di + 8], eax
    imul eax, eax, 15
    mov dword ptr es:[di], eax
7:
    pop eax
    and byte ptr [bp + 6], 0xFE
    pop bp
    iret

/* AH=88h / AX=E801h (see the header): low = the BIOS E801h AX (KiB 1-16
   MiB), high = 64 KiB blocks of the E820 RAM entry that covers 16 MiB.
   Without a BIOS E801h the call goes to the BIOS unchanged. */
mem_sizes:
    push bp
    mov bp, sp
    push ax                                /* [bp - 2]: the function */
    push 0                                 /* [bp - 4]: high blocks */
    push 0                                 /* [bp - 6]: low KiB */
    push si
    push di
    push es
    push ebx
    push ecx
    push edx                               /* [bp - 24] */
    sub sp, 20                             /* E820 entry */
    mov di, sp
    push ss
    pop es
    mov ax, 0xE801
    pushf
    .byte 0x2E, 0xFF, 0x1E                 /* call far cs:[OLD15] (m16:16) */
    .word OLD15
    jc 5f
    mov word ptr [bp - 6], ax
    xor ebx, ebx
1:
    mov eax, 0xE820
    mov ecx, 20
    mov edx, 0x534D4150
    pushf
    .byte 0x2E, 0xFF, 0x1E                 /* call far cs:[OLD15] (m16:16) */
    .word OLD15
    jc 4f
    cmp dword ptr es:[di + 16], 1
    jne 3f
    cmp dword ptr es:[di + 4], 0
    jne 3f
    mov eax, dword ptr es:[di]
    cmp eax, 0x1000000
    ja 3f
    mov edx, dword ptr es:[di + 12]
    add eax, dword ptr es:[di + 8]
    adc edx, 0
    jnz 2f
    sub eax, 0x1000000
    jbe 3f
    shr eax, 16
    jmp 6f
2:
    mov ax, 0xFF00                         /* up to 4 GiB */
6:
    mov word ptr [bp - 4], ax
3:
    test ebx, ebx
    jnz 1b
4:
    /* RAM cap: at most (cap - 16 MiB) / 64 KiB blocks above 16 MiB. */
    mov ah, byte ptr cs:[HOOK_RAM_CAP]
    sub ah, 1
    jc 11f
    mov al, 0
    cmp word ptr [bp - 4], ax
    jbe 11f
    mov word ptr [bp - 4], ax
11:
    clc
5:
    lea sp, [bp - 24]
    pop edx
    pop ecx
    pop ebx
    pop es
    pop di
    pop si
    jc 7f
    mov ax, word ptr [bp - 6]
    cmp byte ptr [bp - 1], 0x88
    je 6f
    mov cx, ax
    mov bx, word ptr [bp - 4]
    mov dx, bx
6:
    mov sp, bp
    and byte ptr [bp + 6], 0xFE
    pop bp
    iret
7:
    mov ax, word ptr [bp - 2]
    mov sp, bp
    pop bp
    jmp 9b

/* INT 1Ah: B101h becomes the unsupported B1FFh (AH = 81h, CF = 1). */
hook_1a:
    cmp ax, 0xB101
    jne 1f
    mov al, 0xFF
1:
    .byte 0x2E, 0xFF, 0x2E                 /* jmp far cs:[OLD1A] (m16:16) */
    .word OLD1A
hook_end:

/* Bus-master quiesce: sector 3, read to 0000:7C00 and near-called from the
   MBR (CS = DS = ES = 0, BP = boot drive; everything is preserved).  Only
   relative jumps: the code runs wherever it is loaded. */
.section .quiesce, "ax"
.global quiesce_start
quiesce_start:
    pushad
    push es
    /* Only with the hook sector ("U3" at the INT 12h top) and its option bit. */
    mov ax, word ptr [0x0413]
    shl ax, 6
    mov es, ax
    cmp word ptr es:[510], 0x3355
    jne 9f
    /* Native NT 3.1: the text-mode key answerer (sector 5, "K3") into the
       second half of the reserved 1 KiB, INT 16h pointed at it. */
    test byte ptr es:[HOOK_OPTIONS], OPT_KEYS31
    jz 8f
    mov bx, KEYS_AT
    mov eax, KEYS_LBA
    mov cx, 0x4200
    .byte 0xE8                             /* near call sl_disk (16-bit) */
    .word sl_disk - (. + 2)
    jc 8f
    cmp word ptr es:[KEYS_AT + 510], 0x334B /* "K3" */
    jne 8f
    mov eax, dword ptr [0x16 * 4]
    mov dword ptr es:[k_old16], eax
    cli
    mov word ptr [0x16 * 4], KEYS_AT
    mov word ptr [0x16 * 4 + 2], es
    sti
8:
    test byte ptr es:[HOOK_OPTIONS], OPT_QUIESCE
    jz 9f
    /* Every bus/device/function, from FF:1F.7 down to 00:00.0. */
    mov ebx, 0x80FFFF00
    mov dx, 0x0CF8
1:
    mov eax, ebx
    mov dl, 0xF8
    out dx, eax
    mov dl, 0xFC
    in eax, dx
    inc eax                                /* no function: FFFFFFFFh */
    jz 2f
    lea eax, [ebx + 8]
    mov dl, 0xF8
    out dx, eax
    mov dl, 0xFF                           /* register 0Bh: base class */
    in al, dx
    cmp al, 0x02                           /* network controller */
    jne 2f
    lea eax, [ebx + 4]
    mov dl, 0xF8
    out dx, eax
    mov dl, 0xFC
    in al, dx
    and al, 0xFB                           /* command bit 2: Bus Master Enable */
    out dx, al
2:
    sub ebx, 0x100
    js 1b
    /* CF8h back to 0 (no configuration cycle selected). */
    xor eax, eax
    mov dl, 0xF8
    out dx, eax

    /* Shutdown log (sector 4, see the header): the record of the boot that
       just ended moves into the history, the new boot starts with "B". */
    xor ax, ax
    mov es, ax
    mov bx, SL_BUF
    mov eax, SL_LBA
    mov cx, 0x4200
    .byte 0xE8                             /* near call sl_disk (16-bit) */
    .word sl_disk - (. + 2)
    jc 9f
    cmp dword ptr [SL_BUF], 0x534F5355     /* "USOS" */
    jne 3f
    cmp dword ptr [SL_BUF + 4], 0x54554853 /* "SHUT" */
    je 4f
3:
    /* Only a zeroed sector becomes a log; anything else is never touched. */
    mov di, SL_BUF
    mov cx, 256
    xor ax, ax
    repe scasw
    jne 9f
    mov dword ptr [SL_BUF], 0x534F5355
    mov dword ptr [SL_BUF + 4], 0x54554853
4:
    /* History: slots 1-6 (64..447) -> 2-7 (128..511), current -> slot 1. */
    std
    mov si, SL_BUF + 447
    mov di, SL_BUF + 511
    mov cx, 384
    rep movsb
    cld
    mov si, SL_BUF
    mov di, SL_BUF + 64
    mov cx, 32
    rep movsw
    /* New current record: boot count + 1, trail "B", times cleared. */
    inc dword ptr [SL_BUF + 8]
    mov di, SL_BUF + 16
    mov cx, 24
    xor ax, ax
    rep stosw
    mov byte ptr [SL_BUF + 16], 0x42       /* "B" */
    mov eax, SL_LBA
    mov cx, 0x4300
    .byte 0xE8                             /* near call sl_disk (16-bit) */
    .word sl_disk - (. + 2)
9:
    pop es
    popad
    .byte 0xC3                             /* ret (16-bit near; "ret" assembles as 66 C3) */

/* One sector of LBA EAX to / from ES:BX (CX = 4200h read, 4300h write;
   INT 13h extensions, drive in BP). CF = error. */
sl_disk:
    .byte 0x66, 0x6A, 0x00                 /* push dword 0 (LBA high) */
    push eax
    push es
    push bx
    .byte 0x6A, 0x01                       /* push word 1 (sectors) */
    .byte 0x6A, 0x10                       /* push word 10h (size) */
    mov si, sp
    mov dx, bp
    mov ax, cx
    int 0x13
    lea sp, [si + 16]
    .byte 0xC3
    .org 510
    .byte 0x51, 0x33                       /* "Q3" */


/* NT 3.1 text-mode key answerer: sector 5 ("K3"), read by the quiesce code
 * to (INT 12h top):0200h when bit 2 of the hook options byte (OPT_KEYS31,
 * native NT 3.1 only) is set, and hooked into INT 16h.  NT 3.1 text-mode
 * Setup (SETUPAPP.EXE inside SETUPLDR) has no answer file; it reads its
 * keys through BIOS INT 16h.  On every INT 16h read / peek the answerer
 * looks at the 80x25 text page (B800:0000) for the pages of the express path
 * that take ENTER -- the rules the install VM's runner used (nt31_vm_tick,
 * nt4_qemu_install.sh): Welcome, Express Setup, the partition C:, keep the
 * file system, the \WINNT location -- and returns ENTER (1C0Dh) once per
 * page; the same page gets ENTER again only after about 30 s (TSC high
 * dword +24).  The final page ("Setup has successfully configured your
 * computer ... Press CTRL+ALT+DELETE") is answered with a full reset (CF9h,
 * then the keyboard controller).  Any other page (errors included) gets
 * nothing: a real key still goes through, the BIOS calls are passed on
 * unchanged.  Later boots (NTLDR menu, the installed system) show none of
 * these texts.
 */
.section .keys, "ax"
.global keys_start
keys_start:
    cmp ah, 0x01
    je k_peek
    cmp ah, 0x11
    je k_peek
    cmp ah, 0x00
    je k_read
    cmp ah, 0x10
    je k_read
k_chain:
    .byte 0x2E, 0xFF, 0x2E                 /* jmp far cs:[k_old16] (m16:16) */
    .word k_old16
k_peek:
    cmp byte ptr cs:[k_pending], 0
    jne 1f
    .byte 0xE8                             /* near call k_check */
    .word k_check - (. + 2)
    jnc k_chain
    mov byte ptr cs:[k_pending], 1
1:
    mov ax, 0x1C0D
    push bp
    mov bp, sp
    and byte ptr [bp + 6], 0xBF            /* ZF = 0: a key is waiting */
    pop bp
    iret
k_read:
    sti
1:
    cmp byte ptr cs:[k_pending], 0
    jne 2f
    push ax
    inc ah                                 /* 00h -> 01h, 10h -> 11h */
    pushf
    .byte 0x2E, 0xFF, 0x1E                 /* call far cs:[k_old16] (m16:16) */
    .word k_old16
    pop ax
    jnz k_chain                            /* a real key: the BIOS reads it */
    .byte 0xE8                             /* near call k_check */
    .word k_check - (. + 2)
    jnc 1b
2:
    mov byte ptr cs:[k_pending], 0
    mov ax, 0x1C0D
    iret

/* CF = 1: answer ENTER now (the final page resets instead).  Keeps every
   register. */
k_check:
    pushad
    push ds
    push 0xB800
    pop ds
    mov si, offset k_pages
    mov cl, 1
k_next:
    cmp byte ptr cs:[si], 0
    je k_none
    xor bp, bp                             /* start offset on the page */
k_scan:
    mov bx, si
    mov di, bp
k_cmp:
    mov al, byte ptr cs:[bx]
    test al, al
    jz k_found
    cmp di, 4000
    jae k_skip
    cmp al, byte ptr [di]
    jne k_mis
    inc bx
    add di, 2
    jmp k_cmp
k_mis:
    add bp, 2
    cmp bp, 4000
    jb k_scan
k_skip:
    inc si
    cmp byte ptr cs:[si - 1], 0
    jne k_skip
    inc cl
    jmp k_next
k_found:
    rdtsc
    cmp cl, byte ptr cs:[k_page]
    jne 1f
    mov eax, edx
    sub eax, dword ptr cs:[k_tsc]
    cmp eax, 24
    jb k_none
1:
    mov byte ptr cs:[k_page], cl
    mov dword ptr cs:[k_tsc], edx
    cmp cl, 1
    je k_reset
    pop ds
    popad
    stc
    .byte 0xC3                             /* ret (16-bit near) */
k_none:
    pop ds
    popad
    clc
    .byte 0xC3
k_reset:
    cli
    mov dx, 0x0CF9
    mov al, 0x02
    out dx, al
    mov al, 0x06
    out dx, al
    mov al, 0xFE
    out 0x64, al
1:
    hlt
    jmp 1b

/* The pages, in this order (1 = the final page); 0 ends the table. */
k_pages:
    .asciz "successfully configured your computer"
    .asciz "Welcome to Setup."
    .asciz "Express Setup (recommended)"
    .asciz "select the partition where"
    .asciz "select a file system option"
    .asciz "Choose the location"
    .byte 0
k_old16:
    .long 0
k_tsc:
    .long 0
k_page:
    .byte 0
k_pending:
    .byte 0
    .org 510
    .byte 0x4B, 0x33                       /* "K3" */
