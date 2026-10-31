<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS first Windows boot: evidence runner

`tools/minios/windows_firstboot_case.py` is a separately invoked QEMU-only
runner. It does not alter the normal installer or menu. Development of the
runner does not constitute any completed Windows boot gate.

The operator supplies `--boot-receipt`, its `--boot-sha256`, `--qemu-dir`,
`--plan`, a fresh reserved `--out` beginning `firstboot-`, and `--arch`
(`x86_64`, `ia32`, `bios`). Default endpoint is 600 seconds, with an explicit
60–900 second bound. A real accepted boot-provision receipt, the pinned native
filesystem gates, actual bcdboot result, BCD comparison and complete immutable
image chain are checked and deny-write locked before output/image creation.
Missing or merely asserted PASS fields refuse. BIOS provisioning must use the
analogous `minios-bios-boot-provision-v1` receipt (`mode=bios`, `arch=bios`).

The source with boot files remains immutable. A fresh QCOW2 overlay and a
`firstboot-base` internal snapshot preserve the pre-boot state. All Windows
targets use AHCI: x64 uses CPU `max`, 4096 MiB; IA32 and BIOS use `qemu32`,
2048 MiB. Reboots are allowed for specialize. UEFI variable storage is a local
copy; no host firmware entries, host mounts, physical disks or new full-disk
RAW/VHD exports are involved.

One QMP connection waits on events/process completion, with one fixed endpoint.
SHUTDOWN may end the wait earlier. The endpoint stops emulation, saves one PPM
screenshot, and quits QEMU. There are no status queries or repeated screenshots.
The screenshot is evidence, **never automatic OOBE/PASS detection**. Successful
transport produces `PENDING_REVIEW` and `windows_gate_passed=false`; a person
must review the screenshot and critical setup errors before the Windows gate.

Only after process completion, the runner independently validates the backing
chain and locks it read-only. `qemu-img map --output=json` locates physical data
within pinned chain files. A bounded seek/read adapter rejects unsupported
compression, external/unknown data, gaps, overlap and out-of-file extents. The
existing independent NTFS parser verifies the actual partition table and scans
the allocated MFT bitmap. It extracts only the two Panther logs and their
UnattendGC counterparts, resolving real parent references/sequence numbers;
total content is limited to 32 MiB. No mounted or fully extracted Windows tree
is needed. Empty logs are preserved, missing logs reported, and log extraction
failure remains evidence failure requiring diagnosis.

Capacity accounting reserves at most 2 GiB of genuinely new files against the
selected **closed** architecture scope and the approved aggregate plan. The
100 GiB actual free-space reserve and 150 GiB aggregate cap stay in force.
Retained bytes are checked after QEMU completes; this is a postcondition, not
a filesystem quota on a running guest. All overlays, snapshots, screenshots,
logs, maps and receipts remain until the user's acceptance.
