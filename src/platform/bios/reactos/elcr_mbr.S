/*
 * ELCR MBR (docs/custom-os-2026-10-11.md, ReactOS behind CSMWrap).
 *
 * CSMWrap's SeaBIOS runs in CSM mode and skips its own PCI setup, so nobody
 * programs the 8259 Edge/Level Control Registers (ports 4D0h/4D1h): after
 * OVMF they are 00/00, every PCI interrupt is treated as edge-triggered.
 * An OS on the 8259 that trusts the ELCR (ReactOS: HalpInitializePICs reads
 * it) then misses the level-triggered PCI interrupts of its disk controller
 * and stops with 0x7B. A real BIOS (and SeaBIOS outside CSM mode) marks every
 * IRQ used by a PCI interrupt pin as level-triggered.
 *
 * This sector does that and nothing else:
 *   1. scans PCI configuration space (mechanism #1, all buses/devices/
 *      functions), and for every function with an interrupt pin (3Dh 1..4)
 *      and an interrupt line 3..15 (3Ch) sets that IRQ's ELCR bit (never
 *      IRQ 0, 1, 2, 8, 13: edge only);
 *   2. loads the image's own MBR, kept unchanged at LBA 1, to 0000:7C00 and
 *      jumps to it with the BIOS drive number in DL.
 * Bytes 440..511 (disk signature, partition table, 55AA) stay those of the
 * image. Code only: at most 440 bytes.
 */
.intel_syntax noprefix
.code16
.section .text
.global elcr_mbr_start

.equ RELOC_BASE, 0x0600
.equ LOAD_ADDR,  0x7C00

elcr_mbr_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld
    mov si, 0x7C00
    mov di, RELOC_BASE
    mov cx, 256
    rep movsw
    .byte 0xEA
    .word RELOC_BASE + (relocated - elcr_mbr_start)
    .word 0x0000

relocated:
    push dx
    xor bp, bp                     /* ELCR bits collected here */
    mov ebx, 0x80000000            /* bus 0, device 0, function 0 */
scan:
    mov eax, ebx
    mov dx, 0x0CF8
    out dx, eax
    mov dl, 0xFC
    in eax, dx
    cmp ax, 0xFFFF
    je next
    lea eax, [ebx + 0x3C]
    mov dl, 0xF8
    out dx, eax
    mov dl, 0xFC
    in eax, dx                     /* AL = line, AH = pin */
    dec ah
    cmp ah, 3
    ja next
    cmp al, 15
    ja next
    movzx cx, al
    bts bp, cx
next:
    add ebx, 0x100
    cmp ebx, 0x81000000
    jb scan
    mov dx, 0x0CF8
    xor eax, eax
    out dx, eax
    and bp, 0xDEF8                 /* IRQ 0, 1, 2, 8, 13 stay edge */
    mov ax, bp
    mov bl, ah
    mov dx, 0x04D0
    in al, dx
    or ax, bp                      /* keep bits already set */
    out dx, al
    inc dx
    in al, dx
    or al, bl
    out dx, al

    /* The image's own MBR from LBA 1 (CHS 0/0/2) to 0000:7C00. */
    pop dx
    mov di, 3
load:
    mov ax, 0x0201
    mov bx, LOAD_ADDR
    mov cx, 0x0002
    xor dh, dh
    push dx
    int 0x13
    pop dx
    jnc loaded
    xor ah, ah
    int 0x13
    dec di
    jnz load
    .byte 0xBE                     /* mov si, imm16 */
    .word RELOC_BASE + (msg - elcr_mbr_start)
print:
    lodsb
    test al, al
    jz halt
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp print
halt:
    hlt
    jmp halt
loaded:
    cmp word ptr [LOAD_ADDR + 510], 0xAA55
    jne halt
    .byte 0xEA
    .word LOAD_ADDR
    .word 0x0000

msg:
    .asciz "USOS ELCR MBR: cannot read LBA 1"
