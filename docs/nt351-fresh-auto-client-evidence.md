# Fresh NT3.51 AUTO client-only and LAN [S22]

Proof commit `fix/nt351-auto-client-net` b7757f2274e0057e2f2ec31f833ed38f0a6ac9da.
Frozen codeaa225ad6, input874c4bf1. Exact Workstation EN PROFILE source
NT351_R18F_ROW, build1057/x86/windows-nt-3-51 csmwrap. ArchiveSHA
24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975;
ISO b9d0e8417c1f502d1de22c249401b593be2a7fe59524b27a624dfa8dedaa099c.

New standalone blank4GiB target and normal USOS. Three effective cache
entries changed (POST, network351 script, target script),829 identical.
Actual SYSf579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf
(17024 B); POST615f6d6b49b3c53df62603b804195f80c0d431dad4b2d88145ece1ad166ed48b
(30208 B/PE3.10),50 imports checked against original351 in RAM.

Actual desktop3.51, native net start has DHCP Client and Workstation with
no Server/ComputerBrowser. No manual policy write/helper. Native DHCP
release/renew10.0.2.15/24, router/DHCP10.0.2.2,DNS10.0.2.3. Ping3/3:
10,<10,<10ms, not all strictly<10. Fresh own logger matched gateway
ICMP0ms, fixed UDP DNS1.1.1.1/8.8.8.8 and TCP1.1.1.1 IDsD69F/DFE6/BE54;
native configured resolver and HTTP68k.news200. Strict matched configured
10.0.2.3 peer packet is not claimed. Negative gatewayDNS/HTTP timeouts
and strict same-XID DORA=false remain; native/guest evidence is separate.

Native safe-off11, QMP/parent/collector0; elapsed2612.14s,collector22.95s.
Independent stopped selected Current/Default1: Browser/Server4/32,
Workstation2/32,Tcpip3/1,NDISLoop2/1,own POST4/16. Two actualSYSreadbacks
and POST match. Target915f6945b90cd9fb627160b22136c54bedecfed6d4ef8e8d323e0d626c9e067e
retained with own stick/vars; original Microsoft bytes only RAM/whole G images.

First frozen collector misspelled CLNT3511.REQ/LOG/ERR. That result is
preserved. An independent bounded stopped FAT reader matched exactly the
public bytes of real CLNT351.REQ/LOG and confirmed ERR absent; no new VM.
Future collector transform fixed with wrong-version/duplicate/typo tests.
32 targeted methods PASS, including actual common C and351 takeover cases.

Source WT `tools/tests/nt351_auto_snapshot/completed/source-and-evidence-proof.json`
SHA02d9efbff0763d636968ba6982e038e252abb4f3d2031e5a63ccc51c1c9f0167;
tracked LF assessment39aea23dd515fe52689feee831ae41843ce936966aae6318b11dd7adbec9130d.
Root independently verified all22 declared raw C-artifact hashes, read the
assessment/source report and viewed actual native service03/safe-off11.
The tracked snapshots use LF; original raw evidence hashes stay unchanged.

Only exact PROFILE Workstation EN QEMU PS/2 baseline. No fresh DEFAULT,
USER/Server/NT31, new USB out/in/MSC, physical/I211/SMP/full IRQ route or
full release PASS. Shared core tests do not qualify POST615 natively on
NT3.5: its separate qualified tuple is POST87cb/SYSd94 [S21]. Old fresh
sharingFAIL [S11] and separate policy overlay [S12] remain historical.
No merge, push, physical write or modification to USB/hub source.
