# BIOS paths on UEFI-only PCs through CSMWrap: DOS, FreeDOS, Windows 3.x (design + prototype, 2026-09-29)

Status: **post-1.0 design and QEMU prototype, not in the release.** Branch
`feature/bios-via-csmwrap`. Builds on [csmwrap-integration.md](csmwrap-integration.md)
(XP/Vista through CSMWrap) and [../research/csmwrap.md](../research/csmwrap.md)
(mechanism, licence, the reserved helper CPU thread).

## 1. Goal and result in one table

Make the existing BIOS paths (Utilities -> FreeDOS, DOS -> MS-DOS, Windows ->
Windows 3.1/3.11, later memtest BIOS and 98/ME) work on UEFI machines with
the CSM off or missing, reusing the BIOS Core instead of writing UEFI copies.

All runs: QEMU 11.1, OVMF `edk2-x86_64-code.fd` (no CSM), i440FX, TCG, 2
vCPUs, std VGA (a PC-AT VGA option ROM, like the RX 560), the USOS stick as
`usb-storage` on `qemu-xhci`, keyboard `usb-kbd` on the same xHCI (the X470
input path), internal disks on AHCI. Screens: [bios-via-csmwrap/](bios-via-csmwrap/).

| # | Test | Result |
|---|---|---|
| A1 | UEFI USOS menu -> Utilities -> UEFI Shell -> `fs0:\EFI\USOS\csmwrap\csmwrapx64.efi` (the file the 1.0 stick already carries) -> SeaBIOS -> the stick's own BIOS MBR -> **USOS BIOS menu** | **PASS** (only the stick attached) |
| A2 | Same, with any internal SATA disk attached | **FAIL with 3.1.2-usos1**: SeaBIOS boots the internal disk (bootable: its MBR runs, [a0](bios-via-csmwrap/a0-usos1-boots-internal-disk.png); blank: "Boot failed", no retry on the stick). **PASS with the prototype 3.1.2-usos2-proto** (SeaBIOS patch 0004, section 3.2) |
| A3 | USB keyboard in the USOS BIOS menu under CSMWrap | **FAIL with the release Core** (it reads keys only from the 8042 ports). **PASS with the prototype Core** (INT 16h fallback, section 3.3) |
| A4 | BIOS menu -> Utilities -> FreeDOS -> Doszip -> `HELLO.COM` reads its companion file from DATA, USB keyboard only | **PASS** ([a1](bios-via-csmwrap/a1-bios-menu-via-csmwrap.png), [a2](bios-via-csmwrap/a2-freedos-usb-keyboard.png)); also with `-machine pc,i8042=off` (no keyboard controller at all, like the ROG Ally) |
| A5 | `REBOOT` in FreeDOS | full platform reset -> OVMF -> **UEFI USOS menu** (CSMWrap routes resets to UEFI `ResetSystem`) |
| A6 | Windows -> Windows 3.1 PL -> ISO -> Automatic -> 256 MiB FAT16 on the AHCI disk, USB keyboard | stage 1 **PASS**: "DOS and Windows Setup files are ready on the target disk" |
| B1 | That target + an end-of-disk CSMWrap ESP (64 MiB FAT16, MBR type 0xEF, slot 2), stick removed | OVMF -> target ESP -> CSMWrap -> SeaBIOS -> target MBR -> MS-DOS 6.22: **hangs after "Starting MS-DOS..."** ([b0](bios-via-csmwrap/b0-dos-high-a20-hang.png)): A20, section 4.3 |
| B2 | Same with `HIMEM.SYS ... /M:2` in CONFIG.SYS | original Windows 3.1 Setup runs; DOS part with the USB keyboard **PASS**; Windows part: **USB keyboard dead** ([b1](bios-via-csmwrap/b1-win31-setup-usb-keyboard-dead.png)), PS/2 keyboard **PASS**; Setup completes, USOS start menu installed |
| B3 | Final restart: installed Win3.1 through the target's own ESP | Program Manager in **standard mode PASS** and **386 enhanced mode PASS** ([b2](bios-via-csmwrap/b2-win31-386-enhanced.png)); a file written from a DOS box in enhanced mode (INT 13h from V86 mode through CSMWrap's BIOS proxy thread) reads back |
| B4 | MS-DOS 6.22 `FDISK` on that disk | ESP shown as `Non-DOS`, 64 MB, no error ([b3](bios-via-csmwrap/b3-fdisk-non-dos-esp.png)); `FDISK /STATUS` fine |
| B5 | Target ESP boot with the USOS stick still plugged in (usos2-proto) | the target boots (BBS: the disk CSMWrap came from first) |
| R  | Prototype Core on plain SeaBIOS (no CSMWrap): PS/2 keyboard, USB keyboard | both **PASS** (menu navigation and FreeDOS); the release Core ignores `usb-kbd` there too |

Not tested: memtest BIOS, MS-DOS "live from USB", Windows 3.11 EN, 98/ME,
EMM386 itself, USB mouse, GOP-only video (no PC-AT VBIOS), WHPX, real hardware.

## 2. Option A: "BIOS mode (CSMWrap)" from the UEFI menu

```
UEFI USOS menu (stick ESP) -> LoadImage \EFI\USOS\csmwrap\csmwrapx64.efi (unsigned, SB off)
  -> CSMWrap: unlock C0000-FFFFF, POST the card's VBIOS, BBS "own drive first",
     ExitBootServices, reserve 1 CPU thread for the BIOS proxy
  -> SeaBIOS CSM16 -> stick LBA 0 (USOS Stage 1, DL=80h) -> Core slot LBA 64
  -> USOS BIOS menu (GPT/ESP FAT32 + DATA NTFS through INT 13h over SeaBIOS xHCI)
  -> any BIOS path: FreeDOS, MS-DOS / Windows 3.x setup, later memtest BIOS, 98/ME
```

Answers to the questions of the task:

* **Chosen boot device.** CSMWrap 3.1.2 has no boot-device option; it builds a
  BBS table from UEFI block devices, the controller it was loaded from first
  (`bootdev.c`). SeaBIOS's CSM code does not use that table the way CSMWrap
  fills it: `csm_bootprio_ata` indexes it with EDK2's fixed layout
  (`1 + 2*channel + slave`), `csm_bootprio_pci` starts at entry 5, and USB
  mass storage asks only the `bootorder` file, which a CSM boot does not
  have. So an AHCI disk gets priority 2 or so and the USB stick the default
  103: **with any internal SATA disk present the stick is never booted**
  (A2). SeaBIOS also tries only the first hard disk. Fixed by patch 0004
  (section 3.2).
* **The stick's hybrid layout over xHCI.** Works: the protective MBR (one 0xEE
  entry, not active) carries Stage 1, SeaBIOS boots it from USB MSC on xHCI,
  and the Core reads GPT, the FAT32 ESP and NTFS DATA through INT 13h.
  `BOOT CONTEXT OK drive=0x80`. No stick-side change is needed.
* **Reset / exit.** One way: there is no return to UEFI without a reset. Any
  reset (REBOOT.COM, Ctrl+Alt+Del, the menu's restart) is a platform reset;
  the firmware then starts its UEFI boot order again, normally the USOS UEFI
  menu. Power off from the BIOS menu goes through SeaBIOS APM (not tested).

## 3. Prototype changes (this branch)

### 3.1 Test tools (no release effect)

* `tools/tests/legacy_bios/create_bios_csmwrap_stick.ps1`: a disposable fixed
  VHD stick (GPT: ESP FAT32 from an installer `payload.zip`, DATA NTFS with
  the DOS test media; Stage 1 + Core slot like the installer's legacyboot
  step, `install_bios_csmwrap_legacy_boot.py`; GPT names by
  `patch_usos_gpt_names.py`). Needs an elevated shell (Mount-DiskImage).
* `tools/tests/legacy_bios/bios_csmwrap_vm.py`: step-by-step QEMU driver
  (OVMF or SeaBIOS, stick on xHCI, `usb-kbd` or PS/2, optional AHCI target,
  `i8042=off`; `key`, `type`, `shot`, `text`, `hmp`).
* `tools/tests/legacy_bios/add_csmwrap_esp_to_dos_target.py`: option B on a
  prepared DOS target (overlay only): the XP tail rule, 64 MiB FAT16, type 0xEF.
* `tools/csmwrap_build/run_build_vm.py`: `--patches` and `--usos-version` for
  prototype builds (default behaviour unchanged).

Reproduce (paths of this session; the ISOs are the user's):

```
powershell -File tools/tests/legacy_bios/create_bios_csmwrap_stick.ps1 -Output zig-out/bios-csmwrap/stick.vhd ^
  -PayloadZip <clone>/installer/internal/payload/assets/payload.zip -MsDosIso "<...>/MS-DOS 6.22.iso" ^
  -Win31Iso <...>/Windows_3.1_PL.iso -DemoDir <...>/dos-programs/DEMO ^
  -CsmwrapEfi tools/vendor/csmwrap/3.1.2-usos2-proto/csmwrapx64.efi -CoreSlot zig-out/legacy-bios-proto/core-slot.bin
python tools/tests/legacy_bios/bios_csmwrap_vm.py --out zig-out/bios-csmwrap/a start --fw ovmf --stick <overlay>.qcow2
  ... key down down ret / key down down down ret / type "fs0:\EFI\USOS\csmwrap\csmwrapx64.efi\n"
```

### 3.2 CSMWrap 3.1.2-usos2-proto (SeaBIOS patch 0004)

`tools/vendor/csmwrap/3.1.2-usos2-proto/`: the three usos1 patches plus
`0004-seabios-csm-bbs-priority-by-pci-address.patch` (LGPLv3, SeaBIOS only):
`csm_bootprio_ata/pci` look the controller up in CSMWrap's BBS table by PCI
address, and a new `csm_bootprio_usb` gives USB mass storage the priority of
its xHCI/EHCI controller. Result: the drive CSMWrap was loaded from boots
first, a USB stick included (A2 PASS), and the XP/Vista target-ESP case keeps
its order (B5: CSMWrap from the AHCI target, stick plugged in -> the target).
Built with the pinned Alpine toolchain (`run_build_vm.py --patches ...`), twice
with the same hash `07ca9779...801f`; the unpatched rebuild of the same run
matched `3.1.2-usos1/manifest.json` (`62d617fc...`). The binary is unsigned and
stays out of the release until the X470 tests (section 7); switching means the
steps of research/csmwrap.md 6.5 (manifest, `usos-efisign`, the pinned hash in
`tools/xp_csmwrap_esp.sh`).

Limitation left: two USB disks on the same controller share one priority
(registration order decides). A USB target plus the USOS stick on one xHCI is
not a USOS case today.

### 3.3 BIOS Core: INT 16h keyboard fallback on SeaBIOS

The Core polls the 8042 in PM32 (`core_poll_scancode`) and never calls the
BIOS for keys (docs/legacy-xp-investigation-2026-09-09.md). On vendor BIOSes a
USB keyboard reaches the 8042 through SMM legacy emulation; SeaBIOS (plain,
coreboot, or the CSM16 inside CSMWrap) has no SMM emulation and serves USB
keyboards only through INT 16h, so the menu gets no keys (A3; also plain
QEMU + `usb-kbd`). Prototype:

* `core_main.zig`: `seabiosPresent()` looks for `SeaBIOS (version` in
  0xE0000-0xFFFFF once; vendor BIOSes keep the 8042-only path unchanged.
* `core.S`: `bios_poll_key` (thunk op 16): IRQ1/IRQ12 masked, `sti`, one
  INT 16h AH=01 (a pending IRQ0 lets SeaBIOS poll USB HID), AH=00 if a key is
  ready, mask restored. Non-blocking. Status 0xFF from port 0x64 now counts as
  "no controller", not as a byte.
* `console.zig`: after an empty 8042 poll, one INT 16h poll while the 8042 has
  not yet delivered any keyboard byte (a PS/2 keyboard in use disables the
  fallback; without that rule a PS/2 key was once seen twice on plain SeaBIOS).
* Core payload 239132 bytes (+436), headroom 6628 (minimum 4096).
  `installer/internal/payload/legacy_boot_generated.go` is **not** regenerated
  on this branch; the prototype Core is `zig-out/legacy-bios-proto/core-slot.bin`
  from `tools/build_legacy_bios.ps1 -OutputDirectory zig-out/legacy-bios-proto`.

## 4. Option B: the installed DOS / Windows 3.x disk boots through its own ESP

```
target (MBR, < 2 TiB):
  slot 1  FAT16, active, LBA 2048, 128/256/512 MiB   MS-DOS 6.22 (+ Windows 3.x)
          ... unallocated (FDISK can use it) ...
  slot 2  type 0xEF, FAT16 64 MiB at the disk tail    \EFI\BOOT\BOOTX64.EFI = CSMWrap
firmware -> the disk's UEFI removable path -> CSMWrap -> SeaBIOS -> USOS DOS MBR -> DOS
```

### 4.1 Layout and FAT16 limits

* The DOS partition stays exactly as the BIOS path makes it (slot 1, LBA
  2048, sizes 128/256/512 MiB inside the BIOS CHS geometry). FAT16 allows
  2 GiB in MS-DOS 6.22 (32 KiB clusters); the current sizes are far below.
* The ESP goes to the **disk tail** with the XP rule (`start = align2048(total
  - 133120)`, 131072 sectors), not after the DOS partition: the free space
  in between stays one contiguous area for FDISK, and the ESP never sits in
  the first 8 GiB that MS-DOS reaches through CHS INT 13h. MS-DOS never reads
  it; UEFI reads it by LBA.
* FDISK (B4): lists it as `Non-DOS 64 MB`, no error. Risk: FDISK's "Delete
  Non-DOS partition" removes it, and the disk then boots only with a CSM (or
  a new ESP). The end-of-setup notice and the manual should say so.
* MBR limit 2 TiB and "whole disk only" as for XP.

### 4.2 Who writes the ESP

The DOS path prepares the target from the BIOS Core, so under option A the
Core is also the only place to add the ESP: when it runs under CSMWrap
(SeaBIOS version string contains `-CSMWrap-`) the MS-DOS / Windows 3.x "Delete
partitions and install" step also creates slot 2 and a FAT16 volume
(`dos_fat16_format.zig`, the Core's INT 13h write thunk) and copies
`\EFI\USOS\csmwrap\csmwrapx64.efi` plus the licence files from the stick ESP
(what `tools/xp_csmwrap_esp.sh` copies), read back like the other DOS files.
Without CSMWrap nothing changes. The summary screen then says that the disk
will boot through CSMWrap (UEFI entry of that disk, Secure Boot off).

### 4.3 A20 and HIMEM (found in B1)

MS-DOS 6.22 HIMEM picks **A20 handler 3** under CSMWrap's SeaBIOS (handler 2,
PS/2 port 92, under plain SeaBIOS; [b4](bios-via-csmwrap/b4-himem-handler-3.png)).
With handler 3 A20 stays off, `DOS=HIGH` copies DOS into a wrapped HMA and
overwrites the IVT and BDA (0x400 held kernel code), SYSINIT loops. `HIMEM.SYS
/M:2` (port 92) fixes it (B2, B3). Design: in CSMWrap mode the DOS installer
writes `/M:2` into CONFIG.SYS and into `W3CONFIG.SYS` (the start menu the
Windows helper installs overwrote the first fix, so both files need it); an
optional SeaBIOS change that saves the real A20 line state in `call32` was
tried and did **not** help (every call32 goes through CSMWrap's proxy thread
there), so the switch is the fix. Port 92 exists on every chipset USOS
targets. HimemX (the USOS preparation session) was not affected.

### 4.4 Memory above 64 MiB

XMS under CSMWrap in OVMF: **7,168 KB** (plain SeaBIOS: 64,512 KB). CSMWrap
reports extended memory (CMOS, INT 15h E801/88h) only up to the first non-RAM
range of the UEFI memory map, and OVMF has an ACPI NVS range at 8 MiB
(`CMOS: ... ext=7168 KB`). E820 is complete (HimemX and XP use it).
MS-DOS 6.22 HIMEM does not use E820. Windows 3.1 ran with it; on real boards
the first hole is expected much higher (AMD AGESA usually reserves around
150 MiB; to be checked on the X470 with `MEM`). HIMEM 6.22 stops at 64 MiB in
any case. A later CSMWrap patch could report E801 from the E820 RAM total.

## 5. The risks of the task, answered

| Risk | QEMU finding | Consequence |
|---|---|---|
| EMM386 / V86, Win3.x 386 enhanced mode calling INT 13h/16h through SeaBIOS's 32-bit code on the proxy core | Every SeaBIOS `call32` goes to CSMWrap's helper thread (also from real mode). Win3.1 386 enhanced mode started, loaded from disk and wrote a file from a DOS box (B3) | works in TCG; WHPX stalled XP at the same kind of point (csmwrap-integration 7) and real hardware is untested: first thing to watch on the X470. EMM386 itself not tested (USOS configs do not load it) |
| USB keyboard via SeaBIOS xHCI | INT 16h consumers work: prototype Core, FreeDOS + Doszip, MS-DOS prompt and startup menu, DOS part of Win3.x Setup. Port-60h consumers do not: Win3.x `KEYBOARD.DRV` (Setup GUI and Windows), DOS games with own INT 9 handlers | Windows 3.x needs a **PS/2 keyboard** under CSMWrap (the X470 has a PS/2 port; the Ally has none: Windows 3.x unusable there) |
| No PS/2 emulation | as above; `i8042=off`: Core + FreeDOS still work (fallback + 0xFF guard) | the summary must say "Windows 3.x: PS/2 keyboard required" |
| A20 | HIMEM handler 3 -> hang with DOS=HIGH | `/M:2` in both config files (4.3) |
| Memory above 64 MiB | 7 MiB XMS in OVMF | fine for DOS/Win3.x; check on hardware (4.4) |
| Timer | IRQ0 through ExtINT routing: 8-s DOS menu timeout, DOS clock, Win3.x all fine | none seen in TCG |
| Video | std VGA's PC-AT ROM POSTed: real text modes, VBE for the Core menu | GOP-only GPUs (SeaVGABIOS): the Core menu (VBE LFB) should work, DOS/Win3.x text and VGA modes are black (the XP finding) |
| CPU thread | one logical CPU reserved by CSMWrap | irrelevant to DOS/Win3.x (single CPU); only a note |

## 6. Recommendation and UI

**Recommended:** option A as the entry point, option B for installed DOS /
Windows 3.x disks, both only when the firmware has no CSM, with patch 0004
and the Core fallback as prerequisites:

1. Ship CSMWrap **3.1.2-usos2** (usos1 + 0004) after the X470 regression of
   XP and Vista (their target-ESP order must stay: B5 says it does in QEMU).
2. BIOS Core: INT 16h fallback on SeaBIOS (3.3); `-CSMWrap-` detection for
   the DOS installer: `/M:2`, the target ESP (4.2), the PS/2 note.
3. UEFI menu entry (Utilities, and a hint row in the DOS category):
   * **"Tryb BIOS (CSMWrap)" / "BIOS mode (CSMWrap)"**, shown only when
     `secure_boot.csm().likelyOn()` is false (with a CSM the firmware's own
     legacy boot is better and already proven);
   * disabled with the reason when Secure Boot is on ("CSMWrap is not signed;
     turn Secure Boot off");
   * a confirmation page: "Switches this PC into BIOS mode until the next
     restart (no reboot now) and opens the USOS BIOS menu (FreeDOS, MS-DOS,
     Windows 3.x). No way back without a restart. CSMWrap reserves one CPU
     thread (DOS does not use it). Windows 3.x needs a PS/2 keyboard. A card
     without a legacy video BIOS shows no DOS text."; badge "Experimental";
   * action: `esp_image_start.load(root, "\\EFI\\USOS\\csmwrap\\csmwrapx64.efi")`
     + `StartImage` (the UEFI Shell path, minus the Shell). If
     `EFI\USOS\csmwrap-verbose.flag` exists, write `EFI\USOS\csmwrap\csmwrap.ini`
     with `verbose = true` first (CSMWrap reads the ini next to itself; the
     release has none, so the quiet defaults apply).
4. Until the entry exists, the 1.0 stick can already be tested by hand:
   Utilities -> UEFI Shell -> `fsN:\EFI\USOS\csmwrap\csmwrapx64.efi` (fsN = the
   ESP), with the limits of A2/A3 (no internal SATA disk attached, PS/2
   keyboard for the BIOS menu).

Not recommended: separate UEFI implementations of the DOS paths (FreeDOS has
no UEFI boot), or a stick-side "chain to the target" (csmwrap-integration
option C).

## 7. X470 test plan (CSM off, Secure Boot off)

1. Release stick + manual Shell start (step 4 above), SATA disks unplugged:
   BIOS menu with a **PS/2** keyboard; then the prototype files
   (usos2-proto CSMWrap + prototype Core) with SATA disks attached and a USB
   keyboard: menu, FreeDOS, Doszip, REBOOT back to UEFI.
2. MS-DOS / Windows 3.1 install to a spare SATA disk, ESP added, `/M:2`:
   standard and 386 enhanced mode with a PS/2 keyboard; `MEM` (XMS size);
   the disk boots alone; `FDISK` display.
3. Regression: XP and Vista target-ESP boots with usos2 (stick plugged in and
   not).
