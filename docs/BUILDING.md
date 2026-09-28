# Building USOS

How to build USOS from the repository, with network or fully offline from
the release build kit (`USOS-<version>-buildkit.zip`).

## Requirements

| Tool | Version | Where it comes from |
|---|---|---|
| Windows | 10 or 11, x64 | — |
| Windows PowerShell | 5.1 (built in) | — |
| Zig | 0.16.0 | `tools\zig` in the repository (identical to the official `zig-x86_64-windows-0.16.0.zip`, also in the kit) |
| Go | 1.26.2 | installed Go, or the kit (`toolchains\go1.26.2.windows-amd64.zip`) |
| Python | CPython 3.13 x64, with Pillow 10.4.0 | installed Python; Pillow from pip or the kit wheel |
| 7-Zip | 25.01 x64 | `C:\Program Files\7-Zip`, or the kit (`USOS_7Z`) |
| Git + Git LFS | any recent | to clone (`payload.zip` is in LFS) |

No Node, .NET SDK, WSL or Docker is needed. QEMU (`tools\qemu`) is used by
the QEMU tests and the CSMWrap VM build, not by `build.bat`.

The Secure Boot signing key lives outside the repository
(`%APPDATA%\USOS\signing`). Without it `build.bat` emits the same layout
unsigned: such a stick boots only with Secure Boot off.

## Online build

```
build.bat
powershell -ExecutionPolicy Bypass -File tools\tests\run.ps1 unit
```

`build.bat` downloads what is missing and checks every download against a
pinned SHA-256: the Alpine 3.24.1 micro-Linux files and packages
(`tools\micro_linux.lock.json`, cached in `tools\cache\alpine`), the EfiFs
NTFS driver (`tools\cache\efifs`), and the Go modules of `installer\go.mod`.
Some inputs are not in git and not downloadable (the Windows 7 update MSUs,
git-ignored vendor archives, the frozen Vista payload in
`artifacts\vista\hardware-success-v11-20260920-235629`): they come from the
build kit.

The release folder (`zig-out\release-1.0\`):

```
powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1 [-Data L:\] [-SkipBuild] [-IssuesUrl https://github.com/<owner>/<repo>/issues]
```

It also builds the build kit (`tools\release\make_buildkit.py`, after
`tools\release\fetch_buildkit_inputs.py` has checked or fetched the pinned
downloads of `tools\release\buildkit.lock.json`).

## Offline build with the build kit

1. Clone the repository (with Git LFS) and extract
   `USOS-<version>-buildkit.zip` somewhere with a short path, e.g.
   `C:\usos-kit`. If the kit was split, join the parts first:
   `copy /b USOS-<version>-buildkit.zip.001+USOS-<version>-buildkit.zip.002 USOS-<version>-buildkit.zip`.
2. Optional check, writes nothing:
   `powershell -ExecutionPolicy Bypass -File tools\release\use_buildkit.ps1 -Kit C:\usos-kit\USOS-<version>-buildkit -DryRun`
3. Build:
   ```
   set USOS_BUILDKIT=C:\usos-kit\USOS-<version>-buildkit
   build.bat
   ```

With `USOS_BUILDKIT` set, `build.bat` first runs
`tools\release\use_buildkit.ps1`, which

- checks every kit file against `MANIFEST.json` (SHA-256 and size);
- restores `inputs\<repo path>` into the repository, never overwriting a
  file that differs;
- unpacks Zig into `tools\zig` if it is missing (an existing one must be
  the official 0.16.0 `zig.exe`), and Go, 7-Zip and Pillow into
  `tools\cache\buildkit`;
- writes `build\generated\buildkit-env.cmd`, which `build.bat` loads: the
  kit's Go first in `PATH`, `GOTOOLCHAIN=local`, `GOPROXY=file://` on the
  kit's module cache, `GOSUMDB=off` (hashes in `go.sum` are still checked),
  `USOS_7Z`, `PYTHONPATH` with Pillow, and `USOS_OFFLINE=1`, which makes
  every downloader fail instead of fetching.

Tested 2026-09-28: a fresh clone at the 1.0.0 commit, the kit, the proxy
set to a dead address (`HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:9`) and an
empty Go module cache: `build.bat` completed (see
`docs/HANDOFF-2026-09-28-release.md` for the result).

## Kit contents

| Kit path | Content | Licence |
|---|---|---|
| `toolchains\zig-x86_64-windows-0.16.0.zip` | official Zig 0.16.0 | MIT |
| `toolchains\go1.26.2.windows-amd64.zip` | official Go 1.26.2 | BSD-3-Clause |
| `toolchains\7zip\` | 7-Zip 25.01 x64 (`7z.exe`, `7z.dll`, `License.txt`) | LGPL-2.1+ with BSD parts and the unRAR restriction |
| `python\pillow-10.4.0-cp313-cp313-win_amd64.whl` | Pillow (used by `tools\generate_legacy_icons.py` and the font tools) | MIT-CMU (HPND) |
| `go-mod\cache\download\` | `golang.org/x/sys v0.47.0` as a Go proxy tree | BSD-3-Clause |
| `inputs\tools\cache\alpine\` | Alpine 3.24.1 virt ISO, netboot kernel/initramfs/modloop (linux-lts 6.18.35) and the 36 pinned packages of the micro-Linux | per package, see `docs/LICENSES-AUDIT.md` (kernel GPL-2.0, BusyBox GPL-2.0, musl MIT, ...) |
| `inputs\tools\cache\efifs\ntfs_x64.efi` | EfiFs 1.12 NTFS driver | GPL-3.0-or-later |
| `inputs\tools\cache\freedos\FD14-LiteUSB.zip` | FreeDOS 1.4 LiteUSB (provenance of the vendored FreeDOS files) | GPL and others, per package |
| `inputs\tools\vendor\...` | git-ignored vendor archives: FreeDOS, HimemX, ImDisk, Patcher9x, Syslinux and wimlib source zips, Windows 7 NVMe assets, GenAHCI, the XP integrator tree | their own licences |
| `inputs\media\Systems\Windows\Windows 7\Updates\*.msu`, `inputs\tools\vendor\windows7-kmdf\*.msu` | Windows 7 SHA-2, NVMe and KMDF updates | Microsoft; kept for preservation at the maintainer's own risk, removed on request |
| `inputs\artifacts\vista\hardware-success-v11-20260920-235629\` | frozen Vista v11 payload (hardware-verified) | USOS code + Microsoft files, as above |
| `csmwrap-vm\apk\v3.24\` | partial Alpine v3.24 mirror (signed `APKINDEX.tar.gz` of main and community + 52 packages) for the CSMWrap build VM | per package |

Toolchain licences and sources: the Zig and Go archives carry their own
`LICENSE` files and are the official releases (hashes published on
ziglang.org and go.dev); the GPL/LGPL source offer for the Alpine packages
and the kernel is in `SOURCE-OFFER.txt` of the release.

## Rebuilding CSMWrap 3.1.2-usos1 (optional)

The release uses the vendored, hash-pinned CSMWrap binary; `build.bat`
does not rebuild it. To rebuild it from source in a throwaway Alpine VM:

```
powershell -File tools\build_csmwrap.ps1                          (online: apk + github.com)
powershell -File tools\build_csmwrap.ps1 -OfflineMirror <kit>\csmwrap-vm\apk   (offline)
```

Offline, the host serves the kit's Alpine mirror to the VM over HTTP and
the VM builds from the vendored source archive
(`tools\vendor\csmwrap\3.1.2-src\csmwrap-3.1.2-src.tar.xz`, the
deterministic archive of the pinned CSMWrap commit and submodules) instead
of cloning. Tested 2026-09-28: the offline rebuild gave byte-identical
`csmwrapx64.efi` (usos1 and upstream) and source archive hashes
(`tools/vendor/csmwrap/3.1.2-usos1/manifest.json`).

## Not in the kit

- **Windows ISOs** (never shipped), the WinPE PE10 donor (a separate release
  asset) and the XP ISOs the XP packages are derived from.
- **TouchI2cDxe** is built outside the repository from an EDK2 checkout
  (`tools\build_touchi2cdxe.ps1`, network); the release uses the vendored,
  MOK-signed binary.
- **GenAHCI** needs the Microsoft WDK 7600.16385.1 to rebuild
  (`tools/vendor/genahci/6.3.0.1-src/SOURCES.txt`); the release uses the
  upstream 6.3.0.1 binaries.
- **Python and Git** themselves.
- The **signing key**.
