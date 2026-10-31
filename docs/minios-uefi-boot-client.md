<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Isolated UEFI boot-file client

`src/prep/uefi_boot_main.zig` is a separate QEMU-only executable. Its
`prep_boot_only` compile-time root flag selects boot provisioning in the
existing UEFI platform framework. The ordinary prep root retains its original
profiles, configuration and reachable code. No normal menu depends on this
client. Build it with the same `ntfs_ro` module as the prep client, once for
UEFI x64 and once for IA32/i486. The shared framework includes the tracked
1 MiB stack, firmware/CPU entropy validation, storage connection, block bounce
buffer and log output. Provisioning has a 16 MiB tracked allocation ceiling.

This executable must only run **after** the real 1c-2 partition/apply/tree and
read-only chkdsk gates, and the real-layout bcdboot comparison, have passed.
Its host caller supplies the accepted receipts. The firmware checks their
bytes against pinned SHA-256 digests; interpreting and approving the receipt
results belongs to the host gate orchestrator. A digest is evidence binding,
not a signature or a replacement for those gates. The target must remain
unchanged between its accepted apply gate and this run.

All client configuration and logs stay on its utility boot ESP:

- `USOSBOOT.CFG`: exact explicit target identity and completed gate pins;
- `USOSLAY.RCP` and `USOSBCD.RCP`: original accepted
  receipt bytes, each nonempty and no larger than 1 MiB;
- `USOSBOOT.LOG`: provisioning output, separate from `USOSPREP.LOG`.

The UTF-8 configuration starts with `USOSBOOT_QEMU_ONLY_V1`. Every following
key is required exactly once; unknown or duplicate keys fail. GUID values are
32 hexadecimal characters in **raw GPT byte order**, as printed by the prep
installation log, not a canonical GUID string. Hashes are 64 hexadecimal
characters. There are no default target identities or default gate results.

```text
USOSBOOT_QEMU_ONLY_V1
target_bytes=<decimal whole-disk byte size>
disk_guid=<32 raw GPT hex digits>
windows_guid=<32 raw GPT hex digits>
esp_guid=<32 raw GPT hex digits>
msr_guid=<32 raw GPT hex digits>
ntfs_serial=<hexadecimal original Windows NTFS serial>
mbr_signature=<hexadecimal nonzero original layout identity field>
loader_guid=<32 raw GPT hex digits, fresh random RFC4122 version 4>
layout_receipt_sha256=<64 hex digits of USOSLAY.RCP>
bcd_receipt_sha256=<64 hex digits of USOSBCD.RCP>
layout_gate=pass
bcd_gate=pass
arch=x64
locale=en-US
```

`arch` is `x64` or `ia32` and must match the executable. `locale` is an
explicit Windows locale with 2–32 ASCII letters, digits or hyphens.
`mbr_signature` preserves the layout object's identity even though a GPT
protective MBR has no Windows MBR disk signature. Generate `loader_guid` from
an independent unused part of validated host entropy, then set the version
and variant bits. Test fixture GUIDs are not production identities. The
loader GUID must differ from all disk and partition GUIDs.

Target discovery considers only whole writable 512-byte-sector BlockIo
devices with the exact byte size. It excludes the utility boot device and
its parent device path. The primary GPT disk GUID must match, then both GPT
headers, both partition tables, CRCs, all partition GUIDs/types/locations and
the Windows NTFS serial must match the supplied layout. A damaged matching
disk is a failure; two matching disks are ambiguous and fail. These checks
run again inside `boot_files.provisionUefi` before any ESP sector write.

The Windows NTFS is read only. The destination ESP must still be the empty
freshly formatted one from 1c-2. The client copies boot files, fonts and
available resources from the applied Windows, emits its own qualified GPT
BCD, and creates the architecture-specific removable-media fallback path.
It does not edit NVRAM, execute Windows or modify the Windows NTFS. A retry
requires resetting the boot-provisioning overlay to its accepted pre-boot
base; an already populated ESP is refused. The subsequent first Windows boot
is a separate gate, with the utility boot media removed from the boot path.

Host tests cover strict pins and missing/duplicate/unknown gate fields,
unpassed gates, malformed geometry and identities, invalid locale, and
missing digests. Existing boot-file tests cover refusal before I/O when
gates are false, fresh GUID formatting and actual GPT/NTFS identity checks.
The firmware build and QEMU provisioning/first-boot gates remain separate
evidence; passing parser tests does not claim Windows has booted.

The boot route additionally wraps block I/O in `boot_target.EspOnly`. Reads
can reach the whole disk, but writes outside the exact ESP byte interval
(including MBR, MSR and Windows) fail before reaching the device callback.
All utility control filenames are deliberately valid 8.3 names.
