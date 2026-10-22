# NT3.51 Workstation R18f — completed installed-system diagnostic

QEMU only. Branch `fix/nt351-net`, assessment commit
`b762b240485c993308ae515789f0003b71e69844`.
No merge, deployment or qualification of another Windows edition.

## Exact inputs and configuration

- Inventory row: `Windows NT 3.51\Windows NT 3.51 Workstation 3.51.1057.1 EN.7z`.
- Archive SHA256: `24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975`.
- Original ISO SHA256: `b9d0e8417c1f502d1de22c249401b593be2a7fe59524b27a624dfa8dedaa099c`.
- Installed own network driver: `f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a`.
- Frozen own USB driver: `2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1`.
- Sole network device: QEMU igb `8086:10C9`, MAC `52:54:00:55:53:01`.
- Hardware i8042 remains present for NTDETECT. OS `i8042prt` Start=4;
  USB and class drivers Start=1. MaximumPortsServiced=3 and
  ConnectMultiplePorts=1 for both classes. Readback used Current/Default
  control set1, after Windows native shutdown and QEMU exit0.

Normal USOS installation produced the preserved R18b system. Subsequent
cold-boot overlays diagnosed bus initialization and isolated USB input.
R18f is a real installed Windows test, but its diagnostic hive changes
and new network driver are not yet a fresh end-to-end installer recipe.

## Completed observations

| Test | Result |
|---|---|
| Actual Program Manager desktop | PASS |
| USB keyboard removed: Run does not open; reinserted: Run opens | PASS, operator04/06 |
| USB mouse reinserted: visible movement and click opening Browse | PASS, operator10/11/12 |
| Only mouse removed: USB keyboard opens Run and desktop responds | PASS, operator25 |
| Mouse reinserted again: visible movement | PASS, operator27 |
| Native DHCP release/renew and guest address readback | PASS, 10.0.2.15/24, router/server10.0.2.2, DNS10.0.2.3, lease86400s |
| Native ping timeout5000ms | PASS, 3/3 replies, 821/1823/2003ms |
| Own logger ICMP | PASS, matching echo, status0, replies1, RTT440ms |
| Own strict DNS UDP1.1.1.1 / UDP8.8.8.8 / TCP1.1.1.1 | PASS, matching transaction/question/address |
| Native resolver and HTTP68k.news | PASS, HTTP/1.1 200 OK |
| USB mass storage | Not tested; NT3 storage remains after1.0 |
| X470 / Server / NT3.1 / NT3.5 | Not qualified by this run |

The transient uniform teal frame after mouse removal did not establish a
hang: a subsequent USB keyboard action opened Run while the mouse was
still absent. Its repaint mechanism is undiagnosed.

The IRQ watchdog selected NDIS-owned checker fallback at nominal2s.
High latency is an unresolved limitation. The older R18e logger1s ICMP
failure remains a failure; the later result does not rewrite it.

Completed R18f PCAP contains171 records/36433B, SHA256
`5527484406c05e1ee8848f14326deb7dfae7f3f52a81bbc1afb2ee2b93080d90`.
Discover/Offer records92/93 use XID4131715410, Request/Ack94/95 use
XID4132504862 with matching client/server/address and lease parameters.
Strict single-XID DORA=false remains unchanged. A separately assessed
coherent lease exchange and the actual guest lease/traffic support DHCP.

## Retained evidence

Completed metadata under `nt351-net/artifacts/nt351-network/`:
`r18f-guest-evaluation.json`, `r18f-stopped-input-readback.json`,
`r18f-pcap-completed-analysis.json`, `r18f-usb-isolation-preparation.json`.
Five own guest files are in the matrix R18f `nt351-own-evidence` folder.
The old collector's expected-driver-hash mismatch remains recorded;
manual readback matches the approved f39d58fd override manifest.
