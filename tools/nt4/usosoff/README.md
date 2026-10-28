# usosoff

Small Win32 console tool for Windows NT 4.0 (i386). USOS runs it at the end of
an unattended NT4 install inside QEMU. QEMU runs with `-no-reboot`, so the guest
reboot ends QEMU.

    usosoff.exe [/r | /s | /p]

`/r` reboots (the default), `/s` shuts down and `/p` powers off. Each one is forced
(`EWX_FORCE`). The tool enables SeShutdownPrivilege and calls `ExitWindowsEx`. If
that fails, it falls back to `ntdll!NtShutdownSystem`. It exits with 0 on success,
1 on a bad argument and 2 when both calls fail.

It does not use the C runtime and has its own entry point. It imports only
kernel32, advapi32 and user32 functions that exist in NT 4.0 RTM.

Build (WDK 7.1 in `tools\WinDDK71` or `%WDKROOT%`):

    tools\nt4\usosoff\build.cmd [workdir]

This writes `bin\i386\usosoff.exe`, marked as PE 4.00 by `tools\nt4\pe_nt4_version.py`.
`tools/tests/test_nt4_usosoff.py` checks the image and its imports.

Licence: GPL-3.0-or-later. Copyright (C) 2026 Maksymilian and the USOS Authors.
