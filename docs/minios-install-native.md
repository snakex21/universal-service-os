<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Native multipartition installation gate

`tools/minios/install_native.py` exports `verify(args)` / `run(args)` and the
equivalent CLI. Arguments are `source` (closed qcow2), `out`, `plan`,
`qemu_img`, `pwsh`, `virtual_bytes`, `mode` (`uefi` or `bios`),
`expected_tree` and `expected_security`. It never starts Windows, formats a
volume, repairs a filesystem or cleans up an image.

The source and every backing file must be regular owned runtime files. A
bounded QCOW2 header/name walk checks each backing path before QEMU opens
the chain; encryption, external data, unsafe paths and cycles are refused.
All source/backing bytes are pinned and locked against writes/deletion for
conversion and validation. The original qcow2 remains the preparation result.

There is one exported dynamic VHD. QEMU creates it only in a fresh output
directory, with `subformat=dynamic,force_size=on`. The normalizer exclusively
opens that exact new `.vhd`, verifies its final handle path, one hardlink,
ordinary host attributes, container geometry, byte length and SHA-256, then
clears SparseFile using `FSCTL_SET_SPARSE(FALSE)`. It verifies unchanged bytes,
length and file identity and refuses compressed/encrypted/reparse files. It
never normalizes an input qcow2 or a previous proof image. The normalized VHD
is made read-only; no intermediate full raw or fixed VHD copies are created.

The independent dynamic VHD reader accepts type3,512-byte sectors,2MiB blocks,
valid footer/header checksums and matching backup footer. BAT metadata bounds,
duplicate/overlapping physical blocks and sector-presence bitmaps are checked.
All logical seeks/reads are bounded; read buffers are at most32MiB. This is a
host oracle, not the MiniOS firmware RAM claim. Differencing VHDs are outside
this reader's scope.

Before mounting, an independent layout check verifies GPT header/table CRCs
and backups, unique IDs, ESP300MiB + MSR16MiB + Windows, or an active100MiB
NTFS system partition plus Windows on MBR. Partition starts/sizes use1MiB
alignment and match the explicit virtual image size. The existing independent
NTFS security oracle reads the Windows partition directly through the VHD
adapter, validating exact SDS bytes, object IDs, file references and declared
attribute transformations against the original WIM expectations.

`tools/tests/minios_install_readonly.ps1` validates the exact file-backed
read-only virtual disk and its entire native partition table against the
independent JSON layout. Each selected NTFS partition gets a temporary DOS
alias with no media broadcast. Alias/device/disk/partition geometry is checked
before the native operation. Windows file-tree acceptance reuses the existing
WIM comparator through the old checker's optional `-LibraryOnly` parameter set;
the old raw-only command's default behavior remains unchanged. The comparator
checks full paths, streams, SHA, timestamps,8.3 names, security, hardlinks,
reparse data, EA and object IDs under the established policies.

Native NTFS and FAT32 `chkdsk` runs are sequential on the same exact VHD, without
repair switches. The ESP uses the FAT32 checker; MSR has no filesystem and is
not passed to `chkdsk`. Every alias is removed and every image detached in
`finally`; source/container/manifests and clean HEAD are checked again. Any
failed gate stops the sequence before boot. All evidence and images remain.

The small normalizer proof uses known32MiB raw bytes, independent
`qemu-img compare`, a full logical SHA through the separate VHD reader and a
negative exclusive-handle test. It does not mount an image. The large native
installation gate is only run after a successful real MiniOS QEMU preparation.
