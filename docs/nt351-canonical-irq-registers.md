# NT351 Intel IRQ register correction — QEMU only

On 82576/8086:10C9, the existing backend wrote its legacy interrupt mask
at0x1508 and read the cause at0x1500. The canonical ICR/IMS/IMC/IAM
registers are0xC0/0xD0/0xD8/0xE0. The extended interrupt registers remain
in0x15xx. This patch changes only those four legacy constants.

Primary references: [Intel igb register definitions](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/intel/igb/e1000_regs.h),
[QEMU common register definitions](https://github.com/qemu/qemu/blob/master/hw/net/e1000x_regs.h),
[QEMU82576 interrupt delivery](https://github.com/qemu/qemu/blob/master/hw/net/igb_core.c).
No original Windows module is changed.

The unmodified control R25 uses the stopped R18f Workstation3.51 build1057
installation. Passive bounded tracing found zero canonical IMS writes,
zero asserted NIC INTx and zero PICIRQ11 delivery. The NDIS-owned checker
entered its nominal2s fallback. This explains the earlier functional LAN
result with native ping around2003ms; it was not a DNS configuration delay.

R26 changes only the same-sized own SYS in a new overlay of that same
stopped installation. Full SYSTEM hive and USB SYS remain byte-identical,
baseline/backing-chain hashes unchanged. Own driver17024B SHA256
`f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf`.
The normal2048MiB plus8GiB resource guard ran once. No physical disks,
hub source, cache or other OS binary changed.

Actual completed R26 results:

- Native DHCP renew/all:10.0.2.15/24, gateway10.0.2.2, DNS10.0.2.3.
- Native ping3/3, each below10ms; own matching ICMP echo RTT0ms.
- Strict UDP DNS replies60/40ms; strict TCP DNS also PASS.
- Native Winsock resolution, HTTP68k.news200; HTTP connection130ms.
- Passive trace:65 canonical IMS writes,32 asserted INTx events,
 31 PICIRQ11 deliveries; no watchdog fallback in the completed run.
- Native safeShutdown operator15, QMPquit/rc0. Post-exit readonly
  collector recovered5 own text files and verified the installed f579SYS.

USOSLOG appends snapshots: evaluation uses only the final complete R26
snapshot. Old failed/slow snapshots remain present and are not attributed
to this candidate. NET351.STATUS/ON still describe baseline stagingf39;
the candidate override is explicit and verified against the actual SYS.
FrogfindHTTP timeout and unavailable gatewayTCP80 remain separate results.

WDK7.1 build351 passed;8 existing NT351 build/import/ABI/checker tests
passed on the actual candidate. The new compiled-C test executes the
actual backend enable/claim/mask bodies with a canonical-MMIO model,
including masked no-read and shared-line negative controls. No new timer,
teardown or NDIS scheduling mechanism was introduced.

Evidence is in nt351-irq/artifacts/nt351-irq-r26/ and
macierz-windows/artifacts/coverage/vm/r26-nt351-canonical-irq/.
R25/R26 are installed diagnostic overlays. R22 independently qualifies
the fresh original USOS installation with the oldf39 driver. This patch
does not qualify a fresh installer containing f579, NT3.5/NT4, I211 on
X470 or physical IRQ routing. Those require their own tests.
