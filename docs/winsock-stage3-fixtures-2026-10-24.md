# Winsock stage3: VM bases and original Win16 test applications

The separate `run_win16_stage3_qemu.py` fixture reuses the existing USOS
DOS/Windows installation flow and integrated experimental Winsock profile.
It does not alter the historical stage2 fixture. Windows 3.1 PL and WfW
3.11 PL each received exactly one installation, eight successful installation
checks and a `base` snapshot. All subsequent application work uses COW.

The bases are in the named new `K:\USOS-VM\winsock-etap3-20261024\vm`
subdirectories `win31` and `wfw311`. Installation took 107.58 and 228.15
seconds respectively. `validation/bases-completed.json`, each `base.json`,
`install-verdict.json`, closed console logs, PCAP and final PPM/PNG preserve
the evidence. The reason for both new installations was written in the
external stage3 report before either installation began.

The normal Win3.1 base retains the existing STANDARD installation flow.
This is not evidence of enhanced-mode application execution. Stage3 overlays
must explicitly use `WIN /3 /B` and prove the actual mode with GetWinFlags.
The WfW catalog ID is `windows-wfw-3-11`, not `windows-3-11`.

Output guards reject other runtimes, physical paths, reparse components,
QEMU CSV separators, control characters and existing images. Before creating
a disk or COW, the fixture accounts for the entire owned pool against 100 GiB
and preserves 8 GiB free after reserving the new disk's worst-case 1 GiB.
The eight host safety tests launch no VM. Boot waits for a serial event/EOF
or one bounded test interval; it performs one final capture and preserves
both PPM and PNG. No progress queries or cleanup are built into the fixture.

## Application library

All downloads and extracted application bytes remain exclusively under
`G:\USOS-Kolekcja\Programy\Win16\`, outside Git. Each directory contains
`source.json`, the original installer and NE inspection receipts. No Trumpet
files were downloaded or used. Evaluation behavior and original license
materials are retained; no application binary or license data was patched.

| Application | Mirrored original installer | SHA-256 |
| --- | --- | --- |
| Netscape Navigator 3.04 16-bit | [n16e304p.exe](https://www.devili.iki.fi/pub/browsers/Netscape/win16/n16e304p.exe) | `14782c5fd8bd520baa3f0178d045d606e3f6067a8a47782a205919b1d06c57a6` |
| Opera 3.62 16-bit | [OW362E16.EXE](https://apajalista.net/tiedostot/PC/Windows_3x/Internet/OW362E16.EXE) | `686bd46d7c68bddb6cf22f61689e65eb91b26c46fc787f9879085bda1ce759f0` |
| mIRC 5.91 16-bit | [mirc591s.exe](https://www.sac.sk/download/comm/mirc591s.exe) | `2394447015f086b2e3b0cc7812258f10e9856d8b0eb98089aff49fb798a623b9` |

Opera also matches the installer in the independent
[Opera ZIP](https://www.modula.org.uk/files/retrorig/OW362E16.ZIP).
A secondary mIRC mirror contained the same installer bytes but also unrelated
third-party registration text. That secondary archive and text are excluded
and quarantined in the external library; do not use either. Only the separate
SAC installer is used, with normal evaluation behavior and no registration
data. Quarantine preserves the evidence without copying it into any VM.
The author's [mIRC 5.91 announcement](https://www.mail-archive.com/announce%40mirc.com/msg00003.html)
identifies `mirc591s.exe` as the Windows3.x 16-bit evaluation package.

Netscape's actual `payload/PROGRAM/NETSCAPE.EXE` is NE, target Windows,
3162432 bytes, SHA-256
`193cd7d3235e3118a06ad75ca51e18fb4962e1701b892b42eea4ea434ae1dd25`.
`PR16301.DLL` and `UNI1600.DLL` are also NE. The original DATA.Z was unpacked
with Apache-2.0 `wfr/unshieldv3`, built in the external library's `_tools`.
`payload-ne-inspection.json` records imports; none directly import Win32s.
The supplied README explicitly requires the 16-bit browser on Windows3.x.

Netscape needs its original **`setup-files/NETSCAPE.LCK`** beside the browser,
plus `payload/LICENSE`, PROGRAM files and the original INI. Its direct
imports include COMPOBJ, STORAGE, OLE2, OLE2DISP and MFCOLEUI; the supplied
`payload/OLE` folder contains those dependencies. The original
`payload/INIFILE/NETSCAPE.INI` documents a launch-directory fallback, allowing
an application-local INI without changing WIN.INI. Adjust only the test copy's
history/cache/temp/bookmark paths. Static import closure does not prove that
all OLE registration/setup effects are unnecessary; retain original Setup
as an application-COW fallback.

Opera's `files/OPERA.EXE` is NE, target Windows, 1739392 bytes, SHA-256
`4c29bdf7a1ca65b7a24a3cdd239ad53b8b76c3fbab9d98437afd4dece619badc`.
The original Wise installer contains complete raw-DEFLATE streams followed
by CRC-32 values. A bounded scan recovered ten NE modules; every recovered
stream matches its stored CRC. `deflate-extraction.json` records original
offsets, compressed lengths, CRC and SHA. The ready `files` folder gives DLLs
their NE-flag-derived extensions. Required DLLs include CTL3DV2, OPTREE16,
JSDLL16, OPJPEG16 and OPPNG16. No direct Win32s imports were found.
The current WiseUnpacker recognized the container but could not parse opcode
102, so its partial output is not treated as a complete extraction.

mIRC's installer is NE (`mIRCSetup`), not a Win32s launcher. ZIP/Wise/raw-DEFLATE
tools did not unpack its payload. The original SAC installer was then run in
normal evaluation mode on a WfW application COW, without another OS install.
The closed final capture confirms successful installation. The Finish action
had been scheduled before copying completed; it was not retried or used to
reinstall the app. A separate application snapshot protects the copied files.
The actual `files/MIRC.EXE` is NE, Windows target, 1529504 bytes, SHA-256
`0d41c7ae3f8f5ad110cef54b0e9ad35db1163e339e4963c8ac7f1f70b83b7900`.
It imports WINSOCK and ordinary Win16 support modules, with no direct Win32s
imports. `payload-ne-inspection.json` records the complete import list and
every file extracted from the installed original package.

## Network preflight and scope

A single host urllib probe in this session obtained HTTP 200 for
`http://www.68k.news/`, with the same final URL. Both HTTP and HTTPS attempts
to `frogfind.com` timed out during connection without an HTTP response.
This does not establish an application or TLS failure. Guest PCAP and actual
rendering remain separate acceptance requirements.

No application compatibility PASS follows from these installation or NE
checks alone. Root owns the enhanced-mode browser runs and final report.
All images and evidence remain until the final report; cleanup is separate.

## Controlled mIRC evaluation fixture

`ircsetup.c` drives ordinary installer buttons at distinct fixed checkpoints.
It disables shortcuts, does not register the application and does not modify
the installer. The first invocation used a resource title different from the
actual top-level window, so no installation occurred. Correcting that title
on the same application COW completed the single installation. The bounded
final screenshot records the original installer's success page. Finish was
scheduled too early and was not retried; this does not claim an unattended
exit from the wizard. `apps/irc-install01/app-base.json` records the protected
`app-installed` snapshot, original installed bytes and NE imports.

`ircdrive.c` launches the installed original client, closes its normal About
evaluation dialog once, then invokes the configured Connect button once at
a separate checkpoint. A final bounded window inventory records actual
GetWinFlags `ENHANCED`. The client itself sends all network commands; the
ordinary `on CONNECT` script requests `JOIN #usos-test`. This controller has
no registration function and no repeated progress/window polling.

`run_win16_irc_stage3.py` creates a COW of that application base, stages only
an explicit original-file allowlist and local-only INI/script configuration,
then coordinates a blocking loopback endpoint and guest run. It reads the
PCAP only after the guest and server have stopped. Endpoint registration,
matching server replies, a real client JOIN and completed capture reassembly
are independent requirements; enhanced-mode launch alone is not IRC PASS.

The closed `apps/irc-join02` discovery capture contains contiguous TCP bytes
`NICK USOS16` plus LF (12 bytes at sequence 1343245449), then `USER ...` plus
LF (58 bytes at sequence 1343245461). Packet lengths are not truncated and
reassembly reports no gap/conflicting retransmission. This is direct wire
evidence, not attribution to uninspected mIRC source. The strict endpoint
rejected it, so that attempt remains FAIL. The diagnostic receipt is
`validation/irc-lf-wire-evidence02.json`.

The server and independent analyzer default to strict CRLF. Explicit
`allow_legacy_lf` / `--allow-legacy-lf` accepts client LF for this original
evaluation client and records the option and observed line endings. Server
replies remain strict CRLF. Bounds, NUL/embedded-CR rejection, exact channel,
registration, reply matching and TCP integrity checks remain in force.
The mIRC fixture opts in openly. The 42 completed host tests, including
negative default-LF and damaged-stream cases, are recorded in
`validation/irc-lf-host01.log`. This is a controlled local endpoint test,
not public Internet IRC interoperability or an X470 result.

With that explicit option, `apps/irc-join03` completed real mIRC registration
and received all eight 001..376 replies. Its screenshot shows the connected
status and original Channels Folder dialog. That attempt still has no JOIN
on the wire and remains a protocol FAIL; script presence is not proof that
the client executed it. A subsequent normal UI channel action is required.

The final authorized UI correction is closed as **BLOCKED**, not JOIN PASS.
In `apps/irc-join06`, original mIRC runs ENHANCED (`GetWinFlags=3113`) with
provider07 SHA-256
`1e33ecc917f4ce85253558e965dd4c7362df5f5dbfd1519c6d5bdaa8d72f70db`.
The endpoint and independently reassembled closed PCAP both confirm NICK,
USER and the complete eight-reply 001..376 registration dialogue, without
TCP gaps. The final screenshot visibly contains `#usos-test` in the Channels
Folder edit control. However, the controller's cross-task GetWindowText
returns empty even at the separate one-second checkpoint. Its exact-input
guard therefore withholds the Join action. No JOIN appears on the wire and
neither endpoint nor analyzer passes. No additional UI variations, OS
installations or VM attempts follow that bounded result. This diagnoses a
test-controller barrier; it does not demonstrate an application/provider
inability to JOIN manually. The final closed review is
`validation/irc-final-closed-review01.json`.

All installer/client bytes remain original, with no registration data.
IRCSETUP02 and the final IRCDRIVE05 have fixed NE descriptions containing
USOS and Win16, with no absolute build path; the final metadata receipt is
`validation/irc-helper-ne-final01.json`. Build commands and source/artifact
hashes are preserved in `apps/irc-drive-build/build05.json`. The application
base, every diagnostic overlay and all screenshots/PCAP/logs are retained
for the final report's separate cleanup decision.
