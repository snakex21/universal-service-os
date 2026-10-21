# NT3.5 Workstation R20 / R20b — desktop, LAN and USB HID

**QEMU only.** Exact archive:
`Windows NT 3.5\Windows NT 3.5 Workstation 3.50.807 EN (ISO + boot disks).7z`,
SHA256 `e63ce7b63906cfad0b705200ca8f1318d8620d88370ab26ce5ba6fbe8bdd5236`.
Original ISO SHA256
`109d2c28e3d774e01987434b11c622fbf336e01f28eec2eafe40544f166852d1`.
The inventory displays the binary-resource version3.50.800.1; actual
Windows desktop identity is Workstation3.5 build807. No other medium,
Server, architecture, NT3.1 or NT3.51 inherits this result.

R20 completed a fresh normal USOS installation, actual desktop, native
safe shutdown and QMP quit/rc0. Its corrected desktop proof is operator12;
the old harness overwrote endpoint.png with its final shutdown frame.
The initial evaluation JSON was preserved before correcting this reference.

Own usosnet35 SYS is16384bytes, SHA256
`e1aa69a3ec8e3da802013131abbb6fefc9f466da6f4eeb66fe15ec47e60421c5`.
Frozen USB SYS is
`2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1`.
The sole NIC is igb82576/8086:10C9, MAC52:54:00:55:53:01.
The source cache is B261020-200536-968CCBE8-nt35-net1 with initrd
`8bfc9d006670aeb05970383cde2e14da709dd28646f3ed66537fd0f81c6b1790`.

Native release/renew yielded10.0.2.15/24, gateway/server10.0.2.2,
DNS10.0.2.3 and24h lease. Initial native ping5000ms was2/3, warm3/3
(2614/2003/2003ms). Actual guest logger returned matching ICMP echo1122ms;
UDP DNS1.1.1.1 and8.8.8.8 and TCP DNS1.1.1.1 passed strict matching.
HTTP68k.news returned200. Gateway used as a DNS server and frogfind HTTP
had failures; those original observations remain in the evidence.

Capture SHA256
`1a020e28132e93e54b57ce78d02a0e7cf707067479fcb0326fccb41f8d85a070`.
Native renew records101/102 are Discover/Offer with XID3107090533;
103/104 Request/Ack use XID3009786686, with matching MAC/address/server
and lease parameters. Strict single-XID DORA remains false; coherent
lease_exchange_observed and actual guest readback are separate evidence.

R20b is an overlay changing only i8042prt Start1→4. Hardware i8042 remains
present for NTDETECT, classes/USB Start1, ConnectMultiplePorts1 and
MaximumPortsServiced3. Actual keyboard out/in, mouse out/in with movement
and a separate click opening Browse passed. With the mouse absent, the
USB keyboard changed Run to File menu on a responding desktop. After
native safe-shutdown/QMPquit0, readback confirmed REGF1.2, Current/Default1,
Start4 and unchanged driver hashes and baseline. Read-only own-file
collection was rerun to the permitted root coverage output after its
first attempt rejected the wrong output worktree before spawning a VM.
The original rejection was retained; the corrected collection read5/5 files.

R20b native ping5000ms passed3/3 (1322/2003/2003ms), while the1s logger
ICMP failed11010. DNS and HTTP200 worked. The short-timeout failure remains
a failure. The approximately2s fallback is an unresolved usability limit;
this is not proof of20ms service or X470 IRQ behavior.

Detailed evaluations/readbacks are
`nt35-net/artifacts/nt35-network/r20-guest-evaluation.json`,
`r20b-usb-evaluation.json` and `r20b-stopped-input-readback.json`.
USB frames are in `nt35-net/artifacts/coverage/vm/r20b-nt35-usb-isolation`.
The agent's documentation is committed as fix/nt35-net bf7c4774.
Five R20b own files are in
`macierz-windows/artifacts/coverage/nt35-stopped-r20b/own-evidence/`.
No registry hives/system modules were exported, no hub code was changed,
and no merge/push/physical deployment occurred. MSC remains after1.0.
