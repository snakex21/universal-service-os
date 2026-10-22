# One-shot 82576 interrupt diagnosis

`tools/tests/coverage/igb_irq_probe.py` reads one snapshot at a specific test
event. It is not a progress watcher, driver fix or LAN qualification.

The target is exactly one root QEMU 8086:10c9 NIC at 00:03.0 and the root
Q35 8086:2918 LPC at 00:1f.0. Query PCI metadata and flattened MMIO mapping
must agree with the ECAM identities and the NIC BAR0 address and size.
The helper refuses unfamiliar layouts and never falls back to guest RAM.

The 300-byte snapshot consists of the NIC PCI header, eight four-byte
non-acknowledging control registers, LPC identity and eight PIRQ route
bytes. The total cap is 512 bytes. ICR/EICR are deliberately excluded:
reading interrupt causes could acknowledge them. DMA rings, payloads,
MAC-address registers and raw monitor replies are not saved.

PCI MSI/MSI-X enables, PCI INTx disable, NIC masks and LPC PIRQ routing
are separate evidence. In particular, GPIE alone cannot establish whether
the emulated PCI function has MSI/MSI-X enabled. A snapshot does not prove
that the Windows ISR or receive callback executed.

Primary contracts:

- [QEMU igb PCI device](https://github.com/qemu/qemu/blob/master/hw/net/igb.c):
  BAR0 is 128KiB `igb-mmio`, with separate PCI interrupt capabilities.
- [QEMU igb interrupt core](https://github.com/qemu/qemu/blob/master/hw/net/igb_core.c):
  non-MSI-X-mode delivery still selects the PCI MSI-X/MSI enable before INTx.
- [QEMU ICH9 LPC](https://github.com/qemu/qemu/blob/master/hw/isa/lpc_ich9.c):
  Q35 legacy PIRQ routing registers.

Eleven host tests execute the real async helper, enforce the exact allowed
addresses and read budget, and check disabled routing, MSI-X state,
identity/layout refusals, capability loops and reply sanitization.
An actual installed-guest snapshot must be assessed separately.

The first installed R23 diagnostic rejected the PCI metadata before any
register read. The initial identity check compared the entire ID object,
although [QAPI permits optional subsystem IDs](https://github.com/qemu/qemu/blob/master/qapi/pci.json).
The corrected check compares the vendor/device fields and still requires
the exact BDF, class, ECAM identity, BAR and MMIO ranges. The original failed
diagnostic is preserved; it is not a Windows failure or interrupt result.

The corrected R23b ran against the unchanged stopped R18f NT351 installation.
Its 300-byte snapshot found MSI and MSI-X disabled, PCI INTx allowed and all
eight LPC PIRQ routes enabled (IRQ10/11); the NIC advertised IRQ11. IMS was
zero at the time of its read. The snapshot does not establish when it was
cleared relative to the driver's checker/watchdog, nor prove guest ISR entry.
No driver or firmware fix follows from those registers alone. Native
Shutdown was observed in operator03, followed by QMP quit/rc0; hashes of
the entire backing chain were unchanged. Details remain in the owned
`artifacts/coverage/vm/r23b-nt351-irq-snapshot` evidence.

Later passive event traces R25/R26 resolved the timing ambiguity without
reading guest RAM or acknowledging registers through QMP. The backend
used0x1500/1508/150C/1510 instead of canonical ICR/IMS/IMC/IAM atC0/D0/D8/E0.
The control R25 had no canonical IMS writes or INTx/PICIRQ11 deliveries;
the same installed diagnostic target with only the corrected own SYS
had65 IMS writes,32 INTx asserts and31 PICIRQ11 deliveries, no watchdog
fallback. Native ping improved from about2003ms to all three below10ms;
strict guest DNS and HTTP also completed. Both runs native-shutdown/rc0,
with the original backing chain unchanged. The independently reviewed
driver fix is `fix/nt351-net-irq` b14378d8; it does not qualify X470 or a
fresh installer containing that candidate.
