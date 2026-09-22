# Vista USB before Windows Setup — hardware trial v4

Deployed 2026-09-20 to the Intel test SSD, GPT disk
`8e281c54-58d1-4ad0-8afd-ad76d2e48148`, OS partition
`73dbde99-8026-4759-a19a-fd943e891d09` (M: on the technician host, D: in Vista).
No partitioning, host certificate changes, host BCD changes or USB-stick writes.

## Evidence and change

The previous v3 helper failed with `0x80070005` while adding its certificate to
TrustedPublisher. It did not reach driver staging. The bootstrap nevertheless
started windeploy after 15 seconds, and the same helper also ran in specialize.
Panther recorded an unattend action failure. This was a defect in our startup
flow, not a hardware test of the driver.

The v4 startup entry runs the helper before windeploy. It uses the writable
physical machine certificate stores rather than the logical collection and
checks certificate readback. This change still needs verification in Vista.

The new candidate is xhci98 1.1.0.0 x64, pinned to upstream commit
`582a960fcb734f73ec0d1e4757b702e9abdb79c1`:
https://github.com/yeokm1/xhci98
The upstream binary is retained in `zig-out/vista/xhci98/upstream` along with
its LICENSE and README. The deployed copy has a local SHA-1 test signature and
a matching catalog; executable payload bytes were checked unchanged. Existing
target-only BCD testsigning was verified, not modified. No private key was
copied to the Intel SSD. The target package includes provenance and license.

The helper installs the driver for detected AMD controllers 43D0 and 149C,
rescans PnP, and waits up to 30 seconds for started controller, HID mouse and
HID keyboard devnodes. Only a successful readiness result launches windeploy.
Failure leaves the diagnostic screen and startup hook in place; no automatic
reboot or timed fall-through. A manually requested next boot retries the hook.
The obsolete helper-only specialize answer file and failed setup queue were
moved into the backup. Setup completion is not forged or bypassed.

Upstream documents Vista only as VM-tested, unsigned as published, and limited
to USB 2.0 speeds on xHCI. A USB 1.1 hub can crash Vista; connect input devices
directly to motherboard ports for this hardware trial. A started HID devnode
is a useful gate but does not prove real input delivery.

## Validation and recovery

`python tools/build_windows_vista_firstboot.py`: exit 0, firstboot 9216 bytes,
bootstrap 6144 bytes. Static PE imports of both helpers and xhci98 resolve
against the original Vista SP2 files. Signing leaves the driver executable
payload unchanged. Deployment checked target disk/partition identities,
prepared SYSTEM with a full registry-value inventory comparison, and verified
all deployed file hashes. CHKDSK exit 0; final volume state NOT Dirty.
No VM, E2E or physical boot was run by the agent. USB operation is unverified.

Deployment tool: `tools/deploy_vista_usb_gate.ps1`.
Backup: `zig-out/vista/usb-gate-v4-20260920-214458/backup`.
Prepared SYSTEM and exact old/new value manifest sit in its sibling `prepared`.
The script restores overwritten files and removed setup state if deployment
raises an exception. Preserve this backup before further hardware changes.

Target logs: `D:\USOS\usb-bootstrap.log` and
`D:\USOS\Vista\firstboot-usb.log` (M: while connected to the technician host).
