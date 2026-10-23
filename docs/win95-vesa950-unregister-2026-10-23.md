# Windows 95 SETUP950 VESA unregister workaround

The installed RTM guest reaches its VESA 1024×768 desktop, but an actual
warm restart hangs inside `CallVDD(VDD_DRIVER_UNREGISTER = 0x81)` in the
published MIT vmdisp9x 119b `Disable`. This branch prepares a narrowly
pinned four-byte derivative on the new target copy, retaining the released
NE ABI. Other source versions and the shared vendor payload are unchanged.

`w9x_vesa950_prepare` requires the exact input SHA256, writes a temporary
copy, substitutes four NOPs for `FF 1E B2 07` at file offset7873, verifies
the complete output SHA256, appends a modification notice alongside the
existing MIT notice, and then replaces the staged copy. Unknown inputs or
an occupied temporary name stop target preparation. The helper is included
in the micro-Linux initrd and called only for `95:4 0 0 950` after copying
the payload. Existing source archives and license distribution stay intact.

Source-level equivalent: omit the single `CallVDD(VDD_DRIVER_UNREGISTER)`
in `enable.c::Disable`. Preserve the surrounding EAX/EBX wrapper,
`PhysicalDisable`, BIOS INT10 mode3 and `UnhookInt2Fh`. The release build is
preserved because an independent local rebuild fell back to VGA; that
rebuild cannot substantiate this VESA runtime change.

Input SHA256: `2e661f2c17b5e7d6bcaa2c93cf3f79d38e70ab901850d7e5e3d26658aa697ddc`.
Output SHA256: `3658d7c3c3314f50ac6f05a034109dd88993433b6d1b216f07297f96c66bdd67`.
No proprietary Microsoft binary is patched or added to the repository.

## Evidence and scope

- R137: an ABI-preserving derivative of the published driver logged cold
  Enable twice, then warm Disable stages VD0, VD1 and VD2. It never logged
  VD3, placing the hang in the unregister call, before BIOS mode3. After a
  concrete failed-restart image, one diagnosis following >=300 seconds of
  native frame-event quiet confirmed the failure. The guest was retained.
- R139: original 950 DOS copied only the diagnostic derivative onto a new
  overlay of installed R128; exit85/3.842s. Entire hives, SYSTEM.INI and all
  other checked core files were identical. R140 strict readonly fsck PASS.
- R141: the same trace derivative with only this four-byte call skipped
  cold-booted 1024×768, completed the selected warm restart, returned to the
  VESA login and second desktop at 1024×768, then powered off normally.
  All six Disable markers completed; new Enable markers appeared after
  restart. QEMU exit0/458.79s; source images unchanged, PS/2 counters zero.
  No Setup, USB or network test was repeated.
- R143/R144: original 950 DOS installed the exact trace-free recipe artifact;
  entire hives/INI/other core unchanged, exit85/1.84s, readonly strict fsck PASS.
- R145: that exact output cold-booted VESA1024×768, completed the selected warm
  restart, returned to login and the second desktop1024×768, then powered off
  normally. QEMU exit0/644.03s; source images unchanged and PS/2 counters zero.
  No USB/network test or Setup was repeated. No final fresh normal install
  is claimed by this branch.

This is a compatibility workaround, not proof of the VDD implementation's
internal defect. RTM was tested in QEMU; OSR1 and X470 need independent
runtime evidence. Runtime display-driver replacement/mode changes have not
been validated, and omitting unregister may affect VDD lifecycle state.
The separate late-display-binding issue is not fixed here: Setup can leave
the active PCI device on `Display\\0001` VGA while VESA exists in class0000.
Keep this branch for review; no merge, push or deployment was performed.
