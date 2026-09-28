# Handoff: Linux ISO boot + Linux answer files (2026-09-28, night)

Milestone: Linux live/installer ISOs from `DATA\Systems\Linux\<Distro>\Images`
on UEFI (Secure Boot on/off) and BIOS, plus Linux answer files from the USOS
profile model. Design: [design/linux-iso-boot.md](design/linux-iso-boot.md).

## Done

- Research and the mechanism decision (design doc sections 2-7): hybrid
  "extract kernel+initrd, append USOS cpio, static `/usos/init` maps the ISO
  file's NTFS extents to a loop/dm block device, then the distro boots as from
  a DVD"; Secure Boot through a "distro-shim relay" for non-Fedora kernels.
- Real boot parameters read from the downloaded ISOs (design doc section 4).
- `tools/linux_test_assets.py`: downloads + SHA-256 check against the
  distro-published checksum files, `manifest.json` in the asset folder.
- ROADMAP: "Przed 1.0" checklist (Vista USB flash via USB3 backport, profile
  applicability filter + missing-required-field warning, Vista CSMWrap step
  counter 1/3 vs 1/5, icons XP x64 / Server 2003, quiet CSMWrap, Linux ISO).

## Code on `feature/linux-iso` (WIP, not merged)

- `src/flow/linux_iso/` exported as `usos.flow.linux_iso`, tests run in
  `zig build test` (green): `iso_map.zig` (writer/parser of `/usos/iso.map`),
  `cpio.zig` (newc writer), `grub_cfg.zig` (first-entry parser: `$linux_cmd`,
  `($root)`, several initrds, memtest skipped), `recipe.zig` (family by
  structure, cmdline rules, answer format; tests for Ubuntu server, Mint,
  Debian live, Debian netinst, Fedora 44, SystemRescue, unknown).
- `src/image_probe/iso9660.zig`: Rock Ridge `NM` names matched next to the
  primary names (additive; Windows ISO lookups unchanged).
- `src/platform/linux/iso_init_main.zig`: the static helper `/usos/init`
  (loop or dm over the extents, `/dev/usos-iso`, init-bottom hook for Ubuntu
  answers). Compiles (21 KB) with
  `zig build-exe -target x86_64-linux-none -O ReleaseSmall -fstrip --dep iso_map -Mroot=src/platform/linux/iso_init_main.zig -Miso_map=src/flow/linux_iso/iso_map.zig`;
  since then run in QEMU (below); BLKPG partition fallback added for d-i.
  Build: `zig build linux-iso-helper` (also part of `install`, so build.bat
  makes it) -> `zig-out/usb|manual-usb/EFI/USOS/linux/usos-linux.cpio`
  (22 360 bytes, deterministic); `verify_release_consistency.ps1` requires it.
- `assets/linux-iso/init-bottom`, `tools/build_linux_iso_helper.py` (cpio
  packer, deterministic).
- `tools/tests/linux_iso/new_linux_test_disk.ps1` (sparse fixed VHD, ESP +
  NTFS DATA with all test ISOs, `<vhd>.extents.json` from
  `fsutil file queryextents`), `run_linux_iso_direct.py` (QEMU
  `-kernel/-initrd` + helper, USB disk, BIOS or `--uefi`, screenshots in
  `tools/tests/artifacts/linux-iso/<name>/`), `iso9660_rr.py`.

- UEFI: `src/platform/uefi/linux_iso_start.zig` (open ISO on DATA, NTFS runs
  -> `/usos/iso.map`, `recipe.plan`, kernel + initrds + ESP helper cpio +
  per-boot cpio, initrd via `LINUX_EFI_INITRD_MEDIA_GUID` LoadFile2,
  `LoadOptions`, start through `verified_image.loadBuffer`), dispatched from
  `manual_summary.start` for `backend == .linux_iso`. Compiles; **never run**.
  Secure Boot relay not written (a non-Fedora kernel under SB ends in
  "Secure Boot rejected"). No answer rendering yet (`answer` is null).
- Routing: backend `linux_iso` (firmware any, badge experimental), profile
  `linux-iso-uefi` (UEFI only, all Linux ids, `automatic`/`direct_iso`,
  progress `linux_iso`); new systems `systemrescue` (Secure Boot off trait),
  `gparted-live`, `clonezilla`. Golden regenerated: removed/changed rows are
  only the 9 existing Linux systems' UEFI `iso` rows (route/menu/profile, 45
  rows); everything else is additions. BIOS still routes Linux as before
  (`linux_live_iso` SliTaz for other-linux, chainload otherwise); the Core has
  no generic Linux path yet.

## First QEMU result (direct kernel boot, no menu)

`python tools/tests/linux_iso/run_linux_iso_direct.py gparted` (SeaBIOS,
WHPX, test VHD as USB disk on xHCI, `snapshot=on`): **helper PASS**.
Serial: `usos-init: iso: 720371712 bytes in 1 extent(s)`, `iso found on
/dev/sda`, `iso attached: /dev/usos-iso -> /dev/loop0`; live-boot then took
`live-media=/dev/usos-iso`, mounted the squashfs and systemd started from the
live root (screenshot `tools/tests/artifacts/linux-iso/gparted/bios-04.png`).
Ubuntu Server 24.04.5 (`run_linux_iso_direct.py ubuntu-server`): **PASS to the
installer** — casper took `live-media=/dev/usos-iso`, the subiquity snap
mounted and the language screen came up (`.../ubuntu-server/bios-05.png`;
the kernel line over it is the test's `ignore_loglevel`).
Fedora Workstation Live 44 (`... fedora`): **PASS to the live desktop**
("Welcome to Fedora Linux", `.../fedora/bios-06.png`): dracut found
`root=live:CDLABEL=Fedora-WS-Live-44` on the loop device through udev with
no extra words, gdm started.
Debian 13 netinst (`... debian13-netinst`): the d-i initrd has neither
`loop.ko` nor `dm-mod` (Debian's kernel has loop as a module), so the loop
path failed first. **Fixed** with the BLKPG fallback in `/usos/init`: the
DATA partition is removed from the kernel's table only (no disk write) and
partition 64 is added over the contiguous ISO: `iso attached: /dev/usos-iso
-> /dev/sda64`, and the **graphical installer's first screen** came up
(`.../debian13-netinst/bios-04.png`). Not yet verified: d-i's CD detection
(after language/keyboard) finding `sda64`; the runner now adds a per-boot
`/preseed.cfg` with `cdrom-detect/try-usb=true`. One keyboard-driven try
(`--keys "70:ret,8:ret,8:ret,40:ret"`) ended on the text console: the first
Enter probably arrived before the GTK frontend (it came up at ~120 s in the
first run). Next: first key after >= 130 s, or test with the text installer
initrd (`install.amd/initrd.gz`), which is easier to drive. Fragmented
ISOs cannot use this path (no dm in d-i): refuse with "copy the ISO again".
GParted's own keymap/language prompt (console) was not answered, so the
GParted UI itself is not shown yet. All ten ISOs on the test VHD are one
extent each (fresh NTFS), so the dm path is not exercised yet (make a
fragmented copy on purpose to test it).

## Menu test (UEFI, OVMF, Secure Boot off): ALL PASS (2026-09-28 morning)

`update_linux_test_esp.ps1` + `run_linux_iso_menu.py` (Home, Linux, system,
ISO, Automatic (Linux ISO), summary "Start Linux", start), OVMF, test VHD as
USB disk, WHPX. Serial: `[LINUX-ISO] family=... extents=1`, then:

| ISO | family | result (screenshot in `tools/tests/artifacts/linux-iso/menu/<name>/`) |
|---|---|---|
| Ubuntu Server 24.04.5 | casper | subiquity language screen |
| Ubuntu Desktop 24.04.5.1 | casper | "Welcome to Ubuntu" installer on the live desktop |
| Linux Mint 22.3 Xfce | casper | live desktop |
| Fedora WS Live 44 | dracut_live | live desktop, "Welcome to Fedora Linux" |
| Debian live 13.7 standard | live_boot | auto-login shell of the live system |
| Debian 13.7 netinst | debian_installer | language, country, keyboard, then media detection and component load from the ISO (BLKPG partition + default `/preseed.cfg` try-usb), up to the hostname page |
| Debian 12.15 netinst | debian_installer | installer language screen |
| SystemRescue 13.02 | archiso (3 initrds) | root shell of the live system |
| GParted Live 1.8.1 | live_boot | console-data keymap dialog (live system running) |
| Clonezilla 3.3.3 | live_boot | Clonezilla language dialog |

Fixes made for this: summary button "Start Linux" (was "Load the Windows
ISO"), specific error details (fragmented ISO, no Linux entry, helper
missing), Linux strings in all 27 locales, default d-i preseed.

## Menu test with Secure Boot ON (Fedora SMM OVMF, MS keys, MokList = USOS cert, TCG)

`run_linux_iso_menu.py --secure-boot --tcg` (WHPX cannot run the SMM OVMF).

| ISO | chain | result |
|---|---|---|
| Fedora WS Live 44 | USOS shim (Fedora CA) verifies the kernel directly | live desktop |
| Ubuntu Server 24.04.5 | relay: Ubuntu shim 15.8 -> USOS (MOK) -> Canonical kernel via its SHIM_LOCK | subiquity language screen |
| Ubuntu Desktop 24.04.5.1 | relay | live desktop; the desktop installer then showed "Something went wrong" under TCG (not seen with WHPX and SB off; TCG is very slow, a TCG SB-off control run did not reach GNOME in time): check on hardware |
| Linux Mint 22.3 | relay (Ubuntu shim) | live desktop |
| Debian live 13.7 | relay (Debian shim 16.1) | live shell |
| Debian 13.7 netinst | relay | installer language screen |
| Debian 12.15 netinst | relay (Debian shim 15.8) | installer language screen |
| GParted Live 1.8.1 | relay (Debian shim) | console-data dialog |
| Clonezilla 3.3.3 | relay (Debian shim) | language dialog |
| SystemRescue 13.02 | no signed shim | blocked in the list: "Requires Secure Boot off" (the explanation text is the generic Windows one: follow-up) |

Two bugs found and fixed on the way: a 64 KiB grub.cfg buffer on the stack
overflowed under shim (now caller-provided), and the relay instance runs on
top of the first instance's live stack, so it now switches to its own 1 MiB
stack (`callOnStack`). The relay plan is `EFI/USOS/linux/relay.ini`
(one-shot, deleted when read, only `\Systems\Linux\...` paths accepted).

## Menu test in Legacy BIOS (SeaBIOS, WHPX): ALL PASS

`run_linux_iso_menu.py --bios` (PS/2 keyboard; the Core swallows the first
Enter on a freshly opened list, so scripts send one extra Enter). The Core
path (`src/platform/bios/linux_iso_boot.zig`) loads the kernel via the 32-bit
boot protocol with the same recipe; Core headroom is now 4 424 bytes (was
17 012; minimum 4 096). Found and fixed: a plain int13 `reader` call after
bulk NTFS reads never returned, so the ESP helper is read first.

Results: Ubuntu Server (subiquity), Ubuntu Desktop (installer on the live
desktop), Mint (live desktop), Fedora 44 (live desktop), Debian live (shell),
Debian 13 netinst (to the hostname page, media found), Debian 12 netinst
(language screen), SystemRescue (root shell), GParted (console-data dialog),
Clonezilla (language dialog).

## Answer renderers (done by a sub-agent, not wired in yet)

`src/flow/answer/sha512crypt.zig`, `src/flow/answer/linux.zig`
(`render(profile, .autoinstall|.preseed|.kickstart, salt, buffer)`), goldens in
`src/flow/answer/testdata/golden/linux/`, `usos-answer render-linux`, docs in
`docs/answer-profiles.md`. Next: answer screen offers profiles for
Ubuntu/Debian/Fedora, `linux_iso_start` renders (salt from EFI_RNG / TSC) into
the per-boot cpio; the relay path must carry it too (write it next to
relay.ini or re-render in the relay instance).

## State at the end of 2026-09-28 (daytime session)

- Merged into master; final build **B260928-122908-E1145505** (build.bat green:
  Zig + Go tests, signing, release consistency); release payload committed.
- Kingston updated to that build (updater RESULT=PASS, profiles/themes kept,
  flushed); DATA now holds Mint 22.3, Fedora WS 44, Debian 13.7 netinst,
  GParted 1.8.1, SystemRescue 13.02, Clonezilla 3.3.3 (SHA-256 read back,
  1 extent each); 2.02 GiB free. ESP backups in
  `artifacts/stick-backup-20260928-*`.
- Answer profiles wired in (UEFI answer screen for Ubuntu/Debian/Fedora) and
  verified in QEMU per format (design doc section 11).

## Exact next steps

1. X470 hardware test (list in the final report / design doc section 11).
2. Ubuntu Desktop under Secure Boot: the installer error seen under TCG.
3. Follow-ups in ROADMAP "Przed 1.0" (texts for SystemRescue/SB and the
   "+ Add profile" hint, subiquity default disk, Core headroom, two stale
   Python tests).
4. Non-Linux unknown ISOs (WinPE/EFI-only) are still not covered.

## Not done (next, in this order)

Design doc section 9: finish step 3 (remaining distros BIOS + `--uefi`,
d-i CD detection, a fragmented ISO for the dm path) (`run_linux_iso_direct.py gparted`, then each distro, BIOS and
`--uefi`), then 4-8. No catalog/routing change, no strings, no build.bat, no
stick deploy yet (the stick was NOT touched this session).

Branch plan: WIP code on `feature/linux-iso`, merged into master only when
build.bat and all suites are green.

## Test assets

Folder: `%LOCALAPPDATA%\USOS\test-assets\linux\` (outside the repo, never
commit ISOs). Re-run `python tools/linux_test_assets.py` to fetch what is
missing (it resumes `.part` files and re-verifies).

Verified (SHA-256 equal to the distro-published value) at 01:04-01:10:

| name | file | SHA-256 |
|---|---|---|
| debian13-netinst | debian-13.7.0-amd64-netinst.iso | a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355 |
| debian12-netinst | debian-12.15.0-amd64-netinst.iso | cd4462c06aa8892e692c0c4b9c17802f38c8ab8690e85cbfb5ccaa5956e9af17 |
| debian13-live | debian-live-13.7.0-amd64-standard.iso | 040a44f35186321eb6cdaab52a8a2d06224fe6b77f6fbb9f1861ad89c14e17ec |
| ubuntu-server | ubuntu-24.04.5-live-server-amd64.iso | 97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8 |
| mint | linuxmint-22.3-xfce-64bit.iso | 45a835b5dddaf40e84d776549e0b19b3fbd49673b6cc6434ebddbfcd217df776 |
| gparted | gparted-live-1.8.1-6-amd64.iso | d789c38779f0d6f7026c12f44c2c52a04f66e28a1aea7d51f3045ad1bbf28411 |
| systemrescue | systemrescue-13.02-amd64.iso | ad4d670b72859d887c7960142a9a9d36a3e50446694a035e254442f65d6e7572 |
| clonezilla | clonezilla-live-3.3.3-37-amd64.iso | 3079458d926a37d3533e5d5caeb61b6e49c2dc69e2c97e0332ef37986bb3414f |
| ubuntu-desktop | ubuntu-24.04.5.1-desktop-amd64.iso | 4da4a0c9035da8e68a59a838674f403f0a54472c78a83b4fb7f78d03588f85a7 |
| fedora | Fedora-Workstation-Live-44-1.7.x86_64.iso | 1620295f6a00c27c3208f0c00b8ece4eab1ec69b9002152d97488bf26a426ddf |

All ten downloads finished and verified (01:04-01:20). `manifest.json`
in the folder has URL, checksum URL, size and time per file.

URLs: `python tools/linux_test_assets.py --list`.

## Facts found (for the implementation)

- Linux ISOs need **Rock Ridge** names: Debian live's kernel is
  `/live/vmlinuz-6.12.107+deb13-amd64`; `image_probe/iso9660.zig` reads
  primary names only today.
- GParted/Clonezilla grub.cfg uses `$linux_cmd`/`$initrd_cmd`; SystemRescue
  uses `$archiso_param` (label `RESCUE1302`) and 3 initrds (2 microcode);
  Debian live's menu is in `/boot/grub/config.cfg` via `source`.
- Mint 22.3 has `/EFI/BOOT/bootia32.efi` too; kernel args include `uuid=`
  (casper UUID check; keep it).
- All secure-boot-capable ISOs have a Microsoft-signed `bootx64.efi` shim +
  `grubx64.efi`; SystemRescue has only an unsigned `bootx64.efi`.
- `Mount-DiskImage` on the ISOs in the asset folder failed ("path not found");
  a scratch Python ISO9660+Rock Ridge reader was used instead (fold into
  `tools/` when the tests need it).

## Open questions (verify first when implementing)

1. Secure Boot relay: Ubuntu shim 15.8 started by USOS under Fedora shim 16
   -> USOS as its second stage -> `SHIM_LOCK->Verify` of the Ubuntu kernel +
   own PE loader. QEMU (OVMF + MS keys + MokList) before anything else in the
   SB path.
2. Debian netinst: can `cdrom-detect` be pointed at `/dev/usos-iso` by preseed?
3. Ubuntu Desktop 24.04 installer: does it read `/autoinstall.yaml` like
   subiquity (server)?
4. BIOS Core size: does the shared recipe module fit into ~19.7 KiB?

## Rules to keep

- Routing golden: only the Linux `iso`+`automatic`/`direct_iso` rows change
  (intended), new systems add rows; all other rows byte-identical.
- Disk selection always manual in every answer format.
- Passwords only as SHA-512 crypt, never logged; nothing on DATA.
- No distro ISOs in the repo; third-party code vendored with licence + hash.

## Hardware round 1 fixes (afternoon 2026-09-28)

Build **B260928-134508-50881FDB** on master (build.bat green; Python suites:
only the known stale test_windows7_pe10_selection / test_windows_setup_media
and test_windows_native_iso_io, which needs a raw image argument). NOT on the
Kingston yet: the stick was not attached when the deploy started. Deploy
with the usual updater (backup, then `usos-physical-update`, readback,
flush); the six Linux ISOs on DATA stay. Fixes: BIOS stack top below the
EBDA (garbled long names on the Socket 939 PC, to confirm there), silent
SHIM_LOCK pre-check before the relay (no "Verification failed", QEMU
verified), Secure Boot notices close on any key, Linux wording in 27 locales.
Open: the SystemRescue firmware screen and 30 s wait on the X470 (USOS
does not load anything there in QEMU; need a photo).
