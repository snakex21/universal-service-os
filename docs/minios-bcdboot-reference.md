<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Host-only real bcdboot reference

`tools/minios/bcdboot_reference.py` requires a SHA-256-pinned complete
`minios-install-native-v1` PASS. Both filesystem gates must have read-only
`chkdsk` exit 0. The independently parsed disk layout, each native child
receipt and the ordinary read-only dynamic VHD are pinned before execution.
This helper never prepares Windows or attempts its first boot.

The caller supplies an explicit capacity plan, fresh output below the reserved
`1c23/oracle-diff` subtree, and the PowerShell executable. All generated files
stay in that application runtime. Final execution requires a clean Git HEAD.

The helper opens the accepted base with deny-write/delete sharing and retains
that handle through completion. `CreateVirtualDisk` creates only a new VHD
differencing child. `OpenVirtualDisk`/`GetVirtualDiskInformation` check type 4,
exact virtual size/sector size, resolved parent pathname and parent identifier
against the accepted type-3 base. No merge, resize or physical-disk API exists
in this helper. The accepted qcow2 and normalized base are never modified.

The child is mounted read/write with `-NoDriveLetter`. Every partition offset,
size, GPT GUID/type or MBR signature/active flag must match the independent
layout. It must be FileBackedVirtual, neither boot nor system. Temporary DOS
aliases use no-broadcast flags; actual volume handles are checked with both
`IOCTL_STORAGE_GET_DEVICE_NUMBER` and `IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS`.
Both aliases must identify the exact child disk and partition extents before
any command and again after it. Aliases and mount are removed in `finally`.

Only the host System32 command is executed, with fixed arguments:

```text
bcdboot <verified-child-Windows> /s <verified-child-system> /f UEFI|BIOS /l pl-PL /v
```

The mandatory `/s` binds the system partition explicitly and avoids requesting
a host firmware boot entry. The two volumes retain the original partition IDs,
so this BCD can serve as an independent reference for our writer. The Windows
source and BCD template must be on the verified child, and critical source
route components must not be reparse points.

The resulting BCD is copied to `reference.bcd` and made read-only. A separate
`inspection.bcd` copy is used for `bcdedit /store ... /enum all /v`, because a
native hive reader can create transaction state or update its writable copy.
The canonical reference SHA must remain unchanged. `result.json` provides
`bcdboot_exit`, `reference_sha256` and `physical_disk_touched:false` for
`bcd_compare.py`, plus child/base identity, hashes, commands and cleanup result.
All child images, copies, stdout/stderr and failed evidence are retained. The
child is limited to 800 MiB inside the approved 1 GiB reference reservation;
there is no full parent image copy.

`test_minios_bcdboot_reference.py` covers acceptance/refusal paths without any
native operations. The PowerShell companion only compiles the C# guard,
checks ABI layouts and rejects unsafe paths/aliases before disk APIs can run.
Actual differencing creation, mount, bcdboot and BCD comparison remain separate
native gates after the parent has accepted 1c-2, not claims of these unit tests.

Public API contracts: [CreateVirtualDisk](https://learn.microsoft.com/windows/win32/api/virtdisk/nf-virtdisk-createvirtualdisk),
[GET_VIRTUAL_DISK_INFO](https://learn.microsoft.com/windows/win32/api/virtdisk/ns-virtdisk-get_virtual_disk_info),
[bcdboot](https://learn.microsoft.com/windows-server/administration/windows-commands/bcdboot).
