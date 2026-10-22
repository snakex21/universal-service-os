# Fresh NT3.5 Workstation with corrected d94 driver

Separate `fix/nt35-net-fresh` commit `4cd6a3bf` qualifies
`nt35-irq-fresh01`: normal USOS installation from exact R20 media to a
new blank standalone4GiB target, actual Program Manager/Version3.5.
The private R20 cache changes only own SYS+SHA;835 other effective entries
and all other cache files remain identical. No policy helper is added.

Actual installed16384B SYS is
`d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85`,
verified by two independent stopped reads. Retained target:
`G:\USOS-Kolekcja\_vm\nt35-irq-fresh01\target-retained.qcow2`, SHA256
`3b76f15ac5eeb410ee3ca21711ef4a8f34729e3a9082427b3e849fb9586e4c6b`.
Native safeShutdown/operator17 precedes QMPquit/process0/QEMU0/cleanup;
clean SYSTEM REGF1.2/current=default1 and scratch cleanup are confirmed.

Native DHCP release/renew/ipconfig gives10.0.2.15/255.255.255.0,
gateway/DHCP10.0.2.2 and configured DNS10.0.2.3. Native ping3/3 is<10ms;
strict ICMP matches the echo at0ms. Frozen loggerff258504 passes strict
**fixed** UDP DNS1.1.1.1/8.8.8.8 at30/40ms, TCP1.1.1.1 connect21ms;
native gethostbyname succeeds40/20/60ms, HTTP68k.news200/connect130ms.
Strict matched configured10.0.2.3 DNS is **NOT_TESTED** by this logger;
ipconfig configuration, native resolver and fixed DNS are separate proof.
Gateway53/80 and FrogfindHTTP negatives remain recorded.

Fresh Client/noSharing remains **FAIL**: Server/Browser RUNNING and
Start2Type32. A separately qualified policy overlay does not make this
fresh AUTO policy PASS. PS/2 is explicit; d94 HID usb01 is a separate run.
No new HID/MSC/AUTO/ServerSKU/SMP/X470 qualification is inferred.
Historical R20 first ping2/3, warm3/3 and approximately2s delay remain.
This supplements the already qualified desktop, without adding a row.

Full source proof: `nt35-fresh/docs/nt35-fresh-irq-runtime-evidence.json`
and usability S15 `docs/nt35-fresh-irq-evidence.md` on `8eaa493e`.
Assessment `nt35-fresh/artifacts/coverage/nt35-irq-fresh01/guest-evaluation.json`
SHA256 `2fefbfd9390f894ab7293ab2a6f398d1119c4f55d0ada19d638e5838cd0fa628`,
with append-only addendum clarifying configuredDNS NOT_TESTED and retention.
