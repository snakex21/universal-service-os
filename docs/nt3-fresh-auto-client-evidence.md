# Fresh NT3.5 / NT3.51 AUTO client policy after earlier desktop qualification

These are new normal USOS installs onto separate blank targets, with
automatic client/no-sharing configuration before first targetboot. The
existing13 reviewed-desktop count stays unchanged: these are already
qualified exact Workstation media, not additional inventory rows.

| Actual fixture | NT3.5 | NT3.51 |
|---|---|---|
| Branch | fix/nt35-auto-client-net | fix/nt351-auto-client-net |
| Final proof commit | e129273f5620251fa867c47ad4651aedb9eca957 | b7757f2274e0057e2f2ec31f833ed38f0a6ac9da |
| Runtime code | 1feadbaf | aa225ad6 |
| Exact own SYS | d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85 /16384B | f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf /17024B |
| Exact own POST | 87cb43259878583758269b979c8e59411d69366ce5d58ec949a51638786d449f /30208B | 615f6d6b49b3c53df62603b804195f80c0d431dad4b2d88145ece1ad166ed48b /30208B |
| Native policy | Workstation/DHCP active, no Server/Browser | Workstation/DHCP active, no Server/Browser |
| Native DHCP |10.0.2.15/24,router.2,DNS.3 |10.0.2.15/24,router.2,DNS.3 |
| Native gateway ping |3/3<10ms |3/3 (10,<10,<10ms) |
| DNS/HTTP |strict fixed peers, native configured resolver, own logger HTTP200 |strict fixed peers, native configured resolver, own logger HTTP200 |
| Finish |nativeSafe17,QMP0/parent0 |nativeSafe11,QMP0/parent0 |

Independent clean stopped selected ControlSet readbacks match actual SYS/
POST and Browser/Server Start4 Type32; Workstation2/32,Tcpip3/1. No manual
policy helper or post-boot service modification supplied the result.
Runtime code guards are finite; USER/Server/NT3.1 are not qualified here.
NT351 is the exact PROFILE fixture, not a new DEFAULT qualification.
Shared host C tests do not give POST615 a native NT35 qualification.

NT35 committed proof `docs/nt35-auto-client-runtime-evidence.json` SHA
29844c7c09fc5227fd98486c5fcbd0d01f4b2863dbda13bdd3d5161be0171597;
assessment c5b86a2c81cc0bf1a897f2371406b4f94c680766eff64fc78903eeefb158173b.
Root independently verified32 artifact hashes and native frames10/17.
NT351 proof `tools/tests/nt351_auto_snapshot/completed/source-and-evidence-proof.json`
SHA02d9efbff0763d636968ba6982e038e252abb4f3d2031e5a63ccc51c1c9f0167;
tracked assessment39aea23dd515fe52689feee831ae41843ce936966aae6318b11dd7adbec9130d.
Root independently verified22 raw evidence hashes, actual compiled C/header
hashes and native frames03/11. NT351 first collector's CLNT3511 typo remains
historical; real CLNT351 public records were independently matched in the
bounded stopped reader without a new VM. Six NT35 and32 NT351 targeted
host methods PASS; original raw/runtime false fields were not rewritten.

Strict matched configuredDNS10.0.2.3 packet tests remain unqualified;
fixed peer DNS and native resolution are separate facts. Strict same-XID
DORA=false and negative gateway DNS/HTTP probes remain in the evidence.
HTTP200 belongs to the own logger, not IE. No new USB/HID/MSC, X470/I211,
SMP, SMB-client transfer, general USB-copy failure-stop or whole release
PASS is inferred. Older fresh sharingFAIL and separate overlay policyPASS
still describe their original packages. Current targets/vars/sticks are
retained on G; no physical write, USB/hub source change, merge or push.

Detailed source-bound capability documents are S21/S22 in
`codex/usability-usb-net` commits a20533e2 and d98331cc;15 classification
tests PASS and only the corresponding exact NT35/NT351 LAN cells changed.
