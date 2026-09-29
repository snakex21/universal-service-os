Community ACPI 2.0 driver for Windows XP x64 SP2 (NT 5.2 amd64)

File:     acpi.sys, version 5.2.3790.7777.4 "built by: Administrator", amd64 free build
SHA-256:  2aaac644abd3b94d8e1f41d1ea98ba88a18fe8c7273ba423796f0fdac20b6202 (327680 bytes)
PE:       machine 0x8664 (AMD64), PE32+, subsystem 1 (native), timestamp 2022-04-28 11:47:27 UTC;
          Authenticode: not signed
Imports:  ntoskrnl.exe, HAL.dll, WMILIB.SYS; 123 imports, 0 missing against XP x64 SP2 AMD64
          (export forwarders followed, tools/tests/check_nt52_driver_imports.py --driver)

Origin:   the MSFN / WinCert community ACPI 2.0 project for NT 5.1/5.2 (ACPI 2.0 compiled from
          source, "Mov AX 0xDEAD" patches, George King builds; MSFN topic 183464, WinCert topic
          17688), 7777.4 build set: 5.1.2600.7777.4 (i386 free/debug) and 5.2.3790.7777.4
          (i386 + amd64, free/debug, with pdb). This file is 5.2.3790.7777.4\amd64_free\acpi.sys.
          Downloaded by the user on 2026-09-30 (exact URL not recorded). Not the MediaFire
          "ACPI2.0_v4_x86+x64_5.1+5.2.7z" (v4 = 2022-04-01; this build = 2022-04-28).
Checked:  Microsoft Defender scan of the downloaded folder: no threats found (2026-09-30).

Licence:  none stated. A community-built driver derived from Microsoft code; redistributed by
          the USOS maintainer at the maintainer's own decision and risk, not covered by any USOS
          licence, and removed on request of the rights holder (docs/LICENSES-AUDIT.md).

Use in USOS: XP x64 SP2 only (profile xp-x64-sp2-uefi-csm), the counterpart of the XP x86
community ACPI in ..\..\x86\ACPI. The stock 5.2 ACPI.SYS stops with 0xA5 on new AMD boards
(X470). tools/xp64_acpi.py packs it with a copy of the source ISO's AMD64\SP2.CAB that holds
it; tools/nt5_storage_stage.sh puts it into $WIN_NT$.~BT and ~LS\AMD64, replaces SP2.CAB and
sets TXTSETUP.SIF [FileFlags] acpi.sys = 16. X470 without CSM: XP x64 install to the desktop
PASS (2026-09-29, B260929-191942). Temporary bridge until USOS has its own implementation
(docs/ROADMAP.md, L1 / L6 rule 3).
