# XP x86 - downloaded driver candidates

Downloaded and checked on 2026-09-21. The experimental builder now consumes an explicit subset of these files through `tools/xp_driver_overlay.py`. It integrates the selected SP3 source into a separate initramfs; the production BIOS XP and Vista paths remain separate. SP2 is refused by preflight before target changes. Physical XP installation with this bundle is not yet verified.

Source: Patch Integrator v4.2.3, distributed by its maintainer with [Integral Edition 2025.8.19](https://zone94.com/software/operating-systems/123-windows-xp-professional-sp3-x86-integral-edition). Only selected ZIP members were fetched with HTTP Range; the Windows ISO was not downloaded. Original files, integration recipe and URL/SHA-256 provenance are under `tools/vendor/xp-modern/2026-09-21` in the project.

Candidates for the separate XP UEFI-preparation / CSM-boot experiment:

- USB3: Microsoft USB3.x xHCI backport v2.2. Its INF matches `PCI\CC_0C0330`, the compatible class reported for the target AMD 149C and 43D0 controllers. This is an INF match, not proof that the driver starts on this board.
- SATA: GenAHCI 6.3.0.1, generic `PCI\CC_010601`. The motherboard SATA controller ID/mode must still be checked. The Intel SSD brand does not imply an Intel SATA controller.
- KMDF: backported framework 1.11; required by this USB stack.
- Dependencies: `ntoskrn8.sys`, `storport.sys`, `storpor8.sys`. The nested `Win2003` files are upstream optional material, **not selected as replacements for XP's existing USB stack**.
- ACPI: upstream default `acpi.sys`, Dietmar 7777.8 (2024-11-07). Nested older versions are alternatives only, never all installed together.

All 20 staged SYS binaries are PE32/i386. Imported module filenames resolve within the candidate bundle or expected Windows kernel/HAL modules. This checks architecture and file presence, not imported-symbol compatibility, signatures, installability or runtime behavior. SHA-256 values in `manifest.json` identify the downloaded bytes; they are not an independent authenticity guarantee.

Target the SP3 source first. SP2 compatibility and operation with RAM above 4 GiB / PAE are unverified. Upstream's integrator itself warns that its 64 GiB PAE option can have stability issues. No VM/E2E tests were run and no host driver or certificate was installed.

Integration follows the upstream recipe for TXTSETUP/DOSNET file lists, boot-time dependencies, SETUPREG.HIV, HIVESYS.INF and PnP registration. ACPI is also replaced inside SP3.CAB. Only the default ACPI, GenAHCI, USBXHCI/USBHUB3 and their dependencies are selected; alternative ACPI, UASP and Win2003 USB files are not activated. Source metadata hashes and payload hashes are checked before the disk-reset dialog and again before staging. Runtime copies are checked after writing. Files are compiled into the experimental initramfs; arbitrary user-added drivers are not consumed automatically.

Additional archives retained separately for review: [GenAHCI](https://github.com/GeorgeK1ng/GenAHCI) 6.3.0.1 and [xhci98](https://github.com/yeokm1/xhci98) 1.1.0.0. xhci98 is not selected for the primary candidate bundle; its maintainer reports limited XP validation and no XP physical-hardware validation at the time of review.
