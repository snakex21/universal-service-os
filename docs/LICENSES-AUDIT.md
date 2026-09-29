# USOS 1.0 third-party licence audit

Audit date: 2026-09-28. Scope: everything that USOS 1.0 distributes, checked
against what is really packed, not against what the build is meant to pack:

- the installer payload `installer/internal/payload/assets/payload.zip`
  (126 entries, build B260928-193034-65E00BAD), which the installer writes to
  the stick's ESP (`EFI/`, `UI/`, `USOS-KEY.cer`);
- the cpio archives and the micro-Linux initramfs inside it
  (`initramfs-usos`, `support.cpio`, `win7-support.cpio`,
  `vista-support.cpio`, `modern-support.cpio`, `usos-linux.cpio`), listed
  member by member;
- what the installer puts on DATA (the installer copy in
  `Programs\USOS`, generated README files, empty profile folders);
- the separately shipped XP package (`zig-out/xp-uefi-csm`: `initramfs-xp`,
  `vmlinuz.efi`, `manifest.json`), diffed against `initramfs-usos`;
- the WinPE PE10 donor ISO shipped as a release asset;
- the installer executable itself (Go).

Licences of Alpine packages come from the `.PKGINFO` of the cached `.apk`
files (`tools/cache/alpine/packages`) and, for the base userland of the
netboot initramfs, from the `APKINDEX` of the Alpine 3.24.1 ISO; the few
packages found in neither are marked "version not recorded" and their
licence is Alpine's usual one. Nothing in this audit is legal advice; it
records facts and the gaps found.

The machine-readable form is `tools/release/third-party.json` (60
components), consumed by `tools/release/assemble_release.py` to build
`LICENSES/`, `THIRD-PARTY-NOTICES.txt`, `SOURCE-OFFER.txt` and
`USOS-<version>-sources.zip` (about 21 MB of third-party sources). Licence
texts that were missing now live in `tools/release/licenses/` (see its
`README.txt`); no payload input was changed.

## 1. Summary

| | Count |
|---|---|
| Components in `third-party.json` | 60 (35 of them Alpine source packages) |
| Already compliant on the stick (licence and, where needed, source next to the binary) | 12 |
| Gaps found | 18 (G1 to G18) plus 2 payload-level follow-ups (F1, F2) |
| Gaps fixed in this audit (release-level licence texts, sources zip, written offer) | 8 (G1 to G6, G8, G9), covering 42 components: 35 Alpine packages, kernel, systemd-boot, EfiFs, wimboot, Zig and Go runtimes, FreeDOS texts |
| Remaining GAPs | 6 (G10 to G13, G17, G18), see section 7; G7 closed by the source pin, G14 to G16 closed by maintainer decisions (2026-09-28) |

Status legend: **OK**: nothing to do. **FIXED in this audit**: the release
now carries the licence text and the source (sources zip) or a written offer
with exact upstream URLs. **GAP**: still open, with the reason.

## 2. Components

Where it ships: *stick ESP* = the installer payload on `USOS_ESP`
(including the initramfs and cpio archives on it), *DATA* = `USOS_DATA`,
*XP package* = `USOS-<version>-XP-package-*.zip` (`EFI/USOS-XP`),
*WinPE asset* = `USOS-<version>-WinPE-PE10-donor.zip`, *installer* =
`USOS-Installer-<version>.exe`.

| Component | Version | Licence (SPDX) | Where it ships | Source location / obligation | Status |
|---|---|---|---|---|---|
| shim (Fedora signed shim-x64) and MokManager | 16.1-7 | `BSD-2-Clause` | stick ESP | <https://github.com/rhboot/shim/releases/tag/16.1> | GAP (minor): licence on ESP; the OpenSSL/SSLeay notice of shim's bundled Cryptlib is not reproduced |
| EDK2 UEFI Shell | edk2-stable202002 (Shell 2.2) | `BSD-2-Clause-Patent` | stick ESP | <https://github.com/tianocore/edk2/tree/4c0f6e349d32cf27a7104ddd3e729d6ebc88ea70> | OK (License.txt + SOURCES.txt on the ESP) |
| EfiFs NTFS driver (ntfs_x64.efi) | 1.12 | `GPL-3.0-or-later` | stick ESP | written offer; <https://github.com/pbatard/efifs/releases/tag/v1.12> | FIXED in this audit (release LICENSES + written offer); ESP copy has no licence next to it (follow-up F1) |
| systemd-boot | 260.2-r0 (Alpine) | `LGPL-2.1-or-later` | stick ESP | written offer; <https://github.com/systemd/systemd/archive/refs/tags/v260.2.tar.gz> | FIXED in this audit (release LICENSES + offer); no licence on the ESP (follow-up F1) |
| Linux kernel (Alpine linux-lts) and modules | 6.18.35-0-lts (Alpine 3.24.1 netboot) | `GPL-2.0-only WITH Linux-syscall-note` | stick ESP, XP package | written offer; <https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.35.tar.xz> | FIXED in this audit (release LICENSES + offer); GAP: aports commit of linux-lts 6.18.35-r0 not recorded; no licence on the ESP (F1) |
| busybox (Alpine v3.24 package) | busybox 1.37.0-r31, busybox-binsh 1.37.0-r31, ssl_client 1.37.0-r31 | `GPL-2.0-only` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/c3ef5d10e6ef6528852c51f0564963e2f8c1be19/main/busybox> | FIXED in this audit (texts + SOURCES.txt + offer) |
| musl (Alpine v3.24 package) | musl 1.2.6-r2 | `MIT` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/f5640d3a10f664c9119720c60515265d3d6f6d01/main/musl> | FIXED in this audit (listed with source URL) |
| apk-tools (Alpine v3.24 package) | apk-tools 3.0.6-r0, libapk 3.0.6-r0 | `GPL-2.0-only` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/1403ea7a8ae3fb8e5a11207ddb1ff536eb8de912/main/apk-tools> | FIXED in this audit (texts + SOURCES.txt + offer) |
| openssl (Alpine v3.24 package) | libcrypto3 3.5.7-r0, libssl3 3.5.7-r0 | `Apache-2.0` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/4a4352d83ab03720965454a8c7b30b1b6a996c84/main/openssl> | FIXED in this audit (listed with source URL) |
| alpine-baselayout (Alpine v3.24 package) | alpine-baselayout 3.7.2-r1, alpine-baselayout-data 3.7.2-r1 | `GPL-2.0-only` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/60a7585bbab2fa0f762504eb617dbca90216e31f/main/alpine-baselayout> | FIXED in this audit (texts + SOURCES.txt + offer) |
| alpine-keys (Alpine v3.24 package) | alpine-keys 2.6-r0 | `MIT` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/b9f23becced4d7b3ccc0fa0f28530243ccd314a0/main/alpine-keys> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected |
| mdev-conf (Alpine v3.24 package) | mdev-conf 4.10-r0 | `MIT` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/203310a84fe34bc9b8dad2c97cba2f5189303415/main/mdev-conf> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected |
| ca-certificates (Alpine v3.24 package) | ca-certificates-bundle 20260611-r0 | `MPL-2.0 AND MIT` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/e41cbd2ae991adfe8df298ba8e8e777e90bd0e03/main/ca-certificates> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected |
| kmod (Alpine v3.24 package) | kmod 3.24 base, kmod-libs 3.24 base | `LGPL-2.1-or-later AND GPL-2.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/kmod> | FIXED in this audit (texts + SOURCES.txt + offer); exact version not recorded |
| cryptsetup (Alpine v3.24 package) | cryptsetup-libs 3.24 base | `GPL-2.0-or-later WITH cryptsetup-OpenSSL-exception AND LGPL-2.1-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/cryptsetup> | FIXED in this audit (texts + SOURCES.txt + offer); exact version not recorded |
| lvm2 (Alpine v3.24 package) | device-mapper-libs 3.24 base | `LGPL-2.1-only` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/lvm2> | FIXED in this audit (texts + SOURCES.txt + offer); exact version not recorded |
| json-c (Alpine v3.24 package) | json-c 3.24 base | `MIT` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/json-c> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected; exact version not recorded |
| xz (Alpine v3.24 package) | xz-libs 3.24 base | `0BSD` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/xz> | FIXED in this audit (listed with source URL); exact version not recorded |
| mkinitfs (Alpine v3.24 package) | mkinitfs (nlplug-findfs) 3.24 base | `GPL-2.0-only` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/mkinitfs> | FIXED in this audit (texts + SOURCES.txt + offer); exact version not recorded |
| kexec-tools (Alpine v3.24 package) | kexec-tools 2.0.32-r2 | `GPL-2.0-only` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/151ef8efcb01d1282c74773d54b0305eb06776bb/community/kexec-tools> | FIXED in this audit (texts + SOURCES.txt + offer) |
| acl (Alpine v3.24 package) | acl-libs 2.3.2-r1 | `LGPL-2.1-or-later AND GPL-2.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/8bac74716d06c84627ab02d101fd9d2bafd0a34c/main/acl> | FIXED in this audit (texts + SOURCES.txt + offer) |
| util-linux (Alpine v3.24 package) | blkid 2.42.1-r0, findmnt 2.42.1-r0, sfdisk 2.42.1-r0, lsblk 2.42.1-r0, libblkid 2.42.1-r0, libfdisk 2.42.1-r0, libmount 2.42.1-r0, libsmartcols 2.42.1-r0, libuuid 2.42.1-r0 | `GPL-2.0-or-later AND GPL-1.0-or-later AND LGPL-2.1-or-later AND LGPL-1.0-only AND BSD-3-Clause` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/58e8609cc84989eeb6f07b86d79b10321eacca9f/main/util-linux> | FIXED in this audit (texts + SOURCES.txt + offer); GAP: permissive copyright notice not collected |
| mtools (Alpine v3.24 package) | mtools 4.0.49-r0 | `GPL-3.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/efa1c7cac97401469414a36748f0f3f46d98b976/main/mtools> | FIXED in this audit (texts + SOURCES.txt + offer) |
| dosfstools (Alpine v3.24 package) | dosfstools 4.2-r2 | `GPL-3.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/9024026ee6838388f8b87e52a17495786ed85d4e/main/dosfstools> | FIXED in this audit (texts + SOURCES.txt + offer) |
| libeconf (Alpine v3.24 package) | libeconf 0.8.3-r0 | `MIT` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/62db33049768522f381410614d59c7d732f72c3a/main/libeconf> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected |
| ncurses (Alpine v3.24 package) | libncursesw 6.6_p20260516-r0, ncurses-terminfo-base 6.6_p20260516-r0 | `X11` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/2cee8a7328d061418336ad327b512d96bcd7bc5e/main/ncurses> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected |
| xxhash (Alpine v3.24 package) | libxxhash 0.8.3-r1 | `BSD-2-Clause` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3b2e469e223a5cb31932b1eae30c266e26b30148/main/xxhash> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected |
| lz4 (Alpine v3.24 package) | lz4-libs 1.10.0-r1 | `BSD-2-Clause AND GPL-2.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/1f16962f34234a77fab0f4651459c4381b4a0cd6/main/lz4> | FIXED in this audit (texts + SOURCES.txt + offer); GAP: permissive copyright notice not collected |
| ntfs-3g (Alpine v3.24 package) | ntfs-3g 2026.2.25-r0, ntfs-3g-libs 2026.2.25-r0, ntfs-3g-progs 2026.2.25-r0 | `GPL-2.0-only` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/6e0f4ace9c11c2ce0a132d763507d1898e707ba2/main/ntfs-3g> | FIXED in this audit (texts + SOURCES.txt + offer) |
| popt (Alpine v3.24 package) | popt 1.19-r4 | `MIT` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/d3abe30d43524bed75a29a3006e703ab51836548/main/popt> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected |
| rsync (Alpine v3.24 package) | rsync 3.5.0-r0 | `GPL-3.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/8cc5798059868c71d4c2efa296afe835c6602689/main/rsync> | FIXED in this audit (texts + SOURCES.txt + offer) |
| zlib (Alpine v3.24 package) | zlib 1.3.2-r0 | `Zlib` | stick ESP, XP package | <https://gitlab.alpinelinux.org/alpine/aports/-/tree/f248b33b5943c7dc69bf691031d7612ab2e8ed93/main/zlib> | FIXED in this audit (listed with source URL); GAP: permissive copyright notice not collected |
| zstd (Alpine v3.24 package) | zstd-libs 1.5.7-r2 | `BSD-3-Clause OR GPL-2.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3c6e2ee2b16f403d53eab39c4426eb61f003c322/main/zstd> | FIXED in this audit (texts + SOURCES.txt + offer) |
| smartmontools (Alpine v3.24 package) | smartmontools 7.5-r0 | `GPL-2.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/58d667cdf3ede3c43a229418c135d07d25983a44/main/smartmontools> | FIXED in this audit (texts + SOURCES.txt + offer) |
| dmidecode (Alpine v3.24 package) | dmidecode 3.7-r0 | `GPL-2.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/639806892e3f8c8225a15326b40548e053350d41/main/dmidecode> | FIXED in this audit (texts + SOURCES.txt + offer) |
| pciutils (Alpine v3.24 package) | pciutils 3.15.0-r0, pciutils-libs 3.15.0-r0 | `GPL-2.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/6f2cdac966e30da20250e59cb11b899fbc03a957/main/pciutils> | FIXED in this audit (texts + SOURCES.txt + offer) |
| hwdata (Alpine v3.24 package) | hwdata-pci 0.408-r0 | `GPL-2.0-or-later OR XFree86-1.1` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/6f27b0b36ae7a3874f59cedf8c361b4016ee30ac/main/hwdata> | FIXED in this audit (texts + SOURCES.txt + offer) |
| gcc (Alpine v3.24 package) | libgcc 15.2.0-r5, libstdc++ 15.2.0-r5 | `GPL-2.0-or-later AND LGPL-2.1-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/423a8ad043d07f2c7546c8ec3e2b0384cda360ae/main/gcc> | FIXED in this audit (texts + SOURCES.txt + offer); GAP: permissive copyright notice not collected |
| wimlib (Alpine v3.24 package) | wimlib 1.14.4-r1 | `GPL-3.0-or-later` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/21d0c4c5f6252e58685fd9665238ded4ec4d5a9b/community/wimlib> | FIXED in this audit (texts + SOURCES.txt + offer) |
| fuse3 (Alpine v3.24 package) | fuse3-libs 3.18.3-r0 | `GPL-2.0-only AND LGPL-2.1-only` | stick ESP, XP package | written offer; <https://gitlab.alpinelinux.org/alpine/aports/-/tree/0adb5f52202c5e2d5029f50a27a972479b3d98b5/main/fuse3> | FIXED in this audit (texts + SOURCES.txt + offer) |
| Zig standard library / compiler-rt and statically linked musl | Zig 0.16.0 | `MIT` | stick ESP, XP package | <https://ziglang.org/download/0.16.0/zig-0.16.0.tar.xz> | FIXED in this audit (release LICENSES); not on the ESP (F1) |
| Roboto and Noto Sans symbol subset (boot UI font pack) | Roboto 2.137, Go Noto Current 2.012 subset | `Apache-2.0 AND OFL-1.1` | stick ESP | sources zip: `assets/fonts`; <https://github.com/googlefonts/roboto/releases/tag/v2.137> | OK (texts on the ESP in EFI/USOS/licenses/fonts) |
| wimboot (iPXE) and the USOS kexec variants (MODIFIED) | 2.9.0 (+ usos kexec variants) | `GPL-2.0-or-later` | stick ESP, XP package | sources zip: `tools/vendor/wimboot/2.9.0/source.tar.gz`, `tools/vendor/wimboot/2.9.0/README.md`, `tools/vendor/wimboot/2.9.0/USOS-KEXEC.md`, `tools/wimboot_kexec.py`, `src/platform/bios/windows_kexec_bridge.S`, `src/platform/bios/windows_kexec_cpu_reset.S`, `src/platform/bios/windows_disk_order.S`; <https://github.com/ipxe/wimboot/releases/tag/v2.9.0> | FIXED in this audit (source + generator in the sources zip); the ESP wimboot has no licence next to it (F1) |
| ImDisk Virtual Disk Driver | 2.1.2 | `GPL-2.0-only` | stick ESP, XP package | sources zip: `tools/vendor/imdisk/2.1.2/source.zip`; <https://github.com/LTRData/ImDisk/tree/06658631441be3f2d560cf58d503532a7ebe67f4> | OK (licence + source.zip travel in support.cpio and the initramfs) |
| UefiSeven | 1.30 | `BSD-2-Clause AND BSD-2-Clause-Patent` | stick ESP, XP package | sources zip: `tools/vendor/uefiseven/1.30`; <https://github.com/manatails/uefiseven/tree/b8f0baba63e60e74d4ed3e86b15b76319d316b83> | OK (uefiseven-LICENSE.txt next to every copy) |
| CSMWrap with its SeaBIOS fork (MODIFIED) | 3.1.2-usos1 | `LGPL-2.1-only AND LGPL-3.0-only` | stick ESP | sources zip: `tools/vendor/csmwrap/3.1.2-src`, `tools/vendor/csmwrap/3.1.2-usos1`, `tools/csmwrap_build`, `tools/build_csmwrap.ps1`, `docs/research/csmwrap.md`; <https://github.com/CSMWrap/CSMWrap/tree/808ac8ea5393db9052044fb0f74aa55e0d719afc> | OK (LGPL texts, source archive, patches, SOURCES.txt on the ESP and on every CSMWrap target ESP) |
| TouchI2cDxe (MODIFIED) | v1.3.1-usos1 | `BSD-2-Clause-Patent` | stick ESP | sources zip: `tools/vendor/touchi2cdxe/v1.3.1-usos1/usos-rc71l.patch`, `tools/vendor/touchi2cdxe/v1.3.1-usos1/UsosTouchPkg.dsc`, `tools/vendor/touchi2cdxe/v1.3.1-usos1/PROVENANCE.md`, `tools/vendor/touchi2cdxe/v1.3.1-usos1/manifest.json`, `tools/build_touchi2cdxe.ps1`; <https://github.com/jlobue10/TouchI2cDxe/tree/cd673f65049f4bd34dd511ca7a28c345f41efac0> | OK (licence on the ESP; patch in the sources zip) |
| Syslinux MEMDISK | 6.03 | `GPL-2.0-or-later` | stick ESP | sources zip: `tools/vendor/syslinux/6.03/source.zip`; <https://www.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.zip> | OK (COPYING + source.zip on the ESP) |
| Patcher9x (with the R. Loew RAM patch) | 0.9.91 | `MIT` | stick ESP | sources zip: `tools/vendor/patcher9x/0.9.91/source.zip`; <https://github.com/JHRobotics/patcher9x/releases/tag/v0.9.91> | OK (LICENSE, NOTICE, source.zip on the ESP) |
| CWSDPMI | r7 | `LicenseRef-CWSDPMI` | stick ESP | <https://www.delorie.com/pub/djgpp/current/v2misc/csdpmi7s.zip> | OK (CWSDPMI.TXT on the ESP; source URL in NOTICE.TXT) |
| HimemX | 3.40 | `GPL-2.0-only OR Artistic-1.0` | stick ESP | sources zip: `tools/vendor/himemx/3.40/source-and-binaries.zip`; <https://github.com/Baron-von-Riedesel/HimemX/releases/tag/v3.40> | OK (licence text + HIMEMSRC.ZIP on the ESP) |
| FreeDOS kernel, FreeCOM and Doszip | FreeDOS 1.4 (kernel 20250409.9, FreeCOM 0.86a, Doszip 2.68) | `GPL-2.0-only` | stick ESP | sources zip: `tools/vendor/freedos/1.4/kernel.zip`, `tools/vendor/freedos/1.4/freecom.zip`, `tools/vendor/freedos/1.4/doszip.zip`, `tools/vendor/freedos/1.4/manifest.json`; <https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/repositories/1.4/base/kernel/20250409.9/kernel.zip> | OK on the ESP (COPYING + package zips with sources); FIXED: licence texts extracted for the release |
| PatchPAE3 (adapted as the USOS XP PAE helper) (MODIFIED) | 3e1d3b65f5c3c1ec0c4759f707d3017e51113103 | `CC-BY-4.0` | XP package | sources zip: `tools/vendor/patchpae3/3e1d3b65f5c3c1ec0c4759f707d3017e51113103`, `tools/windows_xp_pae.c`, `tools/windows_xp_pae_strings.h`; <https://github.com/evgen-b/PatchPAE3/tree/3e1d3b65f5c3c1ec0c4759f707d3017e51113103> | OK (attribution + licence reference in xp-pae-LICENSE.txt) |
| GenAHCI | 6.3.0.1 | `GPL-3.0-only` | XP package | sources zip: `tools/vendor/genahci/6.3.0.1-src` (tag `GenAHCI` = commit b936a0d8); <https://github.com/GeorgeK1ng/GenAHCI/tree/b936a0d8bdf410928aefa9e0f373fb1d6c7c8240> | FIXED (source pinned and bundled); consistent with the binaries, not byte-verified (needs WDK 7600), see G7 |
| xhci98 | 1.1.1.0-usos1 (**MODIFIED**) | `GPL-2.0-only` | XP package (branch `feature/nt52-xhci98`, 1.1 work) | sources zip: `tools/vendor/xhci98/1.1.1.0-src` (tag `v1.1.1.0` = commit 7d0dd9d4, git-ignored tarball pinned in `tools/vendor/xhci98/1.1.1.0/SOURCES.txt`) plus `tools/vendor/xhci98/1.1.1.0-usos1/` (patch, `build.cmd`, `toolchain.txt`, `MODIFIED.txt`); <https://github.com/yeokm1/xhci98/tree/7d0dd9d440e9716a87e0882f905bf8e99fa443ac> | USOS-built (WDK 7.1) x86/amd64 `xhci98.sys` + `.inf`, `LICENSE`, `MODIFIED.txt`, `SOURCE.txt` in `usr/lib/usos/nt52-usb/`; Server 2003 x86 and XP x64 only. The unmodified 1.1.1.0 pin stays in `tools/vendor/xhci98/1.1.1.0` as the reference |
| Go runtime and standard library, golang.org/x/sys | Go 1.26.2, x/sys v0.47.0 | `BSD-3-Clause` | installer, DATA | <https://go.dev/dl/go1.26.2.src.tar.gz> | FIXED in this audit (release LICENSES); the installer itself shows no notice (F2) |
| Microsoft Windows PE 10.0.19041 x64 donor (PE10_x64_19041_USOS.iso) | 10.0.19041 | `LicenseRef-Microsoft-redistributed-by-user` | WinPE asset | n/a (proprietary) | Microsoft, see section 5 (maintainer responsibility) |
| Microsoft Windows 7 SP1 x64 update packages | KB4474419 v3, KB2685811, KB2990941 v3, KB3087873 v2 | `LicenseRef-Microsoft-redistributed-by-user` | stick ESP | n/a (proprietary) | KEPT by maintainer decision (preservation), see section 5 |
| Microsoft Windows Vista update and USB 3 driver files | KB2864202 + Windows 8-family USB 3 stack (usbxhci, ucx01000, usbhub3, usbd8) | `LicenseRef-Microsoft-redistributed-by-user` | stick ESP | n/a (proprietary) | KEPT by maintainer decision (preservation), see section 5 |
| Windows XP / Server 2003 driver bundles derived from Microsoft ISOs | per source ISO (see XP package manifest.json) | `LicenseRef-Microsoft-redistributed-by-user` | XP package | n/a (proprietary) | KEPT by maintainer decision (preservation), see section 5 |
| Operating system icons in UI/Icons/Systems | 2026-09-03 | `LicenseRef-USOS-generated-icons` | stick ESP | generated by the maintainer with ChatGPT (OpenAI image generation) | OK: origin recorded, kept by maintainer decision; they depict Microsoft trademark logos (G15) |

Notes on individual entries:

- **CSMWrap 3.1.2-usos1** is recorded as `LGPL-2.1-only AND LGPL-3.0-only`:
  the upstream `LICENSE` is the LGPL 2.1 text with no "or any later
  version" statement and no per-file notices, and SeaBIOS states LGPLv3.
  "Only" is the conservative reading. The build is MODIFIED (three patches
  of 2026-09-27, `tools/vendor/csmwrap/3.1.2-usos1/patches`); the complete
  corresponding source is the unpatched archive
  `tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz`
  (SHA-256 `9be5b839...ff72`, all submodules pinned) plus those patches,
  exactly as `docs/research/csmwrap.md` section 7 describes. Both already
  travel on the ESP (`EFI/USOS/csmwrap/`) and onto every CSMWrap target ESP
  (`tools/xp_csmwrap_esp.sh`); the release sources zip adds the build
  scripts (`tools/build_csmwrap.ps1`, `tools/csmwrap_build/`).
- **wimboot**: the ESP binary `EFI/USOS/windows-native/wimboot` is the
  unmodified 2.9.0 release. The initramfs also carries `wimboot-kexec` and
  `wimboot-kexec-ordered`, generated by `tools/wimboot_kexec.py` from that
  binary plus the USOS assembly in `src/platform/bios/windows_kexec_*.S` and
  `windows_disk_order.S`. These are MODIFIED GPL-2.0-or-later works; their
  complete source is the upstream tarball plus the generator and the
  assembly files, all in the sources zip.
- **MEMTEST86+ and SliTaz are not shipped.** The menu only validates and
  boots a Memtest86+ image or a SliTaz ISO that the user copies to DATA
  (`src/platform/bios/memtest_image.zig`, `USOS-SliTaz.txt`). The same holds
  for every OS image, Linux ISO, DOS image and user driver on DATA.
- **SeaBIOS** has no entry of its own: it is linked into `csmwrapx64.efi`
  and covered by the CSMWrap entry (its LGPLv3 and GPLv3 texts are listed
  there).
- **PatchPAE3** (CC-BY-4.0): `tools/windows_xp_pae.c` is an adaptation of
  its patterns. CC BY 4.0 is satisfied by attribution plus the licence URI,
  which `usr/lib/usos/xp-pae-LICENSE.txt` carries in the XP package.
- **zstd** (`BSD-3-Clause OR GPL-2.0-or-later`) and **hwdata**
  (`GPL-2.0-or-later OR XFree86-1.1`) are dual-licensed; USOS relies on the
  GPL option, which the written offer covers.
- **gcc** runtime (`libgcc`, `libstdc++`): the licence string is Alpine's;
  upstream the runtime libraries are GPL-3.0-or-later with the GCC Runtime
  Library Exception 3.1, whose text is not yet in the repository.

## 3. What the payload really contains

`payload.zip` (126 entries) maps to the components above as follows:

| Payload path | Component(s) |
|---|---|
| `EFI/BOOT/BOOTX64.EFI`, `EFI/BOOT/mmx64.efi`, `EFI/USOS/licenses/shim/*` | shim 16.1-7 |
| `EFI/BOOT/grubx64.efi`, `EFI/BOOT/BOOTAA64.EFI`, `EFI/USOS/bios-ui.bin` | USOS (Zig menu, AArch64 bootstrap, Legacy BIOS UI pack) + Zig runtime + fonts + system icons |
| `EFI/USOS/licenses/fonts/*` | fonts |
| `EFI/USOS/ntfs_x64.efi` | EfiFs 1.12 NTFS |
| `EFI/USOS/systemd-bootx64.efi` | systemd-boot 260.2 |
| `EFI/USOS/micro-linux/vmlinuz-virt` | Linux 6.18.35-0-lts |
| `EFI/USOS/micro-linux/initramfs-usos` | Alpine userland (35 origins), kernel modules, USOS scripts and `usos-fb-ui`, ImDisk (+ licence + source), UefiSeven (+ licence), wimboot and the kexec variants, Microsoft NVMe update files (KB2990941, KB3087873) |
| `EFI/USOS/windows-native/wimboot` | wimboot 2.9.0 |
| `EFI/USOS/windows-native/support.cpio` | USOS helpers, ImDisk (+ licence + source) |
| `EFI/USOS/windows-native/win7-support.cpio` | USOS helpers, UefiSeven (+ licence), Microsoft CABs KB4474419, KB2685811, KB2990941, KB3087873 |
| `EFI/USOS/windows-native/vista-support.cpio` | USOS helpers, UefiSeven (+ licence), 13 files of the frozen Vista payload (Microsoft KB2864202 CAB, Windows 8-family USB 3 driver files with a USOS test catalog, USOS tools) |
| `EFI/USOS/windows-native/modern-support.cpio`, `int10.original.efi`, `UefiSeven.ini` | USOS only |
| `EFI/USOS/windows-native/int10.efi`, `uefiseven-LICENSE.txt` | UefiSeven 1.30 |
| `EFI/USOS/dos-native/memdisk`, `COPYING`, `source.zip` | Syslinux MEMDISK 6.03 |
| `EFI/USOS/dos-native/ram-patch/*` | Patcher9x 0.9.91, CWSDPMI r7 (+ USOS BAT files) |
| `EFI/USOS/dos-native/msdos/HIMEMX.*`, `HIMEMSRC.ZIP`, `LICENSE.TXT` | HimemX 3.40 (+ USOS BAT files and REBOOT.COM) |
| `EFI/USOS/dos-native/freedos/*` | FreeDOS kernel, FreeCOM, Doszip (+ USOS BAT files) |
| `EFI/USOS/csmwrap/*` | CSMWrap 3.1.2-usos1 with source and licences |
| `EFI/USOS/shell/*` | EDK2 UEFI Shell (+ USOS `startup.nsh`) |
| `EFI/USOS/touchi2c_x64.efi`, `EFI/USOS/licenses/touchi2cdxe/LICENSE` | TouchI2cDxe v1.3.1-usos1 |
| `EFI/USOS/linux/usos-linux.cpio`, `EFI/USOS/themes/*`, `ENROLL*`, `secure-boot.ini`, `build-info.ini`, `USOS-KEY.cer`, `UI/index.html`, `UI/theme.css` | USOS only |
| `UI/Icons/Systems/*.png` (22 files) | system icons (Microsoft logos) |

XP package (`initramfs-xp` = `initramfs-usos` + 114 entries):
`usr/lib/usos/xp-pae.exe` + `xp-pae-LICENSE.txt` (PatchPAE3 adaptation),
`usr/lib/usos/nt5-storage/` (GenAHCI x86/x64 + `gpl.txt` + `SOURCE.txt`),
`usr/lib/usos/nt52-usb/` (xhci98 1.1.1.0-usos1, MODIFIED, x86/amd64 `.sys` + `.inf`, `LICENSE`, `MODIFIED.txt`, `SOURCE.txt`; branch `feature/nt52-xhci98`),
`usr/lib/usos/xp-drivers/<bundle>/I386/*` (per-ISO bundles: `SP3.CAB`,
`TXTSETUP.SIF`, `DOSNET.INF`, `HIVESYS.INF`, `SETUPREG.HIV` and the added
drivers, largely from the Integral Edition patch set: `USBXHCI`, `UCX01000`, `USBHUB3`, `USBD8`,
`WDF01000`, `WDFLDR`, `NTOSKRN8`, `KSECD8`, `ACPI`, `STORPORT`, `HIDCLASS`,
`HIDPARSE`, `WPPRECOR`, plus `GENAHCI`). `vmlinuz.efi` is the same signed
kernel as `vmlinuz-virt`.

## 4. Build-time only (not redistributed)

| Tool | Version | Licence | Note |
|---|---|---|---|
| Zig compiler | 0.16.0 (`tools/zig`) | MIT (+ LLVM Apache-2.0 WITH LLVM-exception, bundled libc sources under their own licences) | only the compiled runtime ships, see `zig-runtime` |
| Go toolchain | 1.26.2 | BSD-3-Clause | only the compiled runtime ships, see `go-runtime` |
| QEMU | `tools/qemu` (tracked in git) | GPL-2.0-only / LGPL-2.1 (`tools/qemu/COPYING*`) | tests only; not in any release zip, but it is in the git repository: if the repository itself is published, QEMU's source offer applies to it |
| Python 3, Pillow | 3.13 | PSF-2.0, MIT-CMU (HPND) | font rasterizer, build scripts |
| 7-Zip | host install | LGPL-2.1-or-later + unRAR restriction | archive extraction during builds |
| EDK2, Visual Studio 2022 Build Tools, NASM 2.16.03 | edk2-stable202411 | BSD-2-Clause-Patent / Microsoft EULA / BSD-2-Clause | builds of TouchI2cDxe and the UefiSeven source check |
| Alpine build VM (GCC 15, binutils) | Alpine 3.24 | GPL | reproducible CSMWrap build (`tools/csmwrap_build`) |
| wimlib for Windows | 1.14.5 (`tools/vendor/wimlib`) | GPL-3.0-or-later / LGPL-3.0-or-later | host-side WIM tooling; only its GPLv3 text is reused (SeaBIOS GPLv3 copy on the ESP) |
| xhci98 | 1.1.0.0 (`tools/vendor/xp-modern`) | see upstream | Vista/9x research (`tools/prepare_vista_xhci98.py`); not packed (1.1.1.0 in `tools/vendor/xhci98` is the packed NT 5.2 copy) |
| Windows XP Integral Edition 2025.8.19 archive | `tools/vendor/xp-modern/.../integrator` | none stated | only the driver files listed in section 3 reach the XP package |
| Microsoft MSU/CAB sources | `tools/vendor/windows7-kmdf`, `tools/vendor/windows7-nvme`, `media/Systems/Windows/Windows 7/Updates` | Microsoft | git-ignored inputs of the CABs in section 5 |

## 5. Microsoft components

USOS never ships Windows ISOs, install images or product keys. It does ship
Microsoft files in four places, and the licence terms do not change because
USOS packs them; they stay Microsoft's property and are not covered by any
USOS licence:

1. **WinPE PE10 donor** (`PE10_x64_19041_USOS.iso`, Windows PE 10.0.19041
   x64: `boot/bcd`, `boot/boot.sdi`, `sources/boot.wim`, `sources/setup.exe`),
   a separate release asset. It is redistributed by the USOS maintainer at
   the maintainer's own responsibility; users download it separately and
   place it on DATA. No USOS licence covers it.
2. **Windows 7 update packages in the stick payload**:
   `win7-support.cpio` holds the original CABs of KB4474419 v3 (SHA-2 code
   signing, 55.8 MB), KB2685811 (KMDF 1.11), KB2990941 v3 and KB3087873 v2
   (NVMe); `initramfs-usos` holds the two NVMe CABs again plus the Setup and
   storport files extracted from them (`usr/lib/usos/windows7-nvme`,
   including `setup.exe` and `segoeui.ttf`). The files are unmodified.
   Microsoft publishes these through the Update Catalog; that is a download
   permission, not an explicit redistribution grant. Unlike the WinPE donor
   these files are inside the USOS payload itself, so every installer
   download redistributes them.
3. **Windows Vista payload** in `vista-support.cpio`: the KB2864202 CAB
   (KMDF for Vista) and Windows 8-family USB 3 driver files (`usbxhci.sys`,
   `ucx01000.sys`, `usbhub3.sys`, `usbd8.sys` with a USOS-made INF/test
   catalog), frozen from `artifacts/vista/hardware-success-v11-20260920-235629`.
   Same situation as item 2, and the catalog is a USOS re-signing of
   Microsoft binaries.
4. **XP package driver bundles**: per-ISO bundles built from the named
   Microsoft XP SP3 ISO (the whole `SP3.CAB`, setup INF/hive files, and
   copies adjusted by USOS for the added drivers) plus community-modified
   Microsoft drivers from the Windows XP Integral Edition 2025.8.19 patch set
   (Windows 8 USB 3 stack backports, WDF, `ntoskrn8`, `ksecd8`, modified
   ACPI and storport). The community patch set states no licence.

`third-party.json` lists these as `LicenseRef-Microsoft-redistributed-by-user`
with an explicit notice each. Whether items 2 to 4 may be redistributed is a
decision for the maintainer; the audit only records that they are
Microsoft (or community-modified Microsoft) files and are shipped by USOS,
not supplied by the user. An alternative that keeps the payload free of
Microsoft files would be to take the packages from the user's DATA
(`Systems\Windows\Windows 7\Updates`, `Systems\Windows\Windows Vista`)
at install time instead of embedding them.

**Maintainer decision (2026-09-28): keep items 2 to 4 in the release.**
The reason is preservation: the original downloads may disappear. These are
Microsoft files (item 4 also community-modified Microsoft files),
redistributed by the USOS maintainer at the maintainer's own risk; they are
not covered by any USOS licence, and they will be removed on request of the
rights holder. The same note is in `THIRD-PARTY-NOTICES.txt` and the release
notes.

## 6. Obligations checklist (GPL / LGPL)

**Sources bundled in `USOS-<version>-sources.zip`** (all exist in the repo;
about 21 MB):

| Component | Paths |
|---|---|
| CSMWrap 3.1.2-usos1 (MODIFIED, LGPL-2.1 + SeaBIOS LGPLv3) | `tools/vendor/csmwrap/3.1.2-src` (archive + licences), `tools/vendor/csmwrap/3.1.2-usos1` (patches, toolchain, binary manifest), `tools/csmwrap_build`, `tools/build_csmwrap.ps1`, `docs/research/csmwrap.md` |
| wimboot 2.9.0 + kexec variants (MODIFIED, GPL-2.0-or-later) | `tools/vendor/wimboot/2.9.0/source.tar.gz`, `README.md`, `USOS-KEXEC.md`, `tools/wimboot_kexec.py`, `src/platform/bios/windows_kexec_bridge.S`, `windows_kexec_cpu_reset.S`, `windows_disk_order.S` |
| ImDisk 2.1.2 (GPL-2.0) | `tools/vendor/imdisk/2.1.2/source.zip` |
| Syslinux MEMDISK 6.03 (GPL-2.0-or-later) | `tools/vendor/syslinux/6.03/source.zip` |
| HimemX 3.40 (GPL-2.0 / Artistic) | `tools/vendor/himemx/3.40/source-and-binaries.zip` |
| FreeDOS kernel, FreeCOM, Doszip (GPL-2.0) | `tools/vendor/freedos/1.4/{kernel,freecom,doszip}.zip` (each with `SOURCE/*/SOURCES.ZIP`), `manifest.json` |
| Patcher9x 0.9.91 (MIT, with libmspack LGPL-2.1) | `tools/vendor/patcher9x/0.9.91/source.zip` |
| UefiSeven 1.30, TouchI2cDxe usos1, PatchPAE3, fonts (permissive, bundled for completeness) | `tools/vendor/uefiseven/1.30`, the TouchI2cDxe patch/DSC/provenance, `tools/vendor/patchpae3/<commit>`, `tools/windows_xp_pae.c`, `assets/fonts` |

These sources also travel on the stick next to the binaries for CSMWrap,
ImDisk, MEMDISK, HimemX, FreeDOS and Patcher9x, so those obligations are
met on the medium itself.

**Covered by the written offer (`SOURCE-OFFER.txt`) plus exact upstream
URLs** (26 components with `"offer": true`): Linux 6.18.35 (kernel.org
tarball + Alpine `aports` `main/linux-lts`), systemd-boot 260.2 (systemd
tag v260.2 + aports commit `c329463d`), EfiFs 1.12 (GitHub tag + its GRUB
submodule), and every GPL/LGPL Alpine package: busybox, apk-tools,
alpine-baselayout, kmod, cryptsetup-libs, device-mapper (lvm2), mkinitfs,
kexec-tools, acl, util-linux, mtools, dosfstools, lz4, ntfs-3g, rsync,
zstd, smartmontools, dmidecode, pciutils, hwdata, gcc runtime, wimlib,
fuse3. Each Alpine entry names its aports commit
(`https://gitlab.alpinelinux.org/alpine/aports/-/tree/<commit>/<repo>/<origin>`,
from the package's `.PKGINFO`) and its upstream tarball; the Alpine
distfiles mirror is `https://distfiles.alpinelinux.org/distfiles/v3.24/`.
Table: `tools/release/licenses/alpine/SOURCES.txt`. The offer text in
`assemble_release.py` promises the source for three years on request; the
maintainer must be able to honour it, i.e. keep copies of these tarballs
(they are not in the repository).

GenAHCI 6.3.0.1 (GPL-3.0): the upstream source at commit b936a0d8 is in the sources zip (G7).

## 7. Gaps

Fixed in this audit (no payload change):

- G1 EfiFs `ntfs_x64.efi` (GPL-3.0-or-later) had no licence, source or
  offer anywhere. Now: GPL-3.0 text, `SOURCES.txt`, written offer.
- G2 systemd-boot (LGPL-2.1-or-later): same. Now: LGPL-2.1 text,
  `SOURCES.txt`, offer.
- G3 Linux kernel and modules (GPL-2.0): same. Now: GPL-2.0 text,
  `SOURCES.txt`, offer.
- G4 35 Alpine source packages in the initramfs had no notices. Now: one
  entry per origin with version, PKGINFO licence, aports commit, upstream
  URL, GPL/LGPL/Apache texts and the offer.
- G5 wimboot: the MODIFIED kexec variants had their source only in the git
  tree. Now: upstream tarball, generator and assembly in the sources zip.
- G6 FreeDOS: vendor folder had no extracted licence texts (the ESP copy was
  fine). Now: kernel COPYING and Doszip LICENSE extracted.
- G8 Go runtime and `golang.org/x/sys` (BSD-3-Clause) compiled into the
  installer had no notice. Now in the release `LICENSES/go-runtime`.
- G9 Zig standard library / compiler-rt and the statically linked musl in
  `usos-fb-ui` had no notice. Now `tools/zig/LICENSE` and musl `COPYRIGHT`.

Remaining GAPs:

- **G7 GenAHCI 6.3.0.1 (GPL-3.0), XP package: closed by the source pin.**
  <https://github.com/GeorgeK1ng/GenAHCI> has no LICENSE file; its tree and
  the release archive carry the same `gpl.txt` (GPL-3.0). The only tag
  (`GenAHCI`) is commit b936a0d8bdf4 (2023-08-21 21:34 UTC); the release
  with `GenAHCI_6.3.0.1.7z` was published 21:42 from it. The binaries are
  FileVersion 6.3.0.1 with PE link times 21:40:00/01, between the last
  source upload and the release; `gpl.txt` is identical, `genahci.inf`
  differs only by a dropped copyright header, and `txtsetup.oem` only by the
  storahci -> GenAHCI rename. A byte-exact rebuild was not possible: the
  build needs the Microsoft WDK 7600.16385.1 (not redistributable, not
  installed) and the binaries are self-signed at build time. Pinned in
  `tools/vendor/genahci/6.3.0.1-src/` (tarball SHA-256 4dda80ca...,
  `SOURCES.txt`, `gpl.txt`) and bundled in the sources zip. Proposal: build
  the USOS copy from this pinned source with WDK 7600 and ship that build,
  so the binary provably corresponds to the offered source.
- **G10 shim**: the OpenSSL/SSLeay licence of the OpenSSL copy linked into
  shim (Cryptlib) is not reproduced; take `Cryptlib/OpenSSL/LICENSE` from
  the shim 16.1 source and add it to the `shim` entry.
- **G11 Linux kernel aports commit**: the netboot files carry no PKGINFO;
  record the aports commit that built linux-lts 6.18.35-r0 in
  `tools/release/licenses/linux-lts/SOURCES.txt` before publishing.
- **G12 permissive notices of Alpine packages**: the copyright notices of
  alpine-keys, mdev-conf, json-c, libeconf, ncurses (X11), xxhash, lz4
  (BSD part), popt, zlib, libuuid (BSD-3-Clause), the MPL-2.0 text for
  ca-certificates and the GCC Runtime Library Exception are not collected.
  Remedy: take the licence files from the matching `-doc` packages or the
  upstream tarballs and add them to `tools/release/licenses/alpine/`.
- **G13 six base-initramfs packages** (kmod, cryptsetup-libs,
  device-mapper-libs, json-c, xz-libs, mkinitfs) have no recorded version:
  the netboot initramfs carries no apk database. Remedy: read them from the
  3.24.1 `APKINDEX` of `main` (not only the ISO subset).
- **G14 Microsoft files inside the USOS payload and the XP package: closed
  by maintainer decision** (kept for preservation, at the maintainer's own
  risk, removed on request; section 5).
- **G15 system icons** (`UI/Icons/Systems/*.png`, 22 files, and their
  renderings in `bios-ui.bin`): **origin recorded, kept by maintainer
  decision.** The maintainer generated them with ChatGPT (OpenAI image
  generation). They depict Windows and MS-DOS logos, which are Microsoft
  trademarks; USOS is not affiliated with or endorsed by Microsoft.
- **G16 USOS's own licence: closed (2026-09-28).** USOS is
  `GPL-3.0-or-later`: `LICENSE` (full GPL-3.0 text) and `NOTICE`
  ("Copyright (C) 2026 Maksymilian and the USOS Authors", SPDX line, scope) at the
  repository root; `build-info.ini` records `license=GPL-3.0-or-later`;
  contributions under `CONTRIBUTING.md` (contributor licence grant that
  also allows other licence terms). Source files carry no per-file headers
  (the repository never had them). The third-party components stay under
  their own licences as separate programs aggregated with USOS
  (THIRD-PARTY-NOTICES.txt says so). Linking check: USOS's own binaries
  link only GPL-compatible code: the Zig menus with the Zig runtime /
  compiler-rt (MIT) and musl (MIT, usos-fb-ui); the Go installer with the Go
  runtime and golang.org/x/sys (BSD-3-Clause); embedded fonts Apache-2.0 /
  OFL-1.1; the XP PAE helper is an adaptation of PatchPAE3 (CC-BY-4.0,
  compatible with GPLv3). The modified wimboot kexec variants
  (GPL-2.0-or-later) and CSMWrap (LGPL) are separate programs with their
  sources in the sources zip.
- **G17 reproducibility inputs outside git**: `vista-support.cpio` is built
  from the git-ignored `artifacts/vista/hardware-success-v11-20260920-235629`,
  and the Windows 7 CABs from git-ignored MSUs. Not a licence issue for the
  binaries, but deleting that folder makes the Vista payload unbuildable.
- **G18 Linux syscall note** text is not in the repository (referenced in
  `linux-lts/SOURCES.txt` only).

Follow-ups at payload level (not changed here, the payload is covered by
golden tests):

- **F1** The ESP carries no licence next to `ntfs_x64.efi` (GPL-3.0),
  `systemd-bootx64.efi` (LGPL-2.1), `micro-linux/vmlinuz-virt` and
  `initramfs-usos` (GPL-2.0 and the Alpine licences),
  `windows-native/wimboot` (GPL-2.0) or the Zig/musl runtime. A stick
  passed on without the release zip therefore lacks these notices. Suggested
  fix: add `EFI/USOS/licenses/<id>/` from `tools/release/licenses` and a
  `THIRD-PARTY-NOTICES.txt` to the payload in the next payload build.
- **F2** The installer shows no third-party notice (Go BSD-3-Clause); an
  "About / licences" line pointing at the release `LICENSES` folder, or the
  notices text embedded in the executable, would cover it.

Release blockers in the audit's view: G7 (for the XP package), G14 (for
the stick payload and the XP package), G15 and G16 need a maintainer
decision before 1.0 is published; the rest are documentation completions.
