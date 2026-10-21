# NT3.1 Workstation R19 / R19c — completed desktop and USB HID

**QEMU only.** No merge, push, physical deployment, storage qualification
or Intel LAN PASS. The exact inventory row is
`Windows NT 3.1\Windows NT 3.1 Workstation 3.10.511.1 EN (ISO).7z`.
Archive SHA256 `d10f9c35bf656e2cca7351518628ba19179540af1b090d61d322b670930b2894`;
original Disk01.iso SHA256
`ee2a27153c0942b6b82f9b15145f3b7eaa34b331add1d077cc6f8d69b9223c0b`.

R19 used the normal fresh USOS flow and reached actual Program Manager
Version3.1 (57152KB). PS/2 input worked. Native Shutdown reached the safe
power-off screen, followed by QMP quit/exit0. This result alone is not USB.

R19c is a separate overlay of that stopped installation. Only the existing
SYSTEM i8042prt Start DWORD changed1→4, verified by a REGF1.1 reader,
full content/byte comparison and qemu-img compare. Hardware i8042 stayed
enabled for NTDETECT. QEMU q35/EPYC-Rome/2CPUs/2048MiB, OVMF/CSMWrap,
AHCI target and three xHCI USB devices (source placeholder/keyboard/mouse).
The installed frozen NT31 own USB SYS stayed32256bytes, SHA256
`f5373eb3bf829d585651bc0da7ea5b1ca9b0cf2b20a1fe74ccb5054955f3ef05`.
USB Start0, classes Start1, ConnectMultiplePorts1/MaximumPortsServiced3.

| Actual R19c action | Observation |
|---|---|
| CtrlAltDel and login with USB | Actual NT3.1 desktop, operator01/02 |
| Keyboard removed, AltF/R attempted | No Run window, operator03 |
| Keyboard reinserted | Immediate command partly precedes enumeration; operator04 selects ReadMe, not Run |
| Subsequent AltF/R after enumeration | Run opens, operator05: keyboard replug PASS |
| Only mouse removed; keyboard Escape/AltF | Run closes and File menu opens, operator06: desktop still responds |
| Mouse reinserted, settled, moved | Cursor moves from top-left to60/60, operator08 |
| Moved to File and clicked | First combined movement/click does not open menu, operator09; separate click opens File menu, operator10: mouse replug PASS |
| Native Shutdown via USB keyboard | Safe-to-turn-off screen operator12, QMP quit/exit0 |

The immediate post-insertion and combined-movement observations are kept;
the later successful actions do not rewrite them. No timing or IRQ cause
is inferred from those individual events.

Stopped readback confirms Current/Default1, i8042prt Start4 and unchanged
USB/class settings and frozen SYS. Original R19 baseline SHA256 stayed
`606806fb88568b3b11debec29741f146f25307db19b13ef0feb883ba2b7d4e3a`.
Microsoft hive/module bytes remained in RAM or whole disk scratch on owned
G; scratch was removed. No host registry loading was used.

Evidence in `macierz-windows/artifacts/coverage/`:
`vm/r19{,-c}` uses the actual full tags `r19-nt31-desktop-ps2` and
`r19c-nt31-usb-isolation`; operator PNGs/actions and unchanged runner JSON.
`nt31-runtime-r19/{desktop-evaluation,stopped-readback,usb-preparation,usb-stopped-readback,usb-evaluation}.json`.
Runner generic flags remain false until a separate manual assessment;
`usb-evaluation.json` records this completed, scoped result.

NT3.1 stock networking has static TCP/IP; DHCP is not an applicable stock
test. An Intel NDIS miniport cannot run unchanged on its full-MAC API.
No compatible Intel full-MAC port or network runtime is claimed here.
