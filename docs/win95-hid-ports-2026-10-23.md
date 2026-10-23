# Preserve original USB HID ports in a reinsertion test

QEMU auto attachment can choose another port after device_del/device_add.
An actual paused QEMU 11.1.0 test R84 observed mouse logical2 ->4, while the
firmware diagnostic R83 independently showed root6 ->8. That is a different
physical-port test, not a same-port reconnection.

The fixed_hid_ports.pin helper validates the two owned descriptors and assigns
keyboard xhci.0 port1 and pointer port2. The initial launch must use the same
ports; reserve them from storage (the runtime test uses port3 for boot storage).
Unknown IDs, buses, unexpected drivers and conflicting explicit ports fail.
The helper never assigns guest PASS and does not change firmware behavior.

Existing actual-QEMU test test_fixed_hid_ports_qemu.py creates a private blank
2-MiB disk, checks resources, starts one paused 64-MiB VM and waits for actual
DEVICE_DELETED events. It first demonstrates automatic port movement, then
asserts two fixed-port cycles each for mouse and keyboard. R95 passed all four
cycles in0.113s with QEMU exit0, with the resource guard enabled. This test
contains no Microsoft payload and proves configuration only.

R85 separately used the helper in an installed Windows95 RTM overlay. The
mouse moved/opened a menu and the keyboard typed usbreplug95 after reinsertion;
closed completed USB reports plus zero PS2 trace events established actual
same-port HID input. No different-port or hub functionality is inferred.
Private results: K:/USOS-VM/Windows95/sesja-cz-20261023/cases/r95-hid-fixed-ports-resource-guard/result.json.
Runtime metadata: C:/Users/ASRock/Documents/Codex/2026-10-21/cz/work/r85-completed-proof.json.
