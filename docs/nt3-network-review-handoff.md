# NT3 network and HID candidates for review — 2026-10-22

No branch in this handoff was merged, pushed or deployed to physical
media. Runtime qualifications below are QEMU only. The per-image audit
is in `docs/windows-usb-network-matrix.md`; unknown variants stay unknown.

## Shared IRQ change: apply the source change once

`fix/nt351-net-irq` b14378d8 and `fix/nt35-net-irq` 2d8d453e each change
the same four legacy register definitions in
`tools/nt/usosnet/src/usosnet_igb.c` and add the same actual-C MMIO test
`tools/tests/test_igb_irq_registers.py`. Select the shared source/test
change once during review; the separate binaries are both needed.

| Candidate | Repository binary | SHA-256 | Runtime proof |
|---|---|---|---|
| NT35 | tools/nt/usosnet/bin/i386/usosnet35.sys,16384B | d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85 | fixed01 DHCP/ping3/3<10ms/DNS/HTTP200; usb01 keyboard/mouse out/in; fresh normal USOS d94 desktop/DHCP/ping3/3<10ms/strict FIXED DNS/native resolver/HTTP200 PASS [S15], fresh policyFAIL; separate usb01 and policy apply03/cold01 PASS [S13] |
| NT351 | tools/nt/usosnet/bin/i386/usosnet351.sys,17024B | f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf | Fresh normal USOS nt351-irq-fresh01: desktop/DHCP/ping3/3<10ms/DNS/HTTP200 PASS, separate fresh Client/noSharing FAIL; R26 passive IRQ trace; R27 keyboard/mouse out/in; separate policy apply02/cold01 PASS [S12] |

Both USB regressions explicitly disable the PS/2 driver with inherited
i8042prt Start4 while leaving hardware i8042 present. They include an
absent-keyboard negative control, keyboard action after insertion,
keyboard action with mouse absent, and mouse movement/menu click after
insertion. Native safe shutdown, process exit0 and actual installed SYS
readback precede each completed assessment. No hub code was changed.

NT35 qualification/USB reports are fa6fab32/cf8f7ca0 in
`C:\Users\ASRock\usos-work\nt35-irq`. NT351 USB report is f54d1ffc in
`C:\Users\ASRock\usos-work\nt351-irq`. Build metadata distinguishes raw
source hashes from normalized CRLF/LF equivalence; use each actual build
manifest rather than silently assigning one source hash to both builds.

The original fresh R20/R22 installations used earlier drivers and retain
their measured approximately2s delay. Corrected NT35 d94 now has completed
fresh normal USOS qualification nt35-irq-fresh01, commit4cd6a3bf in
`C:\Users\ASRock\usos-work\nt35-fresh` [S15]. Its private R20 cache
changes only SYS+SHA, with835 other effective entries and every other
cache file identical. A new blank4GiB target reaches Program Manager and
passes native DHCP release/renew, ping3/3<10ms, strict fixed DNS1.1/8.8,
native resolver and HTTP68k200. Configured10.0.2.3 is confirmed by native
ipconfig, without a strict matched configuredDNS test in frozen ff258504.
Two stopped actual SYS reads, native safe shutdown and process/QEMU0
complete the qualification. PS/2 is allowed; usb01 remains a separate HID
proof. Fresh Server/Browser RUNNING/Start2 is a separate policyFAIL,
preserved alongside the installed policy coldPASS [S13], without fresh
AUTO policy qualification.

Corrected NT351 f579 now has completed fresh normal USOS qualification,
commit664d721e in `C:\Users\ASRock\usos-work\nt351-fresh` [S11 in the
per-image audit]. Its private R22-derived cache changes only the own SYS
and SHA sidecar: two of832 effective initrd entries change,830 and all
other cache files remain identical. A new blank target reaches the native
desktop and passes DHCP renewal, three native ping replies below10ms,
strict UDP/TCP DNS and HTTP68k200. Native safe shutdown, exit0 and two
independent stopped reads pin the actual17024-byte f579 SYS. PS/2 is
allowed in this fresh case; HID out/in remains the separate R27 proof.
Strict same-XID DORA stays false despite native lease/renew evidence.

The same fresh NT351 case separately fails Client/noSharing: native
Server/Computer Browser are RUNNING and both have Start2/Type32 in the
selected stopped SYSTEM control set. No service policy changed in that
case. Separate NT351 helper-only apply02 and unchanged cold01 now qualify
the policy correction, commitd268e499 in `C:\Users\ASRock\usos-work\nt351-client`
[S12, `docs/nt351-client-policy-evidence.md`]. Actual SCM/native service
lists and clean stopped readback confirm Server/Browser STOPPED/Disabled,
Workstation/TCPIP RUNNING, with cold ping3/3<10ms and native safe shutdown.
The fresh parent's original policy FAIL remains; this is diagnostic
overlay apply/cold PASS, not fresh AUTO policy. No new USB/DHCP/DNS/HTTP
qualification is inferred. The private fresh cache result does not claim
integration into default release assets.

NT35 now separately qualifies the helper-only policy apply03 and unchanged
cold01, commite8bef69b in `C:\Users\ASRock\usos-work\nt35-client`
[S13, `docs/nt35-client-policy-evidence.md`]. SCM/native services and stopped
readback confirm Browser/Server STOPPED/Disabled, Workstation/Tcpip RUNNING,
and3/3 ping replies below10ms after cold boot. New cold `/check` log has no
NativeNetExit; d94/USB2d455/helper4a927 and i8042prt Start4 remain pinned.
Native safe shutdown and rc0 complete both policy overlays. This adds no
fresh AUTO policy PASS; independent d94 fresh LAN [S15] preserves its
policyFAIL. R20 history and the scope of each installed overlay remain.

QEMU's working NIC IRQ does not qualify the physical I211 IRQ/polling
behavior on X470. NT4 and other OS binaries were not rebuilt by this fix.

## NT31 is a separate full-MAC port

`C:\Users\ASRock\usos-work\nt31-net`, branch `fix/nt31-net`, has the
NDIS full-MAC port, its original-contract tests, native integration
helpers and RAM-only checks against original NT31 modules. Relevant
later commits:88e16bc8 alignment, d51ff7ce argument order/native C test,
83ae1ec6 successful R24c qualification. Review the branch dependencies,
not only its last documentation commit.

R24c's exact own SYS is b49f2445a2e48dbf75b50f426ccc1cef09943a84e779d351747d4cbc8df27a8d,
16384B. It uses UP, explicit BDF00:05.0, QEMU82576 and20ms polling with
IRQ disabled. Static IP, two native ping3/3 runs, strict DNS, native
resolver and HTTP68k200 pass. Native safe shutdown and stopped readback
confirm the candidate. Earlier loader error193 and ABI STOP remain.

R24c was integrated through native NCPA on a retained installation. It
does not qualify fresh automatic network setup. That still needs own
staging, original NT31 TCP/IP/NCPA binding and reboot, a scoped normal
collector, then a blank-target normal USOS run. Stock DHCP is not
applicable. Reset/unload, SMP, Server and physical hardware are outside
this qualification. Separate R24d, commit3820cbfc, now confirms keyboard
and mouse out/in with this full-MAC and native ping3/3 after replug.
Native safe shutdown and actual SYS/USB/Start4 readback pass. R19c remains
the prior completed USB evidence; neither run is fresh auto networkflow.

R24d's native service check finds Server RUNNING; that failure remains.
Separate fix2064ae00 and completed R24e/R24f now qualify Browser/Server
STOPPED/Disabled with Workstation/TCPIP RUNNING and ping3/3 after cold boot.
Own helperd00c, b49SYS/f537USB and native safe shutdown/readback are pinned;
final note8d269a40. Functional LAN and client policy retain separate proofs.
No fresh automatic integration or hardware readiness is claimed.

## NT4: completed Setup/HID and separate LAN07, MSC follows separately

The corrected temporary address198.51.100.1 replaces192.0.2.1 in the own
renderer because original TCPCFG rejects a zero octet. `fix/nt4-net`
a4313b36/3863468b records the original-code validator and host tests.
Candidate03 has completed fresh normal Setup and the native desktop,
safe shutdown and stopped retained-target readback. Separate HID01
qualifies keyboard/mouse out/in with i8042prtStart4, USB2d455 and original
parent unchanged (fix/nt4-usb0c53a3ed, S14). Its BIOS cold firmware differs
from the original OVMF/CSMWrap warm handoff. Its new own EFI is qualified as
a partial build output: fullbuild03 remains FAIL on an unrelated Win7
asset, despite589/589 host tests. Frozen MSC is being tested separately;
there is no combined-HID+MSC or physical claim. Network05 versus unchanged
Start3 control06 establishes the Start2 requirement under matched cold
argv, but the official05 LAN result remains false for observer/DNS
collector failures. Separate LAN07 now has completed strict qualification
[S16], sourcec06435bf: actual first-logon/TESTNET_DONE, lease-matched DHCP
DORA, matching gateway ICMP and configuredUDP10.0.2.3 DNS peer/port/id/
question. Collector07 dhcp/gateway/dns/lease gates all pass. Helper82279
and loggerfe4ffa are explicitly pinned; old4f2 SYS is unchanged. Native
Winver09 confirms SP6a; safeShutdown12/QMP0 and stopped payload/hive
readback complete the run. This BIOS installed overlay is not fresh AUTO,
new IRQ89/08, MSC, Server or X470 qualification. LAN05 false and unchanged
control06 remain preserved; HID01 has its separate S14 proof.
