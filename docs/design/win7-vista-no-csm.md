# Windows 7 / Vista x64 on UEFI Class 3 (no CSM): the Int10h shim (design, 2026-09-26)

Status: **Windows 7 x64 is already wired** (dispatcher + UefiSeven 1.30 on
the target ESP, since the September 2026 Win7 UEFI work). It is proven in
QEMU/OVMF, but not on hardware without CSM. **Vista x64 is not wired**:
an installed Vista needs CSM today. This document records the licence
verdict and how USOS uses the shim. It covers where the shim runs, when it
is enabled, the known limits, the gap for Vista and the hardware test plan.

Related: [windows7-uefi.md](../windows7-uefi.md),
[windows7-direct-iso.md](../windows7-direct-iso.md),
[windows7-uefi-reference-analysis.md](../windows7-uefi-reference-analysis.md),
[windows7-x470-starting-windows.md](../windows7-x470-starting-windows.md),
[windows7-amd-shadow-2026-09-20.md](../windows7-amd-shadow-2026-09-20.md),
[windows7-int10-return-2026-09-20.md](../windows7-int10-return-2026-09-20.md),
[windows-native-uefi-win10-11-2026-09-25.md](../windows-native-uefi-win10-11-2026-09-25.md),
`tools/vendor/uefiseven/1.30/PROVENANCE.md`.

## 1. Problem

Windows Vista SP1+ x64 and Windows 7 x64 (and Server 2008 / 2008 R2) boot
from UEFI. Their boot manager and loader draw with GOP. The kernel's basic
display path, however, still calls the video BIOS: VideoPort `Int10`
requests run in the HAL's x86 real-mode emulator, and the emulator
executes whatever the real-mode IVT entry 0x10 (physical 0x40) points at,
normally the VGA option ROM shadowed at 0xC0000. With CSM, the firmware
loads that ROM and sets the vector. On a Class 3 machine (no CSM, or CSM
with "Video OpROM: UEFI only"), the vector is 0 or garbage. Windows then
stops at the "Starting Windows" screen (or fails with 0xc000000d).
Windows 8 and later do not need this.

## 2. UefiSeven: what it is and how it works

[manatails/uefiseven](https://github.com/manatails/uefiseven), successor
of Dawid Ciecierski's VgaShim, 1.30 = commit `b8f0baba` (2021-10-04),
also the tip of `master`. Upstream is finished and unmaintained. It is one
UEFI application (`UefiSevenPkg/Platform/UefiSeven/*.c`, 2.5k lines of C
plus a 650-byte real-mode handler adapted from OVMF's `VbeShim.asm`):

1. Frees and re-claims page 0 (the IVT) with `AllocatePages(Address)`.
2. Switches GOP to 1024x768 (the mode Windows 7's basic driver expects).
   If GOP has no such mode, `ForceVideoModeHack` fakes one inside a larger
   mode (the picture can be glitchy).
3. If IVT 0x10 already points into 0xC0000-0xEFFFF with a plausible first
   opcode, it leaves the firmware handler alone (unless `force_fakevesa=1`).
4. Otherwise it makes 0xC0000 writable: `EFI_LEGACY_REGION_PROTOCOL`, then
   `EFI_LEGACY_REGION2_PROTOCOL`, then fixed MTRRs. It copies the handler
   and two VBE tables (VbeInfo + one 1024x768x32 ModeInfo, with the GOP
   framebuffer as the LFB) to 0xC0000, locks the region again and points
   IVT 0x10 at 0xC000:0x0200.
5. It checks the handler ("Pre-boot Int10h sanity check"), reads
   `UefiSeven.ini` (`verbose`, `logfile`, `skiperrors`, `force_fakevesa`)
   and starts `<own name>.original.efi` from its own directory.

Its install mode, in the upstream README, is to rename `bootmgfw.efi` to
`bootmgfw.original.efi` on the target ESP and put UefiSeven in its place.
USOS does the same through its own dispatcher (section 4).

## 3. Licence verdict

**BSD-2-Clause**, which allows vendoring. `UefiSevenPkg/License.txt`:
"Copyright (c) 2020, Seungjoo Kim; Copyright (c) 2016, Dawid Ciecierski",
the two-clause BSD text. All C/H sources carry the matching "BSD License"
notice. `Int10hHandler.asm` adds Red Hat and Intel (OVMF) notices under the
same terms. The bundled `IntelFrameworkPkg` header is Intel's
BSD-2-Clause-Patent. The conditions: keep the notices in source, and ship
the licence text with binaries. USOS already ships `uefiseven-LICENSE.txt`
next to every copy. The licence is compatible with the rest of USOS: no
copyleft and no patent clause to track.

Vendoring is done the TouchI2cDxe way. The sources are in
`tools/vendor/uefiseven/1.30/src/` (unmodified, hashes pinned). They build
reproducibly outside the repo with the EDK2 workspace of
`tools/build_touchi2cdxe.ps1`, through `tools/build_uefiseven.ps1`. Section 8
has the result.

## 4. How USOS uses it today (as built)

| Phase | What boots | Shim? | Why |
|---|---|---|---|
| USOS menu → Windows 7 Setup | wimboot → PE ≥ 6.2: the hybrid ISO's own PE10, or the external PE10 donor for an original 6.1 ISO | **No** | PE 10 bootmgr/winload/kernel are GOP-native. `win7-no-chainload` refuses WORK/chainload for Windows 7, so the 6.1 boot manager never starts from the stick |
| USOS menu → Vista Setup | wimboot → external PE10 donor | **No** | same |
| End of Setup (`setup.exe /noreboot`) | `usos-win7-finalize after[-modern]` in PE10 | writes it | The target ESP gets the dispatcher (below) before the first reboot |
| Installed Windows 7, every boot, with or without the stick | target ESP `\EFI\Microsoft\Boot\bootmgfw.efi` **and** `\EFI\Boot\bootx64.efi` = USOS dispatcher | **Runtime decision** | see below |
| Installed Vista | target ESP: Microsoft `bootmgfw.efi`, copied to `\EFI\Boot\bootx64.efi` | **No: needs CSM** | gap, section 7 |

Target ESP layout written by `tools/windows7_uefi_publish.h` (both
directories): `bootmgfw.efi` / `bootx64.efi` = `win7-wrapper.efi`
(`tools/windows7_uefi_wrapper.zig`), `win7.original.efi` = the Microsoft
boot manager that Setup wrote (version 6.1 checked), `win7.efi` =
UefiSeven, `UefiSeven.ini` (`logfile=1`), `uefiseven-LICENSE.txt`. It is
published only after every asset is staged and verified. A third-party
fallback loader is never replaced. The stick's ESP is never a target.

Dispatcher sequence on each boot:

1. `windows7_video.handlerValid()`: IVT 0x10 points into 0xC0000-0xEFFFF
   and the first opcode is not 00/FF (the same test as UefiSeven). If yes,
   CSM already supplied a video BIOS: start `win7.original.efi` directly.
2. Otherwise: make sure GOP exists (`windows7_uefi_graphics.zig`, one
   `ConnectController` pass if GOP/UGA is missing; stop with a log line if
   still none), record a legacy-memory probe (`usos-memory.log`), unlock
   QEMU's PAM (`prepareEmulatedVga`, TCG + i440FX/Q35 only), and on AMD
   Vermeer try the fixed-MTRR RdMem/WrMem routing for C0000-CFFFF
   (`windows7_amd_shadow.zig`). Then start `win7.efi` (UefiSeven), which
   starts `win7.original.efi`.
3. Each step writes `usos-boot.log` next to the dispatcher.

## 5. When the shim is enabled: detection

Two detectors exist:

* **Menu side, `secure_boot.csm()`** (`src/platform/uefi/secure_boot.zig`):
  `EFI_LEGACY_BIOS_PROTOCOL` present, or legacy (BBS) boot options. It feeds
  the Secure Boot/MOK guidance.
* **Boot side, the dispatcher's IVT test** (above).

Decision: **the dispatcher is always installed for Windows 7, and the shim
is chosen at every boot from the IVT, not at install time from
LegacyBios.** Reasons:

1. The installed disk outlives the firmware settings it was installed
   under. Users toggle CSM (the X470 tests did so), move disks, and update
   firmware. An install-time decision would be wrong after any of these.
2. LegacyBios presence is the wrong question. On AMI boards, "CSM enabled"
   with "Video OpROM: UEFI only" produces LegacyBios but no VGA Int10, and
   Windows still hangs. The IVT test asks the right question: "is there an
   Int10 handler Windows can run?".
3. With CSM and a legacy VGA ROM, the dispatcher only adds one LoadImage
   (the original manager runs, and the firmware handler is kept). There is
   nothing to switch off.

LegacyBios stays a **menu hint**. When it is absent and the user picks
Windows 7, the summary could say that the target will use the Int10
compatibility loader. For Vista (until section 7 lands), it should warn
that the installed system needs CSM. That is a UI change with i18n strings
and is left to the menu/i18n owner. It is not in this prototype.

### Profile flag

The request was to put the shim "behind a profile flag". For Windows 7,
a flag would switch nothing: the WinPE side never needs the shim, and the
target side should decide at runtime (point 1). A flag earns its place when
**Vista** gets the dispatcher. The proposal: a `SystemTraits` field
`int10_dispatcher: bool` (true for `windows-7`, `windows-vista` once
done; Server 2008 R2/2008 inherit through `route_as`). The Vista plan adds
the dispatcher assets to `vista-support.cpio` and a flag file only when it
is set. That keeps the routing golden additive: new rows, no change to the
existing `wimboot` rows until Vista is switched on deliberately.

## 6. Known limits

* **Secure Boot must be off.** Microsoft does not support Secure Boot for
  Windows 7 or Vista, and the shim rewrites the IVT and legacy memory. USOS
  does not sign UefiSeven or the dispatcher chain for this path
  (`release.go`, "Secure Boot incompatible paths and stay unsigned"). The
  profiles carry `secure_boot_off`, and the menu refuses to start with Secure
  Boot on (`secure_boot_policy.zig`). MOK signing would change nothing:
  the Windows 7 loader itself does not enforce Secure Boot.
* **Writable 0xC0000 is required, and it is the weak point.** UefiSeven
  can unlock through LegacyRegion(2) (only present on CSM-capable
  firmware) or MTRRs, and MTRRs change caching, not the chipset routing.
  In QEMU/OVMF, q35 PAM keeps 0xC0000 read-only until USOS sets it (see
  the upstream-only QEMU run below: "Pre-boot Int10h sanity check failed",
  then the hang). On AMD Zen, C0000-CFFFF is routed to MMIO unless the
  fixed-MTRR RdMem/WrMem bits say DRAM. USOS's `amd_shadow` does that only
  on CPUID `00a20f12` (Vermeer 5700X/5800X3D). Other AMD CPUs (for example
  the ROG Ally's Phoenix) and Intel boards without LegacyRegion are
  **unhandled** and will log a failed sanity check.
* **Resolution: 1024x768 only.** The VBE table offers one 1024x768x32
  mode. Windows keeps it until a vendor display driver is installed. If
  GOP lacks 1024x768, the forced-mode hack may give a distorted picture.
* **Handler coverage.** The handler implements the subset Windows 7's
  basic driver uses. Upstream 1.30 loops forever (`jmp Hang`) on an
  unknown function. `tools/build_windows7_int10_patch.py` is an
  experimental byte patch that returns 014F instead. It is not shipped.
* **More than Int10.** Windows 7 also touches VGA I/O ports and the
  0xA0000 window directly (PrimeExpert on FlashBoot). With CSM off, the
  firmware may leave "VGA Enable" clear in the Bridge Control register of
  the root port above the GPU, or the GPU's legacy decode off. Those
  accesses then go nowhere. This is an **open hypothesis** for the X470
  (RX 560) hang, which persisted after C0000 was unlocked and the handler
  passed its check (windows7-int10-return doc). The next experiment is to
  log, and optionally set, VGA Enable on the bridge path to the GOP device
  before starting UefiSeven.
* **Servicing can undo it.** A Windows 7 update or `bcdboot` that rewrites
  `\EFI\Microsoft\Boot\bootmgfw.efi` removes the dispatcher from the main
  entry. `\EFI\Boot\bootx64.efi` still carries it, but a firmware entry
  pointing at `bootmgfw.efi` then hangs without CSM. Recovery is to
  re-publish the dispatcher (a USOS "repair boot" utility is a candidate)
  or to enable CSM.
* **GOP must exist when the dispatcher runs.** Without GOP there is no
  framebuffer for the VBE table. The ConnectController pass covers boards
  that connect graphics lazily on fast boot.

## 7. Vista x64: the gap and the plan

The Vista finalizer (`tools/windows_vista_install.c`, `configure_boot`)
copies Microsoft's `bootmgfw.efi` to the target fallback path and sets
`testsigning` on the default entry. It installs no Int10 shim. Every
hardware Vista success so far was with CSM on (windows-vista-*-2026-09-2x
docs). UefiSeven does not check the Windows version, and Vista SP1+'s
basic display path is the same VideoPort/x86-emulator design. It should
work, but that is **unverified**.

Plan (not implemented here; it changes a hardware-confirmed path):

1. Trait `int10_dispatcher` (section 5). When set for `windows-vista`, add
   `usos-win7-wrapper.bin`, `usos-win7-video.bin`, `UefiSeven.ini` and the
   licence to `vista-support.cpio`, plus a plan flag (new golden rows).
2. `configure_boot`: after the BCD/test-signing step, call the Win7
   publisher (`windows7_uefi_publish.h`) with the Vista loader as
   `win7.original.efi` (the dispatcher only needs the file names). Accept
   the 6.0.600x version instead of 6.1.
3. QEMU: full Vista SP2 x64 install on OVMF/TCG (no CSM), then the
   installed disk once plain and once with the dispatcher (A/B like 8.2).
4. X470: repeat the CSM-on install (regression: the dispatcher must pass
   straight through). Then boot the same disk with CSM off.

## 8. Prototype results (this change)

### 8.1 Source build

`tools/build_uefiseven.ps1` builds the vendored 1.30 sources with EDK2
`edk2-stable202411` and VS2022 into `UefiSeven.efi` (54 784 bytes, SHA-256
`e601fdc4…0447c0`). Repeated clean builds give the same bytes. The shipped
file stays the upstream release binary (`0a44a256…a947`). Switching is a
separate, hardware-tested step (PROVENANCE.md).

### 8.2 QEMU A/B: Windows 7 SP1 x64 Setup on OVMF without CSM

Setup: QEMU TCG, q35, 2 GiB, `-vga std`, bundled OVMF
(edk2-stable202408, no CSM), no Secure Boot. The ESP is a vvfat folder
holding the ISO's `EFI\Microsoft\Boot\BCD` and fonts, `boot\boot.sdi` and
`sources\boot.wim`. The boot manager is the **6.1.7601** `bootmgfw.efi`
from `boot.wim` index 1, the same generation Setup installs on the target.
This is the classic "Win7 without CSM" case, and USOS's own installer
never hits it (PE10), so it exercises exactly what the target-ESP dispatcher
must fix. Harness: `tools/tests/windows7_int10_ab.py` (manual, about 13
minutes per variant). Screens: `docs/evidence/win7-no-csm-qemu-2026-09-26/`.

| Variant | `\EFI\BOOT\BOOTX64.EFI` | Result |
|---|---|---|
| plain | Microsoft `bootmgfw.efi` 6.1 | **Hang**: "Starting Windows" from 90 s through 720 s (`plain-t0720.png`) |
| upstream install mode | UefiSeven (source build), `BOOTX64.original.efi` = bootmgfw | **Hang**: serial shows `Pre-boot Int10h sanity check failed` (C0000 not writable, `skiperrors=1` went on), then "Starting Windows" through 720 s (`upstream-t0720.png`) |
| USOS target layout | `win7-wrapper.efi` → `win7.efi` = UefiSeven (source build) → `win7.original.efi` = bootmgfw | **Setup**: the Windows 7 language page at 90 s, still there at 720 s (`usos-t0090.png`) |
| USOS target layout, shipped binary | as above with the release `UefiSeven.efi` | **Setup** at 90 s (`usosrel-t0360.png`): the source build and the release binary behave the same |

The dispatcher's `usos-memory.log` from the run confirms the class-3 state:
`LegacyRegion=false LegacyRegion2=false INT10=00000000`, C0000 reads as
zeros, GOP present (framebuffer 0x80000000).

What this shows: the hang is the missing Int10 handler. The shim fixes it
only when 0xC0000 is really writable. In QEMU, USOS's PAM unlock is the
piece that makes the difference. On hardware, that piece is LegacyRegion,
AMD fixed-MTRR routing, or nothing (section 6). This is Setup's PE 6.1, not
an installed system. The installed-system path (the same dispatcher on a
target ESP) already passed a full QEMU install to the desktop in September
(windows7-uefi.md).

## 9. Hardware tests needed

1. **X470 / 5700X / RX 560, CSM disabled, Secure Boot off.** Install
   Windows 7 SP1 x64 from the current stick to the SATA SSD. Then boot the
   SSD without the stick. Read `EFI\Microsoft\Boot\usos-boot.log`,
   `UefiSeven.log`, `usos-memory.log` and `usos-amd-shadow.log` from the
   ESP. Expected: AMD shadow PASS, UefiSeven sanity check success. If it
   still hangs at "Starting Windows", that points at VGA routing (section 6)
   rather than Int10. Enable CSM on the same disk once as a control: the
   dispatcher must log "valid firmware Int10".
2. **X470, CSM enabled but "Video OpROM: UEFI only".** It should behave
   like CSM off (no VGA Int10), which confirms the IVT-based decision.
3. **ROG Ally (no CSM, AMD Phoenix).** Expect `amd_shadow` SKIPPED (wrong
   CPUID) and UefiSeven unable to unlock C0000. The logs will say whether
   the region happens to be writable. Windows 7 also has no Ally drivers
   (USB4/xHCI, display), so this is a shim test, not an installation target.
4. **Vista**: only after section 7 is implemented, the same pair as test 1.
