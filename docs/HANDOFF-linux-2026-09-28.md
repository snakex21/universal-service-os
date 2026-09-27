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
