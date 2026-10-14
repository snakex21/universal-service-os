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
  pinned Arch/Debian container on another machine. The release keeps the
  pinned upstream release binary, whose SHA-256 equals the GitHub release
  digest, like `UefiSeven.efi`. A source build now exists (2026-09-27): an
  Alpine VM in QEMU, section 6.
- **Signing:** CSMWrap must run with Secure Boot **off**: its whole purpose
  is to execute unsigned 16-bit BIOS code and a legacy boot sector outside
  any verification. Signing it with the USOS MOK would let anyone with the
  stick start arbitrary unverified code under the USOS trust chain
  (`docs/secure-boot-usos.md`). Keep the existing decision: **never sign
  CSMWrap**; `usos-efisign` already lists it as unsigned on purpose
  (`installer/cmd/usos-efisign/release.go`).

## 6. USOS build 3.1.2-usos1: quiet boot (2026-09-27; the release binary since 2026-09-28, section 7)

With `csmwrap.ini` `verbose = false` (the release default since the X470
PASS), the upstream 3.1.2 binary still shows three things before XP:

| Upstream behaviour | Where |
|---|---|
| CSMWrap ASCII logo and credits, **always** | `efi_main` sets `gConfig.verbose = true` around `printf(banner)`, before `csmwrap.ini` is even read |
| `SeaBIOS (version 578d260b-CSMWrap-3.1.2)` (and a `Machine UUID` line when SMBIOS has one) | `enable_vga_console()` (`bootsplash.c`), called by the CSM `Legacy16PrepareToBoot` handler after the int 10h mode-3 switch |
| `Press ESC for boot menu.` plus a 2.5 s wait, then `Booting from Hard Disk...` | `interactive_bootmenu()` and `do_boot()` (`boot.c`) |

### 6.1 Patches (`tools/vendor/csmwrap/3.1.2-usos1/patches`)

Three small patches on the unpatched source archive, applied in order with
`patch -p1` (they span CSMWrap and its `seabios` submodule):

1. **`0001-csmwrap-logo-only-when-verbose.patch`** (CSMWrap): drops the
   forced-verbose logo print and prints the logo after `config_load()`
   through the normal `printf`, so it reaches the screen only with
   `verbose = true` (and serial with `serial = true`).
2. **`0002-quiet-flag-no-seabios-banner-or-boot-messages.patch`** (both):
   the loader-to-SeaBIOS channel. A new byte `CsmwrapFlags` after
   `ExtraPciRootListCount` at the end of `EFI_COMPATIBILITY16_TABLE` (both
   copies of `LegacyBios.h`), bit `CSMWRAP_FLAG_QUIET`; CSMWrap sets it
   when `verbose` is false, next to the extra-PCI-roots fields it already
   fills. SeaBIOS gets `csm_quiet()`; `enable_vga_console()` still switches
   to text mode 3 but skips the banner and UUID line, and the five
   `Booting from ...` lines are skipped. Error messages (`Boot failed`,
   `No bootable device`) stay visible.
3. **`0003-seabios-no-boot-menu-when-quiet.patch`** (SeaBIOS): in
   `csm_maininit`, next to `etc/extra-pci-roots`, a quiet boot adds the
   romfiles `etc/show-boot-menu = 0` and `etc/boot-menu-wait = 0`, so
   `interactive_bootmenu()` returns at once (no prompt, no wait). Chosen
   over `CONFIG_BOOTMENU=n` because it keeps the menu for a
   `verbose = true` boot.

`verbose = true` gives back exactly the upstream screens (logo, CSMWrap
log, SeaBIOS banner, ESC prompt and menu), so the existing
`EFI\USOS\csmwrap-verbose.flag` switch of `tools/xp_csmwrap_esp.sh` stays
the diagnostics path. Cosmetic leftover on a quiet boot: Flanterm's cursor
block in the top-left corner during the CSMWrap phase (under a second).

### 6.2 Build (`tools/build_csmwrap.ps1`)

No WSL/Docker/ELF GCC here, so the build host is a throwaway **Alpine
Linux 3.24.1 virt live ISO** (the hash-pinned ISO of
`tools/micro_linux.lock.json`) in the repository's QEMU 11.1.0 with WHPX
(TCG fallback). `tools/csmwrap_build/run_build_vm.py` logs in on the serial
console, hands `tools/csmwrap_build/guest_build.sh`, the lock and the
patches over as a tar on a raw virtio disk, and reads the results back from
a second one. The guest:

1. installs exact apk versions from the `v3.24` branch
   (`tools/csmwrap_build/lock.json`): gcc 15.2.0-r5, binutils 2.45.1-r1,
   musl-dev 1.2.6-r2, make 4.4.1-r4, nasm 3.01-r0, xxd 9.2.1091-r0,
   python3 3.14.7-r1, git 2.54.0-r0, tar 1.35-r5, xz 5.8.4-r0, patch 2.8-r0
   (stable branches keep only the newest build; a superseded pin fails the
   build and must be bumped deliberately);
2. clones CSMWrap at `808ac8ea5393db9052044fb0f74aa55e0d719afc` (tag 3.1.2)
   and checks all seven submodule commits against the lock (SeaBIOS fork
   `578d260b94f62150bf6ab9149784287bd1154f06`);
3. writes `seabios/.version` (`578d260b`, what `git describe` gives, so the
   version string matches upstream without `.git`) and the **source
   archive** `csmwrap-3.1.2-src.tar.xz` (GNU tar, sorted, mtime 2026-05-09,
   owner 0, no `.git`);
4. builds from that archive with `make ARCH=x86_64 BUILD_VERSION=...`:
   `3.1.2` unpatched, and `3.1.2-usos1` with the patches, twice.

Two separate VM runs gave the same archive and the same unpatched build;
the usos1 build is identical when built twice:

| File | SHA-256 |
|---|---|
| `csmwrap-3.1.2-src.tar.xz` (1.0 MB, vendored in `tools/vendor/csmwrap/3.1.2-src/` with the licence files) | `9be5b839d64d25021037096b6cf928cfcf444db587a40a06d50bc4863991ff72` |
| unpatched rebuild `3.1.2` (not kept) | `62d617fc02e0bf983f4d62c7f9a95d31bcfd4b049d3b0bc46b988434502856da` |
| **`3.1.2-usos1/csmwrapx64.efi`** (471040 bytes, unsigned) | **`0146cc90c7c30be79115f0a0b86e1077c8df73057c94007fd036ebfbd20762a4`** |
| upstream release `3.1.2/csmwrapx64.efi` (Arch GCC 16.1.1, binutils 2.46) | `96fdb387e177c6340287b7e07713dc09bf1f965dd404311eafd9c6eb99a02745` |

The rebuild is not byte-identical to the release (different compiler), so
"same as upstream" is a functional check (below). Version strings:
`CSMWrap Version 3.1.2-usos1`, `SeaBIOS (version 578d260b-CSMWrap-3.1.2-usos1)`.
`tools/build_csmwrap.ps1` compares a rebuild with
`3.1.2-usos1/manifest.json`; `-Stage` copies it in only when it matches.

### 6.3 Tests (OVMF without CSM, TCG, std VGA)

Prepared English XP disk (`zig-out/xp-uefi-textmode-en-v5/target.qcow2`)
through `tools/tests/legacy_bios/run_csmwrap_xp_ovmf.py` (new options
`--csmwrap-efi`, `--verbose`, `--tag`, `--shots-every`), and the new
`tools/tests/legacy_bios/capture_csmwrap_screen.py`, which pauses the VM at
CSMWrap's `Unlock!` serial line to screenshot the CSMWrap phase itself:

| Binary, `verbose` | Screens before XP Setup | Result |
|---|---|---|
| upstream release, true | logo + log; SeaBIOS banner + ESC prompt | text-mode copying, 51.5 s |
| upstream release, false (current release) | logo; SeaBIOS banner + ESC prompt + `Booting from Hard Disk...` | copying, 52.4 s |
| **unpatched rebuild**, true | same as the release binary | copying, 52.4 s (**functional check PASS**) |
| **3.1.2-usos1, false** | none: the first text is `Setup is inspecting your computer's hardware configuration...` | copying, 41.0 s |
| **3.1.2-usos1, true** | logo + CSMWrap log (`verbose = true`, unlock path, `Unlock!`); SeaBIOS `...-3.1.2-usos1` banner + ESC prompt | copying, 43.2 s |

Screenshots in [csmwrap-quiet/](csmwrap-quiet/): `before-1-csmwrap-logo.png`,
`before-2-seabios-banner.png` (release binary, `verbose = false`);
`after-quiet-1-csmwrap.png`, `after-quiet-2-first-text.png`,
`after-quiet-3-copying.png` (usos1, quiet); `after-verbose-1-csmwrap-log.png`,
`after-verbose-2-seabios-banner.png` (usos1, `verbose = true`).
Not tested on hardware (X470) yet.

### 6.4 LGPL obligations for shipping 3.1.2-usos1

Shipping the modified binary is allowed (LGPL-2.1 section 2 for CSMWrap,
LGPLv3 with GPLv3 for SeaBIOS) if USOS:

- **marks it as modified**: the version strings above, and a `SOURCES.txt`
  saying "modified by the USOS project", with the date and the list of
  changes (the patch headers say the same);
- **provides the complete corresponding source**: the vendored
  `csmwrap-3.1.2-src.tar.xz` plus the three patches, shipped next to the
  binary (preferred, 1 MB) or offered in writing for as long as the binary
  is distributed, plus the scripts used to control compilation
  (`tools/build_csmwrap.ps1`, `tools/csmwrap_build/`);
- keeps shipping the LGPL-2.1, LGPLv3 and GPLv3 texts (already staged by
  `usos-efisign`) and the permissive notices of the other components
  (`tools/vendor/csmwrap/3.1.2-src/licenses/`);
- leaves the modified files under their licences (the patches are
  LGPL-2.1 for CSMWrap files, LGPLv3 for SeaBIOS files).

### 6.5 What switching the release to 3.1.2-usos1 would take

Done on 2026-09-28 (section 7). The binary stays unsigned either way.

1. `installer/cmd/usos-efisign/release.go`: `csmwrapVendorDir` ->
   `tools/vendor/csmwrap/3.1.2-usos1` (its manifest has the binary hash; the
   `LICENSE`/`COPYING.LESSER` hashes `stageCSMWrap` checks must be added, or
   read from `3.1.2/`), a new `SOURCES.txt` text, for example:
   "CSMWrap 3.1.2-usos1 (csmwrapx64.efi, unsigned): a MODIFIED version of
   CSMWrap 3.1.2 and its SeaBIOS fork, changed by the USOS project on
   2026-09-27 (quiet boot unless csmwrap.ini sets verbose = true). Source:
   csmwrap-3.1.2-src.tar.xz (CSMWrap 808ac8e, SeaBIOS 578d260b) plus
   patches/0001..0003", and staging of the patches and the archive into
   `EFI/USOS/csmwrap/`.
2. `tools/xp_csmwrap_esp.sh`: `PINNED=` -> `0146cc90...62a4`, the
   "pinned 3.1.2 hash" message, and the licence/source loop that copies
   files to `\CSMWRAP\` on the target ESP (add the patches, and the archive
   or the offer).
3. Allowlists and goldens: `tools/tests/golden/staged_payloads.tsv` (the new
   `xp_csmwrap_esp.sh` hash in its initramfs row, new `EFI/USOS/csmwrap/`
   rows), `tools/verify_release_consistency.ps1` (the `EFI/USOS/csmwrap/`
   list); `installer/internal/payload/bundle_test.go` and the unsigned list
   in `usos-efisign` keep the same file name.
4. Test tools that default to `3.1.2`: `run_csmwrap_xp_ovmf.py`
   (`CSMWRAP_DIR`) and `run_csmwrap_xp_prepared.py` (reads the staged files).
5. X470 check with `verbose = false` and with the flag file, then a release
   build and payload commit.

## 7. Release switch to 3.1.2-usos1 (2026-09-28)

The release ships 3.1.2-usos1 (section 6) instead of the upstream binary;
the usos2 `system_thread_visible` experiment of `feature/csmwrap-quiet`
(it resets the installed XP) is not part of it.

- `installer/cmd/usos-efisign/release.go` stages from
  `tools/vendor/csmwrap/3.1.2-usos1` (binary by its manifest hash), the
  licence texts as before (LGPL-2.1 of CSMWrap and LGPLv3 of SeaBIOS from
  `3.1.2/`, GPLv3), and now also the complete source: the unpatched archive
  `csmwrap-3.1.2-src.tar.xz` (hash shared by both manifests), `patches/`
  (the three patches, hashes from the usos1 manifest) and `licenses/` (the
  notices of every component, from `3.1.2-src/manifest.json`) into
  `EFI/USOS/csmwrap/`. `SOURCES.txt` says "MODIFIED", what changed and when,
  where the source and the patches are, and offers the source on request.
- `tools/xp_csmwrap_esp.sh` (XP, 2000, 2003, XP x64 and Vista through
  CSMWrap) pins `0146cc90...62a4`, and copies the licences, `SOURCES.txt`,
  the source archive, `patches\` and `licenses\` into `\CSMWRAP\` of the
  target's CSMWrap ESP (about 1.1 MB of 64 MiB), so every installed disk
  carries its source. `csmwrap-verbose.flag` still writes `verbose = true`,
  which gives back every upstream screen (section 6.3).
- Allowlists: `tools/verify_release_consistency.ps1` (new required paths),
  the staged-payload golden (new `EFI/USOS/csmwrap/` rows, the new hashes of
  `xp_csmwrap_esp.sh` and of the payload); the QEMU harnesses copy the whole
  staged `EFI/USOS/csmwrap` tree.

QEMU (OVMF without CSM, TCG, std VGA), release staging of this commit:

| Harness | Result |
|---|---|
| `run_csmwrap_xp_prepared.py` (XP SP3 PL, prepared by the package scripts) | OVMF logo, then no text before XP Setup: the first text screen is "Instalator systemu Windows XP Professional" (28.5 s); `SeaBIOS (version` appears 0 times; text-mode copying reached (40 s) |
| `run_csmwrap_vista_prepared.py` (Vista SP2 x64, tweaks profile answer) | no CSMWrap logo, no SeaBIOS banner, no ESC prompt; PE10 boots, Vista Setup starts with the merged answer |

Left over on a quiet boot: the VGA text-mode cursor (a blinking underline in
the top-left corner) from SeaBIOS's mode-3 switch until the boot loader
changes the video mode (about 20 s for bootmgr loading PE10 under TCG,
under a few seconds on hardware). Hiding it needs another SeaBIOS change
(cursor off in `enable_vga_console()` on a quiet boot), i.e. a new build;
not done here. Not tested on the X470 yet.


## 8. 3.1.2-usos3 for 1.1 (2026-09-29, branch `feature/bios-via-csmwrap`)

usos1 plus SeaBIOS patch 0004 (CSM boot priorities looked up in CSMWrap's
BBS table by PCI address, USB mass storage included), so the drive CSMWrap
was loaded from boots first also when it is a USB stick next to a bootable
SATA disk. Needed by the UEFI menu's "Legacy BIOS mode (CSMWrap)"; details,
naming (no clash with the failed usos2 `system_thread_visible` experiment)
and tests in [../design/bios-via-csmwrap.md](../design/bios-via-csmwrap.md)
section 8.2. `csmwrapx64.efi` SHA-256
`bbf05216af896e24e5dd9da21d89bd063c17d1dab42f83561abc8cd49844de5f`, repeatable
over three VM runs; staged by `release.go`, pinned in `xp_csmwrap_esp.sh`
and in the DOS target ESP image. XP and Vista target-ESP boots with and
without the stick: PASS in QEMU. The blinking-cursor patch mentioned in
section 7 is still not done (it would be a later build).

## 9. 3.1.2-usos4: the disk CSMWrap was loaded from is 0x80 (2026-10-11, branch `feature/csmwrap-boot-disk`)

usos3 plus patch 0005. CSMWrap's BBS table names controllers only, so every
disk on the controller CSMWrap was loaded from got priority 0 and SeaBIOS
broke the tie by port: a bootable disk on a lower port of the same SATA
controller became 0x80 (design doc csmwrap-integration 13.4). Now CSMWrap
finds the raw disk whose device path prefixes the loaded image's path and
tags its BBS entry (IBV1 = "USOS", IBV2 = FNV-1a of its first 512 bytes);
SeaBIOS reads sector 0 of each hard disk before mapping drives and moves the
single match in front of the first hard disk, the other disks keep their
order (0x81, ...). No tag, no match or several matches (cloned disks): the
order stays as in usos3. Legacy IDE (16-bit-only `DTYPE_ATA`) drives cannot
be read at that point and keep the usos3 order.

`csmwrapx64.efi` SHA-256
`e566e5a91c7b880105afbb435e3d8fbecfca748cbf28101ff14d686a47f8e807`, built
twice in one VM run (identical). Alpine v3.24 dropped python3 3.14.7-r1, the
pin is now 3.14.8-r0; the unpatched rebuild still gives the
`upstream_rebuild` hash, so the toolchain output did not change.

Tests: `tools/tests/legacy_bios/run_csmwrap_boot_disk_qemu.py` (OVMF without
CSM, two raw disks whose MBR code reports which disk is 0x80 and which 0x81
on the debug console): decoy on port 0 / target on port 1 of one AHCI
controller, the reverse, decoy on its own controller, target on qemu-xhci
usb-storage: all `USOS-TARGET USOS-DECOY` with usos4; the usos3 control
boots the decoy. XP SP3 PL (`run_csmwrap_xp_ovmf.py --decoy`) and 32-bit
Windows 10 (`qemu_native.py`, `USOS_NATIVE_DECOY_SAME_CONTROLLER=1`) in
csmwrap-integration 13.4.

## 10. 3.1.2-usos5: ACPI 1.0 view for Windows 2000/XP (2026-10-13, branch `feature/csmwrap-acpi10`)

Patch 0006 (`src/usos_acpi10.c`, own code from the ACPI specification):
CSMWrap's RSDP copy gets an RSDT built from the XSDT when RsdtAddress is 0 or
the RSDT is invalid, and a FADT copy with the 32-bit fields filled from the
X_ fields when they are 0; with `acpi_legacy_fadt = true` in csmwrap.ini
(written by `tools/xp_csmwrap_esp.sh` only for Windows 2000 with ACPI) the
RSDT's FADT is cut to revision 1 / 116 bytes for the 2000 ACPI HALs. Binary
`1207f8cc287372b32cc3ddce2ea4cc67c022a8d7844f7651bff476ca3fb1598b` (with the legacy AML filter: QWord windows above 4 GiB cleared in the DSDT/SSDT copies for 2000), built
twice identical in the pinned Alpine VM (xxd pin moved to 9.2.1178-r0; the
unpatched build still matches upstream_rebuild). Details and the q35 A/B:
docs/windows-2000-acpi-x470-2026-10-12.md, last section.

## 11. 3.1.2-usos6: ACPI mode before the legacy boot, Windows 2000 diagnostic (2026-10-14, branch `feature/w2k-acpi-csmen`)

Patch 0007 (`src/usos_acpien.c`, own code from the ACPI specification and
the PC CMOS RTC layout; host unit test
`tools/tests/csmwrap/test_csmwrap_acpien.py`): only with
`acpi_legacy_fadt = true` (the Windows 2000 ACPI flow), CSMWrap reads
SMI_CMD / ACPI_ENABLE / PM1a_CNT_BLK / PM_TMR_BLK from the RSDT's FADT
before ExitBootServices and, after SeaBIOS's Legacy16PrepareToBoot and right
before Legacy16Boot, switches the machine to ACPI mode (SCI_EN polled for at
most 3 s on the PM timer) with RTC A/B read before and after. Result: 8
bytes at physical 0x4F4 (BDA inter-application area) for usosvid 1.2, and a
`USOS ACPIEN:` serial line. Every other flow runs the usos5 path. Why and
the reading table: docs/windows-2000-acpi-x470-2026-10-12.md, section
"Step A". Binary
`804d5f870c8958067ced48a23b461a69e98da81a645e50750b99d8b7feb4f342`, built
twice identical in the pinned Alpine VM (same lock as usos5, BUILD_VERSION
3.1.2-usos6; the unpatched build still matches upstream_rebuild). The
vendor folder is `tools/vendor/csmwrap/3.1.2-usos6` (release.go, the DOS
ESP builder, the XP ESP script pin and the tests moved to it; 3.1.2-usos5
stays as the previous release binary).

## 12. 3.1.2-usos7: APM power-off from every APM interface (2026-10-15, branch `feature/apm-poweroff`)

Why: Windows 98 SE / ME on the X470 end at "Można teraz bezpiecznie wyłączyć
komputer" (docs/research/win9x-acpi-2026-10-15.md). Two holes in CSMWrap
3.1.2's APM 5307h power-off: from the 16-bit and 32-bit protected-mode APM
interfaces (Windows 9x VPOWERD uses the 32-bit one) `apm_shutdown()` called
`bios_proxy_reset()`, whose mailbox scan loads real-mode segment values
into `%es` = #GP in protected mode; and the fallback wrote SLP_TYP 0, which
is S5 on QEMU only (X470 `_S5` = 5, the right PM1a_CNT write is 0x3400).
SeaBIOS `dprintf` had no output at all in this build (no DEBUG_SERIAL), so
the "UEFI reset" lines were never visible.

Patch 0008 (own code from the APM 1.2 and ACPI specifications; host unit
test `tools/tests/csmwrap/test_csmwrap_apmoff.py`, QEMU test
`tools/tests/csmwrap/run_csmwrap_apmoff_qemu.py`):

1. UEFI `ResetSystem(EfiResetShutdown)` on the helper core through the
   existing mailbox (`usos_proxy_reset_timed`, 2 s timeout): from INT 15h
   (real / V86 mode; `%es` = F000h) and from the 32-bit PM interface
   (through `%gs`, the APM data segment based at the F-segment). The
   helper-core loop is unchanged. The 16-bit PM interface skips this step.
2. Direct ACPI S5: SLP_TYPa/b from `Name(_S5, Package(){...})` in the DSDT
   (else an SSDT), found by a small AML byte parser (`fw/usos_s5.h`), into
   PM1a_CNT and PM1b_CNT, SLP_EN last (X_ GAS fallbacks for the FADT ports).
3. Still on after 2 s with SCI_EN = 0: FADT ACPI_ENABLE to SMI_CMD, S5 again.
4. Still on: the APM call returns AH=60h instead of halting (9x then shows
   its own "safe to turn off" text, the USOS menu its message).

Known limitation: `_PTS(5)` is not run (no AML interpreter). Boards whose S5
needs `_PTS` work only through step 1 (the firmware's own ResetSystem).

Diagnostics: "USOS APMOFF:" lines (pm1a/pm1b/pm_tmr/`_S5` at boot, the path
at power-off) reach the serial port with csmwrap.ini `serial = true`:
CSMWrap sets CsmwrapFlags bit 0x02 and the new CsmwrapSerialPort field, and
SeaBIOS's debug output (dprintf level 1) goes to that port; with serial off
nothing changes. For INT 15h callers 4 bytes at BDA 4FCh-4FFh: `'P'`,
step<<4 | path (path 1 INT 15h, 2 PM16, 3 PM32; step 1 helper asked, 2 S5
written, 3 S5 after ACPI enable, 4 gave up), SLP_TYPa | SLP_TYPb<<4, flags
(bit0 `_S5` found, bit1 PM1a, bit2 PM1b, bit3 helper timeout, bit4 helper
reset unavailable, bit5 ACPI enable tried). The PM paths cannot write the
BDA (no flat data segment) and log to serial only.

QEMU (OVMF, TCG, own test MBR, pc and q35): real-mode INT 15h -> `path=uefi
from=1`, 32-bit PM with paging -> `path=uefi from=3`, 16-bit PM -> `path=s5
from=2 typ=0/0`: all six runs end with a guest SHUTDOWN. Control with usos6:
both PM paths reset the guest (the #GP). The X470 values (PM1a_CNT 0x804,
`_S5` 5, no PM1b) are covered by the host test on the X470 DSDT dump only.

F-segment space: with this patch SeaBIOS's 16-bit + 32-bit segmented code,
F-segment variables and 32-bit flat runtime code no longer fit in the
F-segment with room left, so `scripts/layoutrom.py` falls back to its
minimum allocation zone (BUILD_MIN_BIOSTABLE). Upstream's 2048 bytes did not
hold the SMBIOS and MP table copies plus one block per AHCI port: the first
usos7 build lost AHCI port 1 in `run_csmwrap_boot_disk_qemu.py` ("Unable to
allocate resource at ahci_port_realloc"). Patch 0008 raises the minimum to
6144 bytes (upstream 3.1.2 had 4320 free); 32-bit flat code moves below the
F-segment, ROM use 96.0 % of 128 KiB. Boot-disk regression: all six layouts
PASS; about 4 KiB of F-segment allocation space stays free in QEMU.

Binary `bd91e53aeab1e971362509cfdfbf61fa7d72dba99b66b269d202c52d0da1041e`,
built twice identical in the pinned Alpine VM (same lock as usos6,
BUILD_VERSION 3.1.2-usos7; the unpatched build still matches
upstream_rebuild). Vendor folder `tools/vendor/csmwrap/3.1.2-usos7`
(release.go, the DOS ESP builder, the XP ESP script pin and the tests moved
to it; 3.1.2-usos6 stays as the previous binary). A later patch 0009 (the
Windows 2000 ACPI watcher) goes on top of usos7.
