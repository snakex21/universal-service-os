# NT4 installed LAN07: completed strict qualification [S16]

Exact NT4 Workstation PL media and SP6a association remain [S14]. Separate
`fix/nt4-net` sourcec06435bf completes `nt4-installed03-network07`, a BIOS
q35/igb/AHCI cold overlay of the stopped candidate03 target. This is not
fresh AUTO network setup or the original OVMF-to-CSM warm transition.
The immutable parent SHA256 is
`cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21`.
Sourcefix f00b1597 selects NDISLoop Start2; matched control06 retained
Start3 and had no adapter. LAN05 remains false for hidden FIRSTLO_FAILED
and the old logger's missing global DHCP DNS handling.

LAN07 has actual first-logon observation, `TESTNET_DONE`, and completed
root collector gates **dhcp_pass/gateway_pass/dns_pass/
lan_traffic_matches_lease=true**. Its first-logon-scoped DHCP-only capture
contains complete DORA, XID140cc72d/MAC52:54:00:55:53:01, address10.0.2.15,
server/gateway10.0.2.2, DNS10.0.2.3, lease86400s. PCAP1952B/4stored frames,
SHA256 `00b4ccb72d2bad7d4482868e6e021dc0b3c970d3ccb923d0ae5b4a0813b7b0b9`.
It is DHCP-only; ICMP and DNS qualification comes from the own guest NET
excerpt, not from nonexistent ICMP/DNS PCAP frames.

Guest gateway ICMP has **echo_match1**, RTT31ms. Configured UDP DNS matches
**10.0.2.3:53, idD7A0, questionfrogfind.com, A64.227.13.248**, dns_match1,
reply63ms. Fixed UDP1.1.1.1/8.8.8.8 also pass63/62ms, TCP1.1.1.1 passes
with connect62ms, and native gethostbyname returns64.227.13.248 after94ms.
GatewayUDP53 has no reply3000ms and remains negative. This is configured
DNS qualification, distinct from older fixed-DNS-only logger results.
No browser/HTTP, MSC or new IRQ result is inferred.

Actual stopped readback pins the unchanged old SYS and USB plus new EXEs:

| Own payload | Bytes | SHA256 |
|---|---:|---|
| USOSNET4.SYS | 21376 | 4f2eb16b71753baab740302025b9e8ba02c38a676670b13626c757bdb3700f8d |
| USOSUSB.SYS | 32128 | 2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1 |
| NT4OBS.EXE | 5632 | 82279b889053a68f42f18fdaeb0a1c0b5a76a00ce21e2685bedb9cb18dc38284 |
| USOSLOG.EXE | 1024000 | fe4ffa555e1cc837185156e7b76639d86b14580150663fd310c35ce3807c94c2 |
| FIRSTLO.CMD | 206 | c0f82213bb319445a9ea6d1407608af2b2cec53cbc633a9931ef4802e3bdbedc |

The collector's network policy explicitly updates the two expected EXE
pins; strict peer/port/transaction/question and lease gates remain.
Preparation reports only these own payload changes and NDISLoopStart3→2;
other virtual-disk bytes match. Host original-import preflight does not
supply the runtime PASS. Completed guest results and readback do.

Native Winver operator09 confirms Service Pack6a; stopped CSD reports
SERVICE_PACK_6. Native safeShutdown operator12 precedes QMPquit/rc0.
Elapsed684.207s; clean SYSTEM/SOFTWARE checksums and sequences pass.
Observer arm/hooks are absent after completion. Workstation/Tcpip/Dhcp
Start2, Server/BrowserStart4; i8042prt/USBStart1. PS/2 is explicit, without
new USB isolation qualification. Final closed target
`G:\USOS-Kolekcja\_vm\nt4-installed03-network07\target.qcow2`, SHA256
`29036264e022d760223f2f091805e8c170888b3b8d6b1f933888c0193ce0da10`.
No registry/answer/key/MS binary export occurs; scratch whole raw removed.

Pinned completed metadata:

- `macierz-windows/artifacts/coverage/nt4-installed07-network-excerpt/collection.json`,
  SHA256 `eb535a3ce535a4493a359c5b89fc0c65f442d69637b5288b7e4d0237de8f86c6`.
- `nt4-net/artifacts/coverage/vm/nt4-installed03-network07/result.json`,
  SHA256 `1e753660ec20f84ff4deda75ad4ce519c6edc0ae71238971bffef365243d80de`;
  `completed.json` SHA256
  `14eb25e4fe80779a092397e4324834e2b79b7597d68331057cbf071746054576`.
- `nt4-net/artifacts/nt4-success-review/candidate07-stopped-readback.json`,
  SHA256 `c21759a064c079d4b8444b6511e979769bae9ea94e8fb9b907b564d17470d427`.
- Same folder `candidate07-network-preparation.json`, SHA256
  `3a3b976bce3a5bf1309f67c28cdcd20aca4bb4777b48c1ec7b81d30d506d2067`;
  `candidate07-payload-preflight.json`, SHA256
  `14ed6e1936b70b20011408cf6174a20a11b66d6e66dad0efcb3641543bb93e81`.

Raw runtime lan/hid/msc fields remain false and are not rewritten. S16
binds this LAN qualification to the strict completed collector/traffic
and actual installed payloads. S14 HID remains separate; MSC and new
IRQ89/08 await their own evidence. No fresh AUTO/X470/Server or new IRQ
SYS PASS is promoted. No VM or frozen asset is changed by this doc update.
