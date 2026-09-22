# XP unified ISO selection and preparation diagnostics

Evidence read from the connected Kingston ESP: the 2026-09-22 00:08 status
stopped at disk-enumeration, uptime 5.87, target unselected. The inventory
contains Intel SSDSC2BW12 as candidate 1 and excludes DataTraveler as the USOS
parent disk. This establishes Linux startup and disk discovery, not that the
menu rendered, received input, or remained alive. No absence of an error file
is treated as proof of process liveness. Identical kernel bytes do not rule out
a firmware-specific graphics/kernel problem.

There is now one windows-xp catalog entry and one ISO directory. BIOS Automatic
keeps xp_staging; UEFI Automatic uses xp_uefi_staging. The UEFI summary launches
the isolated EFI/USOS-XP kernel/initramfs with the selected ISO filename encoded
as hex and ESP identity from usos-device.ini. Per-ISO EFI launchers and their
old directory are no longer used by the menu. UEFI preparation still requires
XP SP3 x86, then the installed XP boots via firmware CSM on MBR. The PAE helper
and the driver overlay remain unchanged. Custom SIF is blocked in the UEFI
summary and runtime; the BIOS path retains its own policy.

The UEFI handoff flushes EFI/USOS-XP/uefi-start.txt at entry and immediately
before StartImage. The latter records kernel load only, not initrd consumption:
the EFI stub loads initrd itself. Linux rotates previous menu diagnostics and
records a fresh boot ID after ESP mount. Before each menu it saves state,
framebuffer/input inventory and dmesg. The renderer flushes events before/after
VT activation, framebuffer opening, initial rendering and input actions.
The wrapper records exit codes and explicit return-to-USOS requests.

VT_WAITACTIVE was an unbounded wait before framebuffer open. It is replaced by
VT_ACTIVATE + VT_GETSTATE and refuses to accept menu input if VT1 activation
cannot be confirmed. Failure to open fb0 is logged, and the text fallback now
explicitly requests KD_TEXT instead of inheriting a previous KD_GRAPHICS state.
These address possible failure paths, not a hardware-confirmed root cause.
No guessed GOP mode, kernel replacement or blind disk selection was introduced.

Build: tools/build_xp_uefi_csm_trial.py --menu-only (UEFI + framebuffer UI + Zig
unit tests), then --ui-only (refresh only the isolated UI overlay).
Short check: tools/tests/check_xp_menu_overlay.py validates packaged renderer,
scripts and menu success/cancel/error behavior in ordinary workspace folders.
Deploy: tools/deploy_xp_uefi_csm_trial.ps1 -UnifiedMenu updates BOOTX64.EFI and
the isolated initramfs/manifest, backing up previous files and available logs.
Production BIOS payload, Vista payload, selected ISO and Intel are not modified.

Hardware follow-up: Windows XP -> original SP3 ISO -> START, CSM enabled.
If no disk menu becomes visible, do not select anything blind. Preserve the
stick's EFI/USOS-XP logs for diagnosis. No VM or E2E is part of this change.
