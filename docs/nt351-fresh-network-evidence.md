# NT351 corrected IRQ: fresh normal USOS qualification — QEMU only

`fix/nt351-net-fresh` 664d721e (preparation f67b84af/498e9895/b16f2f3e)
starts from the exact R22 inputs and a blank target. The private cache
changes exactly two of 832 initrd entries: own f579 SYS and its SHA sidecar;
830 entries and all other cache files remain identical. Original frozen
inputs are unchanged. New initrd SHA256:
`2540baab9efb257396fc21d58a3572f9a774bf2212593ea37ad25e61c4a8d820`.
The own SYS is 17024 bytes, SHA256
`f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf`.

The normal OVMF/USOS/micro-Linux/CSMWrap installation reaches Program
Manager, Workstation3.51, using the same hardware argv as R22 apart from
owned paths/ports. Native DHCP renew/all gives10.0.2.15/24, gateway.2,
DNS.3. Native ping receives3/3, every reply below10ms. Matching ICMP0ms,
strict UDP DNS40/51ms, TCP DNS20ms, native name lookup90ms and HTTP68k200
pass. Historical gateway/frogfind timeouts are retained separately.

Native safe shutdown/operator16 precedes QMP quit and TTY2659 exit0.
Two independent stopped reads confirm the actual f579 own SYS,17024B.
Strict same-XID full-DORA remains false; guest lease/renew evidence is
separate. Six new host tests pass. No new USB out/in, MSC, Server or
physical-X470 claim is inferred from this fresh run; PS/2 is allowed.

Client/noSharing is explicitly FAIL: native service list has Server and
Computer Browser RUNNING, and selected REGF1.2/CurrentDefault1 readback
finds both Start2/Type32. Workstation is2/32 and Tcpip3/1. Nothing was
changed in this trial. A separate helper-only policy overlay is under
test; no completed apply/cold policy PASS is added here. Successful LAN
does not override the policy failure. This private-cache qualification
also does not claim incorporation into the default release assets.

Local full report/assessment:
`nt351-fresh/docs/nt351-fresh-irq-qualification.md` and
`nt351-fresh/artifacts/coverage/nt351-irq-fresh01/guest-evaluation.json`.
Closed target-retained.qcow2 SHA256
`cb9d664615260a2e6b3c8e618be19b9cf785696019f41753b1461d3754b1196c`;
SYSTEM hash `e8f6295b58248e6568c804eab170af2a165d934a93a1bf8bfe9789424fa0ca65`.
No hive/Microsoft module was exported to the repository or outputs.
