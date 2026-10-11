# CSMWrap in USOS: XP (and Vista's VgaSave case) without firmware CSM (design, 2026-09-27)

Status: **design + QEMU prototype, not in the release.** Facts about CSMWrap
(licence, mechanism, limits, build) are in
[../research/csmwrap.md](../research/csmwrap.md). This replaces the outline
in [nt5-uefi-family.md](nt5-uefi-family.md) section 7 where they differ.

## 1. Goal and the key observation

Goal: install and run Windows XP (then Vista with its basic VGA path) on a
UEFI machine whose CSM is off (X470 with CSM disabled) or missing (ROG Ally,
Intel 12th gen+, some AM5 boards).

Key observation: the **USOS preparation for XP already runs in UEFI mode.**
The XP UEFI-CSM path (`docs/windows-xp-uefi-csm-pae-2026-09-21.md`) is:

```
UEFI menu -> EFI\USOS-XP -> micro-Linux preparer -> target disk: MBR, active NTFS,
             $WIN_NT$.~BT/~LS, NT52 bootstrap (EDD)          [UEFI mode, no BIOS code]
reboot -> firmware CSM -> target MBR -> NTFS boot -> SETUPLDR -> text mode -> GUI -> XP
```

Only the part after the reboot needs a BIOS. So CSMWrap does **not** have to
run the USOS preparer, the micro-Linux, or the BIOS Core under SeaBIOS. It
only has to replace "firmware CSM boots the target MBR". The only new thing
is a way to reach the target MBR through CSMWrap, on every boot of that disk.

## 2. Chosen design: a CSMWrap ESP on the target disk

```
UEFI menu -> EFI\USOS-XP -> micro-Linux preparer (unchanged) -> target:
    MBR (USOS NT52 bootstrap, unchanged)
    part 1  type 0xEF  FAT16/32  ~64 MiB   \EFI\BOOT\BOOTX64.EFI = CSMWrap 3.1.2
                                            \EFI\BOOT\csmwrap.ini, LICENSE files
    part 2  type 0x07  NTFS, active        XP (as today)
reboot -> firmware boots the target's UEFI removable path -> CSMWrap
       -> SeaBIOS CSM (card VBIOS POSTed) -> BBS: this disk first -> MBR (DL=80h)
       -> active NTFS -> SETUPLDR -> text mode -> GUI -> XP; every later boot the same
```

Why this and not the alternatives:

| Option | Verdict |
|---|---|
| **A. CSMWrap on the target ESP (chosen)** | Needed anyway: the installed XP must boot without the stick, and every boot needs CSMWrap. CSMWrap's own BBS rule (the drive it was loaded from goes first) makes the target MBR the boot device with no configuration. `DL=80h` matches the prepared bootstrap (`XP_BIOS_DRIVE=80`). |
| B. CSMWrap on the stick, SeaBIOS boots the stick's BIOS MBR -> USOS BIOS Core -> existing BIOS XP path | Works in principle (the stick is BIOS-bootable), and useful as a *diagnostic* (USOS BIOS menu on a CSM-less board). But then SeaBIOS numbers the stick 80h and the target 81h during preparation, the installed system still needs A for later boots, and the BIOS Core path duplicates the UEFI preparer. Not the install path. For the DOS, FreeDOS and Windows 3.x paths this is the chosen entry: [bios-via-csmwrap.md](bios-via-csmwrap.md). |
| C. CSMWrap on the stick, chaining to the target | CSMWrap has no boot-device option in 3.1.2 (only BBS "own drive first"). Would need an `int 18h`/chain boot sector on the stick ESP and still A for later boots. Rejected. |

### 2.1 Partition plan (profile `uefi_csmwrap_target`)

`FirmwareMask.uefi_csmwrap_target` already exists in
`docs/design/refactor-os-pipeline.md`. The profile
`xp-x86-sp3-uefi-csmwrap` (new, experimental, off by default) differs from
`xp-x86-sp3-uefi-csm` only in the plan:

- **Whole-disk mode only** at first ("format the whole disk"), MBR, < 2 TiB:
  `p1` = 64 MiB FAT32 (type 0xEF, LBA 2048), `p2` = NTFS (type 0x07, active)
  from the next 1 MiB boundary. The preserve-partitions mode is out of scope
  until tested (an existing ESP on an MBR disk could be reused, but XP's
  128 GiB rule and C: assignment in `MIGRATE.INF` must be rechecked).
- `MIGRATE.INF` keeps assigning C: by MBR signature + offset of the NTFS
  partition: the offset changes (p2), the mechanism does not. XP ignores
  type 0xEF (no drive letter), text mode keeps it (`Repartition=No`).
- The preparer copies `csmwrapx64.efi` (hash-checked against
  `tools/vendor/csmwrap/3.1.2/manifest.json`), a generated `csmwrap.ini`
  (`serial=false`, `verbose=false`; a "diagnostic" answer sets
  `verbose=true`) and the licence/source files to p1.
- It also writes the stick-side ready file as today; the reboot message
  says "boot the target disk's UEFI entry (not Legacy)".
- The firmware UEFI boot entry: the removable path is enough on most
  firmware (the X470 AMI lists every FAT partition with `BOOTX64.EFI`,
  an accepted limitation per `hardware-topology`); optionally the preparer
  adds a `Boot####` "Windows XP (CSMWrap)" via `efibootmgr` from the
  micro-Linux, as the Win7 dispatcher path does for its ESP.

### 2.2 Menu and selection

- Profile trait `csmwrap` (planner), selected only when the firmware
  reports **no CSM** *and* the user picked XP, or by an explicit answer
  "Legacy through CSMWrap (experimental)". With CSM available USOS keeps
  the firmware CSM path (proven on the X470).
- Summary screen: "Secure Boot must be off", "XP will see one CPU fewer",
  "USB keyboard does not work in XP text mode / until the USB3 driver
  runs", "a GPU without a legacy VBIOS gives a black text mode".
- Secure Boot on -> the option is shown disabled with that reason
  (CSMWrap is never signed, research section 5).

### 2.3 Build flag

Not wired into `build.bat`/payload yet. When it is, it goes behind a build
option (`-Dcsmwrap=true`, default false), the same way the XP UEFI-CSM
package was staged: the flag adds `tools/vendor/csmwrap/3.1.2/*` to the XP
package (`EFI\USOS-XP\csmwrap\`) and enables the profile; without the flag
the payload is byte-identical (golden digests unchanged).

## 3. Video

- **Card with a legacy VBIOS in its ROM (RX 560):** CSMWrap POSTs it from
  `PciIo.RomImage`, so XP text mode, `bootvid`, `vga.sys`/VgaSave and
  VBE all behave as under firmware CSM. This is the X470 case to test.
- **GOP-only GPU (Ally 780M, most class-3 iGPUs):** SeaVGABIOS on the GOP
  framebuffer = VBE only. XP text mode and the boot logo write VGA memory
  directly -> black screen (text mode is unattended, so it still
  completes); the desktop needs VBEMP (user-supplied driver, like the
  VBEMP note in nt5-uefi-family 7.2). Alternative: `vgabios=` in
  `csmwrap.ini` with a dumped VBIOS of the *same* card (legal only if the
  user supplies it from their own card).

## 4. Target-side boot after installation

Nothing extra: the installed disk keeps p1 with CSMWrap, and every boot of
that disk's UEFI entry goes through it. Risks: a firmware update or CMOS
reset that drops the `Boot####` entry (the removable path still works);
Windows XP never touches p1. Removing CSMWrap later (for example to go back
to firmware CSM) is harmless: the MBR still boots in a CSM.

## 5. Vista's VgaSave case

Vista x64 on UEFI (the current USOS Vista path) runs `bootmgfw.efi` ->
`winload.efi`; it needs UEFI boot services and runtime services, so it
**cannot** run after CSMWrap (which exits boot services and never
returns). Two options:

1. **VBIOS POST only, then continue in UEFI.** Not a CSMWrap feature
   (3.1.2 always proceeds to `Legacy16Boot`). It would be a separate tool,
   in the Int10 dispatcher chain before UefiSeven/Vista: unlock C0000 (the
   AMD shadow unlock USOS has), copy the PC-AT image from the GPU's
   `RomImage` to C0000, run its init entry (`C000:0003`) through a
   real-mode thunk *before* ExitBootServices, then chainload the Vista boot
   manager. Windows' HAL x86 emulator would then run the card's real Int10
   (like CSM-on), and the RX 560's A0000 would decode. Hard problems: the
   real VBIOS POST reprograms the display engine, so the firmware GOP
   framebuffer becomes stale (the Vista boot manager draws through GOP);
   the POST needs a working real-mode thunk and PCI/IO routing inside UEFI;
   reusing CSMWrap's `oprom.c`/`x86thunk.c` makes the tool LGPL-2.1.
   **Research item, not planned for the first CSMWrap milestone.**
2. **Full legacy boot:** install Vista as a BIOS/MBR system (USOS already
   has BIOS Vista from ISO: `src/platform/bios/windows_native_iso.zig`)
   and boot it through the same target ESP + CSMWrap as XP. Everything
   Vista needs from the BIOS (VGA, Int13, E820) is then SeaBIOS + the real
   VBIOS. Costs: the installed Vista is a legacy install (MBR, no UEFI
   runtime), preparation needs a BIOS-mode Vista preparer run from UEFI
   (today's BIOS Vista path runs from the BIOS Core). **Preferred** if the
   X470 test of the Int10 dispatcher path for Vista (win7-vista-no-csm.md
   section 9 test 4) fails because of VgaSave/A0000.

## 6. Test plan

QEMU (done, see section 7): OVMF without CSM + target ESP + CSMWrap ->
XP text mode.

X470 (5700X, AMI, RX 560), CSM **off**, Secure Boot off, x2APIC off:

1. **Smoke:** a spare disk prepared by the prototype layout (or the stick
   with CSMWrap as a boot option and `verbose=true`): CSMWrap log shows
   `Unlock!` (AMD MTRR path), finds the RX 560 PC-AT image, SeaBIOS banner
   on the card's own VBIOS (real VGA text), BBS picks the right disk.
2. **XP text mode -> GUI -> desktop** from a target prepared with the
   p1 ESP. Watch: AHCI driver (SATA mode stays AHCI), `pae-install.log`
   and visible RAM (E820 from CSMWrap), USB keyboard only after USB3
   driver, one CPU fewer in Task Manager.
3. **Every later cold boot** through the target ESP without the stick;
   CMOS default boot order.
4. With Above-4G/ReBAR on (the X470 default in UEFI mode): if CSMWrap
   fails BAR relocation, record it and retry with both off.
5. Vista: only if section 9 test 4 of win7-vista-no-csm.md fails on
   VgaSave: the full legacy Vista option (5.2).

ROG Ally RC71L (no CSM, 780M, xHCI only, touch):

1. CSMWrap smoke with `verbose=true` from the stick: unlock path (AMD MTRR
   on Phoenix), SeaVGABIOS expected (no PC-AT image) -> VBE only.
2. XP text mode is expected to be **black** but should complete; record
   whether GUI Setup (VBE via VGA miniport fails; VBEMP needed) shows.
3. No input in XP without a USB3/xHCI driver and no touch at all: the Ally
   is a stretch target; the realistic result is "boots, but not usable
   without extra drivers".

## 7. QEMU prototype (2026-09-27)

`tools/tests/legacy_bios/run_csmwrap_xp_ovmf.py` (test tool only). It takes
a disk prepared by the real XP package preparer
(`run_seabios_xp_uefi_csm_textmode.py`, phase 1: MBR, active NTFS from
LBA 2048, `$WIN_NT$`), puts a qcow2 overlay on it (the prepared image is only
read), grows it by 32 MiB and adds MBR partition 2 (type 0xEF) with a FAT16
ESP it builds itself (deterministic; `BOOTX64.EFI` = CSMWrap 3.1.2,
hash-checked; `csmwrap.ini` with serial + verbose). Then it boots OVMF
(`edk2-x86_64-code.fd`, no CSM), i440FX, 2 CPUs, `-vga std` (QEMU's std VGA
carries `vgabios-stdvga.bin`, a PC-AT option ROM), TCG.

(The partition is at the end only because the prepared image fills the
disk; the product layout puts the ESP first, section 2.1.)

Prepared disk: `zig-out/xp-uefi-textmode-en-v5/target.qcow2` (XP SP3 EN,
package v5). Artefacts: `zig-out/csmwrap-xp-ovmf*/` (screens as PNG, VGA
text dumps, `serial.log` with CSMWrap's verbose log, `result.json`).

| Run | Firmware / accel / video | Result |
|---|---|---|
| **before** | OVMF, TCG, std VGA; disk without the ESP | `BdsDxe: failed to load Boot0001 "UEFI QEMU HARDDISK" ... Not Found` -> UEFI Shell. No way to boot the legacy MBR. |
| **after** | OVMF, TCG, std VGA; disk with the CSMWrap ESP | OVMF boots `Boot0001` = the disk's `\EFI\BOOT\BOOTX64.EFI` -> CSMWrap -> `SeaBIOS (version 578d260b-CSMWrap-3.1.2)` on real VGA text (720x400) -> XP `Setup is inspecting...` -> F6/F2 prompts -> `Examining disk configuration` -> **`Setup is copying files...` at 46.7 s** after power-on. **PASS.** |
| after, no legacy VBIOS | OVMF, TCG, `bochs-display,romfile=` (GOP only, no PC-AT ROM) | CSMWrap: `Video Initialisation Succeed with SeaVGABIOS GOP`. Screen **black from SeaBIOS on** (SETUPLDR's text is in B8000 but not visible); VGA text memory shows SETUPLDR up to `Setup is starting Windows`, then nothing for 4.5 min and the disk overlay did not grow (no copying). **FAIL**: XP text-mode Setup does not proceed without a legacy VBIOS (expected risk, section 3). |
| after, WHPX | OVMF, WHPX, std VGA | SeaBIOS and SETUPLDR as in TCG, then **stalls at `Setup is starting Windows`** (5 min, no disk writes). Control: the same prepared disk on plain SeaBIOS + WHPX reaches `Setup copies files` in 31 s. So the stall is specific to CSMWrap under WHPX (not investigated: timer/APIC ExtINT routing or the BIOS-proxy AP under Hyper-V's virtual APIC are the suspects). TCG is the reference until explained; it is a **risk to watch on real hardware** (hang at the same point). |
| after, WHPX `kernel-irqchip=off` | as above | Same stall at `Setup is starting Windows`. |
| **run-through** | OVMF, TCG, std VGA | Text mode copied files (46 % at 267 s), XP restarted itself; OVMF started `Boot0001` again -> **second CSMWrap boot** (`Unlock!` twice in the serial log, second SeaBIOS banner at 373 s) -> XP GUI Setup: **"Welcome to the Windows XP Setup Wizard"** (attended wizard waiting for Next, as in the CSM path). Stopped there (time box). **PASS**: the target-side ESP boots the installed disk on every restart without the stick. |

CSMWrap log highlights (after, std VGA): `Legacy Region 2 Protocol not
found` -> `Unlocking BIOS region with PIIX4 PAM` -> `Unlock!`;
`csm_bin_base: 0xe0000` (SeaBIOS CSM16 is 128 KiB, so a VBIOS may be at most
128 KiB: 0xC0000-0xDFFFF); MADT patched to hide APIC ID 1 (`BIOS proxy
ready (AP 1)`); `Video Initialisation Succeed with OpROM` (QEMU std VGA's
`vgabios-stdvga.bin`); `bootdev: Boot device: PCI 00:01.1 type=HDD`, BBS
with the loading disk first; E820 with 24 entries built from the UEFI map.
Note `CMOS: ... ext=7168 KB` (the first OVMF NVS range at 8 MiB caps the
CMOS extended-memory count; XP uses E820, unaffected).

## 8. Implementation (2026-09-27, experimental)

Profile `xp-x86-sp3-uefi-csmwrap`, used **only when the UEFI menu finds no
firmware CSM** (`secure_boot.csm().likelyOn()` false). With a CSM nothing
changes: same kernel command line, same Windows plan output (checked
byte-for-byte), same package goldens.

* **Menu** (`src/platform/uefi/xp_preparation.zig`, `manual_summary.zig`):
  without CSM the XP micro-Linux gets ` usos.xp_boot=csmwrap` in addition to
  the unchanged `usos.plan_profile=xp-x86-sp3-uefi-csm`, and the summary shows
  "XP without CSM (experimental): CSMWrap, card with a legacy VBIOS, 1 core
  reserved" (`boot.summary.xp_csmwrap`, 27 locales). Same disk picker and
  confirmation as XP.
* **Plan** (`tools/xp_windows_partition_plan.awk`): `USOS_XP_ESP_TAIL_SECTORS`
  (133120 = 65 MiB, exported by `legacy_xp_staging.sh` only in CSMWrap mode)
  keeps the disk's last sectors free; unset, the output is identical.
* **ESP** (`tools/xp_csmwrap_esp.sh`, after `prepare_xp_target.sh` PASS): a
  64 MiB FAT16 partition, MBR type 0xEF, in the first free MBR slot at the end
  of the disk, with `\EFI\BOOT\BOOTX64.EFI` = CSMWrap 3.1.2 (SHA-256 pinned,
  read back), `\EFI\BOOT\csmwrap.ini` (`serial = false`; `verbose = false`
  since the hardware PASS, `verbose = true` when an empty
  `EFI\USOS\csmwrap-verbose.flag` is on the USOS stick) and `\CSMWRAP\`
  licence files + `SOURCES.txt`.
  Refuses if the tail area overlaps a partition, if an ESP already exists, or
  with a custom WINNT.SIF. No `Boot####` entry is written: the firmware's
  removable-path entry for the target disk boots it.
* **Deviation from 2.1:** the ESP is **last**, not first. The NTFS Windows
  partition stays MBR entry 1 at LBA 2048, so the ARC paths
  (`multi(0)disk(0)rdisk(0)partition(1)`) in WINNT.SIF, boot.ini and pae.exe
  and the MIGRATE.INF offset are exactly as in the proven UEFI-CSM layout.
  The QEMU prototype (section 7) used the same position.
* **Payload:** `EFI\USOS\csmwrap\` (staged by `usos-efisign release`,
  hash-checked, unsigned): `csmwrapx64.efi`, `LICENSE-CSMWrap-LGPL-2.1.txt`,
  `COPYING-SeaBIOS-LGPLv3.txt` (FSF LGPLv3 text, vendored as
  `tools/vendor/csmwrap/3.1.2/COPYING.LESSER`, hash in its manifest),
  `COPYING-SeaBIOS-GPLv3.txt` (GPLv3 text from the wimlib vendor folder),
  `SOURCES.txt`.
* Test: `tools/tests/legacy_bios/run_csmwrap_xp_prepared.py` (package chain in
  CSMWrap mode, then OVMF without CSM, TCG).

## 9. Hardware results

**2026-09-27, X470 Master SLI/ac / Ryzen 7 5700X, CSM OFF, Secure Boot OFF, build
B260927-153019: PASS.** USOS (UEFI) prepared the Intel SSD in CSMWrap mode
(`legacy-xp-csmwrap.log`: NTFS in MBR slot 1 at LBA 2048, CSMWrap ESP in slot
2 at LBA 234309632, 131072 sectors, BOOTX64.EFI read back); the firmware then
booted the target through CSMWrap, and XP SP3 (Polish) installed unattended
with the user's answer profile. Still to be reported by the user: PAE /
31.9 GB, CPU count (CSMWrap reserves one core), USB.

Findings from that run, fixed afterwards:

* **English micro-Linux UI.** This was not specific to CSMWrap. The command
  line did carry `initrd=\EFI\USOS\lang.cpio`, but that build's
  `initramfs-xp` was 114817435 bytes, not a multiple of 4. The EFI stub
  concatenates the initrds without padding, and the kernel accepts a cpio
  header only at a 4-aligned offset. So `lang.cpio` was dropped
  (`menu-hardware.txt`: "rootfs image is not initramfs (invalid magic at
  start of compressed archive)"), and the UI fell back to English whenever
  `/mnt/esp/EFI/USOS/lang.bin` was not mounted. Earlier builds were
  4-aligned by chance, and `initramfs-usos` (Vista disk prep, systemd-boot
  entry) was exposed the same way. `pad_initrd` (tools/build_micro_linux.py)
  now zero-pads both files to 4 bytes (`tools/tests/test_initrd_alignment.py`).
  A Zig test in `xp_preparation.zig` pins the CSMWrap command line to the
  default XP one plus `usos.xp_boot=csmwrap`.
* **CSMWrap on-screen log** was on (`verbose = true`). It is now off by
  default, with the flag-file switch above.
  `verbose = false` still left the upstream CSMWrap logo (always printed),
  the SeaBIOS banner and the "Press ESC for boot menu" prompt (2.5 s wait)
  on screen. The release now ships a patched source build, **CSMWrap
  3.1.2-usos1** (since 2026-09-28; staged 2026-09-27), which removes them on
  a `verbose = false` boot and keeps all of it with `verbose = true` (so the
  flag file restores the full diagnostics); see
  [../research/csmwrap.md](../research/csmwrap.md) sections 6 and 7.

## 10. Vista without firmware CSM (profile `vista-x64-sp2-uefi-csmwrap`, 2026-09-27)

Status: **experimental, hardware PASS** (X470, 2026-09-28, build
B260927-205829-3C3E79FE; section 10.5). Replaces the "full legacy boot"
option 2 of section 5 (now chosen, because the X470 test of 2026-09-27
gave a black screen on the UEFI path: vgapnp Code 10, VgaSave needs A0000,
which only a POSTed legacy VBIOS provides; win7-vista-no-csm.md section 10).

### 10.1 Chosen design: PE10 staged on the target, Setup in BIOS mode

```
UEFI menu (no CSM) -> Vista ISO + PE10 donor checked (hash), request on the ESP
  -> micro-Linux step 610 (disk picker + wipe confirmation) -> target, MBR:
       free space (Vista installs here)
       slot 1  NTFS USOS-VISTA, active, 1 GiB: NT60 boot code, bootmgr
               (PE10 Windows\Boot\PCAT), boot\bcd + boot.sdi (donor ISO),
               sources\boot.wim = the donor's Setup image + the USOS helpers
               in \Windows\System32 (what wimboot injects on the UEFI path)
       slot 2  CSMWrap ESP, 64 MiB (tools/xp_csmwrap_esp.sh, unchanged)
restart -> firmware boots the disk's UEFI entry -> CSMWrap -> SeaBIOS (card
  VBIOS POSTed) -> MBR -> NT60 -> bootmgr -> PE10 in RAM (BIOS mode, own USB 3,
  AHCI, NVMe) -> USOS Vista installer (usos-vista-csmwrap.flag):
     staging partition marked inactive, Vista setup.exe from the ISO on the
     stick (ImDisk, as on UEFI), InstallTo = the prepared Windows partition
     (since 2026-10-11, section 13; before: the user picked unallocated space)
  -> Setup in BIOS mode: MBR partition, bootmgr + \Boot\BCD on its own
     partition (active), NT60 MBR
  -> finalizer: test signing in that BCD, USB v11 first boot armed (MBR
     identity in MountedDevices), staging entry removed, message "remove the
     stick" -> restart -> CSMWrap -> Vista phase 2 / OOBE / desktop
every later boot: firmware -> the disk's UEFI entry -> CSMWrap -> Vista
```

Why this one:

| Option | Verdict |
|---|---|
| **A. PE10 staged on the target, Setup in BIOS mode (chosen)** | Setup itself makes a real legacy install (no conversion afterwards). PE10 has USB 3 (the X470 has only xHCI ports), so keyboard and mouse work in Setup; Vista's own PE does not. The proven installer (KMDF servicing, USB v11 arming, autochk) is reused; the ISO stays on the stick, nothing big is copied. The CSMWrap ESP is the XP one, on every later boot too. |
| B. Vista's own boot.wim through CSMWrap (stick or target) | No xHCI driver in Vista's WinPE: no input in Setup on the X470. Injecting the test-signed USB 3 backport into Vista's WinPE needs KMDF 1.11 and test signing inside WinPE. Rejected. |
| C. The UEFI path as today, then convert the installed disk (GPT to MBR, BCD for BIOS) | Setup phase 2 would run on a firmware type other than the one phase 1 prepared; GPT to MBR conversion with mounted volumes, MountedDevices rewrite. Too many unknowns. Rejected. |
| D. USOS BIOS Core on the stick through CSMWrap | Runs the whole BIOS menu under SeaBIOS; the BIOS Vista path uses Vista's PE (no xHCI, see B). Rejected. |

### 10.2 Details

* **Selection** (`src/platform/uefi/manual_summary.zig`): Vista (and Server
  2008, routed as Vista), ISO, UEFI and `secure_boot.csm().likelyOn()` false.
  The routing rows are unchanged (`vista-uefi-pe10` still decides the
  selection); `os_profiles.csmwrap_variants` names the variant and the golden
  file lists it (`csmwrap` rows, additions only). With a CSM nothing changes.
  Summary line `boot.summary.vista_csmwrap` (27 locales).
* **Request** (`windows_native_iso.prepareCsmwrap`): the same ISO and PE10
  donor checks as the wimboot start (the donor is hashed against
  `winpe-donor.ini`), then `\EFI\USOS\vista-csmwrap\usos-source.ini` (the DATA
  binding the wimboot start injects) and `request.ini` (DATA-relative ISO and
  donor paths, folder, answer source; no secrets). The micro-Linux starts with
  `usos.legacy_action=vista-csmwrap usos.plan_profile=vista-x64-sp2-uefi-csmwrap`
  (`vista_preparation.formatCommand`; the `vista-disk` command line is pinned
  byte-for-byte by a test).
* **Disk** (`tools/vista_csmwrap_prepare.sh`, `tools/vista_csmwrap_target.sh`,
  pipeline step 610): the XP disk picker (the stick and read-only disks are
  never offered), wipe confirmation, >= 16 GiB and <= 2 TiB. MBR code: the
  USOS MBR (`xp-geometry-fix-mbr-440.bin`, boots the active partition by EDD),
  a random disk signature. NT60 NTFS boot code: extracted at build time from
  the build host's `bootsect.exe` (`extract_xp_nt52_boot.py --nt60-ntfs-out`,
  the NT52 precedent; nothing Microsoft in the repo). Every write is read
  back (MBR, boot code, the helpers inside the WIM, the final table).
* **Answers**: USOS profiles (rendered by the menu to `\EFI\USOS\answer`,
  taken by `usos_answer_plan_take`) and DATA `Unattended` files; since
  2026-09-28 also on the UEFI path with CSM (the same installer merge). The installer inserts its KMDF `<servicing>` block right
  after `<unattend ...>` (`merge_user_answer`, UTF-8 only; a file with its own
  `servicing` section is refused). Since 2026-10-11 the installer adds InstallTo for
  the prepared Windows partition (section 13); before, disk selection stayed manual (the renderer
  writes no DiskConfiguration/InstallTo).
* **Installer** (`tools/windows_vista_install.c`, CSMWrap mode v1): BIOS
  firmware is accepted only with `usos-vista-csmwrap.flag`; before Setup the
  WinPE letters of the prepared disk's volumes are removed and the staging
  partition becomes inactive and hidden (type 0x17); the target disk is
  the one internal MBR disk with the recorded signature; no ESP hints and no
  Vista bcdedit extraction; partition identity = signature + offset (what
  MountedDevices stores); after Setup: exactly one active partition, its
  `\Boot\BCD` default entry must name the new partition, then test signing on;
  the staging entry is removed unless Setup made it the system partition; on
  a failed Setup the staging partition is made active again when no other
  partition is, so the next boot of the disk retries. Int10 dispatcher: not
  used (SeaBIOS runs the card's real VBIOS).
* **Unchanged**: the Vista UEFI path with CSM (same wimboot plan, same
  installer behaviour: the new code runs only with the flag), the XP path and
  its goldens, Vista disk preparation (still off by default), autochk
  exclusion (Vista only, as before).

### 10.3 Limits

* CSMWrap limits of section 3: a card without a legacy VBIOS gives no
  VgaSave (black screen); one CPU core is reserved for the BIOS proxy.
* The target must be MBR (<= 2 TiB) and is wiped. Vista has no NVMe driver.
* The firmware may list the stick first after each restart: the finalizer
  says to remove it (or to start the disk's UEFI entry from the boot menu).
* Secure Boot must be off (CSMWrap is unsigned).

### 10.4 QEMU results (2026-09-27)

Harness `tools/tests/legacy_bios/run_csmwrap_vista_prepared.py`: `prepare`
runs `vista_csmwrap_target.sh` in the release micro-Linux on a blank 24 GiB
disk with the PE10 donor ISO as a raw disk (37 s, every read-back PASS);
`boot` starts OVMF **without CSM** (i440FX, TCG, std VGA) with the target on
AHCI and the Vista test stick (`vista-esp-repro/stick-c.vhd`, overlay) on
xHCI. Screens and logs: `tools/tests/artifacts/csmwrap-vista*` (not in git).

| Run | Result |
|---|---|
| 1 (no answer) | OVMF boots the disk's `BOOTX64.EFI` = CSMWrap -> SeaBIOS -> USOS MBR -> NT60 -> bootmgr -> PE10 (Windows logo after 13 s) -> USOS installer in BIOS mode (`Firmware type = 1`, disk found by signature, staging made inactive) -> **Vista Setup language page** (PE10 USB keyboard works) -> disk page lists the unallocated space, USOS-VISTA and CSMWRAP -> the install runs to the end, `Vista Setup returned=0`, exactly **one active partition = the new Vista partition** (not the staging one), BIOS BCD `\Boot\BCD` with `winload.exe`, `BOOTSECT.BAK`. Finalizer failed at the BCD check (the store stays open after Setup: CopyFile sharing violation, `/store` + `/export` refused) -> fixed: `bcdedit /store ... /enum {default}` must name the new partition twice and `winload.exe`. With test signing set by hand and a restart: **phase 2 boots from the disk through CSMWrap** ("Windows is configuring the computer", Setup's finishing screen at 800x600) and reaches **OOBE** (user account page). |
| 2 (answer merged: the Vista golden profile without its fake key) | Language page and EULA skipped (the merged answer was accepted), key/edition/disk pages manual. Finalizer PASS (BCD check, test signing, USB v11 armed, staging entry removed, log copied), "remove the stick" dialog. That dialog got no keyboard or tablet input in QEMU -> it is now foreground/topmost and the restart follows after 3 minutes anyway. After a reset: phase 2 in **test mode** (test signing active) runs the USB v11 first-boot gate; QEMU's `qemu-xhci` is not driven by the Vista USB 3 package, so the gate stops with "USB IS NOT READY" (the gate is the UEFI path's; on the X470 it passed with CSM, v11, where the ports are AMD xHCI). The installer now also removes the WinPE letters of the prepared disk's volumes (staging C:, CSMWrap ESP) before Setup and hides the staging partition (type 0x17; 0x07 again for a retry), so no stray letters reach the installed system. (The "D:\USOS\Vista\firstboot-usb.log" line on the gate screen is a fixed text of the USB bootstrap, not the real letter.) |
| 3 (final installer, build B260927-205829) | Same flow with the answer: letters C: and F: removed, staging inactive + hidden, `Vista Setup returned=0`, the new partition had **C:** in WinPE, one active partition (the new one), BCD check PASS (2 entries name the partition, `winload.exe`), test signing set, staging entry removed, USB v11 armed; the notice timed out after 3 minutes and PE10 restarted by itself; the disk booted phase 2 through CSMWrap in test mode up to the USB v11 gate (QEMU xHCI, see run 2). Disk afterwards: Vista NTFS + CSMWrap ESP only. |

### 10.5 Hardware result (X470, 2026-09-28)

User report: Windows Vista SP2 x64 installed **without CSM** through CSMWrap
on the ASRock X470 / Ryzen 7 5700X / Radeon RX 560, build
B260927-205829-3C3E79FE, target a Biostar S100 120 GB SATA SSD.

* PE10 Setup with the answer profile `vista-ultimate.ini` (Ultimate, user
  Retro, no password, no key): PASS.
* Phase 2 through CSMWrap: display OK.
* USB keyboard and mouse work on the desktop (USB v11 gate passed on AMD
  xHCI).
* The disk boots on its own without the stick (firmware -> the disk's UEFI
  entry -> CSMWrap -> Vista).
* Test mode stays on, because the USB 3 backport is test-signed. Accepted by
  the user and closed. There is no legitimately signed xHCI driver for the
  X470 on Vista x64 (the AMD Win7 catalog is OSAttr 6.1 only, SHA-256
  chain); **the only way to drop test mode is a Renesas uPD72020x PCIe USB 3
  card**, whose vendor driver supports Vista.

UX issues to fix before 1.0:

* Step counter: the flow shows 1/3, then the XP-style "1/5" disk
  confirmation screen of micro-Linux step 610; one counter for the whole
  flow. Fixed, section 10.6.
* SeaBIOS text and a blinking cursor show during the CSMWrap boot; a quiet
  CSMWrap build is pending.
* A restart is needed between the disk preparation and Setup.

### 10.6 Preparation screens (2026-09-28, after the B260928-161042 X470 test)

User report on B260928-161042: during step 610 micro-Linux text was visible
on the USOS screens, the counter went 1/3 then "1/5", and the disk question
came as a surprise (the Vista path with CSM has no USOS disk step) with a
plain "OK" confirmation.

* **Leak source**: `vista_preparation.formatCommand` started the kernel with
  `quiet loglevel=3` and no `console=`, so /dev/console was tty0: every
  `printf` of /usos-init, the pipeline and `vista_csmwrap_prepare.sh`
  (`[MICRO-LINUX]`, `[PIPELINE]`, `[VISTA_CSMWRAP] ...`), the stderr of the
  menus and mounts, and KERN_ERR and higher printk went to fbcon over the
  usos-fb-ui frames. The CSMWrap mode now uses the XP preparation's options
  (`boot_console.xpConsoleOptions`: `console=tty0 console=ttyS0,115200n8 rw
  quiet loglevel=1 vt.global_cursor_default=0`; the USOS diagnostic flag
  gives the verbose set). /dev/console is the serial port, fbcon never takes
  the screen over, the VT cursor is off. `vista_csmwrap_target.sh` (dd, mkntfs, wimlib, cpio)
  still writes only to `prepare.log`, now with stdin
  from /dev/null; the disk overview's stderr goes there too. The vista-disk
  command line (UEFI with CSM, off by default) is unchanged byte for byte.
* **One counter**: `VistaCsmwrapStage` (5 stages, all labels already
  translated): Validating installation ISO (UEFI: ISO + PE10 donor), Loading
  the preparation environment (UEFI handover, kernel, /usos-init), Choosing
  the target disk, Preparing the disk, Starting Windows Setup (the restart
  notice). The UEFI page shows 1 and 2 (no "Starting..." splash in between,
  as for XP); micro-Linux draws the same stage-2 page first
  (`usos_ui_bootstrap_frame`, `USOS_UI_VISTA`) and continues with 2 to 5.
  Golden rows `progress vista_csmwrap*` (additions only).
* **Disk step**: kept (the MBR, the USOS-VISTA staging partition and the
  CSMWrap ESP must exist before Setup can boot), never automatic. The summary
  says so (`summary.vista_csmwrap_disk`: chosen in the next step, required
  without CSM, that disk is erased completely). The picker says why in one
  sentence (`lx.vista_csmwrap_why`); the confirmation is the XP
  "FORMAT THE ENTIRE DISK?" screen: ERASE ALL DATA ON THIS DISK, the
  read-only disk overview (model, S/N, size, partitions, systems found), "All
  partitions, systems and files on this disk will be erased", the new layout
  with the real free size (`lx.vista_csmwrap_layout`) and the Setup hint
  (`lx.vista_csmwrap_setup_hint`); button "Erase ALL partitions and data on
  the selected disk". What is erased, exactly: the whole disk's partitioning
  (the first and the last MiB are zeroed: MBR and both GPT copies, then a new
  MBR); the sectors in between are not overwritten, but no partition refers
  to them any more and Setup formats its new partition. In Vista Setup the
  user picked the unallocated space (until 2026-10-11; now InstallTo, section 13).
* XP: unchanged behaviour (the picker's extra `info=` line appears only with
  `USOS_XP_DISK_NOTE`, set only by step 610; `USOS_UI_VISTA` only with
  `usos.legacy_action=vista-csmwrap`).

## 11. 32-bit Windows 8.1 / 10 without firmware CSM (profile `win-x86-uefi-csmwrap`, 2026-10-10)

Status: **experimental, QEMU end-to-end** (section 11.3); X470 untested.

The X470 firmware is 64-bit UEFI only, so x86 Windows 8.1 / 10 media were
blocked (`needs_32bit_uefi_or_bios`). Their own Setup WinPE already has
xHCI, AHCI and NVMe drivers, so unlike Vista (section 10) no PE10 donor is
needed: the ISO's own x86 `boot.wim` is staged on the target and started in
BIOS mode through CSMWrap.

```
UEFI menu (no CSM, x86 media of windows-10 / windows-8-1 / Embedded 8.1)
  -> windows_native_iso.prepareX86Csmwrap: x86 Setup PE 6.3 or 10, BCD,
     boot.sdi, root bootmgr, setup.exe, install image; usos-source.ini and
     request.ini (profile=win-x86-uefi-csmwrap, donor = the ISO itself) in
     \EFI\USOS\vista-csmwrap; the answer profile is staged as x86
  -> micro-Linux step 610 (same picker + "FORMAT THE ENTIRE DISK?"), target
     script with X86_SELF=1, MBR:
       slot 1  NTFS "Windows", inactive, 1 MiB .. staging
       slot 2  NTFS "USOS-SETUP", active, 1 GiB: the ISO's bootmgr, boot\bcd,
               boot\boot.sdi, sources\boot.wim (Setup image) + support.cpio
               + modern-support.cpio + usos-x86-csmwrap.flag +
               usos-csmwrap-target.ini (+ usos-unattend.xml)
       slot 3  CSMWrap ESP (xp_csmwrap_esp.sh)
restart -> disk UEFI entry -> CSMWrap -> SeaBIOS -> MBR -> bootmgr -> x86 WinPE
  -> usos-start.cmd mounts the ISO from DATA (usos-source x86, ImDisk x86)
  -> usos-x86-csmwrap.cmd: usos-x86-csmwrap before (disk by MBR signature,
     WinPE letters of its volumes dropped, Windows partition active, staging
     inactive + hidden 0x17, InstallTo DiskID/PartitionID added to the answer)
  -> setup.exe /noreboot /installfrom /unattend (no disk page)
  -> usos-x86-csmwrap after (bootmgr + winload.exe on the Windows partition,
     one active partition; staging entry removed; 2-minute "remove the stick"
     notice) -> restart -> disk -> CSMWrap -> Windows phase 2 / OOBE
```

Failure of Setup: `usos-x86-csmwrap failed` makes the staging partition
active again (the next boot of the disk retries).

### 11.1 Limits / open

* Answer commands are not wrapped by `usos-run-hidden` (x64 only) and user
  INF drivers (DATA\Drivers) are not loaded on this path.
* The WinPE notice text is English only (no `winpe.*` key yet).
* The image list row and the boot-method help still describe the x64 path.
* After the staging entry is removed its 1 GiB stays unallocated.
* Same CSMWrap limits as section 3 (legacy VBIOS, one core reserved, Secure
  Boot off; the menu refuses with Secure Boot on).

### 11.2 Tests

`tools/tests/test_windows_x86_csmwrap.py` (InstallTo edit), Zig tests
(`formatX86CsmwrapRequest`, variant selection, golden `csmwrap` row).
QEMU: `tools/tests/windows_native/qemu_native.py` with
`USOS_NATIVE_MACHINE=pc USOS_NATIVE_TARGET_BUS=ahci USOS_NATIVE_TARGET_FIRST=1`
(the target boots first once prepared; the stick stays connected for the ISO).

### 11.3 Product key and answer architecture (X470 2026-10-11)

X470, build B261011-094317: Windows 10 22H2 x86 Setup stopped right after
"Instalator rozpoczyna pracę" with "cannot read the `<ProductKey>` setting"
(setupact: `Callback_Productkey_Validate_Unattend ... hr = 0x80070002`), in
two runs:

* DATA answer made for amd64 only (generator file, every component
  `processorArchitecture="amd64"`): 32-bit Setup ignores all of it
  ("No `<ImageInstall>` section"), so neither the InstallTo the helper added
  nor the answer's key reached Setup;
* no answer: the helper's InstallTo-only answer has no key; 8.x / 10 Setup
  with `/unattend` on multi-edition media without ei.cfg requires one.

Not an encoding or nesting fault of `windows_installto.h`. Fix
(`usos_it_arch`, `usos_it_key`): an answer without components for Setup's
architecture is retargeted (x86 <-> amd64); an empty `<Key>` never reaches
Setup (removed for Vista / 7 / 2008, whose Setup rejects it); for Setup 6.2+
(version of the ISO's `sources\setup.exe`, 5th argument of
`usos-x86-csmwrap before`) a missing or empty key becomes
`00000-00000-00000-00000-00000` with `WillShowUI=Always`, i.e. Setup's own
key / edition page, as without an answer file. The menu no longer warns
about an answer for another architecture on these paths.

QEMU recheck (OVMF no CSM, `pc`, AHCI target, real stick path, Windows 10
22H2 PL x86): the user's amd64-only generator answer (generic Pro key) ->
helper "components retargeted ... InstallTo added" -> Setup installs with
no page at all; no answer -> language page, then Setup's own "Aktywuj system
Windows" key page (with "Nie mam klucza produktu") instead of the stop.

## 12. 32-bit Windows 7 / Vista / Server 2008 without firmware CSM (profile `win-nt6-x86-uefi-csmwrap`, 2026-10-10)

Status: **experimental, QEMU end-to-end for Server 2008 x86** (section 12.2); Windows 7 x86 and Vista x86 untested (no retail 32-bit media in the library); X470 untested.

The 32-bit NT 6.0 / 6.1 media were blocked on the X470 (64-bit UEFI only,
`needs_32bit_uefi_or_bios`). Their own Setup WinPE has no xHCI driver (no
keyboard or mouse on the X470), so, as for Vista x64 (section 10), a PE10
donor runs their Setup: here an **x86** PE10, i.e. the Setup image of a
Windows 10 x86 ISO. The disk layout and the WinPE helper are the ones of
section 11 (`X86_SELF=1`), only the staged WinPE comes from the donor.

```
UEFI menu (no CSM, x86 media of windows-7 / windows-vista / Server 2008)
  -> windows_native_iso.prepareNt6X86Csmwrap: the ISO has sources/setup.exe
     and an all-x86 install.wim of NT 6.1 (Windows 7) or 6.0 (Vista / 2008);
     the x86 PE10 donor = the first valid Windows 10 x86 Setup ISO (PE 10.0
     build 10240..21999, BCD, SDI, setup.exe, root bootmgr) in
     Programs/USOS/WinPE, else in Systems/Windows/Windows 10/Images (where a
     Windows 10 x86 ISO for its own install already lives);
     usos-source.ini (binds the 32-bit ISO) + request.ini
     (profile=win-nt6-x86-uefi-csmwrap, donor=<the x86 PE10 ISO>)
  -> micro-Linux step 610: exactly the section 11 layout, with the donor's
     bootmgr / BCD / boot.sdi / boot.wim (+ support.cpio, modern-support.cpio)
  -> CSMWrap -> x86 PE10 in BIOS mode -> usos-start.cmd mounts the 32-bit
     ISO -> usos-x86-csmwrap.cmd: InstallTo added, the ISO's setup.exe
     /noreboot /installfrom /unattend -> staging entry removed -> restart ->
     disk -> CSMWrap -> Windows phase 2 / OOBE
```

Where the ISOs go on DATA: the system ISO in its usual folder
(`Systems\Windows\Windows 7\Images`, `...\Windows Vista\Images`,
`...\Windows Server 2008\Images`), the Windows 10 x86 ISO in
`Systems\Windows\Windows 10\Images` (or `Programs\USOS\WinPE`).

### 12.1 Limits / open

* USB 3 in the installed system: Windows 7 x86 see 12.3 (user files on
  DATA); Vista / Server 2008 x86 still none (no 32-bit NT 6.0 xHCI driver,
  12.3), so on the X470 (xHCI only) their phase 2 / desktop have no USB
  keyboard or mouse.
* DATA\Drivers and answer-command wrapping: as section 11.1.
* A USOS profile renders x86 components; with no key and no edition Vista /
  2008 Setup asks for them (a DATA answer with `/IMAGE/INDEX` avoids that).

### 12.2 QEMU results (2026-10-10, build B261010-204513-7DF3AAC3)

OVMF **without CSM** (`pc`, TCG, std VGA), target 40 GiB on AHCI, the test
stick (`new_native_stick.ps1`: Web Server 2008 SP2 PL x86 ISO, Windows 10
22H2 x86 ISO as `-DonorPath`, a DATA `Unattended` answer with
`/IMAGE/INDEX` 1, empty key, Administrator password + autologon) on xHCI,
`qemu_native.py` with `USOS_NATIVE_MACHINE=pc USOS_NATIVE_TARGET_BUS=ahci
USOS_NATIVE_TARGET_FIRST=1`:

* Menu: the x86 image is listed (no 32-bit block); summary "Boot source ISO
  = the Windows 10 x86 ISO, Boot PE 10.0.19041 x86 / WIM index 2".
* Step 610: picker, "FORMAT THE ENTIRE DISK?", PREPARED (X86_SELF layout).
* Restart -> disk -> CSMWrap -> x86 PE10 -> Server 2008 Setup started from
  the mounted ISO: **no language, key, edition or disk page** (InstallTo),
  install ran to the end, usos-x86-csmwrap removed the staging entry, the
  PE restarted by itself.
* Phase 2 through CSMWrap, Setup finished, autologon: **Server 2008 Web x86
  desktop** (Server Manager, computer name from the answer, PL).
* Final MBR: slot 1 Windows NTFS active, staging entry gone, slot 3 CSMWrap
  ESP. The disk alone (stick removed, same NVRAM) boots to the desktop.
* Input on the desktop: none (qemu-xhci, Server 2008 has no xHCI driver;
  see 12.1). Setup in PE10 had USB.

### 12.3 USB 3 for the installed 32-bit Windows 7 (2026-10-10)

After Setup returned 0 (`/noreboot`) and before the staging entry is
removed, `usos-x86-csmwrap.cmd` runs a `usb3` step (never fatal):

* `usos-x86-csmwrap.exe target <file>`: the volume at the prepared Windows
  partition keeps its letter or gets a free one; the file gets
  `<letter>: <major.minor>` from `Windows\System32\ntoskrnl.exe`.
* NT 6.1 only. From DATA (the read-only ImDisk mapping the ISO came from):
  `Systems\Windows\Windows 7\Updates\*kb2864202-x86*.msu` (or
  `*kb2685811-x86*`; expanded with `expand.exe`) and
  `Systems\Windows\Windows 7\Drivers\x86\` (one folder per package). The x86
  PE10's DISM adds the KMDF 1.11 CAB (`/Add-Package`), then the packages
  (`/Add-Driver /Recurse /ForceUnsigned`; 32-bit Windows 7 does not enforce
  kernel-mode signatures, so a community-signed package loads). Logs:
  `<Windows>\USOS-usb3\dism-*.log`. Missing files or a DISM error only skip
  the step. Windows 8.1 / 10 x86 (same script) are left alone.
* The 32-bit package used for the tests is the user's Win8 generic USB
  backport (`driwer\x86`: usbxhci / ucx01000 / usbhub3 / usbd8
  6.2.9200.22453, `NTx86.6.1`, PCI\CC_0C0330 plus AMD/ASMedia/Intel/...
  HWIDs, catalog signed by Riolin); it needs KMDF 1.11. KMDF x86 for
  Windows 7: Microsoft Update Catalog
  `windows6.1-kb2864202-x86_9e556e48e72ae30ec89c5f1c713acde26da2556a.msu`
  (the user has it in `driwer\`). Both are user files on DATA, never in the
  repo or the release (temporary bridge, ROADMAP L6 rule).
* NT 6.0 x86 (Vista / Server 2008): skipped. Checked 2026-10-10:
  - DISM 10 refuses NT 6.0 images ("DISM does not support servicing a
    Windows Vista RTM or earlier operating system"), and Vista's own
    `pkgmgr /o:` fails offline under a Windows 10 kernel (0x80070057), so
    KMDF for Vista/2008 x86 (Microsoft Update Catalog
    `windows6.0-kb2864202-x86_ede193c9c47705284407043eac9daee1ce489389.msu`,
    one file for both) would have to be installed online (pkgmgr before
    windeploy, as the Vista x64 v11 flow does);
  - the user's x86 package cannot load on NT 6.0 even with KMDF 1.11:
    usbxhci / ucx01000 / usbhub3 import Windows 7 kernel exports that Server
    2008 SP2 x86 lacks (`KeQueryActiveProcessorCountEx`,
    `KeGetProcessorIndexFromNumber`, `KeQueryHighestNodeNumber`,
    `KeGetCurrentProcessorNumberEx`, `RtlUnicodeToUTF8N`, `wcsncpy_s`,
    `ObfReferenceObjectWithTag`, `ObfDereferenceObjectWithTag`);
  - the Vista-capable community build used for Vista x64 (marie-systems
    win7-sp2 `patches/drivers/USB3/XHCI`) has no x86 folder; AMD has no
    32-bit or Vista USB 3 driver for Ryzen / Promontory; Renesas / ASMedia
    packages do not bind the AMD controllers.
  A Vista / 2008 x86 USB 3 path needs a 32-bit xHCI package whose imports
  resolve against Vista SP2 + KB2864202 (user-supplied), plus the online
  KMDF step.

### 12.4 QEMU results with retail 32-bit media (2026-10-11, build B261010-215407-A5A3B2C3)

Same harness as 12.2 (OVMF without CSM, `pc`, TCG, AHCI target, stick on
xHCI, DATA answer file), sticks built with `new_native_stick.ps1
-DataExtraPath` for the Windows 7 USB 3 files.

* **Windows 7 Ultimate SP1 PL x86** (`pl_windows_7_ultimate_with_sp1_x86_dvd_u_677455.iso`,
  5 editions Starter..Ultimate, build 7601.17514; answer `/IMAGE/INDEX` 5,
  local account + autologon): menu lists it (x86, summary "Without CSM",
  boot PE 10.0.19041 x86); step 610; PE10 Setup hands-free; the `usb3` step
  logged `installed Windows: C: 6.1`, KMDF DISM exit 0, both packages
  (usbxhci, uaspstor) "successfully installed", driver DISM exit 0; phase 2
  through CSMWrap to the **desktop**. The disk alone, then booted with
  `pc,i8042=off` (no PS/2 controller at all) and only qemu-xhci +
  usb-kbd + usb-tablet: the USB keyboard types in Notepad / Run; `sc query`
  shows usbxhci, usbhub3, kbdhid, mouhid RUNNING, i8042prt STOPPED. Windows
  asks once for a restart (new devices).
* **Windows Vista SP2 PL x86** (`pl_windows_vista_with_sp2_x86_dvd_x15-36306.iso`,
  7 editions, build 6002.18005; answer index 4 = Ultimate): accepted by the
  menu and step 610. Client Vista Setup shows the product key page even
  with `/IMAGE/INDEX` and no `ProductKey` (an empty `<Key>` is rejected as
  "invalid product key"); Next + No continues (USB input in PE10). The
  `usb3` step logs the NT 6.0 skip; phase 2 through CSMWrap, OOBE skipped,
  autologon: **Vista Ultimate x86 desktop**. No USB input there (12.3).
* **Server 2008 Web SP2 PL x86**: as 12.2; the `usb3` step logs the NT 6.0
  skip. An empty `<Key>` is rejected there too; leave `ProductKey` out.

### 12.5 X470: Vista x86 OOBE hang (WinSAT) and stick autochk (2026-10-11)

X470 / 5700X / RX 560, CSM off, build B261011-123142-843DD3F6, no answer
profile (the helper's InstallTo-only answer), Biostar S100 target.

**WinSAT.** Evidence on the target (read-only): `Windows\Performance\WinSAT\winsat.log`
of the first OOBE (15:08) ends with `Running Assessment: mem ''` after the
features / graphics / media / cpu assessments, i.e. `winsat moobe` (OOBE's
"Sprawdzanie wydajnosci komputera") never returned (user: 100 % CPU, no
bugcheck); same spot as the Vista x64 stall of 2026-09-21
(`docs/windows-vista-winsat-recovery-2026-09-21.md`). UnattendGC shows
`create user [test]` + `Exiting mandatory tasks [0x0]` at 15:08 and, after
the hard reset, a complete second OOBE (15:16: computer name, time zone,
`create user [test1]`): OOBE had not finished, so Windows ran all of it
again, and with no answer profile the pages were interactive. WinSAT then
logged `Already ran during MOOBE key value = 1` and windeploy finished
(`IMAGE_STATE_COMPLETE`).

Fix: the x64 Vista path has had the OOBE gate since 2026-09-21
(`tools/windows_vista_oobe_gate.c`: `WinSAT\MOOBE=2` before OOBE, so `winsat
moobe` exits before any assessment, no score is invented; an interrupted
late OOBE with exactly one completed account resumes via the native
`SkipMachineOOBE` instead of asking for a second account; boot autochk
limited to the system volume). The x86 path now uses the same gate:
`usos-vista-oobe-x86.exe` (x86 build with `USOS_GATE_NATIVE_DEPLOY`: hands
over to native `windeploy.exe`, there is no USB payload), armed by the
`nt60_gate` step of `usos-x86-csmwrap.cmd` for installed NT 6.0.6002 only:
offline `MOOBE=2` (SOFTWARE), the gate copied to `<Windows>\USOS\oobe.exe`,
`Setup\CmdLine` `oobe\windeploy.exe` -> that path, `SetupType=2` (SYSTEM,
with WinPE's `reg load`). Never fatal: any check failing leaves Setup's own
entry. WinSAT itself is untouched; the assessment stays available later
(Control Panel / `winsat formal`). An answer profile with
user and time zone still fills those pages; without one they stay Setup's own.

**USB input in OOBE.** The keyboard / mouse worked up to the clock page and
not on the desktop. Vista x86 has no xHCI driver, so that input can only be
the firmware's legacy USB emulation behind the i8042 (`ACPI\PNP0303` =
i8042prt is installed); setupapi / System logs show no USB or xHCI device
install around that point. What ends the emulation is not identified;
not pursued (no 32-bit NT 6.0 xHCI driver, 12.3).

**Stick autochk ("Skanowanie i naprawianie dysku").** Windows 10 x86 phase 2
on the X470 scanned the USOS stick. micro-Linux mounts the stick ESP
read-write (`micro_linux_init.sh`) and step 610 (and the w9x, Vista-prepare,
hardware, XP-menu paths) ended with `reboot -f` / `poweroff -f` while it was
still mounted. Linux vfat sets the FAT32 dirty flag (boot sector 0x41
bit 0) on a read-write mount and clears it only on unmount / remount
read-only, so the stick ESP came back dirty and Windows' boot autochk
repaired it. Fix: every micro-Linux restart / power-off goes through
`tools/stick_release.sh` (remounts every rw FAT / exFAT / NTFS mount
read-only, unmounts it, each bounded to 10 s, then restarts); `stop()`
remounts them read-only before the emergency shell
(`tools/tests/test_stick_release.py` fails on any direct `reboot -f`).
Diagnostics: `usos-x86-csmwrap.exe stick` logs `FSCTL_IS_VOLUME_DIRTY` of
every USB / removable volume before Setup and before the restart
(read-only). A drive-letter based autochk exclusion (`/k:`) cannot cover
the stick on the installed system (letters unknown offline); the Vista gate
keeps its fixed-volume exclusion.

## 13. One disk question per flow (2026-10-11)

Rule (user, 2026-10-11): every flow asks for the target disk **exactly once**.
Where Windows Setup can boot straight from the stick, that is Setup's own
disk page and USOS asks nothing. Where something must be staged on the target
before Setup can boot (the CSMWrap paths), the USOS picker of step 610 is that
one question and Setup must not ask again.

### 13.1 Inventory

| Path | Before | After | USOS picker required? |
|---|---|---|---|
| Windows 8.1 / 10 / 11 x64 native UEFI (also Embedded 8.1 x64, Server 2012 R2 Storage/Foundation) | Setup page only | unchanged | no: wimboot from the stick, Setup chooses |
| Windows 7 x64 / Server 2008 R2 / Home Server 2011 (UEFI, Int10 dispatcher, PE10 donor) | Setup page only | unchanged | no |
| Vista x64 UEFI with firmware CSM | Setup page only (USOS disk prep off unless `vista-disk-prep.flag`) | unchanged | no |
| Vista x64 / Web Server 2008 x64 without CSM (`vista-x64-sp2-uefi-csmwrap`) | **both**: USOS picker + Setup page (pick the unallocated space) | USOS picker only (InstallTo) | yes: the PE10 staging partition and the CSMWrap ESP must be on the disk before Setup can boot in BIOS mode |
| 8.1 / 10 x86 without CSM (`win-x86-uefi-csmwrap`) | USOS picker only (InstallTo); a UTF-16 answer kept the Setup page | USOS picker only, UTF-16 answers converted | yes (same reason) |
| 7 / Vista / 2008 x86 without CSM (`win-nt6-x86-uefi-csmwrap`) | as above | as above | yes |

### 13.2 Implementation

* `tools/vista_csmwrap_target.sh`: the Vista x64 layout is now the x86 one
  (slot 1 NTFS "Windows", inactive; slot 2 the active staging partition;
  slot 3 the CSMWrap ESP), read back; `usos-vista-target.ini` already carried
  `windows_start` / `windows_sectors`.
* `tools/windows_installto.h` (shared by `usos-x86-csmwrap.exe` and
  `usos-vista-install.exe` CSMWrap mode v2): the answer's own disk settings
  (`DiskConfiguration`, `InstallTo`, `InstallToAvailablePartition`) are
  removed, then `ImageInstall/OSImage/InstallTo` = the prepared disk and
  partition goes into **every** `Microsoft-Windows-Setup` component (answer
  files often carry one per architecture), or a windowsPE component is added
  before `</unattend>`. UTF-16 answers are converted to UTF-8. Only the disk
  confirmed in step 610 can be written by Setup.
* The disk is the one internal MBR disk with the recorded signature whose
  partition table holds the prepared Windows partition (offset + length).
  Not found exactly once: a message box says so, Setup is never started (no
  fallback to any other disk, no Setup disk page).
* Host test `tools/tests/test_windows_x86_csmwrap.py` (hostile answer with
  `WillWipeDisk` on disk 0, two Setup components, UTF-16, the Vista
  servicing-only answer).

### 13.3 Two-disk QEMU check

`qemu_native.py` with `USOS_NATIVE_DECOY=<qcow2>`: a second internal disk
(20 GiB, MBR with an active partition, marker data) enumerated before the
target (Linux `sda`, Windows disk 0); the DATA answer file is hostile on
purpose (`DiskConfiguration` with `WillWipeDisk` on disk 0 and `InstallTo`
disk 0). OVMF without CSM, `pc`, TCG, target 40 GiB on its own AHCI
controller, build B261011-082326-3D3F4F21:

| Run | Result |
|---|---|
| Server 2008 Web SP2 PL x86 (`win-nt6-x86-uefi-csmwrap`, x86 PE10 donor) | picker lists both disks, the target is confirmed; PE10: `target physical disk=1`, `the answer's own disk settings removed; InstallTo added`; Setup ran with no page at all, the helper removed the staging entry, phase 2 through CSMWrap, Server 2008 desktop. Target MBR: Windows active at 2048, CSMWrap ESP; decoy: `qemu-img compare` identical to its pristine copy. PASS |
| Vista SP2 PL x64 (`vista-x64-sp2-uefi-csmwrap`, PE10 x64 donor) | picker + "FORMAT THE ENTIRE DISK?" with the new layout text; PE10 Setup with `vista-csmwrap-answer.xml`: only the (known) client key page, then straight to "Installing Windows" (no edition or disk page); finalizer PASS; phase 2 from the target through CSMWrap in test mode up to the USB v11 gate (stops in QEMU as in 10.4). Target MBR as above; decoy identical. PASS |


### 13.4 Finding: SeaBIOS boot priority is per controller, not per port

With the decoy on **port 0 of the target's own AHCI controller**
(`USOS_NATIVE_DECOY_SAME_CONTROLLER=1`), the firmware started the target's
CSMWrap ESP correctly, but SeaBIOS then booted the **decoy's** MBR (black
screen, nothing read from the prepared staging partition). Cause: patch 0004
(`csm_bootprio_ata`) ranks by the controller's PCI address only; every disk on
that controller gets the same priority and SeaBIOS breaks the tie by port
order. This affects every CSMWrap target path (XP, 2000, NT, 9x, Vista, x86)
on a PC with another disk on a lower port of the same SATA controller (common
on the X470 chipset ports). It needs a SeaBIOS patch that also matches the
port (CSMWrap's device path names the SATA port it was loaded from) and a
CSMWrap rebuild.

**Fixed in CSMWrap 3.1.2-usos4 (patch 0005, 2026-10-11,
research/csmwrap.md section 9):** CSMWrap tags the BBS entry of the exact
disk it was loaded from (device-path prefix of the loaded image) with an
FNV-1a hash of that disk's sector 0; SeaBIOS reads sector 0 of every hard
disk before mapping drives and moves the one match in front of the first
hard disk. The target is 0x80, the other disks follow in their usual order
(0x81, ...), so `rdisk(0)` in boot.ini / WINNT.SIF, the 9x `C:` and NT6's
system disk (the first BIOS disk) keep meaning the prepared target; nothing
in the flows had to change. QEMU, OVMF without CSM, build
B261011-094317-A0DAC3F4:

| Run | Result |
|---|---|
| `run_csmwrap_boot_disk_qemu.py`: decoy port 0 / target port 1 of one AHCI controller; target port 0 / decoy port 1; decoy on its own controller; target on qemu-xhci usb-storage | all four: target is 0x80, decoy 0x81 (read through INT 13h), decoy byte-identical. Control with usos3: the decoy boots. PASS |
| XP Professional SP3 PL, prepared target on port 1, bootable decoy on port 0 of the same controller (`run_csmwrap_xp_ovmf.py --decoy --run-through`) | CSMWrap -> target MBR -> text-mode Setup copies, restarts, second CSMWrap boot -> GUI Setup; decoy byte-identical. PASS |
| Windows 10 22H2 PL x86 (`win-x86-uefi-csmwrap`), `qemu_native.py` with `USOS_NATIVE_DECOY_SAME_CONTROLLER=1` (decoy port 0, target port 1), stick on qemu-xhci | USOS picker lists both, target confirmed, restart -> CSMWrap from the target ESP -> staging WinPE -> Setup without a disk page -> restart -> second CSMWrap boot from the target -> Windows phase 2 ("Przygotowywanie urządzeń"; run stopped there with the QEMU monitor `quit`). Target MBR: Windows active at 2048, CSMWrap ESP in slot 3; decoy `qemu-img compare` identical to its pristine copy. PASS |

### 13.5 Booting Setup from the stick instead (evaluated, not implemented)

Asked for 2026-10-11: no USOS picker on the CSMWrap paths either; Setup's own
disk page, with the WinPE boot set loaded into RAM by the UEFI side and
exposed to SeaBIOS as an INT 13h RAM disk; the CSMWrap ESP added afterwards
on the disk Setup used.

* Why the design staged on the target (section 2, 10.1): CSMWrap 3.1.2 has
  no boot-device option (BBS: the drive it was loaded from first); the
  installed system needs the target ESP on every boot anyway; Vista's own PE
  has no xHCI, so PE10 had to be bootable without the stick.
* RAM disk: SeaBIOS in CSM mode has no RAM hard-disk driver (its `ramdisk.c`
  is a CBFS floppy for coreboot) and CSMWrap always ends in `Legacy16Boot`
  (BBS). The memdisk part itself exists in USOS: the BIOS `wimboot` gives
  bootmgr an INT 13h virtual disk built from files in RAM (the BIOS Core's
  Windows ISO path uses it). Missing: a way to start a preloaded real-mode
  image after CSMWrap's ExitBootServices without SeaBIOS reading the stick,
  i.e. a CSMWrap/SeaBIOS patch (for example `boot_image=` in `csmwrap.ini`,
  loaded below 1 MiB / reserved in E820 and entered instead of the BBS boot)
  plus a rebuild with the pinned toolchain, new hashes and the release steps
  of research/csmwrap.md 6.5.
* USB INT 13h fallback: exists today (Utilities -> BIOS mode: CSMWrap from
  the stick -> USOS Stage 1 -> Core -> BIOS wimboot from the DATA ISO); never
  run on the X470; the Core reads the whole boot.wim through SeaBIOS's xHCI
  driver. QEMU check 2026-10-11 (OVMF without CSM, stick on qemu-xhci, build
  B261011-082326): the BIOS menu comes up through CSMWrap from the stick, but
  Windows 10 x86 -> Automatic stops with `RuntimeWindowNotUsable` right after
  `WIMBOOT FILE LOOKUP PASS`: `windows_wimboot.allocate` reserves 1-17 MiB for
  wimboot's runtime, and the E820 that CSMWrap builds from the OVMF memory map
  has a non-RAM range at 8 MiB (section 7: OVMF NVS at 8 MiB). The X470 map is
  unknown; the fix would be a smaller or relocated window in the Core.
* Open risks for any "Setup chooses" variant in BIOS mode: Setup puts
  bootmgr on the active partition of what the BIOS reports as the boot disk;
  booted from the stick (80h) it may pick another internal disk (the classic
  multi-disk case), which writes to a disk the user did not choose and leaves
  the chosen disk unbootable through its own CSMWrap ESP; and 13.4 applies to
  phase 2 as well. The ESP itself can be carved after phase 1 (PE10
  `diskpart shrink` by 65 MiB, a free MBR slot: Vista uses one partition,
  7+ two).
* Verdict (first evaluation): blocked by the CSMWrap/SeaBIOS rebuild and by
  the unverified system partition placement.

### 13.6 RAM-disk boot: system partition placement measured (2026-10-11)

The rebuild is no longer the blocker (13.4 landed as usos4). The deciding
question was what NT6 Setup does when BIOS drive 0x80 is a RAM disk that
Windows cannot see. `tools/tests/legacy_bios/run_setup_system_disk_probe.py`
reproduces exactly that BIOS view without building the RAM disk: QEMU legacy
SeaBIOS, the ISO booted from CD, 0x80 = a virtio-blk disk with an MBR (Setup
has no virtio driver, so like the RAM disk it is a BIOS disk with no Windows
disk behind it), the AHCI disks after it, an answer file with language and
EULA only, so Setup shows its own disk page; the target (40 GiB) is picked.

| Setup | Disks Windows sees | Disk page / Next |
|---|---|---|
| Windows 7 Ultimate SP1 PL x86 | disk 0 = decoy (0x81, active NTFS-type partition), disk 1 = target (0x82) | the decoy's partition is listed as type **System**; Next on disk 1: "Instalator nie mógł utworzyć nowej partycji systemowej ani zlokalizować istniejącej partycji systemowej" |
| Windows 7 Ultimate SP1 PL x86 | disk 0 = blank decoy (0x81), disk 1 = target | same error on disk 1 |
| Windows 7 Ultimate SP1 PL x86 | disk 0 = target only (0x81) | same error |
| Windows 10 22H2 PL x86 | disk 0 = target only (0x81) | "Nie mogliśmy utworzyć nowej partycji ani zlokalizować istniejącej" |

Nothing was written in any run (decoy and the 0x80 stand-in byte-identical,
target still empty). Result: in BIOS mode Setup takes the system disk from
BIOS drive 0x80. A RAM disk at 0x80 that Windows cannot see makes Setup
refuse **every** disk, even on a single-disk PC. Numbering the RAM disk after
the real disks does not help either: then 0x80 is whatever internal disk the
BIOS lists first, Setup puts the system partition (bootmgr, BCD) there when
it is not the disk the user picked (the "System" row above) - a write to a
disk the user did not choose, which the design must never do. Only the disk
the user picks being 0x80 is safe, and that needs the choice before the BIOS
boot, i.e. the step-610 USOS picker.

Not built because of this: the UEFI-side boot-set loader, the SeaBIOS RAM
disk, the E820 reservation for it, and the WinPE helper that would carve the
CSMWrap ESP after phase 1. The `RuntimeWindowNotUsable` item of 13.5 belongs
to the BIOS Core's own wimboot path and is unrelated to this result.

Possible route, not attempted: make the RAM disk visible to Windows as a
fixed disk (a memdisk-style table, mBFT, plus a WinPE disk driver that reads
it, e.g. the GPL WinVBlock). Setup would then put the system partition on
the RAM disk (written only in memory), install to the disk the user picked,
and the helper would run `bcdboot` on that disk and add the CSMWrap ESP. It
needs a Windows kernel driver for x86 PE 6.x/10 and its own tests; the
`attributes disk set readonly` trick does not help because the disk the user
will pick is unknown before Setup runs.

Decision: the USOS picker (step 610, one question, Setup without a disk
page) stays the default for all CSMWrap paths.
