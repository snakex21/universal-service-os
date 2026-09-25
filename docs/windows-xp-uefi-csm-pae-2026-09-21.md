# XP x86: separate UEFI preparation / CSM / PAE experiment

User approved UEFI preparation followed by **firmware CSM boot of XP**, with PAE.
This is not native XP x86 boot through x64 UEFI and does not use Quibble/CSMWrap.

## Deployed

Menu: Windows -> **Windows XP - UEFI/CSM + PAE (experimental)**.
The existing Windows XP BIOS entry and production BIOS initramfs remain separate.
Launchers bind the existing SP2 / NiKKA SP3 ISO names; no ISO was changed.

The launcher starts the EFI stub of the existing pinned Linux kernel with a separate
`EFI/USOS-XP/initramfs-xp`. Its explicit disk selection and destructive confirmation
come from the production staging workflow. The target is MBR / NTFS, not GPT.
After preparation, remove USOS and boot the target disk through firmware CSM.
Keep CSM enabled. This deployment itself did not write to Intel or change partitions.

The experiment uses canonical 255/63 on-disk geometry, **not measured BIOS geometry**.
It verifies that the NT52 NTFS template contains the existing EDD-only modification.
The old BIOS implementation still uses its existing BIOS inventory / AH08 checks.
Only the separate archive gets the altered geometry handling and new PAE helper.

## PAE

`GuiRunOnce` invokes `%SystemDrive%\USOS\XP\pae.exe` after setup at first logon.
It requires Windows XP 5.1.2600 and checks the kernel/HAL file versions and unique
patch patterns in executable PE sections. It writes `usospae.exe` and `usoshal.dll`,
updates their PE checksums, backs up boot.ini to `USOS\XP\boot-original.ini`,
then adds a PAE entry retaining the original entries. PAE applies on a subsequent boot.
Original kernel/HAL files are not overwritten. Unknown versions/patterns are refused.
The helper logs to its own `USOS\XP\pae-install.log` and does not use host registry or
profile directories for application data. Prior output/backup files block a blind retry.

Patterns adapted from [evgen-b/PatchPAE3](https://github.com/evgen-b/PatchPAE3), commit
`3e1d3b65f5c3c1ec0c4759f707d3017e51113103`, with CC-BY-4.0 attribution/license in payload.
The upstream auto-elevating CMD script is **not executed or deployed**.
Its instructions also contain an inconsistent XP kernel filename; our boot entry names
the actual separately patched output `usospae.exe`.

## Verification actually performed

- `python tools/build_xp_uefi_csm_trial.py`: exit 0; x86 helper and two x64 EFI launchers.
- `python tools/build_xp_uefi_csm_trial.py --menu-only`: exit 0; Zig UEFI build and Zig tests.
- `python tools/tests/check_xp_pae.py`: exit 0; real MP kernel and ACPI MP HAL extracted
  from **both user's ISO files**, patching copies only. Original files unchanged;
  repeat patches refused. Shell syntax and exact experimental archive delta checked.
- USB deploy: exit 0, hash readback PASS, partition layout unchanged, production
  BIOS and Vista payload hashes unchanged.
- Backup: `artifacts/xp-pae/deploy-20260921-215410`.
- No VM / QEMU / E2E / physical XP boot performed.

## Still unverified / limitations

No new XP ACPI, AHCI or xHCI drivers have been integrated. Preparation uses Linux USB
drivers, but XP requires its own compatible drivers. The old SP2 and 2014 SP3 sources
must **not** be represented as verified Ryzen/X470 installers. PAE pattern success
does not establish runtime driver compatibility, usable RAM above 4 GiB, or successful
hardware installation. Current Vista success does not prove any of these for XP.

Logs from preparation are in `EFI/USOS-XP/` on ESP. Source ISO library and the prior
BIOS XP installation path are preserved. Rebuilding the experiment requires a matching
production base on the selected ESP; the deployment verifies its recorded hashes.

## 2026-09-22: final USB flow (silent PAE, no boot menu, hardening)

Physical result before this change: clean SP3 PL install on Intel/Ryzen 5700X,
PAE entry booted, 31.9 GB RAM visible. Changes in the flow source:

- `pae.exe` (v2) is a GUI-subsystem binary (no console). `/silent` (also `/quiet`)
  suppresses the message box; GuiRunOnce runs `pae.exe /silent`. The log
  `USOS\XP\pae-install.log` is still written.
- boot.ini: the PAE entry stays first in `[operating systems]` with the original
  ARC path, so NTLDR takes it as `default=`; `timeout=0` means no menu is shown.
  Original entry: press F8 at boot -> "Return to OS Choices Menu"; original
  boot.ini is kept in `C:\USOS\XP\boot-original.ini`.
- `HIVESYS.INF` in every driver bundle: `CrashDumpEnabled=0` (was 3). The 0x50
  bugcheck in `dump_ntoskrn8` and the forced power-off that followed produced the
  zero-filled WinSxS files (see `artifacts/xp-pae/winsxs-repair-20260922-202458`).
  AutoReboot stays 0 (source default), so a real STOP stays on screen.
- Linux preparer: after the final unmount `blockdev --flushbufs`, then
  `xp_verify_target.sh` drops caches, remounts the target read-only, compares
  pae.exe and refuses the target if any non-empty file reads back as all zeros;
  it unmounts and flushes again. Host-side equivalent for an attached XP disk:
  `tools/check_xp_zero_files.ps1 -DriveLetter M` (read-only).
- No diagnostics in the flow: `/NUMPROC`, `/SOS`, `/BOOTLOG`, `d.cmd` and CmdLine
  edits were only ever applied to the Intel test disk; `check_xp_pae.py` now
  asserts they are absent from the shipped scripts.

Build: `python tools/build_xp_uefi_csm_trial.py --refresh-pae-flow` (after any
`--add-source` bundle rebuild). Checks: `check_xp_pae.py`,
`check_xp_driver_integration.py [--added-source]`, `check_xp_driver_imports.py`,
`check_xp_menu_overlay.py`. Deploy to the Kingston ESP (only
`EFI/USOS-XP/initramfs-xp` and `manifest.json`):
`tools/deploy_xp_uefi_csm_trial.ps1 -DriversOnly`.

## 2026-09-22 (later): PAE at setup end, first-logon fallback; console flashes

Clean install from the pendrive worked end-to-end. Two follow-ups:

**PAE without the extra restart.** `pae.exe` v3 now runs at the END of GUI setup
via `[SetupParams] UserExecute="C:\USOS\XP\pae.exe"` (SYSTEM context; the flow
always installs XP to C:). No argument = silent setup-end mode. system32 is
complete at that point; the helper writes only its own `usospae.exe`/`usoshal.dll`
(no Setup/WFP file names) and clears then restores boot.ini's R/H/S attributes
around an atomic replace. The reboot that ends setup therefore boots PAE.
Fallback: GuiRunOnce runs `pae.exe /firstlogon`. If the entry is present it logs
and exits with no UI. Only if it is missing does it apply PAE (re-using the
original backup if an earlier run's entry did not survive) and ask, in Polish,
"Pełna pamięć (PAE) zostanie włączona po ponownym uruchomieniu komputera.
Uruchom ponownie teraz?" (Tak = restart now). `/interactive` keeps the manual
English message. `USOS\XP\pae-install.log` is appended to and records
`path=setup-end`, `path=first-logon` and the RESULT of each run.
Not yet verified on hardware: that XP's syssetup honours UserExecute here; if it
does not, the fallback prompt appears once at first logon.

**Console flashes during "Rejestrowanie składników".** The USB flow injects no
program into that phase: no cmdlines.txt, svcpack.inf entries, DetachedProgram,
RunOnce or scripts (checked in the SIF, the driver overlay diff against the
source TXTSETUP/DOSNET/HIVESYS, and the driver INFs: no RunPrograms/co-installers).
Before this change the only hook was GuiRunOnce at first logon, and pae.exe is a
GUI-subsystem binary. The flashes therefore come from stock XP Setup processes
and were not changed; no launcher (usoshide) was needed. To identify them,
read `C:\WINDOWS\setupact.log`/`setupapi.log` from a finished install.
`check_xp_pae.py` now also tests mode parsing, boot.ini staging (PAE first,
timeout=0, originals retained) and entry detection through the DLL harness.

## 2026-09-24: reproducible package build

Until now the deployed package was the proven 2026-09-22 build, patched in
place (`--ui-only`, `--refresh-pae-flow`), because a full rebuild never gave
the same driver bundles. Causes, found by building twice and comparing:

- **Cabinets:** makecab copies each input file's local modification time into
  its CFFILE entry. The 15 USOS driver files are copied into `raw/` (and the
  replacement `acpi.sys` into the SP3 cabinet folder) at build time, so each
  build stamped a new time. The MSZIP data and every other byte were already
  identical; Microsoft's own files keep their source times through 7-Zip.
- **Setup hive:** `RegLoadAppKeyW` stamps the current time into the 29 keys it
  creates or touches, the header's reorganisation time and the first bin, and
  writes the loader's path and a runtime root-parent link. Keys, values and
  cell layout were already identical.
- **drivers/0:** bundle work folders were numbered by list position. The first
  build had only the NiKKA ISO (drivers/0); the Microsoft ISO was added later
  (drivers/<sha>), and a later full build sorted the Microsoft ISO first and
  overwrote drivers/0 with it, so `check_xp_driver_integration.py` compared
  the NiKKA-era folder number with a different bundle.

Fixes: `tools/xp_cab.py` pins every CFFILE date/time (source-cabinet files
keep Microsoft's stamp, files USOS supplies get 2026-09-22 21:21:32);
`tools/xp_hive.py` pins the touched keys' LastWriteTime and restores the
header bookkeeping from the source hive (content verified unchanged); bundle
work folders start empty and are named by the source ISO's SHA-256; the
manifest records `driver_sources` and the checks look bundles up there.
Two consecutive full builds are byte-identical
(`initramfs-xp` d362b73f...eb0a). `tools/compare_xp_packages.py OLD NEW --base`
expands every cabinet, parses every hive and classifies each entry; against
the proven package: 721 entries identical, 20 content-equivalent (CFFILE
times / key times / their hashes only), 13 equal to the current micro-Linux
base (Win7/WIM/VHD/WORK helpers), 0 unexplained. Pinning the proven hives
gives the new hives byte for byte. pae.exe is unchanged (v4, bab558bb...).
Unit test: `tools/tests/test_xp_reproducible.py`.

## 2026-09-24: which XP screens can take a key after the USOS disk choice

Measured in QEMU/SeaBIOS with the package's own preparation chain
(`tools/tests/legacy_bios/run_seabios_xp_uefi_csm_textmode.py`: probe_nt5_source,
driver preflight, target_disk_guard snapshot, the automatic plan,
prepare_xp_target.sh -> prepare_xp_ntfs_target.sh on a blank 12 GiB disk, then
the disk booted alone as BIOS 0x80 with no USOS media and no ISO; frames every
1.5 s plus VGA text dumps). Sequence after the restart:

1. NTDETECT ("Instalator sprawdza konfigurację sprzętową komputera...").
2. SETUPLDR, blue "Instalator systemu Windows": status line "Naciśnij klawisz F6..."
   (~5 s), then "Naciśnij klawisz F2 ... (ASR)" (~5 s), then "Instalator ładuje pliki".
3. Text-mode Setup: "Badanie konfiguracji dysku...", "Czekaj. Instalator
   sprawdza dyski" (autochk of C:, gauge), "Tworzenie listy plików do
   skopiowania...", "Instalator kopiuje pliki..." (gauge).

No Welcome, EULA, partition-list or format screen appears: WINNT.SIF has
`[Unattended]` (Microsoft: specifying UnattendMode "fully automates text-mode
Setup"), OemSkipEula=Yes, FileSystem=LeaveAlone, Repartition=No, and no
AutoPartition, for which the reference says text-mode Setup installs on the
partition holding `$WIN_NT$.~LS` - the one USOS prepared and formatted.
`AutoPartition=1` would instead pick "the first available partition that has
adequate space" (possibly another disk), and `UnattendMode=FullUnattended`
would change GUI mode (refuses unsigned drivers, stops on missing answers), so
neither is set. During setup NTLDR is SETUPLDR itself: there is no boot.ini
and no boot menu until text mode writes a single-entry boot.ini.

Keys: 88 key presses (D, C, Esc, F3, Enter, L, F8, R) typed throughout the
disk check and 45 s of copying changed nothing (`...-keys` run). The only live
keys are SETUPLDR's in its first ~10 s: F6 (extra storage driver prompt later;
Enter continues), F2 (ASR, asks for a floppy; nothing written yet), F5 (HAL
list), F7 (non-ACPI HAL) and F10 (Recovery Console). SETUPLDR.BIN calls that
prompt unconditionally (disassembly: 0x31cc02 with a 5 s timeout); only the F2
prompt can be disabled (TXTSETUP.SIF `[SetupData] DisableAsr=1`), which is in
the driver bundle and deliberately left unchanged here.

USOS now says so before the power-off step: a done-style progress page
"Windows XP zainstaluje się teraz automatycznie" with the notice "Po ponownym
uruchomieniu instalator Windows XP przebiegnie automatycznie aż do graficznego
kreatora instalacji. Do tego czasu nie naciskaj żadnych klawiszy - dysk został
już wybrany tutaj." and [Enter] Kontynuuj (boot.lx.* keys, 27 locales). The
GUI wizard itself still asks its normal questions (ProvideDefault), so the
notice does not say "until the desktop".

## 2026-09-24: rebuild on the Secure Boot base

The Secure Boot release signs the micro-Linux kernel in place (vmlinuz-virt
155c0f9f...1670, was 77007123...6c54) and changes the base initramfs
(b5e7fecc...e97b, was d853f6ed...a736), so the package was rebuilt in full
(`build_xp_uefi_csm_trial.py --esp <staging ESP with zig-out/micro-linux and the
stick's usos-device.ini> --data L:/`). Two builds are byte-identical
(initramfs-xp 4c5716b8...). `compare_xp_packages.py` against the deployed
package: 755 entries identical (both driver bundles, hives, cabinets, pae.exe and
the PAE scripts byte for byte), 1 base update (`usr/bin/usos-fb-ui` = new base),
0 unexplained. pae.exe (bab558bb...) and the three launchers are unchanged;
vmlinuz.efi is the signed kernel.

`deploy_xp_uefi_csm_trial.ps1` now requires the shim layout on the ESP (see
docs/secure-boot-usos.md) and, in `-DriversOnly`/`-UnifiedMenu`, deploys the
package's `vmlinuz.efi` too when the ESP's XP kernel is not the base kernel
(the package kernel must equal the base, which must equal the ESP's production
kernel). EFI\BOOT\BOOTX64.EFI/grubx64.efi/mmx64.efi are protected in every mode
that does not copy them, and the layout is re-checked after the copy.
## 2026-09-24: rebuild for B260924-121942 (input hints)

The micro-Linux base changed (usos-fb-ui: last-input-wins pad/keyboard hints),
so the package was rebuilt in full (staging ESP from zig-out/micro-linux + the
stick's usos-device.ini, --data L:/). compare_xp_packages.py against the
previous package: 755 identical, 1 base update (usr/bin/usos-fb-ui), 0
unexplained. initramfs-xp 53ac9098...; deployed with -DriversOnly -Language pl
(backup artifacts/xp-pae/deploy-20260924-143516).


## 2026-09-24: rebuild for B260924-132627 (pad glyphs, Secure Boot key)

usos-fb-ui changed again (coloured controller glyphs, D-pad hint), so the
package was rebuilt in full (staging ESP zig-out/xp-staging-20260924-key from
zig-out/micro-linux + the stick's usos-device.ini, --data L:/).
compare_xp_packages.py against the deployed package (initramfs-xp
53ac9098...): 755 identical, 1 base update (usr/bin/usos-fb-ui), 0
unexplained (artifacts/xp-pae/compare-20260924-key.log). New initramfs-xp
3d288525...0fd6, kernel unchanged (155c0f9f...). Deployed with -DriversOnly
-Language pl (backup artifacts/xp-pae/deploy-20260924-154357).

## 2026-09-24: rebuild for B260924-141634 (touch driver release)

usos-fb-ui differs from the deployed base only by the embedded build
information (build ID/epoch/source hash and the resulting string layout; no
UI code change in this release), but the package was rebuilt in full as
usual so the XP menu names the current build (staging ESP
zig-out/xp-staging-20260924-touch from zig-out/micro-linux + the stick's
usos-device.ini, --data L:/). Two builds are byte-identical (initramfs-xp
0e585726...fd48). compare_xp_packages.py against the deployed package
(3d288525...): 755 identical, 1 base update (usr/bin/usos-fb-ui), 0
unexplained (artifacts/xp-pae/compare-20260924-touch.log). Kernel unchanged
(155c0f9f...).
Deployed with -DriversOnly -Language pl after usos-physical-update
(backup artifacts/xp-pae/deploy-20260924-162654).

## 2026-09-24: rebuild for B260924-154458 (driver folders)

The micro-Linux base changed (usos-fb-ui gained `--stage-drivers`, and
extract.sh stages user INF drivers into WORK's $WinPEDriver$; neither is used
by the XP flow), so the package was rebuilt in full (staging ESP
zig-out/xp-staging-20260924-drivers from zig-out/micro-linux + the stick's
usos-device.ini, --data L:/). Two builds are byte-identical (initramfs-xp
58e5131b...140f). compare_xp_packages.py against the deployed package
(0e585726...): 754 identical, 2 base updates (usr/bin/usos-fb-ui,
usr/lib/usos/extract.sh), 0 unexplained
(artifacts/xp-pae/compare-20260924-drivers.log). Kernel unchanged
(155c0f9f...). The XP driver bundles and hives are unchanged; the user
folder Drivers\Windows XP is not used yet (design in docs/drivers.md).
check_xp_driver_imports, check_xp_menu_overlay, check_xp_driver_integration
(default and --added-source) PASS; check_xp_pae PASS once the stick carries
the new base (it compares against J:\EFI\USOS\micro-linux).
Deployed with -DriversOnly -Language pl after usos-physical-update
(backup artifacts/xp-pae/deploy-20260924-175702).

Redeployed the same day for B260924-155947-C34E7F2A (Tools -> Drivers help
panel fix; usos-fb-ui differs only by build info): 755 identical, 1 base
update, 0 unexplained (artifacts/xp-pae/compare-20260924-drivers2.log),
initramfs-xp a4f1e4a3...; backup artifacts/xp-pae/deploy-20260924-180604.

## 2026-09-24: rebuild for B260924-181530-020158EF (batch of leftovers)

The micro-Linux base changed (virtio_pci + its two dependencies, the
Setup-media driver staging in extract.sh with windows_setup_media.sh,
selected_system, install.esd/.swm, the documented dead Win7 WORK path), so
the package was rebuilt in full (staging ESP zig-out/xp-staging-20260924-batch
from zig-out/micro-linux + the stick's usos-device.ini, --data L:/). Two builds
are byte-identical (initramfs-xp 64426a81...945b). compare_xp_packages.py
against the deployed package (a4f1e4a3...): 749 identical, 10 base updates
(usos-fb-ui, the three virtio modules, extract.sh, windows_setup_media.sh,
legacy_windows_request.sh, prepare_windows7_uefi.sh, prepare_work.sh,
windows_bios_startup.cmd), 1 intended change (`usos-init`: the XP package
patches its own copy of the base init, so the base's new virtio_pci modprobe
and SELECTED_SYSTEM lines show up as a diff), 0 unexplained
(artifacts/xp-pae/compare-20260924-batch.log). Kernel unchanged (155c0f9f...).
check_xp_driver_imports, check_xp_menu_overlay, check_xp_driver_integration
(default and --added-source) and check_xp_pae PASS. Deployed with -DriversOnly
-Language pl after usos-physical-update (backup
artifacts/xp-pae/deploy-20260924-202244).

## 2026-09-24: rebuild for B260924-202302-7ED55EB2 (Secure Boot key gate)

usos-fb-ui changed (boot string table: new Secure Boot guidance strings and
the corrected key-removal strings; the XP flow does not show them), so the
package was rebuilt in full (staging ESP zig-out/xp-staging-20260924-sbgate2
from zig-out/micro-linux + the stick's usos-device.ini, --data L:/). Two
builds are byte-identical (initramfs-xp 2beb9c5e...0bef). compare_xp_packages.py
against the deployed package (64426a81...): 759 identical, 1 base update
(usr/bin/usos-fb-ui), 0 intended, 0 unexplained
(artifacts/xp-pae/compare-20260924-sbgate2.log). Kernel unchanged
(155c0f9f...). Previous package kept in
artifacts/xp-pae/package-before-20260924-sbgate. (The intermediate build
B260924-200740, initramfs-xp 18b7160b..., was never deployed.)

## 2026-09-25: rebuild for B260925-084847-A23C795E (native Windows 10/11 release)

The micro-Linux base changed (`usos-init` gained the UEFI architecture gate
before any write, `work_boot_relocate.sh` gained `source-check`), so the
package was rebuilt in full (staging ESP zig-out/xp-staging-20260925-release
from zig-out/micro-linux + the stick's usos-device.ini, --data L:/). Two builds
are byte-identical (initramfs-xp df616bf3...260d). compare_xp_packages.py
against the deployed package (2beb9c5e..., kept in
artifacts/xp-pae/package-before-20260925-release) with `--intended usos-init`:
757 identical (both driver bundles, hives, cabinets and the PAE scripts byte
for byte), 2 base updates (usr/bin/usos-fb-ui, usr/lib/usos/work_boot_relocate.sh),
1 intended (usos-init: the architecture gate block), 0 unexplained
(artifacts/xp-pae/compare-20260925-release.log). pae.exe (bab558bb...), the
three launchers and the kernel (155c0f9f...) are unchanged.
check_xp_driver_imports, check_xp_menu_overlay, check_xp_driver_integration
(default and --added-source) PASS; check_xp_pae PASS against the new base
(zig-out/micro-linux) and, as expected before the deploy, fails against the
stick's older base (J:) only on work_boot_relocate.sh. Not deployed yet.
Tests after the release build: test_modern_finalize PASS, run_stage_drivers_qemu
0 failures, run_qemu_secure_boot.py --only matrix 0 failures (TCG).
