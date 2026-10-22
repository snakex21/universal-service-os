Windows 95 storage replug test backend
====================================

R62 read the hot stick's control file in the real RTM desktop after the boot
stick was removed. The next QMP insertion failed on the host: the legacy
`-drive if=none,id=usabilityhot` backend had been removed with usb-storage.
That failure does not measure Windows' handling of a second insertion.

`coverage/persistent_usb_storage.py` constructs explicit named `-blockdev`
nodes for both disposable images. Each USB frontend can be deleted and
created again while its block node remains owned by the monitor.

The standalone integration test uses one paused 64 MiB QEMU and owned blank
images. It waits for DEVICE_DELETED, reinserts each frontend twice, then
checks the named nodes once at completion. It contains no Windows and never
assigns a guest USB PASS. The installed RTM read/replug test remains required.

R63 on the current QEMU binary passed all four reinsertion operations and
the final node check in 0.212 s, exit 0. The corrected RTM run follows this
infrastructure check; its result must be recorded separately.

Use a new private VM folder and an explicitly reserved QEMU slot:

    python tools/tests/test_persistent_usb_storage_qemu.py --qemu <qemu-system-x86_64> --work <new-owned-folder>

The test writes all logs and images inside that folder. It does not reset a
controller, edit hubs or tools/nt4/usosusb, or access a physical disk.
