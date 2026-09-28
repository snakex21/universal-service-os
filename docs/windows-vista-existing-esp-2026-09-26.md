# Vista SP2 x64 on a disk that already has an ESP (X470 0x1F, 2026-09-26)

Build B260926-183931, X470, CSM off: Vista Setup exited with 0x1F at
`Callback_PrepareSystemVolume`. The Intel SSD kept the ESP of the Windows 7
install (p2); the user deleted only C:, and Setup created a second 200 MB
ESP (p4, never formatted). Evidence: `artifacts/vista-x470-setup-fail-20260926/`
(GPT, both ESPs, stick logs; `usos-startup.log` of that session is 0 bytes).

## Cause

1. **Only PE10's `bcdedit /sysstore` ran.** Vista Setup resolves the system
   partition through Vista's own BCD library, which does not see PE10's hint
   (`GetSystemDiskNTPath` / `GetSystemPartitionNTPath: ... 0xc0000451` in the
   Sept 20/21 sessions). The successful hardware runs v3/v5-v7 also ran
   Vista's own bcdedit, but only with the hardware `--intel-profile`, which is
   not in release builds.
2. **The guard refused and kept probing a raw new ESP.** `refresh_esp`
   required FAT32 (`GetVolumeInformationW`) before re-targeting, so when Setup
   created p4 it re-mounted, probed and dropped p4 on every Panther/device
   notification while Setup was preparing it, and never pointed a hint at it.

## Changes (`tools/windows_vista_install.c`, installer v9)

* **Vista's own bcdedit in every build.** `load_vista_bcdedit` extracts
  `Windows\System32\bcdedit.exe` (6.0) and the MUI files of the ISO's UI
  languages (`sources\lang.ini`, plus en-US) from the selected ISO's
  `sources\boot.wim` with PE10's wimgapi (`WIMExtractImagePath`, image 1) into
  WinPE RAM. A DISM mount does not work in the wimboot PE10 (DISM error 1).
  If extraction fails Setup is not started (existing "boot partition could
  not be confirmed" dialog). The hardware boot profile still wins when present.
* **Both hints on every selected ESP, at once.** `point_system_store` runs
  PE10's and Vista's `/sysstore` through a raw DOS alias as soon as exactly
  one new internal ESP appears (or the single existing one), also while it
  is unformatted. A new ESP is never opened (no `GetVolumeInformationW`, no
  FAT32 test, no handle). An ESP that existed before Setup is mounted once by
  a volume query before `/sysstore`.
  The alias is not short-lived as in the Windows 10/7 guards: Vista's hint is
  bound to it, and removing it right after `/sysstore` made Vista's `/export`
  fail with ERROR_FILE_INVALID. It is a symbolic link only, replaced when
  another ESP is selected and removed after Setup.
* **Pre-Setup check, log only.** For an existing ESP the installer exports
  the system store with Vista's bcdedit and checks that `{bootmgr}` points at
  it. In QEMU this export fails with 1006 even for a store Vista itself
  created (it worked on the X470 in v3), so it cannot gate Setup: the result
  is logged, no dialog.
* **Finalizer** always verifies the store with Vista's bcdedit (before: only
  with the boot profile; otherwise PE10's export).
* **Logging.** Every `refresh_esp` decision is written to
  `vista-install.log` (identical decisions in a row are counted, not
  repeated); `vista-bcd-sysstore.txt` keeps every bcdedit call with its
  command line.

## Logging (`tools/windows_setup_logging.c`)

* **Vista's Panther log.** Vista Setup started from the ISO under PE10 writes
  nothing to X: (checked from a Shift+F10 console in QEMU: no `setupact.log`
  on any drive at the language page). It appears only on the target,
  `<target>\$WINDOWS.~BT\Sources\Panther\setupact.log`, after the disk is
  committed; when Setup fails before that, no Panther log exists at all. The
  collector saves the target copies of every lettered drive (as before) and
  now also of every unlettered fixed volume (`target-vol-NN-bt-*.log`), plus
  any Panther log the X: watcher sees (`x-*.log`).
* **0-byte `usos-startup.log`.** It only appeared in sessions where Vista
  Setup failed (0x1F: 2026-09-20 23:35, 09-21 00:01, 09-26 20:03). The
  watcher rewrites every snapshot in place (truncate, then copy) on each
  change; a reset during that leaves a 0-byte file. Snapshots are now written
  to `<name>.new` and renamed over the old copy, and an empty source never
  replaces a non-empty snapshot. In the QEMU 0x1F run below the snapshot on
  the stick has the full log (1745 bytes).

## QEMU (OVMF, no CSM, TCG, AHCI target)

Target disks come from `tools/tests/windows_native/make_vista_esp_repro_disk.py`:
the SSD's layout (WinRE 500 MB, ESP 100 MB with the Windows 7 boot files and
a BCD bound to this disk, MSR, C: with data) or `--blank`.
In Setup the old C: (partition 4) is deleted and Vista is installed into the
freed space, as on the X470.

| Case | Build | Result |
|---|---|---|
| Win7-style ESP, C: deleted | 183931 (old) | Setup expands all files, then "Windows could not update the computer's boot configuration"; cancelled, exit 0x1F |
| Win7-style ESP, C: deleted | new | Vista's bcdedit extracted, both hints on p2 (no volume access), Setup resolves the system partition through them (`GetSystemPartitionNTPath: Found system partition at [\Device\HarddiskVolume6]`, no 0xc0000451); then the same boot-configuration failure, exit 0x1F |
| blank GPT disk | new | Setup refuses: "cannot verify that the computer contains a valid system volume", exit 0x1F; no ESP ever appears, so there is nothing to hint (log: `waiting for a unique target ESP`); same as the old build on 2026-09-26 |

QEMU never created the second ESP of the X470: both builds reused p2. Both
then fail on the **existing BCD** of p2: Setup's rollback copy of
`Z:\EFI\Microsoft\Boot\BCD` fails with 1006, and at the end
`ModifyBootEntries: BCDOpenSystemStore failed ... c0000098` (STATUS_FILE_INVALID,
= 1006). It is the same error as the pre-Setup export. The store on this test
ESP was written by Windows 10 tools (like the X470's Windows 7 ESP made from
PE10), and Vista's BCD library under PE10 cannot open it as the system store.
In the earlier QEMU success (2026-09-26 e2e) the ESP had no BCD and Setup
created one. The X470's second ESP may be Setup avoiding this unreadable
store; this is not proven.

Open (a product decision, not implemented): when Vista's library cannot open
the existing ESP's BCD, Setup could be given a fresh store, e.g. by moving the
old `BCD` aside before Setup. This breaks the other Windows on that disk
unless it is restored or merged afterwards.

## Not changed / open

* Answer files for Vista on UEFI stay unsupported.
* The blank-disk refusal in QEMU is unchanged; the hardware runs v5-v7 did
  install onto a disk whose partitions were all deleted (with the profile
  hint). Needs the X470.
* X470 test: the same SSD layout (Windows 7 ESP kept, C: deleted), CSM off.
  Expected in `vista-install.log`: `Vista BCDEdit: bcdedit.exe 6.0 extracted`,
  `ESP refresh: system stores pointed at the ESP` for p2, no second ESP, and a
  first boot.

## v10 (2026-09-27): no pre-Setup ESP gate

X470 with B260926-211821 (v9), CSM on: Setup never started. The SSD had two
ESPs (Windows 7 p2 plus the raw p4 left by the 0x1F run), and the old
pre-Setup gate refused (`waiting for a unique target ESP`, exit 21) before the
user reached the disk page.

* No refusal before Setup for 0 or several internal ESPs; only the hardware
  boot profile keeps its exact-disk gate. If Setup fails with no ESP ever
  selected, `vista-install.log` says so.
* Vista's disk page does not list ESPs or the MSR (QEMU: only "Partition 5"
  is shown), so the user cannot delete a leftover ESP there. Before Setup,
  each existing ESP's boot sector is read from the raw disk (no volume
  opened): when no new ESP appears and exactly one of the existing ones holds
  FAT, it is selected.
* QEMU with WHPX (`USOS_NATIVE_ACCEL=whpx` in `qemu_native.py`), Setup
  through file expansion only:
  (a) `make_vista_esp_repro_disk.py --raw-second-esp` (X470 layout: WinRE,
  Windows 7 ESP, MSR, raw ESP, C:), C: deleted: Setup starts, p2 = FAT, p4
  = raw, both hints on p2, Setup reaches the expand phase, then the known
  boot-configuration failure on p2's Windows-10-made BCD (above);
  (b) blank disk: Setup starts, refuses "cannot verify a valid system volume"
  on Next (unchanged QEMU behaviour, no ESP to hint).

## v11 (2026-09-27): USOS prepares the disk (default for Vista on UEFI)

User decision: reuse the XP target-disk mechanism.

* **Menu:** Vista, UEFI, method Automatic, and no pending record: the UEFI
  menu starts the base micro-Linux (`src/platform/uefi/vista_preparation.zig`,
  `usos.legacy_action=vista-disk`, pipeline profile `vista-uefi-disk`, step
  600).
* **micro-Linux** (`tools/vista_disk_prepare.sh`): the XP disk picker
  (`usos_xp_choose_disk`) and confirmation (`usos_xp_confirm`, Cancel
  preselected), same wording ("{0} - SELECT DISK", "{0} - CONFIRM
  INSTALLATION", "All partitions ... will be erased."); the USOS stick and
  read-only disks are never offered. Then: first and last MiB zeroed, a new
  GPT with ESP 300 MiB (FAT32) + MSR 128 MiB (what Vista/7 Setup creates on
  GPT), the rest unallocated; read back (2 partitions, FAT32 boot sector),
  flushed; `EFI\USOS\vista-target.ini` (disk GUID, ESP PARTUUID, size)
  written, then a restart into USOS. Six new `lx` strings, 27 locales.
* **Second Vista start:** the record exists, so WinPE starts directly; the
  installer (v11) reads the record through `usos-log-root.txt`, pins that disk
  and ESP (the boot-profile logic), points both hints at the ESP and renames
  the record `.done` after the finalizer (`.stale` if the disk is not found).
* **No fresh BCD is created** before Setup (deviation from the request): the
  empty FAT32 ESP lets Setup create the store with its own library (the QEMU
  run below, and the 2026-09-26 e2e); a store created by Vista's own
  `bcdedit /createstore` under PE10 failed the same way as the Windows-10-made
  one in QEMU (1006).
* The explicit **ISO** method skips the preparation (v10 behaviour).

QEMU WHPX:
- (a) blank disk: picker, confirmation, GPT, record, then Setup on the
  unallocated space (no "partition order" question), **Setup returned 0**,
  finalizer: Vista export/bootmgr check PASS, dispatcher installed, record
  retired. The final WinPE reboot stalled under WHPX (seen before), so the
  first boot was not run.
- (b) X470-like disk (Windows 7 ESP + raw ESP + C:): the preparation replaced
  it with ESP + MSR (read back), Setup started on the unallocated space and
  expanded files, then the VM froze at 60 % (WHPX stall); not completed.
- The micro-Linux restart after "Disk prepared" hung in the first build
  (unmounting DATA); now sync + `reboot -f` + sysrq fallback, no unmount
  (in the committed build, not yet re-run).

## v12 (2026-09-27): USB arming no longer blocked by the dispatcher; disk preparation opt-in

X470 with B260927-115052, CSM on, ISO method (`artifacts/vista-x470-usb-20260927/`):
the finalizer exited 7 ("Int10 dispatcher: publication failed"). The reused
ESP p2 held the Windows 7 no-CSM files (`win7.original.efi` = the Win7 boot
manager), `publish_loaders()` refused to mix them with Vista's boot manager,
and because this happened inside `configure_boot()` **before
`arm_target()`**, the USB v11 first-boot step was never armed (CmdLine still
`oobe\windeploy.exe`, xHCI without driver in phase 2). Regression from
fb3c46f1.

* `tools/windows_vista_install.c` (v12): `configure_boot` (BCD, test signing,
  fallback loader) -> `arm_target` -> `install_optional_dispatcher`. The
  dispatcher is optional: a failure is logged and the Vista boot manager
  stays on both entries (right with CSM on); it never changes the exit code.
  The misleading `Target BCD preparation failed=0` (GetLastError) now says
  "see the lines above".
* `tools/windows7_uefi_publish.h` (shared with Windows 7): after both
  existing loaders are confirmed to be the boot manager Setup just wrote, the
  known USOS dispatcher files (`win7.original.efi`, `win7.efi`,
  `UefiSeven.ini`, `uefiseven-LICENSE.txt`, `usos-win7-new.efi`) are removed
  from those folders before the fresh ones are copied; nothing else is
  touched, and a folder without its own loader is left alone. Windows 7
  finalizer: it runs last in its script (after the USB steps), so it cannot
  block them; the same cleanup fixes its reused-ESP case.
  Test: `test_vista_int10_dispatcher.py` reused-Windows-7-ESP case.
* **Disk preparation (v11) is off by default** (user decision: deleting and
  formatting in Vista Setup's disk page is enough). To re-enable it for both
  methods, create an empty `EFI\USOS\vista-disk-prep.flag` on the USOS ESP;
  without that file the UEFI menu never starts it and the installer ignores
  any leftover `vista-target.ini`. The default path is the v10 ESP selection:
  Setup always starts, the ESP is picked when exactly one new or remaining
  ESP exists or, with several pre-existing ESPs (Vista's disk page hides
  them), the only formatted one.
* **Answer files/profiles for Vista on UEFI** stay unsupported this round
  (superseded 2026-09-28: the installer merges them on both Vista paths,
  docs/answer-profiles.md)
  (Setup already gets USOS's KMDF servicing answer through `/unattend`; merging
  a user answer into it is not done yet). The answer screen now says so
  instead of listing files the start script would then refuse: "No answer
  file (manual installation)" and "Answer files: not supported for Vista on
  UEFI yet" (27 locales).
* micro-Linux restart after "Disk prepared": works under TCG (20 s after
  the confirmation); under WHPX the guest never resets (`reboot -f` reached,
  QEMU WHPX reset issue, not USOS).

## v13 (2026-09-27): Vista without CSM "not supported yet"; autochk limited to the system volume

* X470 with B260927-130833: CSM on = full success; CSM off = black screen
  (docs/design/win7-vista-no-csm.md section 10). The UEFI summary now shows
  "Windows Vista without CSM: not supported yet (black screen) - enable CSM in
  the board settings" when no CSM is detected (`boot.summary.vista_case_nocsm`,
  27 locales; with CSM: "the installed system needs CSM"); the WinPE console
  says the same. The installation stays allowed; the dispatcher is still
  installed (pass-through with CSM on).
* **Test signing stays on.** A trial boot with test signing off cannot work:
  the Vista USB 3 package is signed with a local test certificate
  (`local-driver-manifest.json`: "not vendor/WHQL signing"), and x64 Vista loads
  such kernel drivers only with TESTSIGNING. With it off, usbxhci does not load,
  so the check could never pass and on the X470 (all ports on xHCI) that boot
  would have no keyboard or mouse. Windows 7 does not use test signing.
* **Autochk (Vista only):** the first-boot gate (`USOS\oobe.exe`,
  `tools/windows_vista_oobe_gate.c` v3, `tools/vista_autochk.h`) replaces the
  untouched default BootExecute `autocheck autochk *` with
  `autocheck autochk /k:D /k:E ... *` (every lettered fixed volume except the
  system one, like `chkntfs /x`) and sets AutoChkTimeout to 3 s; logged in
  `C:\USOS\oobe-prep.log`, never fatal. The system volume keeps its check
  (only when dirty). Volumes without a letter cannot be excluded with /k:.
  Windows 7 and XP are unchanged. Test: `tools/tests/test_vista_autochk.py`.
