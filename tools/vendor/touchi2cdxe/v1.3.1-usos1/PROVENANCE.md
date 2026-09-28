# TouchI2cDxe v1.3.1 + USOS patch 1

UEFI DXE driver that produces `EFI_ABSOLUTE_POINTER_PROTOCOL` for
HID-over-I2C touchscreens on AMD FCH DesignWare I2C controllers (AMDI0010):
FCH AOAC power-up, a polled DesignWare I2C master, the HID-over-I2C transport
and a HID report parser. USOS starts it from `\EFI\USOS\touchi2c_x64.efi` on
supported handhelds (`src/platform/uefi/touch_driver.zig`), so the ROG Ally's
Novatek touchscreen works in the boot menu. Research: `docs/research/uefi-i2c-touch.md`.

| File | What it is | SHA-256 |
| --- | --- | --- |
| `TouchI2cDxe.efi` | the driver, built as below, **unsigned** (build.bat signs the copy on the ESP with the USOS MOK key) | `35d511bca22407a6bcb9e8a56d6bac4e4c8a45d27b60cdb21ccf10a49d0d4ff5` |
| `usos-rc71l.patch` | the USOS changes, `git apply` on the upstream tree | `76a313ec6b641839946984e40a27527ad2ee523591e346d68b9ff4b4274252a2` |
| `UsosTouchPkg.dsc` | minimal EDK2 platform description (MdePkg only) used for the build | `72500443e23e2b1d9bd9ff6ff7652c8999b81aaeec1b85f57ca8986dfe7f74f8` |
| `LICENSE` | upstream licence, BSD-2-Clause-Patent (copied to `EFI/USOS/licenses/touchi2cdxe/`) | `da440a8b65d810013ad1d2f56ec0c961f123ad70c75564b794d96283a03c3ac3` |
| `manifest.json` | the same pins in machine-readable form (read by `usos-efisign release` and `tools/build_touchi2cdxe.ps1`) | |

## Source

- Upstream: <https://github.com/jlobue10/TouchI2cDxe>, tag `v1.3.1`,
  commit `cd673f65049f4bd34dd511ca7a28c345f41efac0` (2026-08-01).
- Licence: BSD-2-Clause-Patent, "Copyright (c) 2026, jlobue10 and contributors".
- `git archive --format=tar.gz --prefix=TouchI2cDxe/ cd673f65...` SHA-256
  `77870109fa31ad92ffae1ddabe02e8a4ec329d363285319723ca10e6a2834930`.
- SHA-256 of every source file at that commit (git blob content, LF) is in
  `manifest.json` (`upstream.source_sha256`); the build script checks them
  before applying the patch.

## USOS patch (`usos-rc71l.patch`, only `src/TouchI2cDxe.c`)

1. **Exact RC71L profile.** The upstream "ROG Ally 2023 (sweep; Goodix GT7868Q
   expected)" entry becomes
   `{ "ROG Ally RC71L (Novatek NVTK0603)", NULL, "RC71L", NULL, DW_I2C_FCH_BASE_0, NVTK_I2C_ADDR, 0x0000, FCH_AOAC_DEV_I2C0, 0 }`,
   a copy of the Xbox Ally X (RC73XA) entry: `\_SB.I2CA` (AMDI0010 `_UID 0`,
   `0xFEDC2000`, AOAC device 5), panel address `0x01`, HID descriptor register
   `0x0000`. Only that one tile is powered and probed, so the other FCH I2C
   buses (IMU on I2CB, amplifiers on I2CD) are never touched. Constants: the
   RC71L DSDT and Linux probes (see the research doc).
2. **Comments fixed.** The header lists the RC71L; the per-device constant
   block documents it; the "Goodix GT7868Q expected" note is gone (the RC71L
   DSDT names a Novatek `NVTK0603`, VID `0x0603`, PID `0xF200`).
3. **No ESP log by default.** New compile-time switch `TOUCH_ESP_LOG`
   (default `0`). Upstream appends to `\TouchI2c.log` on the volume the
   driver was loaded from on every boot; with `0` it writes nothing unless the
   loader passes the UTF-16 load option `log=<path>` together with a
   `LoadedImage->DeviceHandle`. USOS passes
   `log=\EFI\USOS\Logs\touchi2c.log` only when `EFI\USOS\diagnostic-boot.flag`
   exists. `-DTOUCH_ESP_LOG=1` restores the upstream behaviour.
4. **No console output by default.** New switch `TOUCH_CONSOLE_PRINT`
   (default `0`): the load-time `Print()` status lines would draw over the
   USOS graphical menu.
5. `TOUCH_DRIVER_VERSION` is `"v13-usos1"`, so logs name this build.

The patch is a candidate for upstream (items 1 and 2 in particular).

## Build (Windows, no WSL/container, everything outside the repo)

Scripted by `tools/build_touchi2cdxe.ps1` (not part of `build.bat`; EDK2 is
not a submodule and not a normal-build dependency):

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_touchi2cdxe.ps1            # default %LOCALAPPDATA%\USOS\edk2-build
powershell -ExecutionPolicy Bypass -File tools\build_touchi2cdxe.ps1 -WorkDir C:\Users\me\usos-edk2   # short path if needed
```

What it does:

1. Fetches TouchI2cDxe at `cd673f65...` (depth 1), checks the source hashes,
   applies `usos-rc71l.patch`.
2. Fetches EDK2 `edk2-stable202411` = commit
   `0f3867fa6ef0553e26c42f7d71ff6bdb98429742` (the commit upstream CI builds
   with), depth 1, plus only three submodules: `BaseTools/Source/C/BrotliCompress/brotli`,
   `MdePkg/Library/MipiSysTLib/mipisyst`, `MdePkg/Library/BaseFdtLib/libfdt`
   (the last two only because `MdePkg.dec` names their include paths).
3. Downloads NASM 2.16.03 win64 (`nasm-2.16.03-win64.zip`, SHA-256
   `3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6`).
4. Builds BaseTools with the already installed Visual Studio 2022 Build Tools
   (32-bit host, `vcvars32.bat` + `edksetup.bat Rebuild VS2022`).
5. Copies the patched `src/` and `UsosTouchPkg.dsc` to `edk2/UsosTouchPkg/`
   and runs `build -a X64 -t VS2022 -b RELEASE -p UsosTouchPkg/UsosTouchPkg.dsc -n 1`.
   The DSC maps only MdePkg libraries (`BaseDebugLibNull`, so `DEBUG()` is
   compiled out) and adds `/Brepro` for the MSVC compiler and linker.
6. Compares the SHA-256 of `Build/UsosTouch/RELEASE_VS2022/X64/TouchI2cDxe.efi`
   with `manifest.json` (`-Vendor` replaces the vendored file instead).

Toolchain used for the vendored binary: Visual Studio 2022 Build Tools 17.14
(MSVC 14.44.35207, cl 19.44.35227), Windows SDK 10.0.26100, Python 3.13.7,
NASM 2.16.03, git 2.x. Footprint outside the repo: about 350 MB (the shallow EDK2
checkout with BaseTools), deletable at any time. Build time about 1 minute
for the driver after a 2-minute BaseTools build.

## Reproducibility

- Two clean rebuilds in the same workspace gave the identical file
  (`35d511bc...4ff5`, 23 040 bytes). The PE timestamp is 0 (GenFw) and no
  build path or PDB path is embedded.
- A from-scratch run of `tools/build_touchi2cdxe.ps1` in a different folder
  (a short `-WorkDir` under the user profile, fresh clones and NASM download) produced the
  same SHA-256 on 2026-09-24.
- Another MSVC version can change the code bytes. That is expected: the
  vendored file is the reference and the release signs exactly it; rebuild
  with `-Vendor` and update this file and `manifest.json` when moving on.
- Upstream CI builds with GCC5 on Ubuntu; that binary differs (different
  compiler) and also lacks this patch, so it is not used.

## Signing and loading

`usos-efisign release` (build.bat) copies `TouchI2cDxe.efi` to
`zig-out/usb/EFI/USOS/touchi2c_x64.efi` after checking the manifest hash and
signs it in place with the USOS MOK key (like `ntfs_x64.efi`). USOS loads it
through `verified_image.zig` (SHIM_LOCK verify + USOS PE loader under shim 16,
plain LoadImage with Secure Boot off) only when SMBIOS matches
(`src/flow/touch_driver_policy.zig`) and `usos-settings.ini` does not say
`touch_driver=off`.
