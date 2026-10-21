# Every USB stick partition on Vista / Server 2008 SP2 x64 (test mode), 2026-10-21

Branch `feat/vista-x64-mpart` (base `feat/vista-x64-nvme` `01389f83`).
Status: **host tests PASS, full build PASS (B261021-163547-BFA844D5
); not run in QEMU; X470 not tested.**

## 1. Problem

Vista x64 on the X470 (CSMWrap path, NVMe or SATA) runs in test-signing mode
(the v11 USB backport and the amd64 usosnvme are test-signed). Plain sticks
work; a multi-partition stick (the USOS stick: ESP + DATA + WORK) shows only
its first partition: Windows before 10 1703 enumerates one partition of a
disk that reports removable media, as on 2000..10 1607 x86
(`docs/usb-multipartition-2026-10-14.md`). The x86 fix, the own GPL disk
class lower filter `usosmpart`, was blocked on x64 NT 6 only by kernel-mode
code signing; with testsigning on it loads when it is test-signed.

## 2. What changes

| Piece | Where | What |
|---|---|---|
| Driver build | `tools/nt/usosmpart/build.cmd nt6x64` -> `bin/NT6/amd64/usosmpart.sys` | the unchanged source, WDK 7.1 `fre x64 WLH` (subsystem 6.0); imports only `ntoskrnl.exe`, the same set as the x86 and WNET builds. `bin/amd64` (WNET, XP x64 / 2003 x64) is unchanged; a rebuild of it gives an identical `.text` |
| 64-bit audit | `src/usosmpart.c` | no change needed: no pointer truncation (SRB / IRP / MDL use native types and `sizeof`), `IoStatus.Information` compared as `ULONG_PTR`, the storage descriptor has no pointer fields (no WOW64 thunk issue), pool buffers are nonpaged and 16-byte aligned, GPT entries are read at power-of-two offsets, LBAs stay 32-bit by design (READ(10), sticks < 2 TiB) |
| Signing | `tools/build_usosnvme_nt6_signed.py` (`arch='amd64'`) | `usosmpart.sys` is embedded-signed with the **same** per-build certificate as the amd64 usosnvme package, in the same session (private key deleted afterwards, checked); no catalog (not a PnP install). Output: `zig-out/windows-source-mount/usosnvme-nt6-amd64/usosmpart.sys` |
| Release package | `tools/build_windows_vista_support.py` | `vista-support.cpio` gets `usosmpart-amd64.sys`; the build refuses a package whose filter is not a signed PE32+ AMD64 image |
| Installed system | `tools/windows_vista_mpart.h` `install_mpart64`, called by `usos-vista-install.exe` after `configure_boot_bios` (testsigning set in the target BCD) and after `install_nvme64` | **CSMWrap path only** (the UEFI path is untouched). File to `System32\drivers\usosmpart.sys` (SHA-256 read-back), SYSTEM backup `USOS\Vista\SYSTEM.before-mpart`, offline SYSTEM (`RegLoadAppKey`): service `usosmpart` Type 1, Start 0, ErrorControl 1, Group "Filter", ImagePath, DisplayName and `usosmpart` appended to the disk class `{4D36E967-...}` `LowerFilters` (REG_MULTI_SZ, kept when already listed), in the Current and Default control sets - the same rows as the x86 `:mpart_reg`. **Not fatal**: any error restores the backup and deletes the file (the stick keeps one volume, as before) |
| OOBE gate | `tools/windows_vista_oobe_gate.c` | unchanged: the filter is a boot-start service, loaded by winload under testsigning; no driver-store staging, so no certificate import is needed (on NVMe targets the gate already imports the same certificate for usosnvme) |

The filter attaches only to disks whose PDO enumerator is `USBSTOR` (every
other disk, the NVMe / SATA boot disk included, builds its stack without it)
and changes `RemovableMedia` only for media with more than one partition;
hot plug, safe removal and the quick-removal write policy stay
(`tools/nt/usosmpart/README.md`). Opt-out on the installed system:
`Services\usosmpart\Parameters\Disabled = 1`.

## 3. Tests (host)

`python tools/tests/test_usosmpart_vista_x64.py`: NT6 amd64 binary (PE32+,
native, subsystem 6.0, unsigned in git, import set, no /GS or CRT
helpers); `build.cmd` target; signing session signs and verifies the filter
before the key is deleted; the Vista package builder refuses an unsigned
filter; installer wiring (after the BCD testsigning step and usosnvme, CSMWrap
only, same service rows as x86); `tools/tests/vista_mpart64_harness.c`
(mock registry / files): UEFI path untouched, build without the filter
skipped, LowerFilters created / appended after `EhStorClass\0PartMgr` /
empty multi-sz / already listed (any case) kept, both control sets or one
when Current == Default, a wrong value type / a failed write / a bad
`Select` restore the hive and remove the file.

Also run: `test_usosmpart.py`, `test_usosnvme_amd64.py`, `test_usosnvme.py`
(PASS). The per-build signing was run once on its own: `usosmpart.sys` and
`usosnvme.sys` carry the same signer, no USOS certificate left in
`CurrentUser\My`.

## 4. QEMU

Not run (no full Windows installs in this session). For Codex
(`docs/vista-x64-nvme-2026-10-21.md` section 4 setup, q35 + OVMF + CSMWrap,
Vista SP2 x64 through the USOS flow on a QEMU NVMe or SATA disk, plus
`-device qemu-xhci -device usb-storage,removable=on` with a 3-partition GPT or
MBR image attached from the first boot, as in
`tools/tests/run_usosmpart_qemu.py`):

1. `usos-vista-install.log` has `Mpart64: offline boot-start filter and disk class LowerFilters=0`;
2. the installed system boots (filter loaded: `sc query usosmpart` RUNNING;
   no STOP 0x7B on the NVMe / SATA boot disk);
3. the stick shows every data partition with a letter (type "fixed"), a
   single-partition stick stays "removable";
4. write + read back on each volume, surprise removal + replug, safe removal;
5. the cold-plugged stick right after the install (the X470 Windows 7 x86
   symptom: invisible until one replug, `docs/usb-multipartition-2026-10-14.md`;
   the x86 `:usbfix` helper is not ported to this path).

## 5. Build

Full `build.bat` PASS: **B261021-163547-BFA844D5**. `vista-support.cpio` carries `usosmpart-amd64.sys` (12456 B, embedded-signed) next to the amd64 usosnvme package; both signed by the per-build certificate `EC3BF3E9...BD980` (key deleted). The installer EXE contains the `Mpart64` step.

## 6. Risks

- **Test signing becomes boot-critical on SATA targets too.** A disk class
  lower filter that cannot load fails the start of every disk, the boot disk
  included (STOP 0x7B). On NVMe targets usosnvme already depends on
  testsigning; on SATA targets it is new. Turning testsigning off on such a
  system needs `usosmpart` removed from the disk class `LowerFilters` first
  (or `Start = 4` plus the removal). The Vista x64 path never turns it off.
- The SHA-1 per-build test signature on a boot-start filter is accepted by
  Vista x64 winload in test mode (the same mechanism as usosnvme, which passed
  in QEMU and boots on the X470); not separately proven for this file.
- The community USB 3 backport's mass-storage PDO must report the enumerator
  `USBSTOR` (it uses Microsoft usbstor); otherwise the filter does not attach
  and nothing changes.
- The cold-plug "invisible until replug" state seen on X470 Windows 7 x86 may
  appear here too (no `:usbfix` on this path).
- Server 2008 x64 shares the profile and code path, not tested.

## 7. Offline test on the existing X470 install

Without a reinstall: a deploy script (outside the repository, session
scratchpad `vista-x64-mpart-deploy\deploy.ps1`) copies the signed
`usosmpart.sys` from this build's
`zig-out/windows-source-mount/usosnvme-nt6-amd64/` to the Micron's
`System32\drivers` and applies the same registry rows offline as SYSTEM
(one-shot scheduled task), with a SYSTEM hive backup and a rollback script.

## 8. Provenance

Own driver (GPL-3.0-or-later), unchanged source of `tools/nt/usosmpart`
(provenance in its README: public WDK documentation; user-supplied NT 5
sources read for local diagnosis only, no code from them). This change adds
a build target, signing, packaging and the offline registration; no
Microsoft binaries in git.
