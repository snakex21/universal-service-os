# shim 16.1 (Fedora shim-x64 16.1-7)

Vendored, unmodified binaries. They are data, not a build dependency: the
release step (`installer/cmd/usos-efisign release`) only copies them after
checking the SHA-256 values in `manifest.json`.

| File | Role on the USOS ESP | SHA-256 |
| --- | --- | --- |
| `shimx64.efi` | `\EFI\BOOT\BOOTX64.EFI` | `351e131d3c4a636704e9cae7d1296baf8a05beca9922cfebbfa48933c9bf1ad3` |
| `mmx64.efi` | `\EFI\BOOT\mmx64.efi` (MokManager) | `ed4442fa88cccba3a9e6a32d21a8f4c56bf5aab184f1fb9aadde8d3a9d04dc27` |

Source package: `shim-x64-16.1-7.x86_64.rpm` from Fedora Koji
<https://kojipkgs.fedoraproject.org/packages/shim/16.1/7/x86_64/shim-x64-16.1-7.x86_64.rpm>
(SHA-256 `0a119f3488e5da27ca55c1864ee8e131afa5ecf27689385ba09b805eb00dd608`,
497 743 bytes, downloaded 2026-09-24). Files taken from
`/usr/lib/efi/shim/16.1-7/EFI/fedora/`. Upstream: rhboot/shim tag `16.1`,
commit `afc49558b34548644c1cd0ad1b6526a9470182ed`.

Signatures: `shimx64.efi` carries two Authenticode signatures, Microsoft
Corporation UEFI CA 2011 and Microsoft UEFI CA 2023, so it boots on machines
that trust either third-party CA. `mmx64.efi` is signed by the Fedora Secure
Boot CA and is trusted through the vendor certificate built into this shim,
so shim and MokManager must always come from the same package.

SBAT: `shim,4`, `shim.rh,3`, `shim.redhat,3`, `shim.fedora,3`. Every
SbatLevel published up to `sbat,1,2025112400` requires `shim,4`, which this
build meets. Embedded `.sbatlevel` it applies to the machine: automatic
`sbat,1,2024040900 shim,4 grub,4 grub.peimage,2`.

Second stage: shim starts `grubx64.efi` from its own directory; USOS is
installed under that name. It opens `mmx64.efi` when the second stage fails
verification (first boot before the USOS key is enrolled).

License: BSD-2-Clause-Patent style (see `LICENSE`, the upstream `COPYRIGHT`
file of shim 16.1). Redistribution of the distribution-signed binary is
common practice (Ventoy ships a Rocky Linux build of the same 16.1 release).
