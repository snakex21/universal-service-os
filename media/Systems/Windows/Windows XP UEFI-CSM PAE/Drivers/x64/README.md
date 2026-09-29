# XP x64 - community ACPI

The community ACPI 2.0 driver 5.2.3790.7777.4 (amd64 free build) for Windows
XP Professional x64 SP2, the x64 counterpart of the XP x86 community ACPI in
`../x86/ACPI`. Provenance, hashes and licence status: `ACPI/ReadMe.txt`; the
pinned SHA-256 is in `manifest.json` and in `tools/xp64_acpi.py`.

Without it XP x64 stops with 0xA5 on new AMD boards (X470). USOS applies it
automatically on the XP x64 path (`tools/nt5_storage_stage.sh`): text mode
(`$WIN_NT$.~BT`, `~LS\AMD64`), the source's `SP2.CAB` (rebuilt by
`tools/xp64_acpi.py` from the named XP x64 SP2 ISO, so GUI-mode PnP and the
driver cache take the same file) and `TXTSETUP.SIF [FileFlags]`. A local
source whose `SP2.CAB` is not one the package was built from keeps the stock
ACPI (the staging log says so). Temporary bridge until USOS has its own
implementation (docs/ROADMAP.md, L1).
