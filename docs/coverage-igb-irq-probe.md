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

Ten host tests execute the real async helper, enforce the exact allowed
addresses and read budget, and check disabled routing, MSI-X state,
identity/layout refusals, capability loops and reply sanitization.
An actual installed-guest snapshot must be assessed separately.
