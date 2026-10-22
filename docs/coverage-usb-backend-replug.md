# Disposable USB backend lifetime in coverage tests

`device_del` of a USB storage frontend also removes a backend made by
legacy `-drive if=none,id=...`. Reusing that drive ID can therefore fail
with `Property 'usb-storage.drive' can't find value ...` before the guest
receives a newly attached stick. That is a fixture failure, not a Windows
or macOS storage result.

The two coverage-owned FAT16 qcow2 sticks now use explicit named
`-blockdev` nodes, `usabilityboot` and `usabilityhot`. Only their USB
frontends are removed/reinserted. JSON arguments preserve Windows paths
containing spaces, commas and Unicode. Install media and target-disk
handling are unchanged. No physical device is opened.

The explicit host regression is `tools/tests/coverage/verify_usb_backend.py`.
It launches one paused Q35 with32 MiB, no guest OS, the standard RAM/disk
reserve check and an exact new owned collection folder. A legacy negative
control reproduces the missing-backend error after DEVICE_DELETED.
Each production qcow2 node survives three completed remove/reinsert
cycles. QMP deletion uses the actual event, without progress polling.

Completed run:
`G:\USOS-Kolekcja\_vm\coverage-usb-backend-20261021-01\result.json`.
QEMU exit0; both fixed nodes passed3 cycles; all three images' SHA256
values were identical before/after. Exact owned images were removed
after verification, leaving metadata. `guest_usb_pass=false` is explicit:
this regression does not qualify any OS USB driver.

The `--nested` CLI help also now describes per-case engine accounting
and resource coordination; it does not assert a fixed global engine cap.
