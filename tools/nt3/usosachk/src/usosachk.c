/*
 * usosachk.c - stand-in for AUTOCHK.EXE during Windows NT 3.51 text-mode
 * Setup in the USOS install VM.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * NT 3.51 text-mode Setup runs autochk.exe from the local source on C:
 * ("Checking drive C:"). In QEMU that run overflows a kernel stack while the
 * HAL resets the display in V86 mode (double fault, STOP 0x7F 8, triple
 * fault; 2026-10-08). This native program ends at once with success, so the
 * check passes quietly and Setup copies it as system32\autochk.exe;
 * nt4_vm_finish (tools/nt4_qemu_install.sh) then puts the CD's real
 * AUTOCHK.EXE (kept as \USOS\NT3\AUTOCHK.EXE) back in place.
 */
typedef long NTSTATUS;

__declspec(dllimport) NTSTATUS __stdcall NtTerminateProcess(void *process, NTSTATUS status);

void __cdecl entry(void *peb)
{
    (void)peb;
    NtTerminateProcess((void *)(long)-1, 0);
    for (;;) {
    }
}
