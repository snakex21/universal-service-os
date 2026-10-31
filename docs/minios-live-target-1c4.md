# Live target policy

Firmware preparation runners create a fresh QCOW2 base, its blank snapshot,
and a writable child. Dynamic VHD is refused before file creation or QEMU
launch, including direct helper calls. A single final VHD conversion remains
in the independent Windows validation gate. Previously closed VHD receipts
remain readable for audit; they cannot select a new writable VHD target.

The unchanged Win11 baseline and matched small-file interval are recorded in
`minios-evidence-1c4-pretests.json`. The bounded QCOW2 diagnostic was deliberately
stopped after its time limit; it is not a full installation gate.

Validation: 15 firmware-runner tests and seven BIOS-runner tests, including
rejection before any IO and preserved blank/prepared QCOW2 checkpoints.
