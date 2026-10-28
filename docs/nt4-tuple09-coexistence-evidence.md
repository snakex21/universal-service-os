# NT4 tuple09: one-VM basic USB HID/MSC and LAN coexistence [S20]

Source proof is `fix/nt4-net` commit
`511b44a221e171f82414618b8004d0404b021b2c`. Exact original source:
`Windows NT 4.0\Windows NT 4.0 Workstation PL.iso`,502075392B, SHA256
`7aae3d7c36619c4edab58c8dccf9d350c78639f88afa36ae6b21e2e9cee9611b`;
staged original SP6a PL SP6I386.EXE SHA256
`a3306f0bc93d1d4709ab784ecd8aebd1a162c8249a219a9e078d1a4a91260542`.
Parent07 native Winver showed SP6a;08/09 preserve original OS binaries.
The binding remains only build4.0.1381.1/pl-PL x86/windows-nt-4 csmwrap.
No different ISO, Server, language or architecture inherits S20.

One completed BIOS q35/AHCI/igb VM qualifies basic coexistence of the
frozen USB313952/43648B package (HID and MSC) with NET89b/21248B Start2.
Native i8042 hardware remains present, i8042prt Start4 isolates USB input.
Source is the exact NT4 Workstation PL ISO7aae3d7c...e9611b, original
candidate03/installed SP6a. This is not fresh AUTO, X470, full IRQ-route,
HTTP/browser or Explorer automatic-refresh qualification.

A new COW of completed08 f0f976...820ee changes only original USB file,
its declared FAT allocation/size, one existing SYSTEM i8042prt DWORD1->4,
and two own additions MSC4TEST.EXE/ON. Actual measured cluster32768B requires
USB chain1->2; first cluster retained, three previously free own clusters
supply the extra USB cluster plus two additions. Full4GiB unrelated-byte
compare, raw/COW compare and independent full2053-file inventory pass;
2051 original file contents remain identical. NET/helper/logger unchanged.
Original-import preflight resolves frozenUSB38 and quiet MSChelper14 imports.
An offline first guard rejected an assumed64KiB cluster before VM/patching;
actual BPB32KiB correction and failed-preflight metadata are retained.
No Windows failure is assigned to that host preparation mistake.

Actual run: GUI helper READY, actual first-logon token and TESTNET_DONE.
Inherited own NET log was deleted at step4 before testing. Native IPCONFIG
shows10.0.2.15/24, DHCP/router10.0.2.2 and configuredDNS10.0.2.3.
Readonly strict collector30.970s/rc0 has all driver/token/DHCP/gateway/DNS/
lease gates true. DHCP-only capture contains complete DORA XID0f3d643a,
MAC52:54:00:55:53:01, lease86400s. ICMP echo_match1/RTT0ms; configuredDNS
matches peer10.0.2.3:53, ID706F, questionfrogfind.com A and64.227.13.248,
reply15ms. Fixed DNS and native resolver are separate; gatewayDNS no reply
remains negative. No stale parent success line supplies the result.

| Actual native observation | Completed frames |
|---|---|
| Explorer desktop and fresh NET run/status/IPCONFIG | 02,04–10 |
| Keyboard out +a,b changes nothing; in +c,d types nt4tuplecd | 11–14 |
| Mouse out, keyboard types mouseout, cursor stays; in moves and clicks Start | 15–18 |
| STARTUP:0, native Notepad reads D:START.TXT | 19–20 |
| HOT:0, fresh E:HOTPLUG and ROUNDTRIP shown in Notepad | 21–25 |
| Remove through DEVICE_DELETED; new Explorer right pane has only C,D | 26–27 |
| Same named backend reinsert; REPLUG:0 only reads persisted data; Notepad confirms | 28–31 |
| Mouse still clicks Start after all MSC operations | 32 |
| Final gateway ping after USB4/4, RTT16/<10/<10/<10ms | 33 |
| Native shutdown, safe-off, then controlled QMPquit0 | 34–36 |

The new Explorer right pane updates correctly, but its left tree retained
stale E after removal, and old windows did not auto-refresh. Those behaviors
are not PASS. Strict read/write/flush/close/reopen/persisted reinsert and
basic coexistence are PASS. No USB source, hub, binary or tester was changed:
completed operator/completion parser/helper75cef are reused from6457ab4b.
NET and MSC use one bounded serial consumer and run their COM1 operations
serially. Three actual archived-class tests pass exact token/idempotence,
NET vs armed MSC isolation and unsolicited/duplicate MSC rejection.

Stopped readback: clean selected SYSTEM, exact six own payloads, i8042prt4,
USB/classes1, NDISLoop/TCPIP/DHCP/Workstation2, Server/Browser4,
TESTNET_DONE; fresh MSC log has3PASS, one write/flush/close and2readbacks.
Own FAT16 boot/hot media retain exact labels/markers and persisted bytes.
Parent08 remains unchanged; original Microsoft bytes are only in RAM or
owned scratch disks, and every declared raw scratch was removed.
Raw runtime generic PASS fields remain false; separate actual evaluation
sets combined_basic_pass=true from these completed observations and gates.

| Actual own payload | Bytes | SHA256 |
|---|---:|---|
| WINNT/SYSTEM32/DRIVERS/USOSNET4.SYS | 21248 | 89b7337c294ca0c56415cdc4e7023615a628ae8158a5a7ab80dcf6f35ca02233 |
| WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS | 43648 | 3139522926f054946b280c14c962593062817a0ca71170a5aeeb8551a6fab2a1 |
| USOS/COVERAGE/NT4OBS.EXE | 5632 | 82279b889053a68f42f18fdaeb0a1c0b5a76a00ce21e2685bedb9cb18dc38284 |
| USOS/COVERAGE/USOSLOG.EXE | 1024000 | fe4ffa555e1cc837185156e7b76639d86b14580150663fd310c35ce3807c94c2 |
| USOS/COVERAGE/FIRSTLO.CMD | 206 | c0f82213bb319445a9ea6d1407608af2b2cec53cbc633a9931ef4802e3bdbedc |
| USOS/NT4/MSC4TEST.EXE | 5120 | 75cef5e2e8be39b1cdc3d52a0f414464a86cd85fb0513de1139133fc3ac6429e |

Closed target `G:\USOS-Kolekcja\_vm\nt4-installed08-usbmsc-hid-net09\target.qcow2`, SHA256 `6c4e80a34c20544c314cb3ad88a0e0222320bd0550351d2f4fbc7f3c95e35743`.
Parent08 SHA256 `f0f976d0af544fc3b2a87dbaac84811785332d9ef487d6e3e0c6a1ed6ad820ee`, unchanged.

- `C:\Users\ASRock\usos-work\nt4-net\tools\tests\coverage\nt4page_snapshot\installed03\tuple09\preparation.json`, SHA256 `1960450136509e4b5b5840c67a7a9c762376623e8d06f2e9cc96d191d27c02ed`.
- `C:\Users\ASRock\usos-work\nt4-net\tools\tests\coverage\nt4page_snapshot\installed03\tuple09\stopped-readback.json`, SHA256 `c982eacb8de11382c1edbbe59eb446edb370cf957513578f849c93b35cb5074b`.
- `C:\Users\ASRock\usos-work\nt4-net\tools\tests\coverage\nt4page_snapshot\installed03\tuple09\evaluation.json`, SHA256 `3792ae307bd09cf87751b24d5618e4a16e7f90a97e82e1b1dda49ae5c9ef1a64`.
- `C:\Users\ASRock\usos-work\nt4-net\tools\tests\coverage\nt4page_snapshot\installed03\tuple09\network-collection.json`, SHA256 `c6f8e11b6e8c0a4686b05382fdc859fe612e6201687f3e714e1c874d33ae7d59`.
- `C:\Users\ASRock\usos-work\nt4-net\tools\tests\coverage\nt4page_snapshot\installed03\tuple09\runtime-result.json`, SHA256 `84c8d0cc3ca7d1a9c363016ff2451409f903000115be65f7859f5c3b9527d557`.
- `C:\Users\ASRock\usos-work\nt4-net\tools\tests\coverage\nt4page_snapshot\installed03\tuple09\runtime-preflight.json`, SHA256 `377a9a4f16d31aab62d3ce9cf5d87258fc71127a3a1599425b6864ae3b0f138c`.

All raw runtime/operator images and PCAP remain in the own C artifacts;
collector transport was copied to C before any qcow2 cleanup. Source
snapshots preserve used code content (LF text normalization only); actual
raw source hashes remain in runtime-preflight/evaluation. No private Setup
frame, EDIT, answer, key, raw registry or Microsoft file was exported.
