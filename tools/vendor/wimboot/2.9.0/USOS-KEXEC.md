# USOS kexec variant

The entry shim restores VGA text mode (INT 10h, AX=0003) after restoring the
firmware interrupt environment. USOS previously left its VESA framebuffer
active, which produced unreadable BIOS output on the physical MS-7100.
General and segment registers are preserved; IF and DF are cleared before
resuming the original setup prefix. This repairs the display handoff; it does
not by itself establish that Windows Setup completes on that machine.

The upstream `wimboot` file in this directory is unchanged. Its corresponding
upstream source and GPL-2.0-or-later license are supplied alongside it.

USOS generates a separate `wimboot-kexec` during the micro-Linux build using
`tools/wimboot_kexec.py` (USOS modification, 2026-09-10). This variant restores
the legacy PIC vectors and PIT before entering the original BIOS setup code.
Linux kexec does not restore the firmware's interrupt environment by itself.

The kexec variant also handles INT13 AH=08 for existing hard disks. The
underlying firmware query may fail or hang after kexec, so the handler returns
a compatibility CHS envelope and the BIOS data area's drive count, including
wimboot's virtual RAM disk. This bootstrap uses linear/EDD I/O; AH=48 still
returns the real extended parameters through firmware. AH=08 queries for
floppies or out-of-range drives report unavailable during this RAM bootstrap;
all other functions, including actual I/O, retain the original BIOS path. No physical
disk or partition table is changed, and drives keep
their original numbers. The lasting wrapper is copied into the reserved
runtime prefix at physical 0x204a0; the original vector lives at 0x204f0.
The full 512-byte working block is initialized, including code, saved-vector
storage and padding. A partial code-only copy did not pass the normal BIOS
start test. These addresses are within the pinned linker's `_start`/prefix
region, below bss16 and payload. The outer interrupt frame retains its IF bit.

The modification occupies verified zero padding in the Linux setup portion
and changes its initial far-return target. The protected-mode payload is
unchanged. The generator rejects any upstream hash other than the pinned
2.9.0 binary. The generated variant remains GPL-2.0-or-later; the generator
provides the full source of the modification.
