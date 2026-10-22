# NT3.5 Workstation: completed fresh d94 qualification [S15]

Separate `fix/nt35-net-fresh`, final commit `4cd6a3bf`, in
`C:\Users\ASRock\usos-work\nt35-fresh`. Case `nt35-irq-fresh01` runs the
normal USOS path from exact R20 media on a new blank standalone4GiB
qcow2 target. It reaches actual Program Manager / Windows NT Workstation
Version3.5. Source archive SHA256
`e63ce7b63906cfad0b705200ca8f1318d8620d88370ab26ce5ba6fbe8bdd5236`;
ISO `109d2c28e3d774e01987434b11c622fbf336e01f28eec2eafe40544f166852d1`.

Its private cache changes **only USOSNET35.SYS and its SHA sidecar**.
The other835 effective entries and every other cache file remain
identical, including frozen post helper8ab10c79 and loggerff258504.
Original R20 compressed prefix/cache remain unchanged. New initrd
`f51137a7d9cecfa7e554c58485446533ee34bcab285ee54827b2aeabdc68c3fa`.
Actual candidate `d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85`,
16384B, is confirmed by both own collector and independent stopped FAT
readback. No full build, policy helper, hub or shared cache change occurs.

Native DHCP release/renew and ipconfig confirm MAC52:54:00:55:53:01,
10.0.2.15/255.255.255.0, gateway/DHCP10.0.2.2 and **configured DNS10.0.2.3**.
Native ping3/3 gives every reply<10ms, and own strict ICMP matches the echo
with RTT0ms. **Strict FIXED DNS** matches UDP1.1.1.1=30ms,
UDP8.8.8.8=40ms and TCP1.1.1.1 connect21ms. Native gethostbyname succeeds
40/20/60ms; own logger HTTP68k.news returns200/connect130ms/4095B.
The frozen logger does **not** prove a matched configured10.0.2.3 reply.
Native resolver, fixed DNS and DHCP configuration retain separate labels.
HTTP is an own logger result, not an IE page. GatewayUDP53/no reply3000ms,
gatewayTCP80/timeout4005ms and FrogfindHTTP/timeout4006ms remain negative.

Bounded VM-only PCAP48257B/184frames has two correlated lease exchanges
and four matched ICMP request/reply pairs. Strict same-XID DORA remains
false because this original NT35 changes XID between OFFER and REQUEST;
matching pairs and native lease data are retained separately. PCAP/status
alone is not the installed guest PASS. Generic harness flags remain
ASSESS_ENDPOINT/installed_runtime_pass=false, with separate manual proof.

Native safeShutdown operator17 precedes QMPquit/process0/QEMU0/cleanup.
Elapsed3543.99s; prepared-target2633.10s. Retained target:
`G:\USOS-Kolekcja\_vm\nt35-irq-fresh01\target-retained.qcow2`, SHA256
`3b76f15ac5eeb410ee3ca21711ef4a8f34729e3a9082427b3e849fb9586e4c6b`.
Clean SYSTEM REGF1.2/current=default1 SHA256
`881147a22ccac179837d89524d48cd9b28cdc57a3f1244b568c495e0319ae2fc`.
MS modules/hives stay in RAM/owned whole G images; scratch raw is removed.

Fresh **Client/noSharing FAIL** remains: native Server/Computer Browser
RUNNING, stopped Browser/ServerStart2Type32, Workstation2/32 and Tcpip3/1.
RasMan/RasAcd/RemoteAccess selected names are absent, without a complete
Dial-Up package absence claim. Policy is unchanged here. Separate S13
apply03/cold01 qualifies a diagnostic correction, not fresh AUTO policy.
PS/2 is explicit in this fresh baseline. Separate d94 usb01 [S9] remains
its own HID proof; S15 adds no HID/MSC/ServerSKU/SMP/X470/full-release PASS.
Old R20 first ping2/3, warm3/3 and approximately2s delay remain history.

Pinned local evidence under the nt35-fresh worktree:

- `artifacts/coverage/nt35-irq-fresh01/guest-evaluation.json`, SHA256
  `2fefbfd9390f894ab7293ab2a6f398d1119c4f55d0ada19d638e5838cd0fa628`.
- Append-only `guest-evaluation-addendum.json`, SHA256
  `7b701f7ddc6c36aa0509ffd1742377267f14f5d9da6b02fb8d16b03582b3040c`.
  It clarifies configuredDNS NOT_TESTED, seven selected service names and
  unique retained741097472B; two stick hardlink names do not double space.
- `stopped-readback.json`, `pcap-completed-analysis.json`, own FRESHNET.LOG;
  runtime frames/collector/own logs in
  `artifacts/coverage/vm/nt35-irq-fresh01`.
- Committed `docs/nt35-fresh-irq-runtime-evidence.json`, SHA256
  `8973e9ffa344248c2aeb42db53ee7ca1c664f4c0af15b285e259efe52a5c0939`.

Seven host boundary checks PASS; actual Windows replies, native shutdown
and installed SYS readback provide runtime proof. No VM/listener remains.
