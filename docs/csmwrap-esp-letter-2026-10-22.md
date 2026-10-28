# CSMWrap ESP without a drive letter (2026-10-22)

X470, Windows 10 22H2 x86 and Embedded 8.1 x86 on NVMe (win-x86-uefi-csmwrap):
both work, but Explorer shows the 64 MiB CSMWRAP helper partition as a drive.
It must stay invisible like a GPT ESP, and the firmware must still boot
`\EFI\BOOT\BOOTX64.EFI` (CSMWrap) from it.

## The partition today

Every CSMWrap path writes the same ESP: `tools/xp_csmwrap_esp.sh` (XP, 2003,
2000, POSReady, NT4 / NT 3.x via `nt4_csmwrap_target.sh`, 9x via
`w9x_csmwrap_target.sh`, Vista / 7 / 2008 / 8.1 / 10 via
`vista_csmwrap_target.sh`, image-to-disk) and `src/platform/bios/dos_csmwrap_esp.zig`
(DOS / Windows 1-3.x, 9x ESP image): 64 MiB FAT16, label CSMWRAP, **MBR type
0xEF** (EFI System Partition per the UEFI specification, 5.2.1), inactive,
at the disk tail. 0xEF is the only MBR type the UEFI spec defines for an
ESP; the firmware notes (`docs/design/bios-via-csmwrap.md`,
`csmwrap-integration.md`) are all from this type. The type was not changed:
a hidden type (0x1C, 0x27, ...) would rest on each firmware's partition
driver accepting a non-ESP type for the removable-path boot, which nothing
here has tested on the X470 AMI firmware.

## Who sees it, and why

| Family | Sees CSMWRAP? | Why |
|---|---|---|
| DOS, Windows 1.x-3.x, 95 / 98 / ME | no | DOS / IOS give letters only to the FAT types 01/04/06/0B/0C/0E |
| NT 3.x, NT4 | no | `IsRecognizedPartition` (NT4/NT5 headers) has no 0xEF; unrecognised = no volume letter |
| 2000, XP, 2003, POSReady 2009 | no | NT 5 ftdisk: `!IsRecognizedPartition(type)` -> `isHidden = TRUE` (supplied NT 5.2 source, `newft\ftdisk.cxx`); 0xEF is not in the pre-Vista list |
| Vista / 7 / 2008 x86, Vista / 2008 x64, 8.1 / 10 x86 | **yes** | the Vista+ `IsRecognizedPartition` lists `PARTITION_SYSTEM` (0xEF) (Windows SDK 10.0.26100 `ntdddisk.h`), so the mount manager gives the FAT16 volume the next letter on the first boot |

Host check, Windows 10 19045 (this PC), a fixed VHD with one 64 MiB FAT16
partition of MBR type 0xEF and a fresh disk signature: attached, it got
`M:` (label CSMWRAP), as on the X470.

## Fix (NT 6+ only)

The mount manager stores "this volume has no drive letter" in
`HKLM\SYSTEM\MountedDevices` as a value whose name starts with `#` and whose
data is the volume's unique ID (MBR: 4-byte disk signature + 8-byte byte
offset). `mountvol X: /D` writes exactly that. Host checks (Windows 10 19045,
same VHD):

* `mountvol M: /D`, detach, attach: no letter (the value `#{...}` = ID stays);
* a new disk signature with only a `#{55534f53-...}` value = ID written into
  `MountedDevices` *before* the first attach: the volume arrived without a
  letter (`\\?\Volume{...}` only). Control without the value: letter given.

So the WinPE step after Setup writes that value into the installed
system's offline SYSTEM hive (and drops a `\DosDevices\X:` value with the
same ID, if Setup copied one), before Windows ever boots:

* `tools/windows_csmwrap_hide.h` (shared): `RegLoadKeyW` of
  `<Windows>\System32\config\SYSTEM`, the edit, `RegUnLoadKeyW`. Value name
  `#{55534f53-4353-4d57-<signature>-<LBA>}` ("USOS" "CSMW").
* 32-bit Vista / 7 / 2008 / 8.1 / 10: `usos-x86-csmwrap.exe hideesp`, called
  by `usos-x86-csmwrap.cmd` after Setup (every version) and before `after`;
  it checks that the MBR has a type 0xEF entry at `esp_start` of
  `usos-csmwrap-target.ini` first.
* Vista / 2008 x64 (CSMWrap): `usos-vista-install.exe` after the USB arming
  and the NVMe / mpart steps (`esp_start` of `usos-vista-target.ini`).

Never fatal: a failure only logs a line (the ESP then shows a letter as
before). The MBR, the partition type, the ESP contents and the boot chain
(firmware -> CSMWrap -> SeaBIOS -> MBR -> bootmgr) are unchanged, so no
QEMU boot-chain run was needed. NT 5 and older are not touched.

Existing installations keep their letter (the fix acts at install time); on
those, `mountvol <X>: /D` as administrator removes it for good.

## Tests

* `tools/tests/test_csmwrap_esp_hide.py`: the edit on a scratch HKCU key
  (marker written with a >2^31 LBA, ESP letter removed, other values kept,
  second run idempotent) and the wiring (cmd order, Vista x64 call,
  `esp_start` in the target ini, ESP type 0xEF unchanged).
* Not run: the hive load inside a real WinPE (this host refuses `reg load`
  of any hive file with error 206, so only the edit runs on the host; the
  load/unload is the same API sequence as the X470-proven lowmem step).

## X470 check

Fresh install of Windows 10 x86 (or 8.1 x86) through the CSMWrap path: after
the first logon, Explorer shows no CSMWRAP drive (yes/no). The log line
`hideesp: no-drive-letter entry for the CSMWrap ESP written` is in the
WinPE startup log.
