# Winsock STANDARD regression

New scope authorized 2026-10-25: Windows 3.1 PL `WIN /S`, Netscape 3.04
and Opera 3.62, on a new branch from `fix/win30-stdmode-mouse` (`ff9b496f`).
MiniOS and other closed systems are outside this investigation.

Use the already installed USOS Windows 3.1 base, internal snapshot `base`,
SHA-256 `531dee257fe81e45edfc94078ece385ba7b18ca2bdbdfc76b1dc047fcf350fda`.
Each trial uses a fresh QCOW2 overlay; no Windows reinstallation is needed.
The dedicated fixture keeps its evidence separate from the closed stage 3
and launches one bounded run with one final screenshot and a packet capture.
The actual mode is logged with `GetWinFlags`; the old fixture still defaults
to ENHANCED. Browser binaries stay in the external application library.

Preserve the baseline diagnostic provider before changing the implementation.
Compare the same browser, configuration, base, machine and network with the
USOS provider and the user's original Trumpet 3.0 control distribution.
Trumpet is an external runtime control, never an implementation input.
An unconfigured or non-networking control is not a successful comparison.

Default `USOSPKT.COM` must stay 8157 bytes with SHA-256
`98cfdf5ad6c8d7c805927d7f7247ef326ca36414c3622189a0a238c16ae933eb`.
The Winsock profile remains opt-in. No merge, deployment or physical disks.
Commits follow completed pieces. Retain every image and evidence file until
the final report and the user's subsequent cleanup acceptance.

Final report: `RAPORT-WINSOCK-STDMODE.md`, then STOP.
