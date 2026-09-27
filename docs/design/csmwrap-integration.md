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
| B. CSMWrap on the stick, SeaBIOS boots the stick's BIOS MBR -> USOS BIOS Core -> existing BIOS XP path | Works in principle (the stick is BIOS-bootable), and useful as a *diagnostic* (USOS BIOS menu on a CSM-less board). But then SeaBIOS numbers the stick 80h and the target 81h during preparation, the installed system still needs A for later boots, and the BIOS Core path duplicates the UEFI preparer. Not the install path. |
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

**2026-09-27, X470 Taichi / Ryzen 7 5700X, CSM OFF, Secure Boot OFF, build
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

## 10. Vista without firmware CSM (profile `vista-x64-sp2-uefi-csmwrap`, 2026-09-27)

Status: **experimental, QEMU only.** Replaces the "full legacy boot"
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
     stick (ImDisk, as on UEFI), the user picks the unallocated space
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
  taken by `usos_answer_plan_take`) and DATA `Unattended` files are allowed
  on this path only. The installer inserts its KMDF `<servicing>` block right
  after `<unattend ...>` (`merge_user_answer`, UTF-8 only; a file with its own
  `servicing` section is refused). Disk selection stays manual (the renderer
  writes no DiskConfiguration/InstallTo).
* **Installer** (`tools/windows_vista_install.c`, CSMWrap mode v1): BIOS
  firmware is accepted only with `usos-vista-csmwrap.flag`; the target disk is
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
