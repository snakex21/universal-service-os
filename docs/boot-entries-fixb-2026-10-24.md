# One firmware boot-menu entry per USOS stick (2026-10-24)

Status: **X470 PASS** (build B261024-175533-AB83E998, Kingston stick).
Branch `feat/boot-entries-fixb`, merged into `test/x470-98se-qemu`.

## What

USOS sets GPT attribute bit 1 (`EFI_PART_NO_BLOCK_IO_PROTOCOL`) on the DATA
and WORK partitions. The firmware then creates no partition handle for them,
so its one-time boot menu (F11 on the X470) shows only the ESP: one entry per
stick instead of three ("UEFI: <disk>, Partition N" for ESP, DATA and WORK).

## Why it works now

The earlier attempt was rejected because the UEFI NTFS path needs partition
handles for DATA/WORK. The fix gives USOS its own handles:

- `src/platform/uefi/partition_handles.zig` (called from
  `ntfs_driver.loadAndConnect`): for every whole-disk Block I/O with a USOS
  GPT, for DATA/WORK with bit 1 and no existing handle, it installs a child
  handle with the EDK2 PartitionDxe device path layout
  (disk path + `HD(n, GPT, PARTUUID, start, size)`) and a Block I/O that
  forwards to the parent disk with spec bounds checks. Idempotent; if the
  firmware ignores bit 1 and made a handle anyway, nothing is added.
- The NTFS driver, WORK discovery, chainload from WORK and the Windows boot
  manager (BCD read from WORK) use these handles.
- Paths that never needed firmware partition handles stay unchanged: DATA
  catalog (whole-disk reader), Legacy BIOS Core, CSMWrap/SeaBIOS, micro-Linux
  prep env, usosmpart (checks only bits 60/62/63). Windows ignores bit 1;
  DATA keeps its drive letter.
- The earlier "rejected" result in TESTING.md was partly a probe false
  negative (efifs returns BUFFER_TOO_SMALL for EFI_FILE_SYSTEM_INFO in a
  512-byte buffer); the probe now also recognises volumes by marker files.

## Switch

`hideDataWorkFromFirmwareMenu` in
`installer/internal/winhost/gpt_buffer_windows.go` (default `true`).

- Fresh install sets bit 1 on DATA and WORK.
- Update USOS (stage ExposeWORK) migrates existing sticks; with the switch
  `false` an update clears bit 1 again (old behaviour, three entries).
- Medium verifiers accept DATA/WORK attributes 0 or bit 1 only; the ESP must
  stay 0.

## Legacy BIOS Core size

The new `gpt.Partition` fields grew the Legacy Core by 196 bytes and
`build_legacy_bios.ps1` refused it (minimum 4096 free bytes). On freestanding
x86 the fields are compiled out; the Core is back to exactly 4096 free bytes.
The Core is at its limit: any further growth needs a slimming step first.

## Results

Host: `zig build test`, `go test` for `internal/winhost`, `localupdate`,
`install` pass; QEMU/OVMF `tools/tests/run_gpt_partition_handles_qemu.ps1`
PASS (baseline and bit 1, incl. host `bootmgfw.efi` reading its BCD from
WORK); usosmpart harness 10/10.

X470 (ASRock X470 Master SLI/ac, AMI), 2026-10-24:

- F11 shows exactly one entry for the Kingston stick.
- USOS menu lists the systems from the hidden DATA partition.
- A Windows 10/11 WORK handoff reached Windows Setup.

## Not tested

- WIMBoot and VHDBoot (`vhd=[locate]`) through bootmgr with bit 1.
- Secure Boot enabled.
- Firmware from other vendors (and other AMI boards), aarch64.
