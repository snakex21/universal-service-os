/* BIOS compatibility bridge for Windows PE started through Linux kexec.
 *
 * kexec provides a Linux boot-params memory map but does not restore a BIOS
 * execution environment.  Some legacy firmware (including MSI MS-7100) can
 * hang on INT 15h,e820 after Linux has run.  This bridge is injected into the
 * unused 0900h..09ffh area of the pinned wimboot setup prefix and copied to
 * 20900h..209ffh before wimboot enters protected mode.
 *
 * INT 15h,e820 is served from the boot-params table supplied to the bzImage
 * setup segment.  If that table is unavailable, e820 fails immediately rather
 * than calling firmware that may no longer be safe.  Physical tracing on the
 * MSI MS-7100 proved that even optional INT 15h services can hang or reset the
 * machine after Linux/kexec.  The direct handoff therefore treats INT 15h as
 * unavailable except for the emulated E820 service and fails every other
 * function immediately with CF set.  A per-image flag can also hide firmware hard disks
 * during the RAM boot so wimboot owns BIOS drive 80h; Windows enumerates the
 * real storage again with its native drivers after WinPE starts.
 */
.intel_syntax noprefix
.section .rodata.windows_kexec_bridge,"a",@progbits
.code16

.set BRIDGE_RUNTIME_SEG, 0x2000
.set BRIDGE_OFFSET,      0x0900
.set E820_HANDLER,       0x0960
.set BRIDGE_DATA,        0x0700
.set BOOTPARAM_E820_NR,  0x01e8
.set BOOTPARAM_E820,     0x02d0
.set BDA_DISK_COUNT,     0x0475

.global windows_kexec_bridge_install
windows_kexec_bridge_install:
    cli
    cld
    pushad
    push ds
    push es

    /* Preserve the setup segment containing the kexec boot parameters. */
    mov dx, cs

    /* Keep the hook after wimboot discards/reuses the Linux setup area. */
    mov ax, cs
    mov ds, ax
    mov ax, BRIDGE_RUNTIME_SEG
    mov es, ax
    mov si, BRIDGE_OFFSET
    mov di, BRIDGE_OFFSET
    mov cx, 0x80
    rep movsw

    xor ax, ax
    mov ds, ax
    mov eax, dword ptr [0x54]
    mov dword ptr es:[BRIDGE_DATA], eax
    mov word ptr es:[BRIDGE_DATA + 4], dx
    mov al, byte ptr cs:[BRIDGE_DATA + 6]
    mov byte ptr es:[BRIDGE_DATA + 6], al

    /* Optional RAM-only mode.  wimboot will increment this from 0 to 1 and
     * therefore create its emulated disk as BIOS drive 80h. */
    test al, al
    jz .keep_disks
    mov byte ptr [BDA_DISK_COUNT], 0
.keep_disks:

    mov word ptr [0x54], E820_HANDLER
    mov word ptr [0x56], BRIDGE_RUNTIME_SEG

    pop es
    pop ds
    popad
    .byte 0xc3 /* 16-bit RET; LLVM Intel syntax may otherwise select 32-bit */

.org 0x60
.int15:
    cmp eax, 0xe820
    jne .unsupported
    cmp edx, 0x534d4150
    jne .unsupported

    push bp
    mov bp, sp
    push ds
    push si
    push di

    mov ax, word ptr cs:[BRIDGE_DATA + 4]
    test ax, ax
    jz .e820_fail
    mov ds, ax
    mov al, byte ptr [BOOTPARAM_E820_NR]
    test al, al
    jz .e820_fail
    cmp ebx, 0x80
    jae .e820_fail
    cmp bl, al
    jae .e820_fail

    /* Entry size in Linux boot_params is 20 bytes. */
    mov si, bx
    shl si, 2
    add si, bx
    shl si, 2
    add si, BOOTPARAM_E820
    mov cx, 10
    rep movsw

    inc ebx
    cmp bl, byte ptr [BOOTPARAM_E820_NR]
    jb .have_next
    xor ebx, ebx
.have_next:
    mov eax, 0x534d4150
    mov ecx, 20
    pop di
    pop si
    pop ds
    and word ptr ss:[bp + 6], 0xfffe
    pop bp
    iret

.e820_fail:
    pop di
    pop si
    pop ds
    or word ptr ss:[bp + 6], 1
    pop bp
    mov ah, 0x86
    iret

.unsupported:
    /* Do not re-enter INT 15h firmware after Linux.  Vista treats unsupported
     * optional services as a normal BIOS capability miss and continues. */
    push bp
    mov bp, sp
    or word ptr ss:[bp + 6], 1
    pop bp
    mov ah, 0x86
    iret

.org 0xff
    .byte 0
.code32
