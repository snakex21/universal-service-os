# NT4 completed Setup and separate HID qualification — QEMU only

The exact source is `Windows NT 4.0\Windows NT 4.0 Workstation PL.iso`,
502075392B, inventory SHA256
`7aae3d7c36619c4edab58c8dccf9d350c78639f88afa36ae6b21e2e9cee9611b`.
The completed candidate03 fixture names that same source path; SP6a is a
separate input of this flow. This does not qualify other media/SP/Server.
Candidate03 reaches the native desktop and safe shutdown09/QMP exit0.
The retained target is cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21.

Separate `fix/nt4-usb` commit0c53a3ed in `nt4-usb-hid` changes only the
existing i8042prt Start1 to4 before boot. Hardware i8042 remains present;
USB/classes stay Start1. The actual own USB1.3 binary is32128B, SHA256
`2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1`.
All19 imports are checked against actual installed kernel/HAL bytes in RAM.

HID01 passes initial login/Run, absent-keyboard negative typing, typing
after keyboard insertion, working keyboard with mouse absent, then mouse
insertion/movement and a left click opening Start. Native safe shutdown12
precedes QMP quit/exit0. Stopped readback confirms exact USB, selectedCS1,
i8042prtStart4, USB/classes1, NDISLoopStart3 and unchanged original parent.
Target SHA256 is
`f2e16aa356c204db8f4c1eeae1f89dde22e55cb1d0d1d6a3b6ae749246e6cba0`.
Evaluation: `nt4-usb-hid/artifacts/nt4-hid/evaluation.json`, SHA256
`8d3c5d7e4e9e8cf1230b8cddefa16a13e6e8d723065edcfc6023e2e0569d6f41`.

This is a BIOS q35/AHCI/igb installed-target overlay, distinct from the
fresh OVMF/USOS/CSMWrap warm handoff. It is not MSC, LAN or X470 PASS.
No hub/USB driver source or frozen binary is modified.

The separate network05 Start2 versus unchanged06 Start3 control uses the
same03 parent and normalized cold argv. Start2 gives native DHCP and
ping4/4; Start3 gives no adapter and4 unreachable replies. Sourcefix is
f00b1597 in `fix/nt4-net`. Official LAN05 remains false because the hidden
FIRSTLO helper failed and the old logger did not read global DHCP DNS.
New collector qualification and frozen MSC tests are separate pending work.
