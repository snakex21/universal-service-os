# NT351 client service policy: separate apply and cold overlays — QEMU only

`fix/nt351-net-client` d268e499 qualifies a diagnostic service-policy
correction after the completed fresh installation [S11]. The unchanged
fresh parent remains SHA256
`cb9d664615260a2e6b3c8e618be19b9cf785696019f41753b1461d3754b1196c`.
Its original Client/noSharing FAIL, with Server/Browser RUNNING/Start2,
remains. These separate overlays do not qualify fresh AUTO policy.

Apply02 stages only own CLNT351.EXE/ON; all1016 original file contents
remain identical. The explicit `/apply` completes, the visible own SCM
log confirms Browser/LanmanServer STOPPED and Disabled/Start4, and
Workstation/Tcpip remain RUNNING. Native `net start` lists Workstation
and DHCP Client, with Server/Computer Browser absent. Native safe shutdown
and QMP quit/rc0 precede bounded stopped readback.

Cold01 starts a new QEMU process from an empty, logically identical COW,
without adding or changing guest files. Readonly `/check` confirms the
same service states; its new log contains no native NET stop record.
Native service list again excludes Server/Computer Browser. Native ping
receives3/3 replies, all time<10ms. Native safe shutdown and QMP quit/rc0
precede independent stopped readback. Tcpip RUNNING is established by the
SCM query and ping; it need not appear in the Win32 native NET list.

Both clean SYSTEM reads select Current=Default1 and confirm Server4,
Browser4, Workstation2/Tcpip3. Own helper5632B SHA256
`ce6edde6808d37b3f51db322cedcea03ceda4beebb67ae051caec2cba7c55976`,
SYSf579/17024B and USB2d455/32128B match their pins. Apply target SHA256
`ada76f4ee4dbac2714cfdb08b067da147da370499f199df5b88885d3b40394d5`;
cold target `c220dc83a421633d91fa603c666af5aafe48538c73694a1dc7347efcb04cdb1b`.
Parents remain unchanged; temporary whole raw files are removed. No
Microsoft module/hive is exported. COM1 and generic runtime flags alone
are not policy PASS; the manual assessments combine SCM, native services,
new cold ping and stopped readback.

These trials retain PS/2 and i8042prt Start1/USB Start1; they add no USB
isolation, MSC, DHCP/DNS/HTTP, Server SKU or X470 qualification. Selected
RAS services are absent; full Dial-Up installation absence is unproven.
Apply01's separate operator-preflight HARNESS_FAIL remains historical.
Fresh AUTO policy still needs explicit helper completion in the normal
installer, a new blank target and its own service/LAN/shutdown/readback.

Source: `nt351-client/docs/nt351-client-only-policy.md` at d268e499 and
`nt351-client/artifacts/nt351-client/{apply02,cold01}/evaluation.json`,
with the corresponding `readback.json`. Evaluation SHA256 pins:

- apply02: `671b2f94e898780ad00b6055620894cbf24532e7f7d34ba4d54302ab19a74b03`
- cold01: `dc9184cb4f7542e70f76bbf905b782a5a5190d86813b13a987880722ef7b8f4b`
