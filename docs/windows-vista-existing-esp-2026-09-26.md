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
