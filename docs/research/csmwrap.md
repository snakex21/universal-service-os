# CSMWrap: state of the art (research, 2026-09-27)

Question: can USOS boot legacy-BIOS systems (XP first, then Vista's VgaSave
case) on UEFI class-3 machines, or with CSM switched off, by using CSMWrap?
Scope: licence, mechanism, requirements, limits, build and signing. The USOS
design built on it is in [../design/csmwrap-integration.md](../design/csmwrap-integration.md).

Earlier material in the repository:

- `tools/vendor/csmwrap/3.1.2/`: the pinned upstream release binary
  `csmwrapx64.efi` (SHA-256 `96fdb387…a02745`, equal to the GitHub release
  digest), its `README.md`, `LICENSE` and `manifest.json`. Vendored for the
  2026-09-20 trial.
- `docs/csmwrap-trial-2026-09-20.md`: one hardware trial on the stick
  (Windows 7 on an Intel disk, GPT): it stopped after SeaBIOS
  `Booting drive`, because that disk had no BIOS boot path at all (GPT +
  `winload.efi`). It did not test a legacy MBR system. The trial menu
  (`tools/csmwrap_boot_menu.zig`, `tools/build_csmwrap_trial.py`,
  `tools/deploy_csmwrap_trial.ps1`) is historical; the obsolete-file cleanup
  in `installer/internal/obsolete` removes its `EFI/BOOT` leftovers.
- `docs/design/nt5-uefi-family.md` section 7 and `docs/ROADMAP.md` L2:
  the earlier outline of "XP without CSM via CSMWrap" (target ESP, Secure
  Boot off, the risk table). This note checks and extends it.

## 1. Upstream and licence

| Item | Fact |
|---|---|
| Upstream | `github.com/CSMWrap/CSMWrap`. `github.com/FlyGoat/CSMWrap` answers `301 Moved Permanently` to it (the project moved from FlyGoat's account to its own organisation). |
| Latest release | `3.1.2` (2026-05-09), assets `csmwrapx64.efi` and `csmwrapia32.efi`; the repository was last pushed 2026-09-18 with no newer tag. USOS pins 3.1.2. |
| CSMWrap licence | **LGPL-2.1** (GitHub `spdx_id: LGPL-2.1`, the `LICENSE` file). The older nt5 note already says this. |
| SeaBIOS | submodule `seabios` = `github.com/CSMWrap/seabios-csmwrap`, a SeaBIOS fork, **LGPLv3**. It is built as `Csm16.bin` and `vgabios.bin` and embedded in the EFI image with `xxd -i`. |
| Other parts | PicoEFI (BSD-2/BSD-2-Patent/BSD-3/MIT mix), uACPI (MIT), Flanterm (BSD-2), nanoprintf (Unlicense/0BSD), `freestnd-c-hdrs-0bsd` (0BSD), `cc-runtime` (LLVM compiler-rt, Apache-2.0 WITH LLVM-exception); EDK2 snippets (BSD-2-Clause-Patent). All permissive. SeaBIOS ships `COPYING.LESSER` (LGPLv3) plus `COPYING` (GPLv3, which LGPLv3 incorporates); both texts go with the binary. |

**Verdict: redistributable.** USOS may ship the unmodified binary on its
stick and copy it to a target ESP, provided it ships next to it the LGPL-2.1
text, the SeaBIOS LGPLv3 notice, and the source offer (the upstream tag and
the submodule commits, or a source archive). USOS does not link against it
(CSMWrap is a separate EFI application started by `LoadImage`/`StartImage`
or by the firmware), so the LGPL has no effect on USOS's own code. If USOS
ever patches CSMWrap or SeaBIOS, the patched sources must be published with
the binary (same obligation as the UefiSeven fork). Reusing CSMWrap C code
*inside* a USOS EFI binary (for example its OpROM dispatch for a
"VBIOS POST only" tool, design section 5) would make that USOS binary a
derivative of LGPL code: keep such a tool a separate, LGPL-licensed program.

To do before shipping (not done here): add the SeaBIOS LGPLv3 text and a
`SOURCES.txt` with the tag/submodule commits to `tools/vendor/csmwrap/3.1.2/`
and to the package the release copies (today the folder has only the
LGPL-2.1 text).

## 2. How it works (3.1.2, `src/csmwrap.c`)

CSMWrap is an ordinary EFI application. It plays the role that the
firmware's CSM (EDK2 `LegacyBiosDxe` + a CSM16 binary) plays on older boards,
but out of firmware:

1. **Config:** reads `csmwrap.ini` next to its own file (serial, `verbose`
   on-screen log via Flanterm, `vgabios` file, `vga` PCI address,
   `iommu_disable`, `system_thread`, CPU allow/block lists).
2. **Unlock the legacy region** 0xC0000–0xFFFFF (`unlock_region.c`):
   EFI Legacy Region 2 protocol if the firmware has one; else chipset
   specific: Intel PAM registers (Q35, Sandy Bridge and newer, i440FX in
   QEMU), **AMD fixed MTRRs with `SYS_CFG.MtrrFixDramModEn`** (RdDram/WrDram
   so the range becomes RAM); then a read/write test of the region. This is
   the same mechanism as USOS's AMD shadow unlock (`usos-amd-shadow.log`,
   `C0/C8=1818181818181818`). Panics "Unable to unlock BIOS region" if the
   test fails.
3. **Tables:** ACPI (uACPI) is parsed; the MADT is patched to hide one CPU;
   SMBIOS 3.0 is synthesized/relocated into a 2.x entry point below 1 MiB;
   an Intel MP table and a `$PIR` table are generated; E820 is built from the
   UEFI memory map.
4. **Video:** finds the GOP, keeps its current mode, and locates the GOP's PCI
   device. `oprom.c` takes the **legacy x86 (PC-AT, code type 0) image out of
   `EFI_PCI_IO_PROTOCOL.RomImage`** of that device (the copy of the card's
   expansion ROM that the PCI bus driver read at boot). If there is none (or
   `vgabios=` names a file) it uses **SeaVGABIOS** in "coreboot framebuffer"
   mode, drawn on the GOP linear framebuffer.
5. **PCI:** relocates BARs below 4 GiB where it can (legacy OSes and
   option ROMs cannot reach 64-bit BARs), collects the other option ROMs
   (storage/network) for dispatch.
6. **ExitBootServices**, `cli`, disables IOMMUs (default), puts the local
   APIC/IO-APIC into legacy (ExtINT) routing, masks the 8259, programs the PIT.
7. Copies SeaBIOS CSM16 to the top of 0xF0000 and the VBIOS to 0xC0000,
   starts the **BIOS proxy helper** on the reserved CPU (it stays in protected
   mode and executes SeaBIOS 32-bit code for BIOS calls made from V86 mode,
   because out of firmware there is no SMM), then calls the CSM16 entry
   points exactly like EDK2's LegacyBios does: `Legacy16InitializeYourself`,
   `Legacy16DispatchOprom` (the VGA ROM: **the card's real VBIOS POST**),
   the other option ROMs, `Legacy16UpdateBbs`, `Legacy16PrepareToBoot`,
   `Legacy16Boot`.
8. **Boot order** (`bootdev.c`): the drive CSMWrap was loaded from is put
   first in the BBS table (PCI location, SATA port, USB flag, CD vs HDD from
   the loaded image's device path). SeaBIOS then reads its LBA 0 and jumps to
   it with `DL=0x80`. If it fails, SeaBIOS tries the next device; `int 18h`
   from a boot sector also continues with the next device.

No return path: after step 6 UEFI is gone. CSMWrap is a one-way switch into
a legacy BIOS machine for the rest of that power cycle.

## 3. Requirements

| Requirement | What it means for USOS targets |
|---|---|
| Writable 0xC0000–0xFFFFF | Built in (step 2). AMD Zen: MTRR/`SYS_CFG` path, the one USOS's AMD shadow unlock already proved on the X470 (5700X). Intel: PAM; locked PAM on some newer boards = panic. |
| Legacy VBIOS image in the GPU ROM | Needed for real VGA (text mode at B8000, planar modes, A0000). The RX 560 (Polaris) ROM has both the PC-AT and the EFI image (it POSTs with CSM on), so CSMWrap should find it in `RomImage`. Pure-GOP ROMs (most iGPUs on class-3 boards, some new dGPUs) fall back to SeaVGABIOS = VBE only. **The ROG Ally's Radeon 780M iGPU almost certainly has no PC-AT image** (class-3 firmware, no CSM ever). |
| Above 4G decoding / Resizable BAR | README: keep x2APIC off; if things fail, try disabling Above-4G and ReBAR. CSMWrap relocates BARs below 4 GiB, which fails when the firmware placed a large (ReBAR) VRAM BAR high and there is no room below 4 GiB. |
| At least 2 logical CPUs | One is reserved for the BIOS proxy and hidden from the OS (MADT + MP table). XP then sees one CPU fewer (non-issue: XP Pro licenses 2 sockets anyway). |
| Secure Boot | Off (the README), or sign it yourself. See section 5. |
| Partitioning | README recommends an MBR disk with a FAT ESP; any FAT (12/16/32) partition that the firmware scans for `\EFI\BOOT\BOOTX64.EFI` works. On MBR, type 0xEF is the ESP. |

## 4. Limitations relevant to XP and Vista

- **Keyboard/mouse:** SeaBIOS (defaults kept by CSMWrap's 5-line
  `seabios-config`: `CONFIG_CSM=y`, `CONFIG_VGA_COREBOOT=y`) has PS/2 and
  USB HID for **int 16h only** (UHCI/OHCI/EHCI/**xHCI**). There is **no
  8042 emulation** (that needs SMM). NTLDR/SETUPLDR menus work with a USB
  keyboard; once the NT kernel owns the hardware, XP's own drivers are
  needed. XP has no xHCI driver: on xHCI-only boards (X470 rear ports,
  Ally) **the keyboard is dead in XP text-mode Setup and in XP**, until a
  USB3 driver is loaded. The USOS XP path is unattended in text mode, and
  the XP package already carries the USB3 backport for GUI/desktop.
- **Disks:** SeaBIOS int 13h drivers: ATA/IDE, **AHCI**, **NVMe**, USB MSC,
  virtio. So NTLDR/SETUPLDR can read the target in any SATA mode and on
  NVMe. XP itself then needs its own driver: AHCI (the SATA mode set in the
  firmware stays as it is; USOS's XP package integrates GenAHCI/AMD AHCI) or
  an NVMe miniport. Same matrix as under firmware CSM.
- **Video:** with the card's own VBIOS: native-like (VGA text, planar,
  VBE). With SeaVGABIOS (no PC-AT image): VBE on the GOP framebuffer only;
  direct writes to B8000/A0000 are invisible, so **XP text-mode Setup and
  the boot screen would be black**, and `vga.sys` would fail; VBEMP would
  be needed for the XP desktop.
- **No return to UEFI**; no UEFI runtime services for the legacy OS (fine
  for XP/Vista BIOS installs).
- **ACPI:** the legacy OS gets the UEFI-mode ACPI tables (patched MADT).
  Boards that enable x2APIC in UEFI mode need it off in setup (README).
- **Maturity:** a community project (2025–2026). Hardware reports are
  collected on its Discord and issue tracker; the README has no
  compatibility list. Issues exist for specific laptops/GPUs; nothing in the
  repository confirms X470/AMI or a ROG Ally. Treat each board as untested.

## 5. Build, reproducibility, signing

- **Upstream build:** `GNUmakefile`, toolchain GCC (or `TOOLCHAIN=llvm`:
  clang + ld.lld) targeting bare ELF, `nasm`, `objcopy`, `xxd`, `python`,
  GNU make. SeaBIOS itself is built by its own Kconfig/Make with the same
  compiler (32-bit ELF, GNU ld scripts; SeaBIOS supports GCC only). The
  release binaries come from GitHub Actions in an `archlinux:latest`
  container (`pacman -S base-devel python git vim nasm`), `make ARCH=x86_64`
  and `make ARCH=ia32`. The toolchain is a rolling release, so a rebuild is
  **not bit-for-bit reproducible** against the release asset.
- **Not the EDK2 workspace.** Unlike UefiSeven (`tools/build_uefiseven.ps1`,
  EDK2 + VS2022 in `%LOCALAPPDATA%\USOS\edk2-build`), CSMWrap does not use
  EDK2 BaseTools and cannot be built with MSVC. This PC has no WSL distro,
  no Docker and only MinGW GCC (PE target, unusable for SeaBIOS). A source
  build therefore needs a Linux environment: the path of least effort is
  the micro-Linux build host USOS already uses for its kernel, or a
  pinned Arch/Debian container on another machine. **Not done in this
  change** (time box); USOS keeps the pinned upstream release binary, whose
  SHA-256 equals the GitHub release digest, like `UefiSeven.efi`.
- **Signing:** CSMWrap must run with Secure Boot **off**: its whole purpose
  is to execute unsigned 16-bit BIOS code and a legacy boot sector outside
  any verification. Signing it with the USOS MOK would let anyone with the
  stick start arbitrary unverified code under the USOS trust chain
  (`docs/secure-boot-usos.md`). Keep the existing decision: **never sign
  CSMWrap**; `usos-efisign` already lists it as unsigned on purpose
  (`installer/cmd/usos-efisign/release.go`).
