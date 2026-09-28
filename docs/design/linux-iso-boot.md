# Linux ISO boot from DATA (design, 2026-09-28)

Goal: a user drops an official Linux ISO into
`DATA\Systems\Linux\<Distro>\Images\` (or a rescue ISO into the new rescue
entries) and USOS boots its live desktop or installer on UEFI (Secure Boot on
and off) and on Legacy BIOS. No extraction to WORK, no copy of the ISO, no
change to the ISO. Optional: a USOS answer profile rendered as the distro's
answer file (autoinstall / preseed / kickstart), disk selection always manual.

Status (2026-09-28, build B260928-114652 + answer wiring): **implemented and
QEMU-verified** for ten ISOs through the real menu on UEFI with Secure Boot
off and on, and in Legacy BIOS; Linux answer profiles verified in QEMU for
Ubuntu (autoinstall), Debian (preseed) and Fedora netinst (kickstart). Not yet
on hardware. Results and test commands: section 11 and
`docs/HANDOFF-linux-2026-09-28.md`.

## 1. The problem

Booting the distro kernel is the easy half. The hard half is the **second
stage**: after the kernel starts, the distro's initramfs has to find its live
root (squashfs) or installer packages *on the medium*. On a real DVD/USB the
medium is a block device with an ISO9660 file system. With USOS the medium is
a file inside an **NTFS** partition (DATA), and:

- the distro initramfs usually cannot mount NTFS (`ntfs3` is a module that is
  not in most live initrds; we cannot add a module from outside: it must match
  the exact kernel build and, under Secure Boot, carry the distro's module
  signature);
- the ISO-locating parameters that exist (`iso-scan/filename=` for casper,
  `findiso=` for live-boot, `iso-scan/filename` / `rd.live.image` for dracut,
  `img_dev=`/`img_loop=` for archiso) all need to *mount the partition that
  holds the ISO file*, i.e. NTFS support;
- Secure Boot: the distro kernel is signed by the distro (Canonical, Debian,
  Fedora), not by Microsoft and not by USOS. USOS's shim is Fedora's shim 16.1,
  so only Fedora kernels verify under the USOS shim.

## 2. Options considered

| | Mechanism | Verdict |
|---|---|---|
| a | Distro-aware: extract kernel+initrd from the ISO, boot them with the distro's ISO-locating cmdline (`iso-scan/filename=`, `findiso=`, ...) | Fails on NTFS for most distros (see 1). Only works where the initrd has `ntfs3` built in or loaded. |
| b | RAM disk: whole ISO in memory, `EFI_RAM_DISK_PROTOCOL` (NFIT/pmem visible to Linux) on UEFI, memdisk on BIOS | Ubuntu desktop is 6+ GB: needs RAM larger than the ISO, slow load over USB, and the initrd must have `nfit`+`nd_pmem` (not in casper/live-boot initrds); memdisk (int13 only) is invisible to Linux. Firmware RamDisk support varies (AMI). Rejected as the main path. |
| c | **Hybrid (chosen)**: USOS extracts kernel+initrd from the ISO itself, **appends a small USOS cpio** to the distro initrd, and a static USOS helper, run first as `rdinit`, turns the ISO file into a **block device** (loop with offset, or device-mapper linear over the file's NTFS extents) *before* the distro's own init starts. The distro then finds an ordinary ISO9660 device and boots exactly as from a DVD. | Chosen. |

Why (c):

- **No NTFS needed in the distro.** USOS already has its own NTFS reader
  (UEFI menu and BIOS Core). It resolves the ISO's data runs to absolute disk
  sectors at boot time and hands them to the helper. The helper only needs raw
  read access to the USB disk (which every live initrd has: it boots from USB)
  plus `loop` (every live initrd has it: it mounts squashfs through loop) or
  `dm-mod` (fragmented ISOs only).
- **One mechanism for all distros**, both firmwares and unknown ISOs. The only
  per-distro knowledge is which kernel/initrd to take and one or two cmdline
  words telling the distro which device is the medium.
- **RAM use is only the initrd** (80-200 MB), not the ISO.
- **The initrd is never verified** by shim/kernel (same as every
  shim+GRUB distro and as USOS's own micro-Linux today), so appending a cpio
  does not interfere with Secure Boot. The *kernel* is verified (section 5).
- Proven idea: Ventoy maps ISOs the same way (device-mapper over the file's
  sectors); USOS does it without patching shim/GRUB and without a USOS GRUB.

## 3. Boot flow

```
USOS menu (UEFI) / Core (BIOS)
  1. open DATA (NTFS), open <ISO> (runs must be non-sparse, non-compressed)
  2. read ISO9660 (+ Rock Ridge names) -> detect family, pick kernel/initrd,
     build cmdline (section 4)
  3. extents: NTFS runs -> absolute 512-byte LBAs on the disk; CRC32 of the
     ISO's primary volume descriptor (bytes 32768..34815)
  4. initrd = distro initrd(s) [pad 4] + \EFI\USOS\linux\usos-linux.cpio [pad 4]
              + generated cpio (/usos/iso.map, answer files)
  5. start kernel: cmdline = distro words + rdinit=/usos/init (+ answer words)
Linux
  6. /usos/init (static, x86_64, no libc): mount /proc /sys /dev, modprobe
     storage + loop + dm_mod, wait (30 s) for a whole disk whose sector at
     extent[0]+32768 has the expected CRC32, then
       1 extent  -> loop (LOOP_SET_FD + LOOP_SET_STATUS64 offset/sizelimit, RO)
       n extents -> dm "usos-iso" with n linear targets, read-only
     symlink /dev/usos-iso -> loopN / dm-N; install answer hooks; umount what
     it mounted; execve("/init") (PID 1 kept)
  7. the distro's own init finds the medium (by label or live-media=) and
     boots as from a DVD
```

`/usos/iso.map` (text, generated per boot, no secrets):

```
usos-iso-map 1
size <iso bytes>
crc <crc32 of ISO bytes 32768..34815, 8 hex digits>
extent <first disk LBA (512)> <sector count>
...
```

Extents in a generated file rather than on the cmdline: x86 cmdline is 2048
bytes and Clonezilla alone uses ~500. If the file has more than 64 extents (or
an attribute list / sparse / compressed runs) USOS refuses with a
"defragment / copy the ISO again" message (a fresh copy onto the installer's
freshly formatted DATA is contiguous in practice).

cpio rules: newc, uncompressed, each archive padded to 4 bytes
(`tools/tests/test_initrd_alignment.py`: the `lang.cpio` lesson). **Never put a
directory entry for `lib`, `bin`, `sbin`, `lib64`** in the USOS cpio: the
kernel's unpacker replaces an existing entry of another type, and on merged-usr
initrds those are symlinks. Everything USOS adds lives under `/usos/`, except
Debian's `/preseed.cfg` (a file at the root).

## 4. Per-distro recipes

Detection is by **structure**, not by file name (ARCHITECTURE.md rule). The
cmdline starts from the ISO's own first `menuentry` in `/boot/grub/grub.cfg`
(`linux`/`linuxefi`/`$linux_cmd` and `initrd` lines; up to 4 initrds; also `/boot/grub2/grub.cfg`, `($root)` prefixes stripped), with
unresolvable `${...}` words dropped, then the family rule is applied. If the
grub.cfg cannot be parsed, the fixed fallback in the table is used.

| Family (detected by) | Distros | kernel / initrd | Medium hint added | Removed | Checked on ISO |
|---|---|---|---|---|---|
| casper (`/casper/vmlinuz`, `/.disk/casper-uuid-*`) | Ubuntu 24.04 desktop/server, Mint 22.x | `/casper/vmlinuz`, `/casper/initrd` (Mint: `initrd.lz`) | `live-media=/dev/usos-iso` | `iso-scan/filename=*` | server 24.04.5: `linux /casper/vmlinuz ---`; Mint 22.3: `boot=casper uuid=... username=mint hostname=mint iso-scan/filename=${iso_path} quiet splash --` |
| live-boot (`/live/vmlinuz*`, `/live/*.squashfs`) | Debian live 12/13, GParted Live, Clonezilla | `/live/vmlinuz[-ver]`, `/live/initrd.img[-ver]` | `live-media=/dev/usos-iso` | `findiso=*` | Debian live 13.7: `boot=live components quiet splash findiso=${iso_path}` (menu in `/boot/grub/config.cfg` via `source`); GParted/Clonezilla: `$linux_cmd /live/vmlinuz boot=live union=overlay ...` |
| debian-installer (`/install.amd/vmlinuz`) | Debian 12/13 netinst | `/install.amd/vmlinuz`, `/install.amd/gtk/initrd.gz` (graphical) | `cdrom-detect/...` preseed (below), to verify | - | 13.7: `linux /install.amd/vmlinuz vga=788 --- quiet` |
| dracut live (`/LiveOS/` + `root=live:` in grub.cfg) | Fedora Workstation Live 40+ | 44 (kiwi): `/boot/x86_64/loader/linux`, `/boot/x86_64/loader/initrd`; 40-41: `/images/pxeboot/vmlinuz`, `initrd.img` | none: `root=live:CDLABEL=<PVD label>` already finds the loop device through udev's by-label link | `($root)` path prefix | 44-1.7: grub.cfg in `/boot/grub2/grub.cfg`, `linux ($root)/boot/x86_64/loader/linux quiet rhgb root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image`; ISO also carries `fbx64.efi` |
| anaconda (`/images/install.img`) | Fedora Everything/Server netinst | same | `inst.stage2=hd:LABEL=<label>` stays | - | not downloaded yet |
| archiso (`/<base>/boot/x86_64/vmlinuz`, `archisobasedir=`) | SystemRescue 13 | `/sysresccd/boot/x86_64/vmlinuz`; initrds `intel_ucode.img amd_ucode.img x86_64/sysresccd.img` | `archisolabel=<PVD label>` (grub.cfg has `$archiso_param`) | `$archiso_param` | 13.02: label `RESCUE1302` |
| slitaz (`/boot/rootfs1.gz`) | SliTaz (existing BIOS path) | unchanged `linux_live_iso` | - | - | - |
| unknown | anything else with a grub.cfg `linux` entry | from grub.cfg | `live-media=/dev/usos-iso` (harmless elsewhere) | `${...}` words | labelled **unverified** |

Why `live-media=` and not a label for casper/live-boot: both skip `loop*`
devices in their automatic scan (`grep -vE "/(loop|ram|fd)"`, live-boot also
`dm-`), but both honour `live-media=<device>` first. Label-based distros
(dracut, archiso) find the loop device through udev
(`60-persistent-storage.rules` handles `loop*` with a backing file, `dm-*`
through the dm rules) so nothing is added.

**Found 2026-09-28:** the d-i initrd has no `loop.ko` and no `dm-mod`, so
neither loop nor dm is possible there; the plan below is replaced by an
in-kernel partition (`BLKPG_ADD_PARTITION` over the contiguous ISO after
`BLKPG_DEL_PARTITION` of DATA in the kernel's table only, no disk write) plus
`cdrom-detect/try-usb=true` (see the handoff).

Debian netinst (d-i) is the open risk: `cdrom-detect` only probes `cd` and
`maybe-usb-floppy` devices. Plan: preseed in the generated `/preseed.cfg`
(`cdrom-detect/manual_config=true`, `cdrom-detect/cdrom_module=none`,
`cdrom-detect/cdrom_device=/dev/usos-iso`), verify in QEMU; fallback: the
helper also bind-creates `/dev/sr99`-style nodes is **not** possible (udev
decides `ID_CDROM`), so if the preseed route fails, d-i gets the ISO via
its `iso-scan` udeb (needs NTFS) = not supported, documented.

## 5. Secure Boot chain

USOS's shim is Fedora `shim-x64-16.1-7` (vendor cert: Fedora CA). Under
Secure Boot shim 16 hooks `gBS->LoadImage/StartImage` and accepts images
signed by db (Microsoft), MOK (USOS key) or the Fedora CA.

- **Secure Boot off**: the menu `LoadImage`s the kernel from a buffer, sets
  `LoadOptions` = cmdline and publishes the initrd through the Linux
  `LINUX_EFI_INITRD_MEDIA_GUID` + `EFI_LOAD_FILE2_PROTOCOL` device path
  (kernel >= 5.8; all targets are 6.x). `StartImage`.
- **Secure Boot on, kernel trusted by the running shim** (Fedora): the same.
- **Secure Boot on, other distros** ("distro-shim relay"): the ISO's own
  `\EFI\BOOT\BOOTX64.EFI` is that distro's **Microsoft-signed shim** (Ubuntu
  15.8, Debian 15.8/16.1; GParted/Clonezilla ship Debian's). USOS
  `LoadImage`s it from a buffer with the device path
  `<USOS ESP>\EFI\BOOT\USOSRELAY.EFI` (a name that does not trigger shim's
  fallback). That shim installs *its* `SHIM_LOCK` (vendor cert = the distro's
  CA) and starts its second stage `grubx64.efi` from the same directory, which
  on the USOS ESP is **USOS itself** (MOK-signed, has `.sbat`: accepted by any
  shim through MokList). USOS finds a one-shot relay plan
  (`\EFI\USOS\linux\relay.ini`, deleted when read) before any UI, verifies the
  distro kernel with each installed `SHIM_LOCK->Verify` until one accepts it,
  loads it with USOS's own PE loader (`image_probe/pe_loader.zig`, as for the
  NTFS driver: shim 16's hooked `LoadImage` would refuse a non-Fedora kernel),
  installs the initrd LoadFile2 and jumps to the kernel entry. Kernel lockdown
  is then enforced by the distro kernel itself (correct behaviour).
  Nothing is patched; every executed image is verified by a shim.
- SystemRescue has no Secure Boot support (unsigned `bootx64.efi`): the menu
  says "Secure Boot must be off" (policy table), as for XP/7.
- SBAT: a kernel without `.sbat` is fine through `SHIM_LOCK->Verify` (shim
  only demands SBAT for images *it* loads as second stage); USOS's
  `grubx64.efi` has `.sbat` (`usos,1`).
- Distro shims write `SbatLevel` like ours; no new side effect.

Open question to verify first in QEMU (OVMF + MS keys + MokList seeded):
does Ubuntu shim 15.8 uninstall Fedora shim's `SHIM_LOCK` (it tries,
"chaining from another shim") and does USOS started as its second stage keep
working under the nested `StartImage` hooks. Fallback if the relay fails: the
menu explains "Secure Boot: this distribution's kernel is not trusted by the
USOS shim; turn Secure Boot off" (honest, no bypass).

## 6. Legacy BIOS

The Core already loads a bzImage + initramfs from an ISO on NTFS
(`src/platform/bios/linux_live_iso.zig`, SliTaz, 32-bit entry). Extend it:
x86_64 kernels via the 32-bit boot protocol entry (`code32_start`), initrds
placed high (below `initrd_addr_max`), cmdline from the shared recipe module,
`usos-linux.cpio` read from the ESP (FAT32 reader exists), `/usos/iso.map`
generated by a tiny newc writer. Core size budget: ~19.7 KiB spare; the shared
recipe code must be compiled with the Core's size checks
(`test_production_core_guard.ps1`). If it does not fit: BIOS hands over to the
micro-Linux (which has ntfs3, loop and kexec) with the same recipe module
compiled into `usos-fb-ui`, then `kexec`.

The existing `other-linux` BIOS route (`linux_live_iso`, SliTaz) stays: SliTaz
is recognized by structure first.

## 7. Answer files (profile model -> distro formats)

Same `usos-profile` INI (`src/flow/answer/profile.zig`); new renderers in
`src/flow/answer/linux/` with goldens. Rendered just in time by the UEFI menu,
delivered in the generated cpio; never written to DATA, never logged.

| Profile field | Ubuntu autoinstall (casper/subiquity) | Debian preseed (d-i) | Fedora kickstart (anaconda) |
|---|---|---|---|
| user / user2 | `identity.username` / `realname` (user2: `user-data.users`) | `passwd/username`, `passwd/user-fullname` | `user --name= --gecos= --groups=wheel` |
| password | SHA-512 crypt (`$6$`, random 16-char salt from the firmware RNG/TSC) in `identity.password` | `passwd/user-password-crypted` | `user ... --iscrypted --password=` ; `rootpw --lock` |
| empty password (user prefers none) | installer requires one: `identity` goes to `interactive-sections` (prefilled user/hostname, the user types it). Honest note in the summary. | not preseeded: d-i asks (it refuses empty user passwords) | `user` without password is created locked; USOS omits `--password` and says so; alternative: leave the user spoke interactive |
| computer | `identity.hostname` | `netcfg/get_hostname` + `netcfg/hostname` | `network --hostname=` |
| timezone | `timezone:` | `time/zone` | `timezone <IANA> --utc` |
| language / locale | `locale: ll_CC.UTF-8` | `debian-installer/locale` | `lang ll_CC.UTF-8` |
| keyboard | `keyboard.layout` (xkb) | `keyboard-configuration/xkb-keymap` | `keyboard --xlayouts=` |
| disk | `interactive-sections: [storage]` (always) | no `partman*` keys (always asked) | no `ignoredisk/clearpart/autopart/part` (Installation Destination stays) |

Injection:

- Ubuntu: `/usos/answer/autoinstall.yaml` in the generated cpio; `/usos/init`
  appends `/usos/hooks/init-bottom` to `/scripts/init-bottom/ORDER`
  (initramfs-tools), which copies it to `${rootmnt}/autoinstall.yaml`
  (mode 600). Subiquity finds `/autoinstall.yaml` in the live root and **asks
  for confirmation** (no `autoinstall` kernel word). Desktop 24.04 installer:
  to verify (same subiquity backend).
- Debian netinst: `/preseed.cfg` at the initrd root (d-i "initrd preseeding",
  loaded before the language questions).
- Fedora netinst (anaconda): `/usos/answer/ks.cfg` + `inst.ks=file:/usos/answer/ks.cfg`.
- Not supported (stated in the summary): Mint (Ubiquity), Debian live
  (Calamares), Fedora Workstation Live (anaconda WebUI), rescue ISOs.

SHA-512 crypt: implemented in Zig (glibc `$6$` algorithm, rounds=5000 default)
with the reference test vectors; salt from `EFI_RNG_PROTOCOL`, else TSC mix.

## 8. Catalog and routing

- Existing Linux systems keep their ids and folders (`ubuntu`, `debian`,
  `fedora`, `linux-mint`, `arch-linux`, `opensuse`, `manjaro`, `kali-linux`,
  `other-linux`). New: `systemrescue`, `gparted-live`, `clonezilla`
  (`Systems\Linux\SystemRescue|GParted Live|Clonezilla\Images`).
- New backend `linux_iso` (firmware any), new profiles `linux-iso-uefi` /
  `linux-iso-bios` for the Linux family, ISO image, `automatic`/`direct_iso`,
  placed before `iso-work-chainload`. **Routing golden**: new systems add rows;
  the existing Linux rows for `iso`+`automatic`/`direct_iso` change from
  `chainload` (WORK copy; never worked for Linux live media) to `linux_iso`.
  That is the intended change of this milestone; every non-Linux row stays
  byte-identical, and `other-linux` BIOS stays `linux_live_iso` (SliTaz).
- Answer screen: `answer_screen.profileCapable` gains `linux_iso` for
  `ubuntu`, `debian`, `fedora` (format chosen at start from the detected
  family; unsupported family -> summary note, profile ignored).
- Strings (27 locales): action "Start Linux", family line, unverified badge,
  errors (fragmented ISO, no kernel found, Secure Boot needs off, relay failed).

## 9. Implementation plan (in order)

1. `src/flow/linux_iso/`: `iso_map.zig` (writer/parser), `cpio.zig` (newc
   writer, 4-byte padding), `grub_cfg.zig` (first entry parser), `recipe.zig`
   (family detection over a reader + cmdline rules) with host tests against
   small synthetic ISOs; Rock Ridge `NM` names in `image_probe/iso9660.zig`
   (Debian live kernel names are long; Rock Ridge is required).
2. `src/platform/linux/iso_init_main.zig`: the static helper (raw syscalls, no
   libc; loop + dm); build step -> `zig-out/usb/EFI/USOS/linux/usos-linux.cpio`
   (deterministic, mtime 0) with `/usos/init`, `/usos/hooks/init-bottom`.
3. Fast validation without the menu: QEMU `-kernel/-initrd/-append` with a
   test VHD (GPT, NTFS DATA holding the ISOs, extents from
   `fsutil file queryextents`), SeaBIOS + OVMF, per distro. Success = live
   desktop / installer first screen (screenshot) + serial markers.
4. UEFI: `linux_iso_start.zig` (read, cpio, LoadFile2 initrd, LoadOptions,
   start), `manual_summary` dispatch, SB-off first; then the relay (5).
5. BIOS Core: generic path in `linux_live_iso.zig` (size check).
6. Catalog/routing/goldens, answer screen, strings in 27 locales, icons.
7. Answer renderers + goldens (`tools/tests/test_answer_render.py` pattern);
   one automated install in QEMU (Ubuntu server autoinstall to the storage
   screen; Debian preseed to partman).
8. Docs (this file -> results), `docs/answer-profiles.md`, ROADMAP, build,
   stick deploy.

## 10. Test assets

`tools/linux_test_assets.py` downloads the official ISOs into
`%LOCALAPPDATA%\USOS\test-assets\linux\` (outside the repo) and checks each
against the distribution's published SHA-256; results in `manifest.json`
there. List, URLs and hashes: `docs/HANDOFF-linux-2026-09-28.md`.

## 11. Results (QEMU, 2026-09-28)

What changed against the plan while implementing:

- d-i (Debian netinst) has neither `loop.ko` nor `dm-mod`: `/usos/init` falls
  back to an in-kernel partition (`BLKPG_ADD_PARTITION` 64 over the contiguous
  ISO, after removing the overlapping DATA partition from the kernel's table
  only; nothing is written to the disk) and USOS always adds
  `cdrom-detect/try-usb=true` to `/preseed.cfg`. The installer then finds its
  packages on the ISO.
- Secure Boot relay: the relay instance runs on top of the first instance's
  stack, so it switches to its own 1 MiB stack; the 64 KiB grub.cfg buffer
  must not live on the stack either (both were real crashes under shim).
- BIOS Core: an int13 read through the plain `reader` after bulk NTFS reads
  never returned, so the ESP helper cpio is read first. `iso.map` numbers are
  hexadecimal (the i386 Core has no 64-bit division). Core headroom 4 424 B.
- Answer files: the answer screen offers profiles for Ubuntu, Debian and
  Fedora ISO starts on UEFI (not BIOS: no profile manager in the Core); the
  profile is rendered at start (salt from `EFI_RNG_PROTOCOL`, else TSC) for the
  installer the ISO carries; ISOs without one (Mint, Debian live, Fedora
  Workstation Live) ignore it (logged). Under Secure Boot the relay passes the
  profile by name and the relay instance re-reads it from the ESP.

| ISO | UEFI SB off | UEFI SB on | BIOS |
|---|---|---|---|
| Ubuntu Server 24.04.5 | installer | installer (relay: Ubuntu shim) | installer |
| Ubuntu Desktop 24.04.5.1 | installer on live desktop | live desktop; installer error under TCG, check on hardware | installer on live desktop |
| Linux Mint 22.3 Xfce | live desktop | live desktop (relay) | live desktop |
| Fedora Workstation Live 44 | live desktop | live desktop (USOS shim, Fedora CA) | live desktop |
| Debian live 13.7 standard | live shell | live shell (relay: Debian shim 16.1) | live shell |
| Debian 13.7 netinst | to the hostname page (media found) | language page | to the hostname page |
| Debian 12.15 netinst | language page | language page (relay: shim 15.8) | language page |
| SystemRescue 13.02 | root shell | blocked: needs Secure Boot off | root shell |
| GParted Live 1.8.1 | live system | live system (relay) | live system |
| Clonezilla 3.3.3 | live system | live system (relay) | live system |

Answer files (UEFI, Secure Boot off, profile `tools/tests/linux_iso/linux-test.profile.ini`, blank 20 GB target disk):

| Format | ISO | Result |
|---|---|---|
| autoinstall | Ubuntu Server 24.04.5 | subiquity skipped language, keyboard, network and identity; stopped at the storage screen (subiquity preselects the largest disk: the user must pick the target) |
| preseed | Debian 13.7 netinst | Polish installer, no key pressed: media, network, hostname, users, password, time zone answered; stopped at "Partition disks" |
| kickstart | Fedora Everything netinst 44 | anaconda hub: keyboard/language pl, Europe/Warsaw, root locked, user tester (admin), network done; only "Installation Destination" left (kickstart insufficient, as intended); software selection defaults to "Fedora Custom Operating System" |

Test commands: `tools/tests/linux_iso/new_linux_test_disk.ps1` (once),
`update_linux_test_esp.ps1 [-Profile ...] [-AddIso name=Folder]`,
`run_linux_iso_menu.py --name X --script "..." [--secure-boot --tcg] [--bios] [--target-disk 20]`,
`run_linux_iso_direct.py <name>` (no menu).
