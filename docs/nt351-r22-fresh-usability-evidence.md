# NT351 Workstation R22 — fresh install and LAN

QEMU only. Exact archive SHA256
`24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975`,
same four inventory identity fields as R18f. R22 is a new normal USOS
installation from the original ISO to actual Program Manager desktop,
Windows NT Workstation3.51 build1057. R18f USB/HID remains a separate
diagnostic overlay result; PS/2 input was allowed throughout R22.

Native release/renew/all returned10.0.2.15/24, gateway10.0.2.2,
DNS10.0.2.3,24h lease. Native ping5000ms passed3/3 with2353/2003/2003ms;
own logger ICMP echo_match1 passed1562ms. Strict UDP DNS1.1.1.1 and8.8.8.8,
TCP DNS1.1.1.1, native Winsock resolution and HTTP68k.news200 passed.
The approximately2s delay remains an unresolved RX/checker usability
limit. Frogfind HTTP timeout and unavailable gateway53/80 remain failures.

Pinned-MAC mirror223records/44639B has SHA256
`83e63e7de8db6ae3cfaa6900be7ef927bffcc14bbd988e9c15e46fa8f0bbca05`.
It confirms initial and renewed coherent DHCP pairs; Discover/Offer and
Request/Ack XIDs differ, so strict single-XID DORA stays false. Four
checksum/address/identity/payload-matched ICMP echo pairs corroborate
native ping and logger. This is not proof of IRQ or20ms polling.

Native safeShutdown operator15 and QMPquit/rc0 completed. Read-only
post-quit collector recovered five own text files and verified SYS
`f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a`.
Original MS modules/hives stayed in the whole disk image. No physical
deployment, merge or hub edits. No MSC, other-media, Server or X470 PASS.

Full evidence is in macierz-windows/artifacts/coverage/nt351-runtime-r22/
and its completed case directory; committed note and exact-source matrix
are in codex/macierz-windows20fa357b. Historical65 result records remain
unchanged; one reviewed desktop result appended. The frozen net3
manifest pins actual inputs; inherited nt351-inputs.json describes old
net2 and was not used as proof of effective files.
