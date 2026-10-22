# Fresh NT3.5 AUTO Client/noSharing and LAN [S21]

Source proof: `fix/nt35-auto-client-net` e129273f5620251fa867c47ad4651aedb9eca957.
Runtime code1feadbaf534d4546c42a051b6d34d430371d8f89, private fixture8c7dba7e.
Exact source matches NT35_R20_ROW: Workstation3.50.807 EN archive,
build3.50.800.1/en-US x86/windows-nt-3-5 csmwrap. Original archive
e63ce7b63906cfad0b705200ca8f1318d8620d88370ab26ce5ba6fbe8bdd5236;
original ISO109d2c28e3d774e01987434b11c622fbf336e01f28eec2eafe40544f166852d1.

New blank target, normal USOS, three effective initrd entries changed and
834 others identical. Frozen POST87cb43259878583758269b979c8e59411d69366ce5d58ec949a51638786d449f
(30208 B), SYSd94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85
(16384 B). Request is staged only for network-on Workstation DEFAULT/PROFILE.
Existing POST configures Browser/Server Disabled after verified takeover;
there is no manual policy helper or post-boot service modification.

Actual native Program Manager3.5, net start (DHCP Client and Workstation,
no Server/Computer Browser), DHCP release/renew10.0.2.15/24 with router/
DHCP10.0.2.2 and configuredDNS10.0.2.3. Ping3/3<10ms. Unchanged logger
has matched gateway echo0ms, fixed UDP DNS1.1.1.1/8.8.8.8 and TCP DNS1.1.1.1
with exact IDs/questions, native resolver success and HTTP68k.news200.
Strict configuredDNS10.0.2.3 is NOT_TESTED; HTTP is the own logger, not IE.
Gateway DNS no-reply and HTTP connection timeouts remain in the log.
Strict DORA=false remains; packet capture alone is never guest PASS.

Native safe-off operator17, QMPquit0/parent0 and completed cleanup.
Independent stopped readback: current/default1, Browser/Server4/32,
Workstation2/32, Tcpip3/1, actual SYS and POST match, REQ matches, ERR absent.
Target retained b316b2faeec744cfb90cddd1a84cac3b50f9c7b63b47c3f3ad7d4290f5021f8a.

Committed proof `docs/nt35-auto-client-runtime-evidence.json` in source WT:
SHA29844c7c09fc5227fd98486c5fcbd0d01f4b2863dbda13bdd3d5161be0171597;
assessment SHA c5b86a2c81cc0bf1a897f2371406b4f94c680766eff64fc78903eeefb158173b.
Root independently checked all32 declared proof hashes and viewed actual
operator10/17. Six selected-ControlSet/native-enumeration guard tests PASS.
Generic first_logon_observed=false/installed_runtime_pass=false remain
unaltered; the separate assessment binds the actual native observations.

QEMU AHCI/igb PS/2 baseline only. No new HID/MSC, Server/USER, NT3.1/3.51,
SMP, X470, SMB-client transfer or general driver-copy failure-stop PASS.
Legacy drivers[] CopyFile failures/void set_dword are not hardened here.
Earlier fresh sharingFAIL [S15] and overlay policyPASS [S13] remain valid
history of different frozen packages. Microsoft bytes stay in RAM or
whole own G images; no merge, physical deployment or USB/hub change.
