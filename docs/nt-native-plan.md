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

### 4.5 Slice 4 - NT 4.0 (hard)

The RTM text-mode kernel resets on Zen 3, the SP6a kernel hangs in text mode.
Options, in order of cost:
1. Find why the SP6a kernel hangs in text mode (local NT5 sources for the
   text-mode/setupdd path; compare with the working SP6a boot of the
   installed system). If it is a known init path (e.g. a driver from the RTM
   CD that does not match the SP6a kernel), slipstream the SP6a kernel, HAL
   and the matching drivers into `~BT` / `~LS` and TXTSETUP.SIF.
2. An own CPUID-limiting shim before NTOSKRNL starts is not possible on
   AMD without virtualization (no MaxVal limit MSR); not planned.
3. Keep the VM path for NT 4.0 (it works on the X470 with the 9x flag fix).
Then the same pieces as NT 3.51 (miniports in text mode, POST.CMD finish
work in-OS, key gate stays).

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
- NT 4.0 VM path with `phase1-native.flag` present (the 2026-10-27 blocker).
