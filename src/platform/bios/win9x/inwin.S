/*
 * INWIN.COM - errorlevel 1 inside Windows (a DOS box), 0 in real-mode DOS.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * DOSMOUSE.BAT (dosmouse.cmd) loads the DOS mouse driver only when this
 * says 0: in a DOS box of Windows 9x a real-mode driver would register its
 * INT 15h C207h handler with SeaBIOS, which keeps one pointer for every VM,
 * and take the BIOS mouse away from USOSMOUS.DRV (docs/dos-mouse-2026-10-18.md).
 * INT 2Fh AX=1600h: AL 00h/80h = no enhanced-mode Windows; anything else
 * (01h/FFh Windows/386 2.x, else the version) = Windows is running.
 */
.intel_syntax noprefix
.code16
.section .text
.global _start
_start:
    mov ax, 0x1600
    int 0x2f
    test al, 0x7f
    mov al, 0
    jz 1f
    mov al, 1
1:  mov ah, 0x4c
    int 0x21
