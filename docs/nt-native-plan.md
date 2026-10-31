# NT 3.x / NT 4.0 without the install VM: plan (2026-10-28)

Goal: install Windows NT 3.1 / 3.5 / 3.51 (Workstation and Server) and then
NT 4.0 natively on the X470, the way the 9x family now runs natively. One flow
per system: UEFI menu -> micro-Linux prepare (step 620) -> automatic restart ->
Setup runs on the PC -> first desktop. No install VM, no finish step in Linux.

Branch `claude/nt-native` (based on `claude/w95-hotpatch` 343a8456).
X470 is the acceptance gate. Claude sessions run no full OS installs in QEMU;
everything below marked "host" is a host test or offline file check.

## 1. Today's flow (per step: VM or not)

| Step | NT 3.51 / 3.5 | NT 3.1 / 3.1 AS | NT 4.0 / Server / TSE |
|---|---|---|---|
| UEFI menu: profile, key prompt, `request.ini`, `EFI\USOS\answer\<tag>.SIF` | native | native | native (key now optional, see 3) |
| micro-Linux prepare (`w9x_csmwrap_prepare.sh`), VM gate `w9x_vm_available` | native | native | native |
| target disk: MBR + FAT16 C:, winnt /b layout, `\USOS\NT3` / `\USOS\NT4` (`nt4_csmwrap_target.sh`) | native | native | native |
| text-mode Setup | **VM** (QEMU in micro-Linux, am53c974 or IDE) | **VM** (keys typed from the VGA text page, `nt31_vm_tick`) | **VM** (pentium3, IDE) |
| GUI-mode Setup | **VM** | **VM** (INITIAL.INF patched between VM starts; Date/Time and AS Domain Settings answered by keys) | **VM** (`alt-n` on the "minor errors" box) |
| first start: usosnt3 service / POST.CMD (drivers, polish, SP6a for NT4, DONE.TXT) | **VM** | **VM** | **VM** |
| finish (`nt4_vm_finish`): fsck, BOOT.INI `/NUMPROC /MAXMEM` + `[USOS /SOS]` + `[VGA mode]`, autochk restore, leftovers removed | Linux | Linux | Linux |
| CSMWrap ESP written, restart | native | native | native |
| installed system on the X470 (our MBR hooks, AHCINT/usosnvme, usosrst, usosusb, usosvbe) | native, PASS | native, PASS | native, PASS |

### Why the VM was needed

- **NT 4.0**: the RTM text-mode kernel triple-faults on Zen 3 (CPUID max
  standard leaf > 3, the "Limit CPUID MaxVal" bug); the SP6a kernel hangs in
  text mode. Only a system that had SP6a applied (inside the VM) boots on the
  X470. This is the hard blocker for NT 4.0.
- **NT 3.x**: the NT 4.0 flow was the template. The 3.51 / 3.5 / 3.1 RTM
  kernels do run on Zen 3 (the installed systems PASS on the X470), so the
  kernel is no blocker. What the VM supplied:
  - a boot disk text mode can see (VM IDE / am53c974; on the X470 only AHCI
    or NVMe, i.e. our AHCINT / usosnvme);
  - a small machine: 512 MiB, PCI buses <= 7 (no NTDETECT/HAL PCI loop), no
    HPET legacy trap; the installed system gets `/MAXMEM` only in finish;
  - a keyboard nobody touches: the runner typed ENTER on "Setup was unable to
    verify your C: drive" (3.5), the whole 3.1 text mode, 3.1 Date/Time and
    the 3.1 AS Domain Settings page;
  - Linux between the VM starts: the 3.1 INITIAL.INF/HARDWARE.INF patch and
    the 3.51/3.5 LAN INF patch (`usos_nt351_vm_patch` / `usos_nt35_vm_patch`);
  - a CPU GUI Setup accepts: 3.5 GUI Setup (`GetProcessor`) refuses newer
    than Pentium (VM `-cpu pentium`); 3.51 accepted pentium3 (I586 branch).
- The 2026-10-27 X470 NT4 "VM unavailable" stop: the hand-placed 9x
  `phase1-native.flag` also blocked NT4 in `w9x_vm_available`. Fixed (2).

### What a native path needs (and what already exists)

- **Boot into text mode on the PC**: already the same chain as the installed
  system: CSMWrap -> SeaBIOS -> our NT 3.x MBR (E820 filter, HPET legacy off,
  PCI BIOS hidden when last bus >= 8, sector-1 hooks) -> syslinux ->
  `chain.c32 ntldr=$LDR$` (SETUPLDR). For NT 3.1 the MBR's AH=88h/E801h
  answer covers the 3.1 loader.
- **Disk in text mode**: our miniports are boot drivers already; text mode
  needs them in `TXTSETUP.SIF [SCSI.Load]`, `[SCSI]`, `[Files]` and the files
  in `~BT` + local source. Text mode then installs the one that found the
  disk into the new system. No CD driver: winnt /b reads the local source on
  C: through the same miniport. NVMe: usosnvme (3.5x build, CF8/CFC scan).
- **HAL**: `nt3_standard_hal` (Standard PC) already covers the installed
  system; the text-mode `[Hal.Load]` stays (verify on X470: NTDETECT sees no
  PCI, the HPET is off, so the Standard text-mode HAL should run).
- **Memory**: `TXTSETUP.SIF [SetupData] OsLoadOptions` reaches both the
  text-mode kernel (SETUPLDR) and BOOT.INI (NT 4.0 Enterprise CD's
  `/maxmem=256` went that way). NT 3.1 has TXTSETUP.INF: its form needs a
  check; fallback = an E801/E820 RAM cap in the sector-1 MBR hook.
- **Answers**: 3.51 / 3.5 are fully unattended through WINNT.SIF + INITIAL.INF
  `!` keys + `!DetachedProgram` (usosnt3); text mode needs no key if the
  autochk stand-in is where text mode looks (3.51: local source; 3.5: `~BT`
  too). NT 3.1 has no unattended text mode: see 4.3.
- **Finish without Linux**: move the `nt4_vm_finish` jobs that matter into
  usosnt3 (`/polish` already runs at the first start): BOOT.INI diagnostics
  entries, autochk restore, `~LS` / `~BT` / syslinux leftovers, DONE.TXT.
- **USB keyboard/mouse during Setup**: text mode and GUI mode use i8042prt
  only; usosusb arrives with the first start. The X470 has Super I/O PS/2,
  so a PS/2 keyboard is the fallback; the plan is to need no key at all
  (USOS rule: no key presses). Later: usosusb in text mode (see 4.4).
- **Display**: text mode = VGA text through the HAL (the installed systems
  run VGA/usosvbe under CSMWrap, NTLDR INT 10h works); GUI Setup = vga.sys
  640x480. Nothing new.

## 2. 9x `phase1-native.flag` scoped to 9x (done, 34cf9f9f)

`w9x_vm_available` checks `EFI/USOS/win9x/phase1-native.flag` only for
95 / 98 / 98 SE / Me. NT 3.x / NT4 / TSE / POSReady keep their VM path with
the flag present. Test: `test_w9x_phase1_qemu.Phase1Vm.test_only_9x_with_qemu_ram_and_no_opt_out`.

## 3. NT 4.0 product key optional (done, 34cf9f9f)

- UEFI menu: `win9x_key_prompt.optional()` covers NT 4.0 / Server / TSE; an
  empty key stages the profile (or the USOS default owner) without ProductId
  (`manual_summary.zig`).
- micro-Linux `nt4_key_gate` (target script, before any disk write): a key in
  `[UserData]`, or a Select (`I386\SETUPP.INI [Pid]` site 270, e.g. the
  English Enterprise Server CD "70234270") / MSDN (335) CD -> go on; any
  other CD without a key -> stop "this CD asks for its product key ... No disk
  was changed" (instead of a 15-minute VM stall). Whether NT 4.0 Select
  really skips the key page is unverified (expected from the channel code).
- Tests: `test_nt4_flow.Nt4KeyGate`, zig test in `win9x_key_prompt.zig`.

## 4. Plan, ordered for the earliest X470 test

### 4.1 Slice 1 - NT 3.51 native, opt-in (implemented, 295e639d, needs a build)

`EFI/USOS/win9x/nt3-native.flag` on the stick ESP + NT 3.51 WS or Server:

1. prepare skips the VM gate and the VM (`nt_native=yes`, logged);
2. target (`NT_NATIVE=1`): `nt3_native_txtsetup` on all three TXTSETUP.SIF
   copies (`[SCSI.Load]` = `ahcint` [+ `usosnvme`], `[SCSI]` names, `[Files]`
   rows from the CD's `amsint.sys` row, `OsLoadOptions = "/nodebug
   /NUMPROC=2 /MAXMEM=1024"`), AHCINT/USOSNVME into `~BT` and `~LS`, LAN off;
   any other NT version with the flag stops before the disk;
3. prepare writes the CSMWrap ESP immediately and shows the normal restart
   notice; text mode, GUI mode and the first start run on the X470.

Not in slice 1 (harmless for a first test): BOOT.INI keeps text mode's
entries (no `[USOS /SOS]`), the autochk stand-in stays as autochk.exe,
`~LS`/`~BT`/LDLINUX/`$LDR$` stay on C: (~100 MB).

Host checks done: `test_nt_native` (synthetic SIF), `test_nt4_flow`,
`test_nt3_flow` (two failures unrelated and pre-existing: the NT31.SIF rm
count pin, and the usosnt3 import test needs `tools\zig` in the worktree).

Offline check (done 2026-10-28, no VM): `nt3_native_txtsetup` on the real
NT 3.51 Workstation TXTSETUP.SIF (scratchpad copy of the user's CD): the 35
`[SCSI.Load]` rows (incl. atapi and amsint) become `ahcint` (+ `usosnvme`),
two `[SCSI]` names, `OsLoadOptions` replaced, two `[Files]` rows
`dx,d7,_3,4,1`; nothing else changes. Without atapi text mode has no CD
driver, which winnt /b does not need (local source on C:).

### 4.2 X470 test 1 (first hardware run)

Kingston, NT 3.51 Workstation EN, Micron NVMe or SATA target, flag present.
Expected: text mode copies files (blue screen, no keys), restarts, GUI Setup
640x480, restarts, usosnt3 service, restarts, logon/desktop.

What tells us where it stopped (silent logging, no photos needed):
- `EFI\USOS\win9x\prepare.log` on the stick: `native:` lines;
- C: of the target afterwards (offline, read-only): `\WINNT\SYSTEM32` present
  -> text mode copied; `\WINNT\SYSTEM32\CONFIG\SYSTEM` + `setup.log` -> text
  mode finished; `\USOS\NT3\POST.LOG` / `DONE.TXT` -> first start done;
  `BOOT.INI` content -> OsLoadOptions reached it; `\USOS\NT3\USOSANS.TXT`
  -> every GUI Setup page with its controls (slice 2 recorder).
- The same run works for NT 3.5 Workstation (slice 2, same flag).
- If the screen stays black/blue right after "Setup is inspecting your
  computer's hardware configuration": text-mode HAL/NTDETECT (compare with
  the installed-system path, which passes).

**Result (B261028-173747, NT 3.51 WS EN, Micron NVMe):** prep PASS, text
mode started (usosnvme `NS1 488386 MiB ... OK`), then "Setup has encountered
a fatal error while initializing your computer's video ... (0, 0xc0000034)".
Code 0 = opening `\Device\Video0` failed (NT 5 `spvideo.c` VIDEOBUG_OPEN,
same screen in 3.51): `vga.sys` was loaded (SETUPLDR stops on a missing
file; `VGA.SYS`/`VIDEOPRT.SYS` are in `~BT`, `[Display]`/`[Display.Load]`
match the CD) but its HwFindAdapter declined. TXTSETUP.SIF differs from the
CD only in `[hal]`, `[SCSI.Load]`, `[SCSI]`, `[Files]`, `OsLoadOptions`.

Cause: CSMWrap's E820 has **A0000-FFFFF reserved** as one entry (csmwrap
`build_e820_map`; plain SeaBIOS: only F0000-FFFFF). The 3.5x/4.0 loaders
make a memory descriptor of every entry, and the hook kept non-RAM entries
below 1 MiB, so the 3.51 `vga.sys` claim of A0000-BFFFF
(`VideoPortVerifyAccessRanges`) conflicted. QEMU repro from a read-only copy
of the staged Micron C: + its CSMWrap ESP (q35, OVMF + CSMWrap, 12 root
ports, NVMe or AHCI, 1-3 GB): same screen; SeaBIOS (pc or q35): text mode,
GUI mode pass; a scratch `vga.sys` copy that ignores the VerifyAccessRanges
result, or claims only the I/O ranges, passes (memory window = the
conflict; not shipped). The same image without the hook sector fails too.

Fix (`nt3_e820_mbr.S` hook): a non-RAM E820 entry stays only when it ends at
or below A0000h (EBDA); every other one becomes the F0000-FFFFF copy, so
CSMWrap's A0000 entry turns into what SeaBIOS reports. QEMU (same repro,
new MBR + hook sector): text mode, GUI mode, first start (usosvbe
1024x768), logon. Test: `tools/tests/legacy_bios/test_nt3_e820_hook.py`
(runs the hook under unicorn). Not only Setup: without the fix the
installed system's first boot under CSMWrap stops with STOP C0000143
(`DISPLAY_DRIVER.DLL`, no video device). Keyboard: `i8042prt` claims ports
and IRQ 1 only, no memory, so this conflict cannot hit it; whether the
X470's PS/2 controller gives text mode a `\Device\KeyboardClass0` without a
PS/2 keyboard is still untested (QEMU always has one).

Memory: `/MAXMEM` in `[SetupData] OsLoadOptions` is ignored in text mode
(3.51 SETUPLDR has no MAXMEM handling; X470 banner 3079532 KB vs 1044100 KB
of the installed system with BOOT.INI /MAXMEM=1024). 3.51 text + GUI mode
ran with 2 GB under CSMWrap in QEMU. NT 3.5 stops with 0x7B above 128 MiB
(docs/nt35-2026-10-09.md), so native NT 3.5 needs a RAM cap before the
loader. Implemented: hook sector byte 508 (`HOOK_RAM_CAP`, 16 MiB units,
0 = none) next to the options byte; `nt4_csmwrap_target.sh` sets it to 8
(128 MiB) for a native NT 3.5 and, since 2026-10-29, to 64 (1024 MiB) for a
native NT 3.51 (NT 4.0 / the VM path keep 0). NT 3.51 reason: text mode
writes Setup's BOOT.INI entry from `[SetupData] OsLoadOptionsVar` (none on
the 3.51 path), so GUI Setup's starts ran on 3 GB; the 3.51 MP kernel (1057)
stopped with 0x0A (C0000000, 2, 0, 801207DC) in MiGrowWorkingSet (own
disassembly; the 3.5 source's `MiGetPteAddress(&Wsle[Quota])` test, VA in
page 0) during a Fastfat cache access (X470 B261029-161430).
The hook then ends E820 RAM at 128 MiB (entries above become the
F0000-FFFFF copy) and reports at most 0x700 64 KiB blocks above 16 MiB for
AX=E801h; the 3.5 SETUPLDR's real-mode part calls AH=88h, AX=E801h and
E820 (same `su` layout as 3.51, own disassembly of the user's CD file).
128 MiB is the largest size proven: 64 / 128 MiB guests and 2 GiB with
BOOT.INI /MAXMEM=128 boot, 256 MiB stops (QEMU, 2026-10-09). Emulated in
`tools/tests/legacy_bios/test_nt3_e820_hook.py`; no X470 run yet.

**Result (B261028-191138, NT 3.51 WS EN, Micron NVMe):** installed, desktop,
but only PS/2 input, and NTLDR's menu at every start (30 s, entries
"[VGA mode]" and "Unrecognized Operating System on C:"). Offline read of the
Micron: usosusb installed by the service (POST.LOG `done`, Start 1, group
Keyboard Port) but **never started** (no `usosusb\Parameters\Diag`; SysEvent
has one EventLog start = the first start only; POST.LOG has no `restart`, so
the service's restart 30 s after `done` never came). On the VM path the VM
did that first start + restart, and `nt4_vm_finish` rewrote BOOT.INI; the
native path had neither. The menu itself is NT's own BOOT.INI menu (no USOS
or CSMWrap stage): Setup's `timeout=30`, the `C:\` entry is the syslinux boot
sector winnt /b saved as BOOTSECT.DOS.

QEMU (read-only copy of that Micron disk, q35 + OVMF + CSMWrap, NVMe behind a
root port, 12 root ports, qemu-xhci + usb-kbd + usb-mouse; the q35 i8042
stays: with `i8042=off` NTDETECT hangs, the X470 has a PS/2 controller):
the next start loads `usosusb 1.4-nt4` (`hc0=00:02.0(8 ports) p5:s1K-
p6:s2-M`), Ctrl+Alt+Del and logon by USB keyboard, Program Manager menus;
keyboard and mouse unplugged/plugged on root ports re-enumerate (`p5-gone
p7:s1K-`, `p6-gone p8:s2-M`); a FAT16 stick plugged at runtime gets E: (D: is
QEMU's empty CD), `dir`/`copy` from it and a write to it work, unplug + plug
again gives `UsosUsbDisk1:E` and a second write lands. A write unplugged
~10 s after the command did not reach the stick (NT 3.51 FAT lazy write; no
safe-removal UI: wait before unplugging).

Fix (`usosnt3`, `NATIVE.TXT` from `nt4_csmwrap_target.sh`, native NT 3.5x
only): `/setup` (GUI Setup) already copies `usosusb.sys` and writes its
service + `ConnectMultiplePorts`, so the first start has USB input; the
service rewrites BOOT.INI like `nt4_boot_ini` (timeout=5, no `C:\` entry,
the native load options on every entry, `[USOS /SOS]`, `[VGA mode]`) and
removes BOOTSECT.DOS, the syslinux files and WINNT.SIF. `usosnt3 /finish`
does both by hand on a native install made before (needs NATIVE.TXT).
QEMU: `/finish` on the disk copy, reboot passes the 5 s menu to the logon.

Still without USB: text-mode and GUI-mode Setup (zero input needed there).
Text mode would need SETUPLDR to load usosusb before kbdclass
([SCSI.Load] makes it a boot driver of the new system as well, and its
KeyboardPort0 would then hide a PS/2 keyboard unless kbdclass connects
multiple ports in the Setup hive); not done, no X470 evidence yet.

**Pagefile (same X470 run):** C:\pagefile.sys was 1816 MiB of the 2000 MiB
FAT16 C:. GUI Setup's `VIRTUAL.INF` (3.51 WS CD, `DoVirtual`) sizes it
RAM in MiB + 12 (`VirtualMarkup`), capped at the free space of the drive;
/MAXMEM is not on Setup's boot entry, so it saw the full RAM and took all
free space. `ConfigureVirtual` -> `REGISTRY.INF SetPagingFiles` writes
`PagingFiles` near the end of GUI Setup (after fonts and ACLs), long after
`/setup` (the DetachedProgram) has run, so a value written there would be
overwritten. Fix: the first-start service (`pagefile_cap`, native NT 3.5x,
also `usosnt3 /finish`) writes `PagingFiles` = `C:\pagefile.sys 64 128`
(REG_MULTI_SZ, MiB). SMSS parses `<path> <min> <max>` and, per the NT5
sources (`sm\server\pagefile.c`, `mm\modwrite.c NtCreatePagingFile`),
creates the paging file with FILE_SUPERSEDE and the minimum as allocation
size, so the large file shrinks to 64 MiB on the next start (the service's
own restart 30 s after `done`). NT 3.51's SMSS/MM was not disassembled for
this; the X470 check is `dir /a C:\pagefile.sys` after the second start.
Native NT 4.0 (syssetup, CMDLINES.TXT + SETUP.REG) not changed.

Partition size limits (not changed): FAT16 with 32 KiB clusters ends at
~2047 MiB (65524 clusters); 64 KiB clusters (NT only, 4 GiB) are not read
by DOS-era tools (untested with the syslinux stage that boots `winnt /b`).
`[Unattended] FileSystem = ConvertNTFS` converts C: in place and keeps its
size, so it frees no space beyond the FAT16 limit. Realistic options: 64 KiB
clusters up to 4 GiB (needs a syslinux + NTLDR check) or a second data
partition after C:.
NTLDR 3.51 reads its files by INT 13h; the boot files must stay inside what
the CSMWrap/SeaBIOS INT 13h serves (CHS ~8 GB without extensions).

**Fresh native NT 3.51, B261029-110651 (X470, read offline 2026-10-29):**
- Clock: Winlogon showed "Invalid System Time" (LOGGEDON.C: year <= 1990);
  event times 1970/2033. The 3.51 HAL (IXCMOS.ASM `HalpGetCmosCenturyByte`)
  reads the century from 37h when the CMOS 10h-2Dh checksum fails, and
  CSMWrap (`e820_update_cmos`) rewrites 15h-18h without updating it. Earlier
  `RtcDiag`: CMOS 32h = 20h, HAL year 26. Fix: the NT 3.x MBR copies a BCD
  century in 32h to 37h when 37h is 00h/FFh (`nt3_e820_mbr.S`,
  `tools/tests/legacy_bios/test_nt3_mbr_cmos_e820.py`). On the next boot the
  check is the SysEvent 6005 time and no Winlogon message.
- The logon notice did show: it was the GUI-Setup notice ("Poczekaj na
  automatyczny restart (okolo 1-2 minuty)"); post clears it before its
  restart, as designed.
- STOP 0x0A after post (first start with usosnet351, usosvbe, RtcFix): no
  dump, no Usosnet* values (the hive did not get them). Firmware DMA into
  RAM given to NT is unlikely from the code: SeaBIOS keeps its xHCI/AHCI/NVMe
  rings in HiPmm (EfiRuntimeServicesData -> E820 reserved), resets AHCI ports
  and xHCI it takes over, and the hook never turns non-RAM into RAM. To rule
  the map out on hardware, the MBR now writes the firmware E820 map to disk
  sector 2 ("E8" at 510) every boot.

### 4.3 Slice 2 - NT 3.5 native + GUI page recorder (implemented, same flag)

Rule (user, 2026-10-28): the native path needs **zero input**. NT 3.x/4 text
mode has no USB keyboard at all, so every text-mode prompt is a dead end; GUI
pages are answered by an NT-side USOSANS equivalent, never by the user.

- NT 3.5 with `nt3-native.flag` (tags NT35 / NT35S), same routing as 3.51:
  - `[Files]` row for ahcint from the CD's `ncrc810.sys` row (the 3.5 CD has
    no amsint.sys; offline check on the user's 3.5 CD: `dx,d6,_3,4,1`);
  - `OsLoadOptions = "/nodebug /NUMPROC=2 /MAXMEM=128"` (3.5 loses the boot
    disk above 128 MiB);
  - "Setup was unable to verify your C: drive ... Press ENTER": 3.5 runs
    AUTOCHK.EXE from `~BT`; the usosachk stand-in now goes there too, so the
    page should not come (unverified on hardware);
  - GUI `GetProcessor` refuses Zen 3: `usos-fb-ui --nt35-initial`
    (`src/compat/win3x/nt35_initial.zig`, own code) unpacks the CD's
    one-file MSZIP `INITIAL.IN_`, adds `set STF_PROCESSOR =
    $(ProcessorID_I586) ;USOS-NT35-CPU` right after `detect ProcessorVar`,
    and writes it back as a cabinet (stored deflate blocks, parsed back
    before use). Offline check on the user's 3.5 CD: exactly that one line
    differs and 7-Zip tests the new cabinet OK. A failure stops prepare.
  - 3.5 LAN off natively (its INF patch ran between VM starts).
- GUI page recorder `USOSANS3.EXE` (`tools/nt3/usosans3`, own Win32 code,
  kernel32 + user32 only, PE 3.10, imports checked against the NT 3.51 CD's
  DLLs): staged in `\USOS\NT3` for every native start; `USOSNT3.EXE /setup`
  (GUI Setup's `[GuiUnattended] !DetachedProgram`) starts it, so it runs on
  GUI Setup's desktop. Once a second it lists the visible top-level windows
  and their child controls; on every change it appends class, title, control
  ID, class, text (Edit controls: length only), visible / enabled to
  `C:\USOS\NT3\USOSANS.TXT` (flushed; 1 MiB / 6 h cap). This version only
  records (`mode=record`); answer rules come from the first X470 log.

Pages that can need input on the native path, and how each is covered:

| Phase | Page | NT | Covered by |
|---|---|---|---|
| text | "unable to verify C:" (ENTER) | 3.51 / 3.5 | usosachk in `~LS` (3.51) / `~BT` (3.5) |
| text | end of text mode (ENTER to restart) | 3.5x | unattended: restarts by itself (as in the VM) |
| text | Welcome / Express / partition / FAT / `\winnt` / restart | 3.1 | open: slice 3 (no unattended text mode) |
| GUI | processor not supported (fatal) | 3.5 | INITIAL.IN_ I586 line |
| GUI | network pages | 3.5x | `!SetupNetWork = NO` + LAN off |
| GUI | Date/Time applet, AS Domain Settings | 3.1 | open: answerer (slice 3) |
| GUI | anything else | all | unknown: USOSANS3 records it; answer rules next round |

Still open after slice 2: the finish jobs in usosnt3 (`[USOS /SOS]` entry,
autochk restore, leftover cleanup) are not needed to reach the desktop and
move to the next round; LAN for native 3.5x.

### 4.4 Slice 3 - NT 3.1 / 3.1 AS, answer rules

- Text mode (SETUPAPP, no answer file): either INF switches that skip the
  express pages (check TXTSETUP.INF offline first) or an own text-mode
  "page answerer": a small boot driver (or a usosusb mode) that reads the VGA
  text page at B8000h every few seconds and feeds the same keys
  `nt31_vm_tick` types today (Welcome, Express, partition C:, keep FAT,
  `\winnt`, CTRL+ALT+DEL). Port the matching rules from `nt31_vm_tick`.
- GUI: pre-patch INITIAL.INF / HARDWARE.INF in the local source (the
  `nt31_initial_inf` edits, today applied between VM starts); the Date/Time
  applet and the AS Domain Settings page need a Win32 answerer started from
  INITIAL.INF (`StartDetachedProcess`): reuse the USOSANS design (dialog by
  class/title/control IDs, press only known buttons, log every action).
- Memory: `/NODEBUG /MAXMEM=64` through TXTSETUP.INF or the MBR hook cap.

### 4.5 Slice 4 - NT 4.0 native, opt-in (implemented, needs a build)

Root causes (offline analysis 2026-10-28: our own binary comparison of the
user's RTM and SP6a kernels; the NT5 `cpu.asm` / `usetup.c` read to confirm
the mechanisms):
- RTM reset: `KiSetProcessorType` runs `mov eax,0; cpuid; cmp eax,3; jg`, so
  a CPU with more than 3 standard CPUID leaves (Zen 3: 10h) is taken for a
  type 5 CPU without CPUID. SP6a has no such check.
- SP6a text-mode hang: text mode's RTM `NTDLL.DLL` / `USETUP.EXE` call
  SP6a's renumbered system services (six USETUP imports land on other
  services). Not needed any more: text mode stays a consistent RTM set and
  POST.CMD installs SP6a afterwards, as in the VM flow.

`EFI/USOS/win9x/nt4-native.flag` on the stick ESP + NT 4.0 / Server / TSE:
1. prepare skips the VM gate and the VM. SP6a (TSE: its SP6) is used when
   present but is no longer required: the patched RTM kernel runs without it.
2. target, before any disk write: `usos-fb-ui --nt4-kernel`
   (`src/compat/win3x/nt4_kernel.zig`, own code) reads the CD's
   `NTOSKRNL.EX_`/`.EXE` and `NTKRNLMP.EXE`, finds
   `B8 00000000 0F A2 64 8B 0D 38000000 8F 41 34 8F 41 30 83 F8 03 7F`
   exactly once, changes `03` to `7F` (1 byte), recomputes the PE checksum and
   writes a plain PE. No match, two matches or a cabinet holding another file
   stop the prepare with no disk change. The family mask (`and ebx,700h`;
   SP6a: `F00h`) stays: the proven QEMU `level=3` runs used 700h.
3. The patched kernels replace both twins (`.EX_` / `.EXE`) in `~BT` and
   `~LS\I386`. `nt3_native_txtsetup` now also takes `[SourceDisksFiles]` and
   an `OsLoadOptionsVar`: `[SCSI.Load]` = `ahcint` (+ `usosnvme`, NT 4.0
   builds), `OsLoadOptions = "/nodebug /NUMPROC=2 /MAXMEM=1024"` (text-mode
   kernel), `OsLoadOptionsVar = "/NUMPROC=2 /MAXMEM=1024"` (the value text
   mode writes to BOOT.INI, NT5 `spboot.c`; the Enterprise CD carries both).
4. MBR: the NT 3.x MBR + hook sector (E820 filter, HPET LegacyReplacement off
   before the HAL starts) with the hook sector's options byte 509 = 1, which
   keeps the PCI BIOS visible (NT 4.0 HAL, AHCINT-NT4).
5. WINNT.SIF: `[Unattended] ComputerType` = the CD's `[Computer] mps_mp`
   description when the answer has none (the USOS answer already pins it).
6. GUI page recorder: NT 4.0 has no `[GuiUnattended] DetachedProgram` (its
   `syssetup.dll` has no such key), so `$OEM$\CMDLINES.TXT` starts
   `USOSANS3.EXE /detach` first. It records from that point on (the end of GUI
   Setup, e.g. the Server "minor errors" box) to `C:\USOS\NT4\USOSANS.TXT`.
   Earlier GUI pages are not recorded (the answer file covers them in the VM).

Offline checks (2026-10-28): the sequence occurs exactly once in all six
kernels of the user's CDs (WS PL 1381.1, Enterprise Server EN, TSE EN; WS/ES
UP 0xC5F8B, MP 0xC9F2B; TSE UP 0xD1E7B, MP 0xD6383) and not at all in the
SP6a kernel. After the patch only that byte and the checksum differ, and the
checksum verifies. QEMU (one text-mode boot, no install): the WS PL CD with
the two patched kernels reaches the text-mode Welcome page with
`-cpu EPYC-Milan,level=0x10` (TCG). The unpatched RTM CD resets there.

Open for the X470 run: real Zen 3 with the RTM `halapic` (text mode) /
`halmps`; the RTM SETUPLDR's E820 path with 32 GB (E820 filter in the hook);
GUI pages before CMDLINES.TXT (no input expected, not recorded); the Server
"minor errors" box (the VM answered Alt+N; natively it would wait); BOOT.INI
gets no `[USOS /SOS]` / `[VGA mode]` entries, and the `~LS`/`~BT`/syslinux
files stay on C: (finish-step jobs, next round).

## 5. What is reused from the 9x native work

| 9x piece | NT use |
|---|---|
| native phase 1 routing (VM skipped, ESP written, restart) | same pattern (`nt_native`) |
| FIRSTBT-style coordinator (one owner of first-start steps, restarts batched) | usosnt3 service is that owner for NT 3.x: finish jobs + polish + DONE.TXT |
| USOSANS (answers known dialogs, logs, never types secrets) | NT 3.1 Date/Time + AS Domain Settings; NT 4.0 "minor errors" box |
| USOSKEY/USOSMOUS bridge | NT uses usosusb (kernel port driver) from the first start; text mode later |
| U9V10STK INT 10h private stack | only if a Setup stub hangs in INT 10h on the RX 560 VBIOS (not seen for NTLDR/SETUPLDR) |
| silent logs (USOSLOG.TXT) | prepare.log + POST.LOG + target C: state; no photos |

## 6. Needs X470 hardware testing

- slice 1: native 3.51 text mode with AHCINT / usosnvme as text-mode
  miniport, the text-mode HAL with hidden PCI, `OsLoadOptions` reaching the
  text-mode kernel and BOOT.INI, GUI Setup on Zen 3 (GetProcessor), usosnt3
  first start without the VM finish step;
- slice 2: 3.5 text + GUI with the patched INITIAL.INF; USOSANS.TXT of
  the 3.51 and 3.5 runs (every GUI page);
- slice 3: the 3.1 page answerer;
- NT 4.0 key gate with a Select CD (no key page) and with the key;
- NT 4.0 VM path with `phase1-native.flag` present (the 2026-10-27 blocker);
- slice 4: native NT 4.0 WS PL (`nt4-native.flag`): text mode on the patched
  RTM kernel, GUI mode, POST.CMD with SP6a. Gates, read offline from the
  target C:: `\WINNT\SYSTEM32` (text mode copied files), `setup.log` (text
  mode finished), `\USOS\NT4\USOSANS.TXT`, `POST.LOG` and CSDVersion 0x600
  (SP6a applied).

## 7. Native NT 3.5 round (2026-10-30, host checks only, no X470 run yet)

Audit of the NT 3.5 native path against the native NT 3.51 / NT 4.0 lessons
(`tools/tests/test_nt35_native.py`):

- Kernel / HAL: `nt3_standard_hal` also fits the NT 3.5 CD (its only MPS row
  is `mps11_mp`, `Multiprocessor = ntkrnlmp.exe,2,ntoskrnl.exe` becomes the
  Uniprocessor row); no `/NUMPROC`, `OsLoadOptions` `/nodebug /MAXMEM=128`.
- MBR: RAM cap byte 508 = 8 (128 MiB), quiesce bit + sector 3, CMOS century
  copy and E820 dump are the shared NT 3.x hook; the pre-boot logger runs for
  `nt_major=3`.
- usosrst 1.7-nt35: the 3.51 shutdown log, NVMe/xHCI/NIC quiesce, CF9h full
  reset and RAM marker page, plus the NT 4.0 ACPI S5 power-off (kernel import
  slot via MDL as on 3.51, HAL inline jmp as fallback). The NT 3.5 Winlogon
  has `PowerdownAfterShutdown` / "Shutdown and Power off"; usosnt3 sets it
  on native NT 3.5 only (3.51's usosrst has no S5 path).
- LAN: `usosnet35n.sys` = the NT 3.51 native code (both 3.51 fixes: no
  Enable/DisableInterrupt handlers in polling mode, direct MmMapIoSpace when
  NdisMMapIoSpace fails; ZwFlushKey breadcrumbs, WriteDiag handle fix) built
  for NDIS 3.5: the three NDIS 3.51 PCI services NDIS 3.5 lacks are not
  used, the card is found through CF8h/CFCh only (`USOSNET_NT35N`). Native
  NT 3.5 now runs the preflight (`native` variant), patches the local
  source's `OEMNADLB.IN_` (pinned 37e16b... -> fff3c0..., the VM patch's
  pair) and stages the driver under `USOSNET35.SYS`; usosnt3 writes BusType 1
  without a HAL PCI bus, holds DHCP during GUI Setup and registers NETCHECK.
- usosnt3 / usosans3 / usosachk / AHCINT / usosnvme / usosvbe / usosusb
  imports resolve against the NT 3.5 (807) exports.
- No product key and no manual mode on NT 3.x (renderer takes none; the key
  prompt covers 95 / NT 4.0 / POSReady only). Autologon: the first-start
  service needs no logon; after the restart the normal Ctrl+Alt+Del.

Boot-screen rows (NT 4.0 and NT 3.x drivers): the white AHCINT status line,
the usosnvme "OK" line and the usosrst load / heartbeat / clock rows are
drawn only when `SystemStartOptions` carries `SOS` (BOOT.INI `[USOS /SOS]`);
red rows (errors, stalls, STOP) as before; logs unchanged.

Text-mode Setup screen only partly blue on the Full HD X470 (not changed;
likely cause, not measured on the X470):
the kernel-load screen comes from the HAL through INT 10h, i.e. the RX 560
VBIOS, which also programs the display scaler; text-mode Setup then sets its
720x400 text mode through `vga.sys` by writing the VGA registers directly
(NT 5 `spvidvga.c` picks the 720x400 mode; NT 3.x/4.0 the same), without the
VBIOS, so the GPU's scaler keeps the earlier source size and shows only part
of the screen. A fix would need an INT 10h mode set after vga.sys starts
(own text-mode helper) or a patched vga.sys; neither is low-risk.

### 7.1 X470 run 1 of native NT 3.5 (B261030-125748, read offline from the Micron)

Desktop reached, LAN works (NETCHECK.TXT: DHCP lease, gateway ping, TCP to
1.1.1.1:80; usosnet35n alive, BcPoint 12), no white boot-screen line. But
"At least one service or driver failed" at every start and no keyboard:
SysEvent 7026 (Kbdclass), Kbdclass 8 (could not connect, C000000E) then 7
(no port device object); i8042prt 0x10/0x11 (no PS/2 devices); usosusb Diag
found the keyboard (p3 K) and mouse (p4 M). Cause (own disassembly of the
user's 3.50 KBDCLASS.SYS DriverEntry): with ConnectMultiplePorts = 1 it
walks \Device\KeyboardPort0..N-1 (N = DEVICEMAP\KeyboardPort values) and,
after a port whose connect fails, skips the step that removes the number it
appended, so the next name is "KeyboardPort01". i8042prt (group Pointer
Port, before usosusb's Keyboard Port) owns KeyboardPort0 without a PS/2
keyboard and refuses the connect; usosusb's KeyboardPort1 was never opened,
nothing connected, Kbdclass did not load. Fix: on native NT 3.5 usosnt3 puts
usosusb in the "Base" group (before Pointer Port), so it owns KeyboardPort0 /
PointerPort0; a PS/2 keyboard would still connect as port 1. The Micron was
patched in place (SYSTEM + SYSTEM.ALT, both control sets).

## 8. Native NT 3.1 / 3.1 AS (2026-10-30, host checks only, no X470 run yet)

`nt3-native.flag` now also covers NT31 / NT31S (`w9x_csmwrap_prepare.sh`).
Codex's preparation branch `codex/nt31-native-prep` is merged (SZDD reader,
USOSANS31 GUI rules, page policy, usosnet31 candidate); the native route is
`nt31_native` in `tools/nt4_csmwrap_target.sh`.

- **Boot driver blocker (solved by the template hive).** NT 3.1 text mode
  (SETUPAPP inside SETUPLDR, BIOS INT 13h) copies the SYSTEM hive template
  `SYSTEM._` from the local source and only flips Start on the stock drivers
  it picked; the first GUI-mode boot then had no AHCI/NVMe boot driver (the
  VM flow added AHCINT only at the end of GUI Setup). `usos-fb-ui
  --nt31-hive` (`src/compat/win3x/nt31_hive.zig`, own REGF 1.1 writer:
  4-byte "previous cell" field per cell, new cells in appended 4 KiB bins,
  sorted `li` list, shared `sk` refcount, header length + checksum) adds
  `ahcint` [+ `usosnvme`] (Start 0, SCSI miniport), `usosrst` (+ Parameters
  HpetLegacyOff / RtcFix) and `usosusb` (Start 0, Keyboard Port) and sets
  Kbdclass / Mouclass `ConnectMultiplePorts = 1` - the values the VM flow's
  `[UsosNt31Post]` writes - and writes it back as literal SZDD under the
  same name. Checked offline on the user's CD template: the independent
  REGF 1.1 reader (`tools/tests/coverage/regf11.py`) sees exactly these
  changes; 7-Zip tests the container. TXTSETUP.INF `[WinntFiles]` gets
  `d2,AHCINT.SYS,4` etc., so text mode copies the files to
  `system32\drivers`. Rejected: TXTSETUP third-party registration
  (`SppThirdPartyRegistry` is the OEM-disk path, needs key presses); a
  pre-boot UEFI hive edit (the logger only reaches the ESP).
- **Text-mode keys.** SETUPAPP reads keys through BIOS INT 16h. The NT 3.x
  MBR's quiesce code loads sector 5 ("K3", `.keys` section) into the second
  half of the reserved 1 KiB when hook byte 509 bit 2 is set (native 3.1
  only) and hooks INT 16h: ENTER once per page for Welcome, Express Setup,
  the partition, keep the file system, the `\WINNT` location (the VM
  runner's rules), a CF9h full reset on "Setup has successfully configured
  your computer". Unknown and error pages get nothing; real keys pass.
  Unicorn test `tools/tests/legacy_bios/test_nt3_mbr_keys.py`.
- **TXTSETUP.INF**: `[SCSI.ISA/EISA/MCA.Load]` emptied (no ISA probes).
- **GUI**: INITIAL.IN_ / HARDWARE.IN_ (+ NTLANMAN.IN_ / OEMNADLB.IN_ on AS)
  patched in the local source with the VM flow's `nt31_*_inf` filters, plus
  `STF_PROCESSOR = I586` after `detect ProcessorVar` (Zen 3) and
  `StartDetachedProcess` USOSANS31 after LoadSetupLibrary (Date/Time OK, AS
  new domain USOSDOMAIN).
- **Finish**: POST.CMD (end of GUI Setup) runs `USOSNT3.EXE /finish31`:
  BOOT.INI as the VM finish step (timeout 5, no `C:\` entry, `/NODEBUG
  /MAXMEM=64`, `[USOS /SOS]`, `[VGA mode]`) and the Setup leftovers.
- **MBR**: RAM cap 64 MiB (byte 508 = 4, AH=88h/E801h; every NT 3.1 X470
  PASS ran at 65,088 KB), quiesce + shutdown log (bit 1), keys (bit 2), PCI
  BIOS hidden, HPET legacy off, CMOS century copy; pre-boot logger.
- **Not covered**: network (the NT 3.1 CD has no DHCP; usosnet31 is
  82576-only, the X470 has an I211), usosrst 1.7-style restart/power-off
  for 3.1 (the 1.6-nt31 build stays), white boot-screen rows of the NT31
  AHCINT build.

### 8.1 X470 run 1 of native NT 3.1 (B261030-141317-FD7BD00C)

Text mode stopped with "Setup was unable to set Windows NT configuration"
(F3 = Exit). In SETUPAPP.EXE that screen is shown only when
SpConfigureRegistry returns FALSE; its first step loads
`\WINNT\system32\config\system` (the expanded `SYSTEM._`) with the hive
library linked into SETUPAPP (HvInitializeHive + CmCheckRegistry). Running
that loader code of the user's SETUPAPP.EXE in unicorn (local check only,
the MS binary never goes into git) on the staged template:
CmCheckRegistry rc 4110 on `Services` - its new subkey list was at hive
offset 0x1EA88. SETUPAPP's HvIsCellAllocated rejects every cell index that
is not a multiple of 16 (`test bl, 0Fh`): REGF 1.1 has the old cell format
with 16-byte cell padding (HCELL_PAD 16; NT 3.5+ hives use 8), and every
cell of the CD template sits on a 16-byte boundary. `nt31_hive.zig` padded
new cells to 8 bytes. Fix: 16-byte padding, and each replaced Services
`li` cell is freed (a positive size, as HvFreeCell leaves it) instead of
left allocated and unreferenced. The same SETUPAPP code now loads and
checks the patched template (NVMe and SATA variants) without error; the
unit test walks every bin for the alignment and for stray lists. The
Micron (USB enclosure on the dev PC) did not answer reads on 2026-10-30,
so the files text mode wrote were not read back.

### 8.2 X470 run 2 of native NT 3.1 (B261030-152624-3C807DCB)

Text mode now completes ("Setting Windows NT Configuration" passed, so the
16-byte cells are accepted). The first GUI-mode boot stopped with STOP
0x7B INACCESSIBLE_BOOT_DEVICE (0xFE393BA8, 0, 0, 0); the loaded modules
were ntoskrnl, hal, ahcint, SCSIPORT, usosnvme, usosrst, Atdisk, Ftdisk,
Fastfat, usosusb: no Scsidisk. Parameter 1 is a kernel stack address
(esp FE393B8C), the UNICODE_STRING of the ARC boot device name that
IopMarkBootPartition fails to open (the NT IoInitSystem pattern): no
disk class driver ran, so no \Device\Harddisk0 behind
multi(0)disk(0)rdisk(0).

Evidence from the Micron (read-only copy): `SCSIDISK.SYS` is in
`system32\drivers`, but the installed SYSTEM hive has Scsidisk Start 1
and Atdisk Start 0, while the CD template has Scsidisk 0 and Atdisk 4.
SETUPAPP.EXE does that itself after copying the template (the routine
that references the "atdisk" / "scsidisk" strings): every SCSI miniport
SETUPLDR loaded gets Start 0; Atdisk (machine type ISA/EISA, or abiosdsk
on MCA) gets Start 0; and when the miniport list is empty, Scsidisk gets
Start 1. On this path the list is always empty (`[SCSI.*.Load]`
emptied), so a template value cannot keep Scsidisk at boot start.

Fix: a second service for the class driver that SETUPAPP does not touch.
`nt31_hive.zig` adds `usosdisk` (Type 1, Start 0, ErrorControl 0, "SCSI
Class"), `nt31_native` copies the CD's `SCSIDISK.SY_` to `USOSDISK.SY_`
in the local source, TXTSETUP `[WinntFiles]` gets `d2,USOSDISK.SYS,4`,
and `nt31_native_initial` turns usosdisk to Start 4 right after
`[UsosNt31Post]` sets Scsidisk Start 0 (end of GUI Setup), so the
finished system is the VM flow's (Scsidisk 0, Atdisk 4). During GUI
Setup Scsidisk (Start 1) loads again as a system driver; it finds the
disk claimed and fails quietly (ErrorControl 0). Atdisk stays loaded
during GUI Setup (harmless on this X470 run: it loaded without a hang).

The interrupted install on the Micron was patched in place instead
(SYSTEM: Scsidisk Start 1 -> 0, Atdisk 0 -> 4; scratchpad
nt31native2/PATCH-261030-164625.TXT).

### 8.3 X470 run 3 of native NT 3.1 (Micron patched per 8.2)

After the Scsidisk patch the first GUI-mode boot hangs on the kernel
banner ("... 65088 KB Memory"), no STOP, no further text (two attempts,
reset button after ~10 s each; BOOTLOG.TXT boots 3-5: power-on, two
SYS_RST_L resets, nothing else of note). Read-only evidence from the
Micron: SYSTEM is byte-identical to the 8.2 patch result (NT never flushed
it), no `PAGEFILE.SYS` although `PagingFiles` = `?:\pagefile.sys 15 60`
(smss never reached the paging-file step), FAT16 clean bit still set.
Boot-start services: ahcint, usosnvme, usosrst (SCSI miniport), Scsidisk
(SCSI Class), Ftdisk (Filter), usosusb (Keyboard Port); Atdisk 4.

Leading hypothesis: the kernel debugger. BOOT.INI is SETUPAPP's (it
appends ` /DEBUG` only for `[debug] DebugBoot = 1`, never `/NODEBUG`); the
native flow adds `/NODEBUG /MAXMEM=64` only in `USOSNT3 /finish31` at the
end of GUI Setup, so every boot before that runs with the 3.1 debugger on
COM1 (section "VM run 2" of docs/nt31-2026-10-09.md; the 3.1 KdInitSystem
enables KD when the options carry DEBUG/DEBUGPORT/BAUDRATE and no NODEBUG,
and the 3.1 KdInitSystem sends no packet itself). The first debugger
packet is then the symbol load of the first system-start driver, right
after IopMarkBootPartition, which is exactly where 8.2 stopped with 0x7B
(so that boot never reached it). With no host on the port the state-change
packet waits for an acknowledge forever; in QEMU (a real, silent 16550)
GUI Setup still ran, so the X470 port behaviour is the suspected
difference. Other candidates, lower: the NT31 usosnvme / AHCINT I/O path
under the 3.1 Scsidisk (static review found no 3.1-specific difference in
the I/O path; both mechanisms already ran on 3.1: AHCINT on X470,
usosnvme in QEMU), a system-start driver probing absent hardware.

Patch on the Micron (one variable): BOOT.INI default entry + `/NODEBUG
/SOS` (/SOS only shows the driver list and the AHCINT / usosnvme rows),
SYSTEM untouched (PATCH-261030-172437.TXT in the scratchpad). Side effect
on this disk only: `/finish31` takes a `multi()` line with `/sos` for the
[USOS /SOS] entry, so its final BOOT.INI keeps that single entry.

If the boot gets past the banner, the code fix is needed for the native
3.1 path: `/NODEBUG` must be in BOOT.INI before the first GUI-mode boot
(SETUPAPP writes the file at the end of text mode; candidates: the
TXTSETUP `LoadIdentifier` value if the 3.1 INF parser keeps an embedded
quote, or an edit of C:\BOOT.INI from the pre-boot UEFI logger, which
would first need the firmware's FAT16 access to the MBR partition).

### 8.4 X470 run 4: `/NODEBUG /SOS` - still hangs (debugger ruled out)

Photo: AHCINT row 0 `43C8p- --/-- R:0 W:0 ... TM:0A7 ID:41` (its 250 ms
ScsiPort timer still ran ~42 s in, so DPCs run and the system is not
frozen at high IRQL; no SATA disk), usosrst 1.6-nt31 row, usosnvme row 9
`1344:5407 NS1 488386 MiB ... OK`, no red row. Something waits for an I/O
that never finishes, or the boot waits elsewhere.

NT 3.1 SCSIPORT (local reading of the user's SCSIPORT.SYS): with level and
vector 0 it connects no interrupt and synchronises through its own spin
lock; after HwStartIo it queues the completion DPC itself when the miniport
notified, so the polled completion model of AHCINT and usosnvme is
supported (interrupt hypothesis ruled out). Data addresses: for a request
without a scatter/gather list (no adapter object / map registers)
ScsiPortGetPhysicalAddress returns SP_UNINITIALIZED_VALUE with length 0;
the x86 usosnvme builds put any value into PRP1 unchecked.

Diagnostic + defensive build (usosnvme NT31 only, 13568 B): every data
address is checked as on amd64 (`USOSNVME_PRPCHECK`; a refused one fails
the request with red row 9 "unusable data address"), and on /SOS boots row
10 shows each request entering (`>`) and leaving (`<`) HwStartIo: SRB
function, CDB opcode, target/LUN, length, SRB status, reads, errors, last
PRP1. Patched onto the Micron (PATCH-261030-184215.TXT), BOOT.INI keeps
`/NODEBUG /SOS`. Reading the next photo: no row 10 = no request reached
usosnvme (look at Scsidisk / ScsiPort queueing, map-register allocation);
`>` frozen = a command inside usosnvme never returns; `<` with an error
status = the failing request.

### 8.5 X470 run 5: the NVMe path works; silent request ring

Photo with the 8.4 build: row 10 `NVME io 80 < fn 00 cdb 28 ... len 06A00
st 01 R 70 E 0`: 112 READ(10) requests completed with SRB_STATUS_SUCCESS,
the last one left HwStartIo, then no further request; AHCINT's timer still
ticks. The disk path works; NT waits on something after loading what it
read. BOOTLOG.TXT of that run: the reset-button reset after a 30 min hang
did NOT keep the RAM marker page (boot 7: ABSENT, POST took longer), while
the earlier short hangs did (boots 4, 5).

Silent measurement (no photo): usosnvme NT31 (14464 B) keeps the last 64
requests (seq, LBA, blocks, opcode, SRB status, time in 2^20 TSC ticks) in
the logger's RAM page at +100h ("USOSNVR1", only when the logger's header
is valid) and, on /SOS boots, writes the same 1.5 KiB block to disk LBA
48-50 (the free gap before partition 1; the NT 3.x MBR uses LBA 0-5) after
every completed request, so the ring survives a RAM-clearing reset. The
pre-boot logger (nt-bootlog, 70656 B, pinned hash updated) decodes the RAM
copy into BOOTLOG.TXT ("NVMe ring" lines). A scratchpad tool maps the
LBAs to files on the FAT16 C: offline.

### 8.6 X470 run 6: GUI Setup to the desktop; usosrst 1.7-nt31

The disk ring of the hung run 5 ended with the image of I8042PRT.SYS
(system-start drivers in group order: floppy, scsiflop, scsicdrm, fat_rec,
hpfs_rec, null, beep, i8042prt; then no request). With i8042prt Start 4 on
the Micron, GUI Setup ran on its own, the post step ran (POST.LOG:
drivers copied, /polish, /finish31 with BOOT.INI and the leftovers
removed, DONE.TXT), USB keyboard and mouse work, desktop. Code:
`nt31_native_txtsetup` rewrites the TXTSETUP.INF [Keyboard] / [Mouse] rows
that name i8042prt to beep (SETUPAPP sets the picked keyboard service to
Start 1 over the template's 4; beep is Start 1 already). NT 3.5 / 3.51
native: unchanged (they reach the desktop with their i8042prt).

Nothing runs after the logon by design: the native 3.1 post step is
POST.CMD at the end of GUI Setup. VGA 640x480: NT 3.1 has no usosvbe
wiring (docs/nt3-vesa-2026-10-14.md "Not done: NT 3.1").

usosrst 1.7-nt31 (bin/nt31): the 1.7-nt35 feature set (shutdown log,
NVMe/xHCI/NIC quiesce, CF9h full reset, RAM marker, ACPI S5 with wake
sources cleared, kernel import slot + HAL inline-jmp fallback); NT 3.1
imports only stdcall forms (IoCallDriver, IoCompleteRequest,
ObDereferenceObject, KeRaiseIrql/KeLowerIrql), no bugcheck callback.
NT 3.1 Winlogon has no PowerdownAfterShutdown and no "Shutdown and Power
off" (no such string in its WINLOGON.EXE): a plain Shutdown is
NtShutdownSystem(ShutdownNoReboot), which never calls
HalReturnToFirmware. The last phase-0 shutdown handler wakes a thread;
when no restart has started 20 s later (the file systems flushed in phase
1), it logs stage N and powers off through ACPI S5.

### 8.7 VESA for native NT 3.1 (host checks only, no X470 run yet)

The NT 3.x usosvbe build already accepted the 3.1 structure sizes
(`VIDEO_HW_INITIALIZATION_DATA` 0x20, config info 0x38) and its imports
resolve on 3.1. What blocked 3.1 (local reading of the user's 3.1 CD
WINSRV.DLL, FRAMEBUF.DLL, VIDEOPRT.SYS and SYSTEM._ template):

- **Display selection.** 3.1 winsrv walks `\.\DISPLAY1..4`
  (`\Device\Video0..`), reads `VgaCompatible` and, until a display works,
  `InstalledDisplayDrivers` + `DefaultSettings.*`; the first device with
  InstalledDisplayDrivers is used, and if its DLL fails the boot ends in
  STOP C0000143 (no fall-through to the next device). There is no
  VgaSave/VgaStart pair: `vga` (Group "Video", Start 1, Tag 10) is both the
  desktop and the VGA-compatible device. The video drivers load in Tag
  order of `GroupOrderList\Video` (1,2,3,4,6,7,8,12,13,9,11,14,15,17,18,16,10:
  vga last; the 3.1 kernel reads GroupOrderList). usosvbe gets **Tag 2**
  (second slot; only jazzg364, Start 4, has it), so it is Video0 and vga
  stays Video1 (full-screen consoles; `[VGA mode]` = /basevideo, where
  usosvbe refuses to start and vga is Video0 again).
- **No mode API.** 3.1 USER32 has no ChangeDisplaySettings (only
  EnumDisplayDevices/EnumDisplayDeviceModes), so usosres cannot apply a
  mode. Missing `DefaultSettings.*` values give an all-zero DEVMODE, and
  3.1 framebuf.dll then takes the first mode of the miniport's list (its
  match loop accepts any mode when X, Y, bpp, flags and frequency are 0).
  The **NT 3.1 build** (`build-nt31.cmd`, `-DUSOSVBE_NT3 -DUSOSVBE_NT31`,
  `bin/nt31/i386/usosvbe.sys`, version `usosvbe 1.2-nt31`) moves the first
  available of 1920x1080x16, 1920x1080x32, 1680x1050x16, 1600x900x16,
  1280x1024x16, 1024x768x16, 800x600x16 to index 0 (UsosVbeDiag
  ` first=WxHxB`). The NT 3.5x binary (`bin/nt3`) is unchanged.
- **VideoPortInt10 on 3.1**: same mechanism as 3.51 (SeTcbPrivilege, first
  call allocates 0..FFFFFh in the caller, frees the Vdm range, maps the
  physical low MB, Ke386CallBios) but no ROM checksum before each call.
- **framebuf.dll**: 3.1 Setup installs it only for Dell DGX and has no
  expand.exe: `nt31_native` expands the CD's SZDD `FRAMEBUF.DL_` with
  `usos-fb-ui --szdd-get` into `\USOS\NT3\FRAMEBUF.DLL` (not in git).

Wiring: POST.CMD runs `USOSNT3.EXE /vesa31` before `/finish31`: copies
framebuf.dll (when system32 has none) and usosvbe.sys, `Services\usosvbe`
Type 1, Start 1, ErrorControl 0, Group "Video", Tag 2, `Device0`
InstalledDisplayDrivers "framebuf", VgaCompatible 0, no DefaultSettings.
vga untouched. Tests: `tools/tests/test_nt31_usosvbe.py`.

X470 risks: the RX 560 VBIOS under 3.1's Ke386CallBios (unproven on 3.1;
3.51 Full HD works with the same miniport code); if no listed mode works
framebuf fails -> STOP C0000143 -> boot `[VGA mode]`.

### 8.7.1 X470 run 1: VGA desktop, usosvbe never ran

Patched Micron: desktop, no STOP, still 640x480. Read-only evidence: no
`UsosVbeModes` (FindAdapter writes it first thing) nor `UsosVbeDiag`
anywhere in SYSTEM, so the miniport never reached FindAdapter; no event
log entry (3.1 logs no 7026). usosvbe was a system-start driver (Start
1): NT 3.1 never ran our WDK-built system-start drivers (usosusb showed
the same, docs/nt31-2026-10-09.md; every working USOS driver on 3.1 is
boot start). Fix: `/vesa31` registers usosvbe **Start 0** (the loader
brings videoprt.sys in as its import; usosvbe initialises with the boot
drivers, so it is Video0 ahead of vga regardless of Tag). The 3.1 build
also tries Isa, Eisa, MCA, PCIBus (first success, as vga.sys does) and
writes `Services\usosvbe` `UsosVbeEntry` (REG_SZ, RtlWriteRegistryValue) =
`usosvbe 1.2-nt31 entry isa=<status> ...` from DriverEntry, so the next
run shows DriverEntry -> VideoPortInitialize -> FindAdapter
(`UsosVbeModes`) -> CSRSS open (`UsosVbeDiag`: VBE list, `first=`, `set=`).

SYSTEM.ALT: NT 3.1 writes the dirty ranges of SYSTEM into SYSTEM.ALT, so
a structural offline patch of SYSTEM alone left ALT inconsistent (strict
checker: double references, sk refcount). Offline hive patches must write
the same image to both files.

Manual resolution on NT 3.1: there is no Display applet; Windows NT Setup
(Options > Change System Settings > Display) lists only VIDEO.INF options
or an OEMSETUP.INF from a disk ("Other"), and VIDEO.INF registers drivers
as system start (which 3.1 never runs for our builds). Until USOS ships its
own OEMSETUP.INF: regedt32, `Services\usosvbe\Device0`
`DefaultSettings.XResolution` / `YResolution` / `BitsPerPel` (REG_DWORD,
a mode the BIOS lists), reboot.

### 8.8 Network for native NT 3.1: assessment (not implemented)

- **The CD**: TCP/IP is there (TCPIP.SY_, OEMNXPTC.IN_, WSOCK32, PING, FTP,
  TELNET, ARP, ROUTE), static only: no DHCP anywhere (the INF asks for
  IPAddress / SubnetMask / DefaultGateway; DHCP came with NT 3.5). WSOCK32
  reads `NameServer` / `Domain` / `SearchList`, so DNS works with a static
  configuration. Applying a new address needs a reboot (no 3.1 API).
- **NDIS 3.1 has no miniport interface**: NDIS.SYS exports 97 names, no
  `NdisMRegisterMiniport` / `NdisM*` (only NdisMapFile / NdisMapIoSpace),
  no NdisRead/WritePciSlotInformation. usosnet35n / usosnet351n import
  21 / 24 names 3.1 lacks, so they cannot load. usosnet31 (Codex) is
  already a 3.1 full-MAC driver (25 NDIS imports, all present), polled
  (no IRQ/MSI), CF8h/CFCh config access, UP only, and it compiles the
  shared `usosnet_igb.c` backend, which already handles the I211 (iNVM
  MAC, PLL erratum; X470 PASS on 3.5 / 3.51). Only its gate is 82576-only:
  `U31PciValid` accepts id 0x10C98086, and the chip entry is the 82576.
- **I211 for usosnet31**: accept 0x15398086 with the I210|I211 chip flags,
  stage PciBus/PciDevice/PciFunction from the prep env (Linux runs on the
  X470 itself during native prep, so the I211 BDF is known), the network
  rows of INITIAL.INF for WS (today: no network on WS; AS uses the
  Loopback adapter). Estimate: about 1 day + one X470 fresh install.
- **Addressing without DHCP**, options:
  1. static from the profile (IP/mask/gateway/DNS): 0.5 day; user must know
     a free address;
  2. the prep env's own DHCP lease: the prep Linux on the X470 uses the same
     I211 MAC, so its lease (address, mask, router, DNS) written as the static
     NT 3.1 configuration is the address the router already holds for that
     MAC: 0.5 day on top of 1., no user input; risk: lease expiry/reuse on
     routers that recycle addresses;
  3. own DHCP client inside usosnet31 before NdisRegisterAdapter (DISCOVER/
     REQUEST over its own polled rings, then the Tcpip values in the
     registry before TCP/IP binds): 1-2 days, the cleanest; renewals would
     need a timer in the driver.
- **Recommendation**: I211 gate in usosnet31 + option 2 with option 1 as the
  profile override (about 1.5 days), option 3 later if leases expire in
  practice.

### 8.9 USB sticks and the I211 for native NT 3.1 (2026-10-30, host checks only)

**Sticks.** Patched Micron after the VESA run (read-only copy of SYSTEM and
SYSTEM.ALT): usosusb `Parameters\Diag` = `usosusb 1.2-nt31: hc0=01:00.0(22
ports) hc1=0c:00.3(8 ports) p15-nohid p17-nohid p3:s1K- p4:s2-M`. The stick
ports were enumerated, but the NT 3.1 build had no `USOSUSB_MSC` (the mass
storage code was compiled only into the NT 3.5x/4.0 and NT 6 builds), so a
stick was "not a HID device" and nothing else. Not a start-mode problem:
usosusb is boot start on 3.1 and runs. **usosusb 1.4-nt31** takes the NT
3.5x/4.0 stick path (`USOSUSB_NT4MSC`: plain `\DosDevices` letters after C:
exists, hot plug / unplug, MBR or superfloppy, FAT12/FAT16/NTFS volumes,
GPT/FAT32/exFAT skipped with a Diag tag). NT 3.1 specifics: the queue's
spin locks and interlocked lists are imported in their stdcall forms
(`KeAcquireSpinLock` / `KeReleaseSpinLock` from the HAL,
`ExInterlockedInsertTailList` / `ExInterlockedRemoveHeadList`; 3.1 has no
Kf/Exf exports; all imports checked against `nt31_exports.txt`). Template
hive (fresh installs): `usosusb\Parameters LogFile =
\DosDevices\C:\USOS\NT3\USOSUSB.LOG`. Host tests: volume publishing code run
on stick images with `-DUSOSUSB_NT31` (`test_nt4_usosusb_storage.py`).

X470 run with 1.4-nt31 (Micron read back, SYSTEM = SYSTEM.ALT): `p15:s1--S
p1:fat-32k-skip(15296M wp0 0v)`, again after a replug: the stick (16 GB,
bulk-only, ready, capacity read, partition 1 FAT12/16) was skipped by a
guard of this build that refused FAT volumes with 32 KiB or larger
clusters. That guard rested on an unproven guess (the 0x1E of the VM
flow's 2000 MiB C:); the NT 3.1 fastfat's own boot-sector check
(FatIsBootSectorFat, local reading of the 3.1 CD's FASTFAT.SYS) accepts
1..128 sectors per cluster and 128..1024 bytes per sector. Guard removed
(1.4-nt31, second build); Diag now notes each FAT volume's BPB and
partition (`p1:fat c64 r1 t0e 2047M`), and a 0x0E (FAT16 LBA) entry is
reported to NT 3.1 as 0x06 (3.1 predates type 0x0E). If the stick now
STOPs on insertion, the cluster size / reserved sectors from that Diag
line are the first suspects.

Stick formats NT 3.1 can use: MBR or no partition table (superfloppy),
FAT12 or FAT16 (FAT16 partitions up to 2 GiB, 4 GiB with 64 KiB clusters);
NTFS only as NT 3.1 itself wrote it (later NTFS versions are not readable
by its ntfs.sys). Not usable: FAT32, exFAT, GPT sticks (the USOS stick itself).

The installed Micron got the new USOSUSB.SYS in place (system32\drivers and
\USOS\NT3; registry untouched; PATCH-261030-221016 in the scratchpad).

**Root cause of "NT 3.1 never runs our system-start drivers" (8.7.1).**
Codex's full-MAC round measured it (docs/nt31-fullmac-port-contract.md,
"Demand-loader contract"): the NT 3.1 kernel image loader used for
system-start drivers returns C000007B when FileAlignment has any of the low
9 bits set; WDK 7.1 links drivers with 0x80 file alignment. Boot-start
drivers go through OSLOADER, which does not check. `DRIVER_ALIGNMENT=0x1000`
(as in the usosnet31 `sources`) gives 0x200 file alignment and loads as a
system driver. usosusb / usosvbe stay boot start (they work).

**I211 in usosnet31.** `U31PciValid` accepts 0x15398086 (and 0x10C98086);
the chip entry follows the device id (`CHIP_IGB_I210 | CHIP_IGB_I211`, so
the shared backend takes the iNVM MAC and the PLL erratum path); config
writes now allow, for the I211 only, the PMCSR word (PM capability + 4) and
the BAR dwords 0x10..0x24 that the PLL erratum's D3hot -> D0 cycle restores
(`U31PciWriteAllowed`, host cases); DMA buffers may sit anywhere below
4 GiB (the 16 MiB limit was an assumption of the QEMU candidate);
`NdisRegisterAdapter` tries PCIBus, then Isa, then Eisa masters
(`UsosBusType` picks the first; NativeDiag stages 0x10..0x12), and a failed
`NdisMapIoSpace` falls back to `MmMapIoSpace` (stage 0x18), both as on
native 3.5x where the HAL has no PCI bus. 17920 B, PE 3.10, file alignment
0x200, section alignment 0x1000, one new import (ntoskrnl MmMapIoSpace).

**Not done: the install wiring.** The binary is not staged by any flow yet,
so a fresh native 3.1 install still has no network. Findings for the next
step (local reading of the 3.1 CD INFs): TCP/IP is not in the 3.1 Setup
copy lists (only FILELIST.INF and OEMNXPTC.INF name TCPIP.SYS);
NTLANMAN.INF installs `[ProtoData]` entries only (NBF), so TCP/IP needs a
`ProtoData_2 = "OEMNXPTC.INF","TCPIP",0,Tcpip` row (billboard 0 = none);
OEMNXPTC.INF in bind mode calls `CPlSetup TCPCFGCHK` and then
`configureadapter`, whose `CPlTcpip` is the interactive address dialog: the
patch has to write IPAddress/SubnetMask (adapter `Parameters\Tcpip`),
DefaultGateway and NameServer (`Tcpip\Parameters`) itself and skip
`CPlTcpip`; the adapter can reuse the AS path's Loopback install
(`[InitialAdapterInstall]` -> LOOP, NDISLoop/NDISLoop1) for WS, followed by
the 3.5x-style takeover of `NDISLoop` by USNET31.SYS with PciBus/PciDevice/
PciFunction at the end of GUI Setup (POST.CMD), plus the client policy
(Server/Browser off, as `NET31CFG /client`). Address source: the prep
environment runs no DHCP client and ships no igb module, so "the prep
Linux's lease" needs igb (+ptp/dca deps) in the micro Linux and a bounded
udhcpc run first; a static profile address works without that. These GUI
Setup INF changes need one QEMU or X470 fresh-install round before they
can be the default; ICMP.DLL and WSOCK32.DLL are on the 3.1 CD, so a
NETCHECK.TXT (ping gateway, TCP 1.1.1.1:80) is feasible from USOSNT3.

### 8.10 Network for native NT 3.1: install wiring (2026-10-30, host checks only)

Default for a fresh native NT 3.1 / 3.1 AS install when the profile has the
network on (`;USOS-NT31-NETWORK=on`, `;USOS-NT31-WORKGROUP=`, rendered by
`nt3.zig` for both 3.1 ids) and the prep Linux sees exactly one card
usosnet31 drives (8086:1539 I211, 8086:10C9 82576). Library:
`tools/nt31_network_setup.sh`; tests: `tools/tests/test_nt31_native_net.py`.

**Driver start mode.** usosnet31 stays an NDIS MAC under the Loopback
adapter's own service (NDISLoop, NCPA's start mode kept; NETCHECK.TXT
records it). Not boot start: its `sources` already link with
`DRIVER_ALIGNMENT=0x1000` (file alignment 0x200, section 0x1000), which the
NT 3.1 system-image loader accepts (8.9, Codex measurement; Codex R24c ran
the same binary family as an NCPA-installed system/auto-start MAC), and an
NDIS MAC has to come up with NDIS and its bindings, after the boot drivers.

**Address source: the prep Linux's DHCP lease** (8.8 option 2, profile as
override). The micro Linux now carries igb.ko (+ i2c-algo-bit, dca, hwmon)
and af_packet.ko from the pinned offline modloop (no download); busybox
already has udhcpc. `usos_nt31_address`: static profile values
(`;USOS-IP=a.b.c.d/n`, `GATEWAY`, `DNS`) when set; else `modprobe igb`, link
up (15 s for carrier), `udhcpc -f -q -n -t 5 -T 4` with a script that only
writes the lease values (no `-R`: the lease is not released, the router
keeps the address for this MAC; usosnet31 uses the same iNVM MAC), link down,
`modprobe -r igb`; profile DNS servers win over the lease's; no lease ->
link-local 169.254.<mac5>.<mac6>/16 (TCP/IP and NetBT start without error
popups, no route; `note=` says why). `NET31.ON` (\USOS\NT3) records mode,
address, mask, gateway, DNS, domain, lease time, DHCP server, PCI
bus/device/function, driver hash, workgroup, client policy. Risk: a router
that hands the address to another device after the lease time (recorded in
NETCHECK.TXT as `net31_lease_s`); then the profile's static address or a
reservation is the answer. Option 3 (DHCP client in usosnet31) stays later.

**GUI Setup (local source, before text mode):**
- INITIAL.IN_: the network part stays on for Workstation too (as on AS);
  right before `shell "ntlanman.inf" DoNetwork` it creates
  `HKLM\SOFTWARE\USOS\NT31NET` (marker).
- NTLANMAN.IN_: the AS path's Loopback bypass (`STF_NCOPTION = LOOP` during
  Setup) + `ProtoData_2 = "OEMNXPTC.INF","TCPIP",0,Tcpip` (TCP/IP after
  NetBEUI; its files come from the local source with the network copy list).
- OEMNADLB.IN_: no media page (AS path).
- OEMNXPTC.IN_ configureadapter, only while the marker exists: the INF's own
  per-card default writer gets the chosen IP / mask (as ipinfo.inf defaults
  would; ipinfo.inf is not copied by 3.1 text mode), the gateway goes to
  `Tcpip\Parameters`, and the CPlTcpip address dialog and the "cannot
  configure" note are skipped, so TCP/IP and LmHosts start with an address
  when NTLANMAN starts the network (a failed LmHosts start would stop Setup
  on a message box). Control Panel runs later (no marker) are the CD's.
- USOSANS31: "Domain/Workgroup Settings" (NCPA dialog 6310, WS) -> member
  of the configured workgroup (radio 1194, edit 1192), the "Welcome to the
  ... workgroup." box -> OK; fallback only: "TCP/IP Configuration" (6290) ->
  Cancel. AS keeps "Domain Settings" -> controller in USOSDOMAIN.

**POST.CMD `USOSNT3 /net31`** (after /vesa31, before /finish31; NT 3.1
only): copies USNET31.SYS (8.3 name) to system32\drivers and compares it,
NDISLoop ImagePath -> `\SystemRoot\System32\drivers\usnet31.sys`,
NDISLoop1\Parameters PciBus/PciDevice/PciFunction (+ UsosBusType 5, which
usosnet31 retries as Isa/Eisa), the TCP/IP values as the 3.1 INF / NCPA
name them (NDISLoop1\Parameters\Tcpip IPAddress + SubnetMask REG_SZ;
Tcpip\Parameters DefaultGateway, NameServer space separated, Domain,
Hostname), each read back; Workstation: LanmanServer + Browser Start 4
(client without sharing, network defaults); removes the marker; registers
`usosnetc` = `USOSNT3.EXE /netcheck31`. Log in POST.LOG, `NET31.STS`.

**NETCHECK.TXT** (first boot, service usosnetc, then disabled): after 45 s
the NET31.ON values, the registry readback, NDISLoop ImagePath / Start,
usosnet31 `NativeDiag` Stage/Status/Value, the CD's PING.EXE (3.1 ICMP.DLL
exports only do_echo_req/do_echo_rep, no IcmpSendEcho) `-n 3` to the gateway
and to 1.1.1.1 (counted "Echo Reply:TTL" lines + the output), a
gethostbyname("one.one.one.one") and a TCP connect to 1.1.1.1:80 (wsock32).

All imports of USOSNT3.EXE and USOSANS31.EXE resolve against the 3.1 CD's
KERNEL32/ADVAPI32/USER32 (host check). Not run anywhere yet: the GUI Setup
network part on Workstation, TCP/IP on 3.1 in the native flow, the
usosnet31 takeover on the X470; the fresh X470 install is the test.

### 8.10.1 X470 fresh install 1 (B261030-222017): no network, answerer not started

Read-only copy of the Micron's C: (USB enclosure; scratchpad m31):
`\USOS\NT3` has no NET31.ON, POST.CMD has no `/net31`, system32 has no
PING.EXE / TCPIP.SYS / NBF.SYS / LOOP.SYS: the network part never ran. GUI
Setup's "Unable to open C:\USOS\NT3\USOSANS31.EXE": a 9-character name on
FAT (Linux vfat wrote it with a long-name entry; NT 3.1's FAT sees only the
short alias USOSAN~1.EXE), so no page was answered (Date/Time waited, GMT).
System event log: NetDDE event 13 "NETBIOS" = the "service failed" box.

Fixes: the answerer is staged and started as `USOSAN31.EXE` (8.3; status
file `NET31.STS` likewise); the no-profile WINNT.SIF of
w9x_csmwrap_prepare.sh (w9x_nt3_default_sif) now carries
`;USOS-NT31-NETWORK=on` / `;USOS-NETWORK=on` / `;USOS-IP=dhcp` as for 3.5x
(the profile-rendered answer already had them; the prep log of this run
was not available, so the preflight's reason is now logged and written to
the target as `\USOS\NT3\NET31.OFF`); the Date/Time page gets the profile
zone (NATIVE31.INI `tz=`, the start of the 3.1 MAIN.CPL entry, e.g.
"(GMT+1:00) Berlin" for Central European; CB_FINDSTRING + CBN_SELCHANGE);
POST.CMD always runs `/net31`, which without a network sets NetDDE to
demand start when no NetBIOS service exists. The installed Micron is not
patched (no TCP/IP / NBF / Loopback registry to complete offline in the
REGF 1.1 hives); a fresh install is the test.

### 8.10.2 X470 fresh install 2 (B261030-224855): stack installed, takeover refused

Read-only copy of the Micron: GUI Setup installed Loopback + NetBEUI +
TCP/IP (TCPIP.SYS, STREAMS.SYS, NBT.SYS, PING.EXE present), IP / mask on
the adapter and `Tcpip\Parameters DefaultGateway` (REG_SZ) as chosen from the
prep DHCP lease (192.168.0.215/24, gw 192.168.0.1, lease 7200 s). Three bugs:
- NT 3.1 NCPA names the Loopback instance **NDISLoop01** (`NDISLoop\Linkage
  Bind = \Device\NDISLoop01`; NT 3.5x: NDISLoop1). `/net31` looked for
  NDISLoop1 and refused, so loop.sys stayed and the I211 had no driver
  (NET31.STS = FAILED, no NETCHECK.TXT). Now found at run time (NDISLoop01,
  else NDISLoop1), also for NETCHECK.
- The TCP/IP service (TCPIPSVC.DLL) needs per adapter, besides IPAddress /
  SubnetMask, the DWORDs ForwardBroadcasts, KeepAlive, BroadcastType and
  Trailers (RouterMTU optional); the skipped address dialog writes them.
  Event 0x1132 TcpipSvc `...NDISLoop01\Parameters\Tcpip\ForwardBroadcasts`,
  then SCM dependency failures (TCP/IP NetBIOS). Now written by the
  OEMNXPTC patch during Setup (0, 0, 1, 0) and again by `/net31`.
- The Date/Time answer required a 4-digit year; 3.1 MAIN.CPL shows two
  digits, so the page waited (the zone entry in NATIVE31.INI was right).
The installed Micron is not patched: completing it offline means adding
values in both REGF 1.1 hives plus the driver swap, which the own hive
writer (template keys only) does not do safely; a fresh install is the test.

### 8.10.3 X470 fresh install 3 (B261030-231755): blue screen, usosnet31 suspected

Reported by the user: a blue screen after the install, now that `/net31`
finds NDISLoop01 and usosnet31 really drives the I211. No STOP code, no
photo, the Micron not read yet (planned for the next session).

**Code review of usosnet31 against the NT 3.5x native BSOD fixes:**
- (a) interrupt handlers with a NULL interrupt object (3.51 STOP 0x0A in
  NdisMDpcTimer): not applicable. The NT 3.1 full-MAC model has no miniport
  Disable/EnableInterrupt handlers; usosnet31 connects no interrupt
  (NdisInitializeInterrupt is never called) and polls from its own system
  thread every 20 ms.
- (b) direct map: present (NdisMapIoSpace, else MmMapIoSpace of BAR0; stage
  0x18). RD32/WR32 only run after a successful map (HardwareTouched).
- (c) WriteDiag handle misuse (3.51 STOP 0x1E): not applicable; NativeDiag
  is written with ZwCreateKey/ZwSetValueKey on the driver's own registry
  path at PASSIVE_LEVEL only (no NdisWriteConfiguration).
- (d) timer/DPC: no NDIS timer and no DPC; the worker raises to
  DISPATCH_LEVEL for the poll and the indications and lowers again. The
  same code passed QEMU R24c/R24d (82576, ping, DNS, HTTP) and cold
  shutdown; the X470 differences are the I211 path (iNVM MAC, PLL erratum
  D3hot -> D0 with BAR restore), the Isa/Eisa master registration retry on
  a HAL without PCI bus, the direct map and DMA below 4 GiB (with
  /MAXMEM=64 all memory is below 64 MiB anyway).
- (e) indications before a binding: EthFilterIndicateReceive with no open
  is the filter library's business (R24c started the same way).
- **Own bugchecks on the failure path (fixed in source):** `Cleanup` (used
  when `Add` fails after touching the card) called
  `KeBugCheckEx(0xE0553101, 3 | 4, ...)` when bus mastering or the I211's
  GIO master status did not turn off, so a failed adapter start was a blue
  screen. Now it keeps the DMA memory (leak, never reused), records
  NativeDiag stage 0x1D (Status = Command register or STATUS, Value = 3 / 4)
  and returns the failure; NT then boots without the card. The remaining
  bugchecks are 1 (worker thread cannot be referenced and does not end)
  and 2 (Cleanup above PASSIVE_LEVEL). **Not rebuilt yet**: the driver
  binary (bin/nt31-native/i386/usosnet31.sys) and the payload still have the
  old code until the STOP code is known (rebuild with tools/nt/usosnet
  build31.py, then build.bat).

**Read the STOP line first:** `0xE0553101` = usosnet31's own check (param 1
= 1..4 as above); 0x0A / 0x1E / 0x50 with an address inside usnet31.sys =
a driver bug at that offset (map with the .map / cod of the build); another
driver named = not usosnet31.

**Read-only checklist for the Micron (USB enclosure, by model + size):**
1. C: partition image (MBR partition 1) and the target ESP, never write.
2. `\USOS\NT3`: POST.LOG (the `/net31` lines: NDISLoop01, ImagePath,
   PciBus/Device/Function, readbacks), NET31.STS, NET31.ON, NETCHECK.TXT
   (exists = one boot ran 45 s+ with the service), USOSANS.TXT (Date/Time
   action line), USOSUSB.LOG.
3. SYSTEM and SYSTEM.ALT (REGF 1.1, scratchpad h31.py reader):
   `Services\NDISLoop` ImagePath / Start, `Services\NDISLoop\Parameters\
   NativeDiag` Stage / Status / Value / Sequence (the last usosnet31 point:
   1 DriverEntry, 2 RegisterMac, 3 Add entry, 4 PCI ok, 0x10.. register
   tries, 5 map, 0x18 direct map, 6 reset, 7 started, 0x20 alive, 0x1D the
   new bus-master check, 0x1F init failed), `NDISLoop01\Parameters` (PciBus
   etc.), `NDISLoop01\Parameters\Tcpip` (the four DWORDs), `Select`
   (Current / LastKnownGood), and whether ControlSet002 has the takeover.
4. SYSEVENT.EVT: boots after Setup, TcpipSvc / NDIS errors.
5. ESP `\USOS\BOOTLOG.TXT`: reset causes of the last boots (the NT 3.1
   usosrst has no bugcheck callback, so no STOP code in the RAM marker; a
   crash shows as a reset without a usosrst shutdown stage).
6. Every boot or once: NETCHECK.TXT / event log timestamps / BOOTLOG boot
   count.

**Getting the installed system up again (only after the read, with
backup, readback and flush):** the smallest change is `Services\NDISLoop
Start` 3 -> 4 (an inline REG_DWORD in its value cell, a 4-byte in-place
write), then the same image to SYSTEM and SYSTEM.ALT. TCP/IP then starts
without an adapter (no network, but the desktop). Alternatives: copy the
CD's LOOP.SYS over `drivers\usnet31.sys` (same name, so no registry change),
or at the boot menu "Last Known Good" if ControlSet002 predates `/net31`.

### 8.10.4 STOP 0x0D on the X470 (fresh install 3): cause and fix

User photo: STOP 0x0000000D MUTEX_LEVEL_NUMBER_VIOLATION, usnet31.sys at
FBCA0000; return addresses map (build of 5e269ad8, image base 0x10000) to
DriverEntry (RVA 0x2ef8, first D31Point) -> D31Point -> KeWaitForSingleObject
(0x11d6) on g_31Mutex (0x600c), a level-0 KMUTEX (KeInitializeMutex at
0x1191). NT 3.1 kernel mutexes carry a level; the loading thread already
owned a higher one. Micron read (read-only): /net31 ok (NDISLoop ImagePath
usnet31.sys, PciBus 4 / 0 / 0, the TCP/IP values and the four DWORDs), no
NativeDiag key at all (the crash came before the first breadcrumb), no
NETCHECK.TXT, no SYSEVENT.EVT. Fix b55cd134: busy flag instead of the mutex,
driver rebuilt (sha256 19cfb189...). Both USNET31.SYS copies on the
installed Micron replaced with it (registry unchanged; backup and
\USOS\NT3\PATCH31.TXT). Date/Time was still not answered (no action line;
the edits' text is not visible to the recorder): the page is now answered
on title + controls, and the year, zone search and selection are logged.

### 8.10.5 X470, patched Micron: internet works; NbtSvc ScopeID

With the b55cd134 driver: no blue screen, `ping 1.1.1.1` answered (TTL 54).
NETCHECK.TXT (first boot): usosnet31 alive (NativeDiag stage 0x20, 0x15
frames received after 500 polls), TCP 1.1.1.1:80 ok; the gateway and
1.1.1.1 pings got 3/3 replies but were counted 0/3 (has_ci wants its word in
lower case; fixed); `gethostbyname("one.one.one.one")` failed (DNS with
NameServer "1.1.1.1 192.168.0.1", DNSLookupOrder 4: open). The "service or
driver failed" box: event 0x1132 NbtSvc
`...\Services\Nbt\Parameters\ScopeID` missing (the skipped NCPA dialog
writes it), SCM 0x1b6f TCP/IP NetBIOS, then NetDDE 0xd "NETBIOS". Fixed:
ScopeID = "" during Setup (OEMNXPTC patch) and by `/net31`. Not patched on
the installed Micron (a new value in both hives); there: Control Panel >
Network > TCP/IP > Configure > OK writes it (or regedt32), then restart.

### 8.10.6 Fresh install 4 (B261031-110036): hands-free incl. Date/Time; NbtSvc PermanentName, DNS order

Fresh NT 3.1 install on the X470: Setup fully hands-free including the
Date/Time page (25d7383a), internet (ping 1.1.1.1). NETCHECK.TXT: gateway
and 1.1.1.1 3/3, TCP 1.1.1.1:80 ok, DNS lookup failed. Popup again: event
0x1132 NbtSvc `...Nbt\Parameters\PermanentName` (ScopeID now present).
NBTSVC copies PermanentName as a string into a 16-character NetBIOS name
buffer; `/net31` now writes the card's MAC in hex (12 characters; NET31.ON
`mac=`, read in the prep env also for a static profile address), else
"USOS" + the IP in hex. DNS: WSOCK32 reads `NameServer` space separated (as
written) and maps DNSLookupOrder 1..4 to its lookup flags; OEMNXPTC.INF
installs 4 (the last of the NCPA order choices, hosts file only), which the
skipped dialog would change. `/net31` writes 3 when a name server is set.
Micron: DNSLookupOrder 4 -> 3 patched in place (2 bytes, CS001 + CS002, the
same image to SYSTEM and SYSTEM.ALT, PATCH32.TXT); PermanentName not (new
value): the popup stays there until a fresh install or the TCP/IP dialog.
