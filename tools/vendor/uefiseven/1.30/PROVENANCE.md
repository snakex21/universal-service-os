# UefiSeven 1.30: binary, sources and the USOS source build

UefiSeven is a UEFI application that puts a minimal Int10h (VESA) handler
into legacy memory at 0xC0000, points the real-mode IVT vector 0x10 at it,
fills VBE info from GOP, and then starts `<its own name>.original.efi`
(the Windows boot manager). Windows 7 (and its Server 2008 R2 twin) need
that handler to get past "Starting Windows" on UEFI Class 3 machines (no
CSM). USOS uses it through its own dispatcher (`tools/windows7_uefi_wrapper.zig`),
see `docs/design/win7-vista-no-csm.md`.

| File | What it is | SHA-256 |
| --- | --- | --- |
| `UefiSeven.efi` | the upstream release binary (`UefiSeven_1.30.zip`), **the one USOS ships** (`int10.efi`, `win7.efi`, `usos-win7-video.bin`) | `0a44a256cda725c22f1daadcf093fc4660b7214e6437968a4c8e119aed02a947` |
| `LICENSE.txt` | `UefiSevenPkg/License.txt`, copied to the ESP as `uefiseven-LICENSE.txt` | `30b044939b58ef5754ed7479e5ec930dd49d154dbf07f618825d4470c189f4dd` |
| `Int10hHandler.h`, `int10-source.json` | the generated handler table, pinned for `tools/build_windows7_int10_patch.py` | see `int10-source.json` |
| `src/` | the upstream sources at the release commit, unmodified (below) | per file in `manifest.json` (`upstream_source.sha256`) |
| `UsosUefiSevenPkg.dsc` | USOS platform DSC for building `src/` with current EDK2 and VS2022 | `9cde10959bded191d7ad8057ca2c26b751005f07f9e744ea5d6e114d77278fd2` |
| `manifest.json` | all pins in machine-readable form | |

## Licence

`UefiSevenPkg/License.txt` is the **2-clause BSD licence**, "Copyright (c)
2020, Seungjoo Kim; Copyright (c) 2016, Dawid Ciecierski" (Dawid Ciecierski
wrote VgaShim, the predecessor). Every C/H file carries the same notice
("BSD License", opensource.org/licenses/bsd-license.php). `Int10hHandler.asm`
adds Red Hat (2014) and Intel (2013-2014) notices from OVMF's `VbeShim.asm`,
under the same BSD terms. `IntelFrameworkPkg/` (one protocol header, one
DEC, one UNI) is Intel's EDK2 code, `SPDX-License-Identifier: BSD-2-Clause-Patent`.

Vendoring, modifying and redistributing source and binaries is allowed. The
conditions: keep the copyright notices in the sources, and reproduce the
licence text with binary redistributions. USOS does both: `src/` is
unmodified, and `uefiseven-LICENSE.txt` sits next to every copy of the
binary on the stick and on a target ESP. The licence has no patent grant
and no copyleft; it is compatible with the rest of USOS.

## Sources (`src/`)

- Upstream: <https://github.com/manatails/uefiseven>, tag `1.30` = commit
  `b8f0baba63e60e74d4ed3e86b15b76319d316b83` (2021-10-04, "minor update for
  debug messages"). This is also the tip of `master`: upstream has had no
  change since, so 1.30 is the final version.
- Tag archive (`/archive/refs/tags/1.30.tar.gz`) SHA-256
  `6b51f07e4f8fe72ef20fbd4fccdab0b4cf55c658b09a3b566f8faffa6c88b528`.
- Omitted: `UefiSevenPkg/Conf/` (upstream's GCC49 `tools_def.txt`,
  `target.txt`, `build_rule.txt`; 500 KB of EDK2 build configuration the USOS
  build does not use) and `.gitignore`.
- Files are byte-identical to the archive (LF or CRLF as upstream has them;
  `.gitattributes` keeps git from converting them).

## Source build (`tools/build_uefiseven.ps1`)

Not part of `build.bat`, like `tools/build_touchi2cdxe.ps1`. It reuses that
script's EDK2 workspace outside the repo (default `%LOCALAPPDATA%\USOS\edk2-build`:
EDK2 `edk2-stable202411` = `0f3867fa6ef0553e26c42f7d71ff6bdb98429742`,
BaseTools, NASM 2.16.03) and downloads nothing:

1. checks every `src/` file and the DSC against `manifest.json`;
2. copies `UefiSevenPkg/` and `IntelFrameworkPkg/` to `<WorkDir>\uefiseven-pkgs`
   (a `PACKAGES_PATH` entry, the EDK2 tree is not touched) with
   `UsosUefiSevenPkg.dsc`;
3. `MdeModulePkg.dec` names the include path of the
   `BrotliCustomDecompressLib/brotli` submodule, which the TouchI2cDxe
   workspace does not check out. EDK2 pins it to the same google/brotli
   commit `f4153a09f87cbb9c826d8fc12c74642bb2d879ea` as
   `BaseTools/Source/C/BrotliCompress/brotli`, so the script copies those
   headers once (UefiSeven includes none of them);
4. `build -a X64 -t VS2022 -b RELEASE -p UefiSevenPkg/UsosUefiSevenPkg.dsc`;
5. compares the result with `manifest.json` `source_build.efi_sha256`
   (`-OutFile` copies it somewhere, e.g. for QEMU).

Result: `UefiSeven.efi`, 54 784 bytes, SHA-256
`e601fdc482f96096625bc294f303eb984cdcbef989d24a51dbf9fce0cd0447c0`,
identical over repeated clean builds (PE timestamp zeroed by GenFw `--zero`,
`/Brepro`, no PDB path). Toolchain: Visual Studio 2022 Build Tools 17.14
(MSVC 14.44.35207), Python 3.13, NASM 2.16.03. Another MSVC version can change
the bytes; then record the new hash here and in `manifest.json`.

The upstream release binary (96 896 bytes) was built by upstream with GCC49
and an EDK2 of 2021, so it differs from the source build byte for byte;
behaviour is the same code. The DSC maps the same libraries as upstream's
(`BaseDebugLibNull`, so `DEBUG()` is compiled out; UefiSeven's own
`PrintDebug`/log file are unaffected) and adds `MdeLibs.dsc.inc`, which
current EDK2 requires.

## Which binary ships

The release binary. The source build is for QEMU trials and for any future
change to UefiSeven itself (for example the Int10 return fix that
`tools/build_windows7_int10_patch.py` now applies by patching bytes of the
release binary). Switching the shipped file is a separate, hardware-tested
change: replace `files.UefiSeven.efi` in `manifest.json`, the staged-payload
golden rows, and re-run the Windows 7 QEMU install.

## Secure Boot

Not signed, on purpose, like CSMWrap (`installer/cmd/usos-efisign/release.go`).
Windows 7 and Vista do not support Secure Boot, and the handler rewrites
legacy memory and the IVT. The Windows 7/Vista profiles require Secure Boot
off (`secure_boot_off` in `src/catalog/os_profiles.zig`).
