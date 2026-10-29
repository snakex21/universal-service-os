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
