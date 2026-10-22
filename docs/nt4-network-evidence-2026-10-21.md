# NT4: silent network evidence — runtime verification pending

Branch `fix/nt4-net`, based on audit checkpoint `dede08a8` and production
base `6476cd9515813af4ef8f58657d398189181947d1`. No merge or deployment.

NT4's existing network defaults did not measure DHCP, gateway ping or DNS.
The existing own USOSLOG GUI/no-CRT program now has an optional dynamic ICMP
path and NT4 adapter-registry fallback. Its own files follow its EXE folder.
The first hardware LAN step launches one quiet snapshot to
`C:\USOS\NT4\USABILITY.TXT`. No USB/hub driver or x64 signature policy changed.
Full build packaging includes the helper. Staging checks copied bytes and
stops on absence/error rather than proceeding with missing diagnostics.

Validation, all host-only:

- 20 usability tests PASS: evidence classification, synthetic ICMP failures,
  NT4 REG_SZ/MULTI_SZ fallback, real portable logger runs, hidden launch,
  quoted Win16 companion arguments and malformed-input handling.
- 21 selected existing network tests PASS, including real shell staging,
  network-off behavior, NDIS4/5 separation, both GUI PE4 helper builds and
  their imports against the NT4 RTM export fixture.
- 4 selected existing USOSLOG tests PASS: source contracts, PE/import checks,
  real one-shot host execution decoding a supplied diagnostic dump.
- OpenWatcom builds of USOSLOG.EXE and USOSDBG.EXE PASS; static ICMP reply
  layout check is 28 bytes on x86. No C runtime in the production logger.
- Read-only original NT4 Workstation PL ISO inspection: 72 static imports
  present; IcmpCreateFile, IcmpSendEcho, IcmpCloseHandle present in ICMP.DLL.
  Metadata only in `macierz-windows/artifacts/coverage/nt4-logger-original-exports.json`.

Still required: fresh NT4 + SP6a with matching driver and actual DHCP,
ICMP, DNS and removable-volume results. The existing LAN helper defers in
QEMU; the test must explicitly invoke the staged logger to obtain a guest
snapshot, and report that test invocation. Source/helper tests alone do not
verify the first physical hardware desktop. Current `r6-nt4-msc-usb-net`
uses unchanged canonical MSC feature inputs; it does not include this new
logger integration. A later fixture must name the exact tested combination.

On X470 the user answers yes/no for START.TXT, hot-plug HOTPLUG.TXT, restored
keyboard and mouse input, and the 68k.news Favorite. DHCP, gateway ICMP and
DNS are read from the target log by the reviewer. A browser result alone
does not prove all three. QEMU does not reproduce the I211 IRQ issue or
prove X470's 20 ms polling fallback.
