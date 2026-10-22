# NT351 R26 IRQ candidate — QEMU only

`fix/nt351-net-irq` b14378d8 corrects four canonical Intel legacy IRQ
register offsets in the own backend. R26 is a new overlay of the same
stopped R18f Workstation3.51 build1057, with only the own same-sized SYS
replaced. SYSTEM and USB unchanged, baseline/backing chain unchanged.
Installed SYS SHA256
`f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf`.

Native DHCP renew, ping3/3 below10ms, own matching ICMP0ms, strict UDP
DNS60/40ms, strict TCP DNS and HTTP68k.news200 PASS. Passive bounded trace
has65 canonical IMS writes,32 INTx asserts and31 PICIRQ11 deliveries,
without checker fallback. Unchanged control R25 has0/0/0 and fallback.
Native safeShutdown and QMPquit/rc0; readonly post-exit collector verified
the actual candidate and five own files. Old appended logger snapshots
remain; assessment uses only the last complete snapshot from this run.

This independently qualifies the installed driver fix, with9 relevant
host checks. Fresh R22 uses the olderf39 driver and retains its measured
approximately2s latency. No cache/physical deployment, new USB-only or
MSC test, other OS or X470 qualification is inferred. The same fix is
under a separate NT35 test. All historical failures remain.

Full source, primary register references and evidence are in
nt351-irq/docs/nt351-canonical-irq-registers.md and
nt351-irq/artifacts/nt351-irq-r26/guest-evaluation.json.
