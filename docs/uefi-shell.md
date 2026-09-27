# Built-in UEFI Shell

Utilities -> **UEFI Shell** (UEFI menu only; the Legacy BIOS menu has no
such row) starts the EDK2 UEFI Shell so users can run their own EFI tools:
BIOS/VBIOS flashers, GPU/VRAM testers (NVIDIA MATS/MODS style), memtest86
`.efi` and similar. USOS bundles none of those tools.

## What is bundled

| Item | Value |
| --- | --- |
| Binary | `ShellBinPkg/UefiShell/X64/Shell.efi`, UEFI Interactive Shell 2.2, unmodified |
| Source | official TianoCore release asset `ShellBinPkg.zip` of tag `edk2-stable202002` (commit `4c0f6e34`) - the last EDK2 stable tag that ships a prebuilt Shell |
| Pins | `tools/vendor/uefi-shell/edk2-stable202002/manifest.json` (zip, Shell.efi and License.txt SHA-256) |
| Licence | BSD-2-Clause-Patent (`License.txt` of the same tag) |
| Refetch/verify | `powershell -File tools/fetch_uefi_shell.ps1` (verify) / `-Write` (refetch) |

At release, `usos-efisign release` copies it hash-checked to
`EFI/USOS/shell/Shell.efi` and signs it with the USOS MOK key, like the NTFS
and touch drivers. It gets no `.sbat` section (its PE headers have no room
for another section): shim requires SBAT only in the second stage it starts
itself; images USOS starts later are checked against db/dbx/MOK, as the
Secure Boot probe test already shows for MOK-signed children. `License.txt`, `SOURCES.txt` and the USOS
`startup.nsh` (`assets/uefi-shell/startup.nsh`) go next to it.

## How it is launched

`src/platform/uefi/uefi_shell.zig`, called from the Utilities list
(`manual_utilities.zig`, built-in row 3 after Secure Boot, Drivers, Theme):

1. `ntfs_driver.loadAndConnect` starts the bundled read-only efifs NTFS
   driver (`EFI\USOS\ntfs_x64.efi`, MOK-signed) once and connects it to every
   Block I/O handle. The menu itself reads DATA with its own NTFS parser, so
   without this step the firmware has no file system for DATA. The driver
   stays resident while the Shell runs.
2. `Shell.efi` is loaded through `esp_image_start.load` / `verified_image`
   (shim 16 LoadImage or SHIM_LOCK + security override on shim 15), so Secure
   Boot with the USOS MOK applies exactly as for user `.efi` images.
3. Load options `Shell.efi -delay 0`: no 5 s startup countdown. The Shell runs
   `startup.nsh` from its own folder; the script finds DATA (the fsN: with
   `\Systems`, `\Utilities` and `\Programs` and without `\EFI\USOS`), prints
   it and changes to `DATA\Utilities\UEFI Shell\Tools`.
4. `exit` returns to USOS, which rebuilds its framebuffer state and redraws
   the list.

## Where DATA appears

The Shell maps the FAT32 ESP and, through the efifs driver, the NTFS DATA
and WORK partitions (fs0:, fs1:, fs2: - the order depends on the firmware).
DATA is **read-only** in the Shell (efifs has no write support): a tool that
must write a file (ROM backup, log) has to write to the ESP (FAT32) or a
separate FAT32 stick.

User flow: copy the tool and its files to `DATA\Utilities\UEFI Shell\Tools\`
(the installer creates the folder and a bilingual README there), start
Utilities -> UEFI Shell, then `ls` and `tool.efi <options>`. By hand:
`map -r`, `fsN:`, `cd "\Utilities\UEFI Shell\Tools"`.

The folder `DATA\Utilities\UEFI Shell` is reserved: the utility catalog never
lists it as a utility (`utility_catalog.isReservedFolder`).

## Secure Boot

The Shell is MOK-signed and starts under Secure Boot (QEMU, Microsoft keys +
MokList: PASS); `map`, `ls`, `cp` and other built-ins work. It can **not**
start `.efi` tools while Secure Boot is on:

- unsigned tool: `Verification failed: Security Policy Violation` (expected);
- MOK-signed tool and Microsoft-signed tool (wimboot): `The image is not an
  application.` The signature passes, but shim 16 has replaced
  `gBS->LoadImage`, and the EDK2 Shell refuses an image whose
  `LoadedImage->ImageCodeType` is not `EfiLoaderCode`, which shim's loader
  does not set.

USOS publishes the volatile Shell variable `%usossecureboot%` (`on`/`off`,
gShellVariableGuid) before the start, and `startup.nsh` prints this
limitation when it is `on`. Ways out: Secure Boot off (most flashers and
testers are unsigned anyway), or a signed tool in
`DATA\Utilities\<Name>\Images\`, which the USOS menu starts directly (the
Secure Boot probe test shows MOK- and Microsoft-signed children load that
way). Fixing it inside the Shell would need a patched Shell or shim.

## Test

`python tools/tests/uefi_shell/run_uefi_shell_qemu.py` (elevated, after
build.bat with the signing key): GPT test disk with the release ESP and an
NTFS DATA, Secure Boot on (Microsoft keys, MokList with the USOS cert) and
off. It opens the Shell from the menu, checks that startup.nsh finds DATA,
`map -r`, `ls`, a MOK-signed and an unsigned tool from DATA and `exit`.
Screenshots and serial logs go to `artifacts/uefi-shell/`.
