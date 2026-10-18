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
to it; 3.1.2-usos6 stays as the previous binary). The next patch 0009 (APM
power-off order and breadcrumbs, section 13) goes on top of usos7.

## 13. 3.1.2-usos8: APM power-off ACPI mode first, CMOS breadcrumbs (2026-10-15)

Why: with usos7, Windows 98 SE on the X470 stays forever on its "shutting
down" logo; BOOTLOG.TXT shows 98 got through `EndTerminate = KERNEL`, so the
hang is inside the 5307h path (docs/research/win9x-acpi-2026-10-15.md, last
section). The board has no serial port, so nothing recorded which step hung.

Patch 0009 (own code from the APM 1.2 and ACPI specifications and the
MC146818 register map; reviewed from a draft that was never compiled):

1. Order on every interface: ACPI mode (SCI_EN = 0 -> ACPI_ENABLE to
   SMI_CMD, at most 1 s), PM1a_EVT/GPE0 status cleared and enables 0
   (FADT PM1a_EVT_BLK/GPE0_BLK with X_ fallbacks), S5 + 2 s wait, then
   (INT 15h and 32-bit PM only) the helper-core ResetSystem, then AH=60h.
2. Waits bounded by the PM timer and by a spin count (4000 port reads per
   millisecond asked).
3. CMOS breadcrumbs in the RTC alarm bytes 01h/03h/05h, written as valid
   alarm times (seconds 40 + step, minutes path * 15 + call count, hours
   1 + function bitmap) in BCD or binary per Status B, because edk2
   PcRtcInit resets invalid alarm bytes at every boot; armed (40/0/1) from
   handle_csm_0002. Own port I/O with interrupts off around each
   index/data pair: hw/rtc.c is not linked into the 32-bit segmented code
   (SRC32SEG) the 32-bit PM entry runs, so the draft's rtc_read/rtc_write
   calls would not link there. Port 80h gets A0h | step.
4. "USOS APMOFF: path=s5 from=N" is now logged for every path;
   "path=uefi" only when S5 left the machine on.

Review fixes against the draft: own CMOS I/O instead of hw/rtc.c (link
error in 32seg, and no interrupt guard), valid alarm encoding instead of
A0h-AFh (wiped by edk2 firmware), BDA flags kept (ACPI enable tried, helper
timeout/unavailable), the 0008 header comment updated to the new order,
dprintf path lines restored for the QEMU test.

Layout (build log): F-segment 16-bit 37344 + 32-bit segmented 4118 +
F-segment variables 3328 = 44790 bytes, leaving 20746 bytes, so the forced
allocation zone keeps the full 6144-byte minimum from patch 0008; ROM 127040
of 131072 bytes used (96.9 %, usos7 96.0 %).

Binary `65df046fc84deb111cb0f867c50dcb7e1971ee3a46890ea353bd0c6174d89a59`,
built twice identical in the pinned Alpine VM (same lock as usos7,
BUILD_VERSION 3.1.2-usos8; the unpatched build still matches
upstream_rebuild). Vendor folder `tools/vendor/csmwrap/3.1.2-usos8`;
release.go, the DOS ESP builder, the XP ESP script pin, third-party.json and
the tests moved to it; 3.1.2-usos7 stays as the previous binary.

Tests: test_csmwrap_apmoff.py (0008 parser + 0009 wiring: order, bounded
waits, valid alarm encoding, interrupt guard); run_csmwrap_apmoff_qemu.py
pc/q35 x real/pm32/pm16 all power off via `path=s5`;
run_csmwrap_boot_disk_qemu.py all six layouts; apm_breadcrumbs.zig unit
tests; `--cmos-check` (build B261015-141111-C6FB249D): pc/q35 x
real/pm32/pm16, the USOS menu reads the record after the power-off and
writes it to apm-off.txt (record found in the ESP image), all six PASS.
Hardware: not yet run on the X470.

## 14. 3.1.2-usos9: NVMe INT 13h after an OS stopped the controller (2026-10-15)

Windows 98 SE on the X470 runs from the Micron NVMe: CSMWrap's SeaBIOS
INT 13h until the VMM starts, then the USOS 9x miniport usosnvme.mpd. The
APM power-off of 98 lives in real mode: after the VMM returns, WIN.COM
re-executes itself from disk as `WIN.COM /z`, which shows LOGOS.SYS and then
calls INT 15h 5300h/5301h/.../5307h. usosnvme resets the controller at its
start (CC.EN = 0, its own AQA/ASQ/ACQ, usosnvme.c init steps 1-3) and on the
exit to real mode flushes, sets CC.SHN and disables it (`HwAdapterState`).
SeaBIOS's admin queue and I/O queue pair 1 were therefore gone, every
INT 13h read timed out (5 s each), the exec failed and the parent WIN.COM
printed "It's now safe to turn off your computer" as plain text (X470 with
usos8: exactly that screen, no LOGOS.SYS; CMOS record: 5301h/5307h never
called).

Patch 0010 (own code from the NVMe 1.4 base specification; the earlier
uncompiled draft had a use-after-free of `ctrl->pci`, which is POST-only
temporary memory): `nvme_runtime_rearm()` runs before every read/write.

| Controller state | Action |
|---|---|
| enabled, ready, no SHN requested/reported, not fatal, ASQ/ACQ = SeaBIOS's pages | used as it is (normal case; one config read + register reads) |
| enabled and ready with another admin queue | a live OS driver owns it: refused at once, nothing written (before: 5 s timeout, and our doorbells could make the controller fetch stale OS slots) |
| anything else (disabled, not ready, CC.SHN, SHST, CFS) | memory + bus master on, CC = 0, wait RDY 0, admin + I/O queue memory from POST cleared, head/tail/phase and doorbells 0-3 reset, AQA/ASQ/ACQ, CC.EN, wait RDY 1, CREATE I/O CQ 1, CREATE I/O SQ 1 on the same pages; `USOS NVME: re-arm` / `re-armed` on serial |

BAR 0 is read again from PCI config space (an OS may move it; a 64-bit BAR
above 4 GiB is refused). The BDF is kept in `struct nvme_ctrl`. No runtime
allocation. After a re-arm every write carries FUA, because SeaBIOS never
sends FLUSH and an APM power-off follows; the OS driver flushed and shut the
controller down before it handed it back.

Why not in usosnvme.mpd only: the driver replaces SeaBIOS's admin queue at
start, and SeaBIOS's I/O queue addresses, tails, heads and phases live in
SeaBIOS's own memory, so the driver cannot hand the original queues back.
Keeping the controller enabled at exit would leave the driver's admin queue
in place, which the new check refuses anyway. usosnvme stays unchanged (its
flush + CC.SHN is the clean handoff for data on the medium).

Layout: 16-bit and 32-bit segmented code unchanged (patch 0010 is 32-bit
flat only), so the F-segment allocation zone keeps 20746 bytes free above
the 6144-byte minimum; 32-bit flat 29066 bytes; ROM 127808 of 131072 bytes
(97.5 %, usos8 96.9 %).

Binary `07afed185535294065276d02e7ca3c18a04b3a0ca7e8cc3bce38333faafa56b8`,
built twice identical in the pinned Alpine VM (same lock and toolchain as
usos8, BUILD_VERSION 3.1.2-usos9; the unpatched build still matches
upstream_rebuild). Vendor folder `tools/vendor/csmwrap/3.1.2-usos9`; the
pins moved as for usos8; 3.1.2-usos8 stays as the previous binary.

Tests: test_csmwrap_nvme_rearm.py (patch wiring, manifest and pins);
run_csmwrap_nvme_rearm_qemu.py: OVMF + CSMWrap from QEMU NVMe, a test MBR
replays usosnvme's register sequence (own admin queue -> INT 13h refused;
CC.SHN + CC.EN = 0 -> INT 13h read works again, FUA write of LBA 1 to LBA 4
reaches the image, real-mode APM power-off), pc and q35 PASS; usos8 control:
the read after the shutdown fails (the X470 symptom). Regression with
usos9: run_csmwrap_apmoff_qemu.py pc/q35 x real/pm32/pm16 all PASS
(`path=s5`), run_csmwrap_boot_disk_qemu.py all six layouts PASS,
run_nvme_freedos_probe.py (FreeDOS from NVMe, write + read back) PASS,
test_csmwrap_acpi10/acpien/apmoff PASS. Windows 98 itself
cannot run this path in QEMU (its VMM exit hangs under CSMWrap there,
docs/research/win9x-acpi-2026-10-15.md). Hardware: not yet run on the X470.

## 15. 3.1.2-usos10: read-only Tick watcher on the helper core, Windows 2000 ACPI diagnostic (2026-10-15)

Windows 2000 SP4 with the ACPI HAL on the X470 stops after kernel phase 1;
step A (patch 0007) ruled out an SMI rewriting RTC A/B, and usosvid's
`hb t=--------` cannot tell a missing clock interrupt from starved DPCs.
Patch 0011 (design and code by Codex, its patch 0008 on usos6; reviewed and
applied unchanged on top of 0001-0010) lets CSMWrap's hidden helper core
read KeTickCount once a second, independently of Windows.

Only with `csmwrap.ini acpi_legacy_fadt = true` (the 2000 ACPI flow):

- EFI: ports from the validated RSDT FADT (PM1a_EVT/CNT, PM_TMR, GPE0; GAS
  System I/O fallback), TSC calibrated on the PM timer (~100 ms, bounded),
  one EfiReservedMemoryType page below 4 GiB. After `build_e820_map` the page
  must be wholly E820 type 2 (`usw_e820_reserved`), else the watcher stays
  off. The address reaches the helper through a private trampoline dword
  (EDX; the CSMPPrxy ABI is unchanged) and BDA 0x4FC-0x4FF right before
  Legacy16Boot through patch 0007's page-0 store (only exactly 0x4FC/4).
  Patch 0008's APM power-off record uses 0x4FC-0x4FF only during an INT 15h
  power-off, which the 2000 ACPI HAL never calls; usosvid reads 0x4FC once
  at VidInitialize and validates the page magic.
- Helper loop (`romlayout.S`): a page address in ESI (> 1) selects watcher
  mode: `request_pending` is still checked first on every iteration, then
  `usos_watch_tick` (PAUSE + RDTSC deadline instead of MWAIT); proxy calls
  record their start and a late flag. A proxied call that never returns stops
  the watcher too.
- Sample: Tick and KUSER_SHARED_DATA InterruptTime (physical addresses
  published by usosvid 1.3), PM1_STS/EN/CNT (16-bit), GPE0 STS/EN (bytewise),
  PIC IMRs from the data ports; stored in the helper's page range
  0x100-0x1FF and as 80 characters on VGA text row 24. Reads only: no OUT, no
  W1C, no SMI_CMD, no CMOS, no IOREGSEL/IOWIN, no LAPIC/IPI.
- Off: trampoline argument 0, no calibration, page, BDA write or sample; the
  loop is the usos9 one (code layout differs, function checked by the
  regression runs below).

Layout: 16bit 37408 (+64) + 32bit segmented 4118 + f-segment vars 3328 =
44854 bytes, 20682 bytes for the allocation zone (6144 minimum kept);
32-bit flat 31722 bytes (+2656); ROM 130528 of 131072 bytes (99.6 %): only
544 bytes are left, so the next SeaBIOS-side addition needs room first (for
example dropping the watcher once the 2000 ACPI diagnosis is done).

Binary `95a85360a10ff5e657f2636f9eedb3a08dfc02d019f8375558e884692b160d63`,
built twice identical in one pinned Alpine VM run (same lock and toolchain as
usos9, BUILD_VERSION 3.1.2-usos10; the unpatched build still matches
upstream_rebuild). Pins moved to 3.1.2-usos10 as for usos9.

Tests: test_csmwrap_watcher.py (Codex's 15 host cases on usos_watcher.c
from the patch, UBSan; gate, read-only and BDA-range checks, pins);
test_csmwrap_acpi10/acpien/apmoff/nvme_rearm PASS. QEMU (not hardware):
run_csmwrap_apmoff_qemu.py pc/q35 x real/pm32/pm16 PASS,
run_csmwrap_nvme_rearm_qemu.py pc/q35 PASS, run_csmwrap_boot_disk_qemu.py
six layouts PASS; 2000 Pro SP4 ACPI on q35 reaches logon with Tick growing
on the page (docs/windows-2000-acpi-x470-2026-10-12.md). X470 not tested.

## 16. 3.1.2-usos11: HPET and AMD GPIO hidden from Windows 2000, watcher dropped (2026-10-17)

The X470 Windows 2000 ACPI hang is a page fault in the 2000 SP4 acpi.sys
early boot IRQ arbitration for devices it has no driver for: the HPET
(PNP0103) and, once that was hidden, the AMD GPIO controller `\_SB.GPIO`
(AMDI0030, IRQ 7). Codex's diagnostic firmware-13 hid both and the X470
reached the 2000 desktop (docs/windows-2000-acpi-x470-2026-10-12.md, section
"2026-10-17").

Series: 0001-0010 unchanged from usos10 + **0012**
(`0012-w2k-hide-hpet-amd-gpio.patch`, own code from the ACPI 6.5 AML
grammar). 0011 (the read-only tick watcher, diagnostic) is no longer in the
series; its file stays in `3.1.2-usos10/patches`. Codex's NMI helper,
capsule staging, `w2k_nmi_snapshot` / `w2k_acpi_profile` options and Intel
GPIO rules are not part of usos11.

Patch 0012, only with `csmwrap.ini acpi_legacy_fadt = true`, only in the
private DSDT/SSDT copies of patch 0006 (RSDT view): a flat Device (NameOp/
MethodOp terms only) with exactly one `_HID`, at most one `_CID` and exactly
one `_STA` whose `_HID` or a `_CID` entry is PNP0103, AMDI0030 or AMD0030
(string, EISA ID integer, `_CID` Package) gets a `_STA` that returns 0, in
place (Name -> Zero, method body -> Return (Zero) + Noop). Dry run on the
firmware table first (valid checksum only; a malformed PkgLength makes the
table count 0), the copy must match the dry run; firmware tables and XSDT
unchanged; `USOS W2KHIDE` log line, flags 0x200/0x400. On the X470 DSDT the
result is byte-identical to firmware-13's table (only the two `_STA` bodies
and the checksum change).

Layout (SeaBIOS identical to usos9 apart from the version string; 0012 is
EFI-side code): 16bit 37344 + 32bit segmented 4118 + f-segment vars 3328 =
44790 bytes, **20746 bytes** for the allocation zone (6144 minimum kept);
32-bit flat 29066; **ROM 127808 of 131072 bytes (97.5 %, 3264 free)**;
CONFIG_SDCARD on.

Binary `94a93de4b40614bc2c75079e83cfbf23c9629a58016bd98ee0fa446d71872cc8`,
built twice identical in one pinned Alpine VM run; the unpatched build
still matches upstream_rebuild `62d617fc...`. xxd 9.2.1178-r0 was superseded
on the v3.24 branch; pin moved to 9.2.1202-r0 (libexpat in apk-installed.txt
also moved, 2.8.5 -> 2.9.0; neither changes the upstream binary). Pins moved
to 3.1.2-usos11 as for usos10.

Tests: test_csmwrap_w2khide.py (new: filter unit cases, truncation/
corruption fuzz, patched usos_acpi10.c against the full 0006 harness and an
end-to-end fixup harness, series and pins), test_csmwrap_acpi10/acpien/
apmoff/nvme_rearm PASS, test_csmwrap_watcher.py now checks the 0011 file in
3.1.2-usos10 only. QEMU (not hardware): run_csmwrap_apmoff_qemu.py pc/q35 x
real/pm32/pm16 PASS, run_csmwrap_nvme_rearm_qemu.py pc/q35 PASS,
run_csmwrap_boot_disk_qemu.py six layouts PASS, 2000 Pro SP4 ACPI on q35
(installed target, legacy FADT, 8 min) reaches the logon screen, no bugcheck; nothing hidden there (QEMU's HPET has an OperationRegion, not a flat device). X470 with usos11: not run.

Provenance: the device-hiding rule comes from Codex's diagnosis, which used
the user-supplied NT5 material as a behaviour map (not clean-room); the
patch 0012 code is ours, from the ACPI specification, without Microsoft code.

## 17. 3.1.2-usos11-int13x: only the boot disk gets a BIOS number (experimental, 2026-10-18)

Patch 0014 (own code), on top of 3.1.2-usos11. When csmwrap.ini has
`int13_boot_disk_only = true`, CSMWrap tags its boot disk with IBV1 "USOX" (it
uses the same IBV2 hash as patch 0005). SeaBIOS (`usos_boot_disk_first`) moves the
one matching disk to 0x80. Then it removes every other `IPL_TYPE_HARDDISK`
entry before `bcv_prepboot` maps the drives. With no match or with several
matches, nothing is removed. Without the key, the binary behaves the same as usos11.

Purpose: on the X470, Windows Me on NVMe stops with "cannot find KRNL386.EXE" when a USB stick is
plugged in. With this key, INT 13h shows exactly one hard disk again, which is the configuration that works.
Details, the 9x IOS stamp/checksum matching and the X470 kit are in docs/nvme-9x-2026-10-14.md
("A second BIOS disk"). Binary
`e0ec207b444962c555b5dc65ccea99938673dca576488166bdc7cd11c8a054be` (the usos1 and repeat
builds are identical). It is not in the flow and not pinned in xp_csmwrap_esp.sh.

QEMU: `run_csmwrap_boot_disk_qemu.py --only` PASSES on nvme-usb, same-port0, usb-target and
nvme-target (`USOS-TARGET NO-DRIVE-81`). The same runs without `--only` keep the usos11 order.
The new layout `nvme-usb` (NVMe target, USB decoy) also PASSES with usos11.

## 18. 3.1.2-usos12: PCI INTx routed to 8259 IRQs for Windows 9x (2026-10-18)

X470, Windows Me on the Micron (CSM off): the USOS usosnet I211 driver installs, but Device
Manager shows Code 29 ("the BIOS did not assign an IRQ"). Every other PCI device with an
interrupt pin shows the same code. Cause: the firmware leaves PIC-mode routing empty (Linux on the
same board: LNKA..LNKH "configured for IRQ 0", FCH PCI_INTR index 0..7 = 0). Interrupt Line holds
no 8259 IRQ. Windows 9x without ACPI has no IRQ steering miniport for the AMD FCH router (1022:790E),
so it can only use what the BIOS assigned. CSMWrap's own `pir.c` `$PIR` also had no slots for
buses without their own `_PRT`. On the X470 that is everything behind the Promontory switch (I211
on bus 4, Wi-Fi, NVMe). Its secondary-bus lookup also reads nested bridges on the root bus number.

Patch 0015 (own code, `src/usos_pciirq.c` + `src/usos_pciirq_core.inc`), only with csmwrap.ini
`pci_irq_routing = true`. The 9x flow alone writes it: `w9x_csmwrap_target.sh` →
`USOS_PCI_IRQ_ROUTING=on` → `xp_csmwrap_esp.sh`. Before `pir_init()` (boot services still up),
CSMWrap:

- walks every PCI bus from the PNP0A08/PNP0A03 root bridges (`_BBN`), through bridges by secondary
  bus number and the ACPI child with the matching `_ADR`;
- resolves each pin through the PIC-mode `_PRT`. uACPI never calls `_PIC`, so `PICM` = 0 and the
  link packages are returned. Buses without a `_PRT` use the bridge swizzle (pin + device) mod 4;
- for each used link, keeps a valid `_CRS` IRQ, or sets one with `_SRS`: the `_PRS` template is
  reduced to one IRQ, 11/10/5/9 first, least loaded, busiest links first, and the result is
  checked with `_CRS`. If that fails, the link's `_DIS` is called and its functions stay unrouted;
- writes Interrupt Line and sets ELCR level bits. IRQ 0/1/2/8/13 are never used;
- has `pir.c` build `$PIR` from that routing: one slot per bus/device with a pin, link 0x80 + n,
  bitmap = the one IRQ.

APIC-mode routing (a separate FCH register bank), the MADT, the MP table and the ACPI tables are
unchanged. 3.1.2-usos12 = usos11 (0001-0010, 0012) + 0014 + 0015. It is the new release pin. The
SeaBIOS side is unchanged from usos11-int13x: ROM 127936/131072, F-segment zone 20746 B. Binary
`35e4e37dc504aecf811277ec3243b303708a49443b4f35bc1789c2b015d2c4eb`, the same in two VM runs; the
unpatched build still matches `upstream_rebuild`.

Tests:

- `test_csmwrap_pciirq.py`: core unit cases on the X470 tree, wiring, pins and the 9x-only gate.
- `--e2e`: the real glue + uACPI on the host against the X470 DSDT/FADT dump (not in the repo),
  with a simulated PCI tree and FCH ports. It found that the firmware's `LNKE._SRS` is broken:
  `FindSetRightBit(PIRE)` instead of its argument, so it stores 0xFF. `_DIS` now handles that
  case. The result: I211 → LNKB → IRQ 10, NVMe/Wi-Fi → LNKA → IRQ 11.
- `run_csmwrap_pciirq_qemu.py`: pc + pci-bridge and q35 + root port PASS (B10Eh, Interrupt Line,
  ELCR). Without the key, the output is identical to usos11-int13x.
- boot-disk layouts (also `--only`) and apmoff PASS with usos12.

X470 with usos12: not tried. The in-place kit is `me-irq-fix`. The 9x side (whether PCI.VXD takes
the BIOS IRQs as expected with no miniport) is checked only on the hardware.

## 19. 3.1.2-usos13: USB mouse wheel (0016) and SeaBIOS romfile-only options off (0017) (2026-10-18)

3.1.2-usos13 = 3.1.2-usos12 (0001-0010, 0012, 0014, 0015, byte for byte) + 0016 + 0017. It is the
new release pin (xp_csmwrap_esp.sh `PINNED`, release.go, lock.json, run_build_vm.py, third-party.json).

**0016 USB mouse wheel** (own code: HID 1.11 report descriptors, IBM PS/2 BIOS INT 15h C2xxh, the public
IntelliMouse knock). SeaBIOS served a USB mouse to INT 15h C2xxh in the HID boot protocol only (3 bytes, no
wheel). Now `usb_mouse_setup` reads the interface's report descriptor and walks it (buttons 1-3, relative
X/Y and wheel of the report that has X, report IDs, fields up to 16 bits). With a wheel it sets the report
protocol and decodes that layout; otherwise the boot protocol as before. The knock (sample rates 200, 100,
80) gives device ID 3 when a wheel mouse is present; C204h returns the ID; C205h takes package sizes 1-7.
Consumers: USOSMOUS.DRV (98/98 SE/Me WM_MOUSEWHEEL, commit dfa24a1) and VBADOS VBMOUSE (DOS INT 33h).

Review of the draft (changes made for usos13):

- Composite devices: SeaBIOS configures only the first boot HID interface of a device (usb.c), and
  SET_PROTOCOL is per interface, so a keyboard interface of the same device stays as it was; the keyboard
  code path is byte-identical. Packets of other report IDs on the mouse interface (consumer, keyboard-macro
  reports of gaming mice) are dropped by the ID filter. New: the report protocol is used only when **every**
  input report of the interface fits in one interrupt packet. A longer vendor report would arrive split, and
  a continuation packet could start with the mouse report ID and be taken as motion. Such mice stay in the
  boot protocol.
- New: one Push level is supported (Push/Pop around feature collections). Nested Push or Pop without Push
  still keeps the boot protocol.
- New: the report-descriptor buffer is zeroed before GET_DESCRIPTOR, so a short answer parses as empty
  items, not stale memory.
- Kept: the boot-protocol fallback for no wheel, absolute X/Y, long items, descriptors over 1024 bytes,
  fields over 16 bits, any control-transfer error; values clamped to +-127; HID wheel up (positive) becomes
  the IntelliMouse negative.
- Behaviour visible to non-wheel USB mice: C204h answers 00h (standard PS/2 mouse) instead of 0AAh (the BAT
  code, an upstream bug), and C205h accepts 1-7 as the IBM BIOS does (C205h used to accept 3 only). With 3
  and no knock, the packets and the handler's Z word (0) are unchanged. i8042 (ps2port.c) is unchanged.
- Upstream limits that stay: a device whose first boot HID interface is a keyboard gets no BIOS mouse
  (wireless combo receivers); mice with wMaxPacketSize over 16 are refused.

**0017 SeaBIOS romfile-only options off.** A CSM build has no romfile source: fw_cfg needs
CONFIG_QEMU_HARDWARE (off for CSM), CBFS and multiboot are coreboot-only; csm.c only adds
`etc/extra-pci-roots-list`. CONFIG_BOOTSPLASH (`bootsplash.jpg/.bmp`, jpeg.c, bmp.c), CONFIG_SERCON
(`etc/sercon-port`) and CONFIG_HOST_BIOS_GEOMETRY (`bios-geometry`) never ran under CSMWrap. They are now off
in `seabios-config`. The VGA text console, INT 14h serial ports and the `serial = true` debug output stay.
Other default-on options were kept because they serve real hardware or the QEMU tests: ATA (QEMU pc), AHCI,
NVMe, SD, MegaRAID, floppy, USB UHCI/OHCI/EHCI/xHCI, UAS, LPT, S3 resume, CD-ROM emulation, DEBUG_LEVEL 1
(serial diagnostics). The virtio/PV SCSI drivers and DEBUG_IO were already off (they need QEMU_HARDWARE).

Layout (build log): **ROM 118688 of 131072 bytes (90.6 %, 12384 free)**. usos12 had 3136 free; with 0016
alone (draft build) it was 864. F-segment: 16-bit 36032 + 32-bit segmented 4118 + variables 3328 = 43478
bytes, **22058 bytes** for the allocation zone (6144 minimum kept). 32-bit flat 28522, flat init 41376.

Binary `8798c35d83b3cd254a5a8cae94d2d5fe5e12fc665d6819a36523895f0fb1eec9`, the same in two pinned Alpine VM
runs (each with its in-guest repeat build). The unpatched build still matches `upstream_rebuild`.

The Windows 2000 diagnostic CSMWrap stays **3.1.2-usos11-diag** (`PINNED_DIAG`, own hash). It is used
only by the Windows 2000 ACPI diagnostic setup (DATA `w2k-diag.txt`), and that round is closed (2000 PASS
on the X470, 2026-10-17). Windows 2000 does not use the BIOS mouse (own USB stack) or the 9x
`pci_irq_routing`, and the diag ESP takes its own binary and patch series from the XP/2000 package. A
rebuild on usos13 would only add code that 2000 does not reach.

Tests:

- `test_csmwrap_wheel.py`: descriptor walk, decoder and packaging built on the host (zig cc, UBSan) from
  the archive + 0016. Cases: QEMU usb-mouse, a Logitech-style report ID 2 mouse with 12-bit X/Y, a
  composite gaming mouse (mouse ID 1 with 16-bit X/Y, consumer ID 2, keyboard ID 3) with foreign packets
  ignored and values clamped, the same on a 7-byte endpoint (refused), plus a 20-byte vendor report
  (refused), the wheel in another report (refused), no wheel, absolute, truncated, Push/Pop (one level kept,
  the report size restored, nested and unbalanced refused), the boot path. Also INT 15h C205h package sizes
  1/3/4/6 with and without the knock, wiring (keyboard functions identical to upstream, the knock gated on a
  wheel mouse, C201h reset, C204h ID, the handler's Z word), the 0017 lines, the series and the pins.
- QEMU with usos13 (2026-10-18): `run_csmwrap_boot_disk_qemu.py` all 7 layouts PASS and `--only` PASS
  (`NO-DRIVE-81`); `run_csmwrap_apmoff_qemu.py` PASS; `run_csmwrap_pciirq_qemu.py` pc + q35 PASS, key-off
  output identical to usos12; `run_dos_mouse_probe.py --csmwrap <usos13> --wheel` session PASS (wheel API
  574Dh, caps 1, sums -3 / +2) and `--mode dosmouse` PASS. The dosmouse mode types `M33TEST` and `EXIT`
  through QEMU's usb-kbd, so the USB keyboard under SeaBIOS still works. The session probe with usos12 shows
  no wheel (caps 0, sums 0) PASS.

`tools/build_csmwrap_dos_esp.py` (the BIOS Core DOS installer's CSMWrap ESP image): with 15 long patch
names, `\CSMWRAP\patches` needs more than the 64 entries of one 2 KiB cluster. The directory now gets two
contiguous clusters (FAT chain). An independent FAT16 walk of the image read all 15 patches back
byte for byte.

X470 with usos13: not tried. The in-place kit for the Me install on the Micron is `me-wheel-kit`.

## 20. 3.1.2-usos14: USB mouse wheel diagnostics (0018) and more mouse shapes (0019) (2026-10-18)

3.1.2-usos14 = 3.1.2-usos13 (0001-0010, 0012, 0014-0017, byte for byte) + 0018 + 0019. It is the new
release pin (xp_csmwrap_esp.sh `PINNED`, release.go, lock.json, run_build_vm.py, third-party.json).

Why: Windows Me on the X470 with usos13 (Micron, `me-wheel-kit`): the USB mouse moves and clicks, the
wheel does nothing. The mouse is a Logitech G502 HERO (046D:C08B). Nothing showed whether SeaBIOS had
taken the report protocol, whether the knock was answered with ID 3, or where the wheel was lost.

**0018 diagnostics record** (own code). SeaBIOS keeps `usb_mouse_diag` in its low memory zone (VARLOW,
16-byte aligned, 312 bytes, signature `USOS` `MWHL` written at setup, version 1). Per mouse (first 4):
interface, wMaxPacketSize, report/boot protocol, a reason code, report ID, wDescriptorLength, the parsed
X/Y/wheel/button layout. Also the first 160 bytes of the first mouse's report descriptor, the IntelliMouse
ID and the last two sample rates, counters (packets, packets with a nonzero wheel, skipped packets of
other report IDs) and the last raw packet. `hid_parse_mouse` returns `USB_MD_*` codes instead of -1; every
decision is the same as in 0016. The record is only written. USOSDBG.EXE 1.4 finds it by scanning
80000h-FFFFFh in 16-byte steps and shows it in its `WHEEL` lines (docs/win9x-modern-2026-09-30.md 4j).

**0019 more mouse shapes** (own code, generic, no VID/PID logic):

- Report IDs present: input reports of other IDs longer than one packet no longer refuse the mouse.
  A packet that starts with such an ID is skipped with its (packets - 1) continuation packets, counted
  from the report length (up to 4 such IDs, up to 127 packets). The mouse report itself must still fit
  one packet. Without report IDs a longer report is still refused (nothing tells the reports apart).
- Zero-length packets: a report that fills its last packet exactly may be ended by a ZLP. The xHCI
  driver then copies its unchanged buffer, so the ZLP reads as the last continuation packet again. After
  such a report, a byte-identical next packet of the same mouse is skipped (USB_MOUSE_ZLP flag). A real
  mouse packet equal to a vendor continuation packet is the only false skip.
- Report descriptors up to 4096 bytes (was 1024), up to 16 input report IDs (was 8).
- usb.c: when a device's first boot HID interface is a keyboard (wireless receivers, keyboards with a
  pointing device), the first later boot mouse interface (alternate setting 0) is set up too, with a copy
  of the device record (same default pipe and address; xHCI endpoint contexts are per endpoint, as for
  UAS). Keyboards are set up exactly as before. A second keyboard interface is never added (usb-hid.c has
  one key state). The device counts as configured when the keyboard or that mouse was set up. This
  closes the "combo receiver gets no BIOS mouse" limit of section 19.

Review of the drafts: 0018 unchanged apart from being split from 0019; 0019 got the ZLP skip, the
127-packet bound, the per-mouse `maxpacket` and the usb.c part.

Shapes (host test, `test_csmwrap_wheel_diag.py`; only the QEMU descriptor is a byte copy of a published
one, the others are written to the layouts these families are reported to use, no device dump was found):
accepted: QEMU usb-mouse; Logitech HERO wired (G502 HERO layout: 16 buttons, 16-bit X/Y, wheel, AC Pan,
no report ID, 8-byte packets; usos13 already accepts it); Logitech receiver mouse ID 2 with 12-bit X/Y plus
consumer and system reports; the same with 16-bit X/Y on a 16-byte endpoint; Razer-style 5 buttons 16-bit;
SteelSeries-style ID 1 with a usage range and vendor feature reports; Microsoft basic; Microsoft Resolution
Multiplier with Push/Pop and AC Pan; generic 3-button wheel; gaming composite (mouse, consumer, keyboard)
with a 32-byte vendor input report on 8-byte packets, or a 64-byte one on 16-byte packets (ZLP case).
Refused (boot protocol, reason code): 9-byte mouse report on an 8-byte endpoint (-7), long report without
report IDs (-7), wheel in another report than X (-10), absolute X/Y (-8), no wheel (-10), truncated (-1),
nested Push (-3), Pop without Push (-4), 17 input report IDs (-5). Not handled at all (upstream limit):
wMaxPacketSize over 16 (no BIOS mouse).

Layout (build log): **ROM 120224 of 131072 bytes (91.7 %, 10848 free)**; F-segment 16-bit 36512 + 32-bit
segmented 4118 + variables 3328 = 43958 bytes, **21578 bytes** allocation zone (6144 minimum kept); low
memory 2512; 32-bit flat 28522, flat init 42080.

Binary `12d05612dc647c9c6b387157e15343ae1c7c34bd501f74c6f789566744b93ffe`, the same in two pinned Alpine VM
runs (each with its in-guest repeat build); the unpatched build still matches `upstream_rebuild`.

Tests:

- `test_csmwrap_wheel_diag.py`: the archive + 0016 + 0018 + 0019 on the host (zig cc, UBSan): the shapes
  above, decoding (G502 layout, receiver ID filter), long-report skipping (also a continuation packet that
  starts with the mouse ID), the ZLP replay, the record layout against USOSDBG.EXE's `MDIAG` (1-, 2- and
  4-byte packing), every reason code named in USOSDBG, the usb.c interface walk (receiver, vendor
  interface first, keyboard only, second keyboard, non-boot or alternate mouse, bNumInterfaces bound,
  truncated), wiring (keyboard functions identical to upstream, the HID branch of configure_usb_device the
  only usb.c change), series and pins. `test_csmwrap_wheel.py` (0016) still PASS.
- QEMU with usos14 (2026-10-18): `run_csmwrap_boot_disk_qemu.py` all 7 layouts and `--only` PASS;
  `run_csmwrap_apmoff_qemu.py` PASS; `run_csmwrap_pciirq_qemu.py` pc + q35 PASS, key-off output identical
  to usos13; `run_dos_mouse_probe.py --csmwrap <usos14> --wheel` session and `--mode dosmouse` PASS (wheel
  API 574Dh, caps 1, sums -3 / +2; the dosmouse mode types through QEMU usb-kbd). QEMU has no composite
  keyboard+mouse HID device, so the usb.c part is host-tested only.

X470 with usos14: not tried. The in-place kit for the Me install on the Micron is `me-wheel-kit-v2`.

## 21. 3.1.2-usos15: the USB wheel in the Z word without the knock, INT 15h C2xxh call ring (0020) (2026-10-19)

3.1.2-usos15 = 3.1.2-usos14 (0001-0010, 0012, 0014-0019, byte for byte) + 0020. It is the new release pin
(xp_csmwrap_esp.sh `PINNED`, release.go, lock.json, run_build_vm.py, third-party.json).

Why: Windows Me on the X470 with usos14 (Micron, G502 HERO), USOSLOG/USOSDBG: the USOSMWHL record shows
the mouse in the report protocol with the wheel at bit 48 (8 bits) and `packets:1076 with wheel:114`, so
the USB side works; but `ID:0 rates:10,40`, and USOSMOUS.DRV reports `knocks:2 knock answered ID:00
wheel:off`. Its rate table is right (200/100/80). So after the knock something resets the emulated mouse
(C201h/C205h set the ID back to 0) and sets rates 10, 40, and 0016 only passes the wheel in the Z word with
ID 3. Who does it is not known yet (suspected: Windows' own PS/2 mouse support, `*PNP0F0E` / VMOUSE,
through INT 15h C2xxh); the ring below is there to show it.

**0020** (own code):

- Package size 3 (USOSMOUS.DRV, VBMOUSE's 3-byte mode): the wheel value always goes in the far-call
  handler's Z word, with or without device ID 3. A standard handler ignores Z; for a mouse without a wheel
  (boot protocol) z is 0. Package sizes 1/2 (byte stream) and 4-7 (4th byte) are unchanged: the wheel byte
  only after the knock, so a 3-byte stream reader never gets an extra byte.
- The USOSMWHL record keeps version 1 and its first 310 bytes (older USOSDBG.EXE reads it as before) and
  grows to 512 bytes: at +312 magic `C2RG` (0x47523243), +316 a call counter (u16, wraps), +318 the next
  slot, +320 16 entries of 12 bytes: AX, BX, ES on entry, the caller's CS:IP (the INT's return address),
  the emulated device ID after the call and the result (0, or 80h | AH with CF set). `handle_15c2` records
  every AH=C2h call after its switch; the ring is only written.

Layout (build log): **ROM 120576 of 131072 bytes (92.0 %, 10496 free; usos14 10848)**; F-segment 16-bit
36672 + 32-bit segmented 4118 + variables 3328 = 44118 bytes, **21418 bytes** allocation zone (6144 minimum
kept); low memory 2704 (usos14 2512); 32-bit flat 28522, flat init 42080.

Binary `329756efef14581c17f1fe5402bcdb157162c234ce715e789d543ce53aa4a8c6` (one pinned Alpine VM run, the
same in its in-guest repeat build); the unpatched build still matches `upstream_rebuild`.

USOSMOUS.DRV v4 (src/platform/win3/usosmous.c): where the wheel is wanted (98 / 98 SE / Me, Wheel=1) a
nonzero Z sum is sent as a wheel event also when the knock was not answered with ID 3, and a knock answered
with another ID is sent once more (once per C205h init). With an older CSMWrap Z stays 0, so nothing changes
there.

Tests:

- `test_csmwrap_wheel15.py` (host, zig cc, UBSan): package size 3 with ID 0 and 3 gives the wheel in Z;
  sizes 1, 4 and 7 unchanged (wheel byte only with ID 3); a mouse without a wheel keeps Z 0; the ring
  layout (+312/+316/+318/+320, 12-byte entries, sizeof 512) and its wrap; wiring (AX/BX taken before the
  switch, the record call after it, the other C2xxh functions, `handle_mouse` and the setup identical to
  usos14); series and pins. The usos14 tests (`test_csmwrap_wheel_diag.py`, `test_csmwrap_wheel.py`) and
  the other csmwrap host tests still PASS.
- QEMU with usos15 (2026-10-19): `run_dos_mouse_probe.py --csmwrap <usos15> --wheel` session PASS (wheel
  API 574Dh, sums -3 / +2), `run_csmwrap_pciirq_qemu.py --machine pc` PASS.

X470 with usos15: not tried when this was written. No Windows 9x VM run was made with usos15 either.
