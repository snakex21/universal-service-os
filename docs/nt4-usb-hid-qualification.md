# NT4 installed USB HID qualification â€” QEMU only

Independent worktree fix/nt4-usb, based on nt4-net f8a87c46.
The pre-existing nt4-usb directory belongs to the separate Desktop repository
on feat/nt4-usb-sticks and was left unchanged. No USB/hub source or binary
was changed. No physical media, merge, push or full build is involved.

The source is the completed Workstation PL/SP6a candidate03, after its
native desktop, native safe-off and QMP quit/rc0. Retained parent SHA256:
`cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21`. The source command SHA256 is `9d077592cb8d52d35d582c1451544481edefcac1376f7eb4161c15f4e79200cd`.
This source remains immutable. The cache reference is frozen
B261020-200536-968CCBE8-nt4-hid13-netdns-utc-ipfix.

A fresh COW changes only the existing selected CS1 i8042prt Start DWORD
from1 to4. USB, kbdclass and mouclass remain Start1; NDISLoop stays Start3.
Full parsed and binary SYSTEM comparison confines the change to that
DWORD. Modified raw/COW compare passes. Restoring the original DWORD
makes the full raw disk identical to the original parent. A separate
raw conversion independently confirms the changed SYSTEM and frozen USB.
Whole-disk scratch is on G and removed with exact owned-path guards.
No Microsoft file or hive is exported separately.

Actual installed USB1.3 is32128B, SHA256
`2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1`.
All19 imports resolve against the actual installed kernel/HAL in RAM;
metadata hashes are retained in artifacts/nt4-hid/preparation.json.
Preboot target SHA256: `facfbaed43b15971930b0890d3a882bece0e09aea4aed9b74e4f5e86537b0a3b`.

Runtime uses a guarded2048MiB q35 BIOS/AHCI/igb cold fixture, with i8042
hardware still present, USB keyboard port1 and relative mouse port2.
Hot insertion preserves those exact ports. No USOS install stick or MSC
fixture is attached. BIOS cold start differs from the original fresh
OVMF/CSM handoff, so this is an installed HID qualification only.
LAN and MSC remain outside this run; no such PASS is inferred.

The runner requires a real Windows operator console, rejects encoded
JSON above450bytes before any action, and uses one150s endpoint. Each
subsequent image corresponds to one explicit UI/HID action. A separate
ReadDirectoryChangesW subscriber is armed before each future image;
no active screenshots, logs, QMP status or process state are polled.
Three actual action-parser contracts and a real redirected-stdin refusal
pass. Preparation and these host checks grant no guest HID PASS.

Runtime assessment: **PASS_INSTALLED_NT4_USB_HID**, after the completed
run and stopped readback. Actual guest observations:

- operator01/02: USB Ctrl+Alt+Del, native login and Workstation desktop.
- operator03: Run contains `nt4hid` typed through USB.
- operator04: removed keyboard, sent `ab`; text remains `nt4hid`.
- operator05/06: reinserted keyboard, then actual `cd` gives `nt4hidcd`.
- operator07: mouse removed; live USB keyboard replaces Run text with `mouseout`.
- operator08/09/10: mouse reinserted, cursor moves to lower-left, and actual
  left click opens the Start menu. QMP insertion alone is not this PASS.
- operator11/12: native Shutdown dialog, then native safe-off screen.

TTY57677 closes exit0 after controlled QMP quit; elapsed565.454s, error null.
Post-exit independent readback confirms clean selected CS1, i8042prt4,
USB/kbdclass/mouclass1 and unchanged NDISLoop3. Frozen USB and its19 actual
imports match; parent cf04 remains unchanged. Temporary whole raw is
removed. Post-run target SHA256:
`f2e16aa356c204db8f4c1eeae1f89dde22e55cb1d0d1d6a3b6ae749246e6cba0`.

The generic runtime record deliberately grants no automatic HID PASS;
`artifacts/nt4-hid/evaluation.json` separately records the manual review,
image/command/action/source hashes and stopped proof. Reproduction tools
are `nt4_hid_fixture.py`, `boot_nt4_hid.py` and `wait_nt4_hid.py` under
`tools/tests/coverage/`. This does not qualify LAN, MSC, Server, X470 or a
combined fresh installer+HID flow. The retained own image is
`G:\USOS-Kolekcja\_vm\nt4-installed03-usb-hid01\target.qcow2`.
