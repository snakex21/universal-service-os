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
| NT35 | tools/nt/usosnet/bin/i386/usosnet35.sys,16384B | d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85 | fixed01 DHCP/ping3/3<10ms/DNS/HTTP200; usb01 keyboard/mouse out/in; separate policy apply03/cold01 PASS [S13]; installed overlays, no new fresh PASS |
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
their measured approximately2s delay. Corrected NT35 d94 still has only
installed-overlay qualification; it needs a reviewed cache and a fresh
normal USOS run before a fresh-install PASS claim.

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
Native safe shutdown and rc0 complete both overlays. This adds no fresh
d94/AUTO policy PASS; R20 history and installed-overlay scope remain.

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

## NT4: completed Setup/HID, network and MSC follow separately

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
collector failures. New07 qualification is pending; do not convert the
native DHCP/ping evidence into an official full LAN PASS prematurely.
