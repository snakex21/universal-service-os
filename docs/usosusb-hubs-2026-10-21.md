# usosusb: USB hubs (2026-10-21)

Branch `feat/usosusb-hubs`. Own xHCI driver `tools/nt4/usosusb` (shared
source of the NT 3.1, NT 4.0 and NT 6.0/6.1 x86 builds) now enumerates
devices behind USB 2.0 and USB 3.x hubs. Status: **QEMU only**; nothing has
run on the X470 yet. Design notes are in `tools/nt4/usosusb/README.md`
("Hubs").

Own code, written from the public xHCI 1.2 and USB 2.0 / USB 3.2 hub class
descriptions; GPL-3.0-or-later like the rest of the driver.

## What changed

* `dev_enum()` (was the second half of `port_enum()`) enumerates a device on
  a root port or on a hub port. Every device has its parent, root port, tier,
  Route String and TT hub slot / port; the Slot Context of Address Device
  carries them.
* Hubs: status change endpoint (on the device's keyboard ring, which a hub
  does not use), GET_HUB_DESCRIPTOR, slot-only Configure Endpoint with
  Hub / Number of Ports / TTT, SET_HUB_DEPTH (SuperSpeed), PORT_POWER, then a
  first pass over every port.
* Port changes behind hubs: the status change bitmap is collected in the
  event poll and handled in the worker loop (`hub_changes()`), plus a
  GET_PORT_STATUS pass over all hub ports every 2 s (`hub_poll_all()`), which
  also re-arms a stopped status change endpoint. A hub that stops answering
  costs one control timeout per pass, not one per port.
* Dropping a hub (root port unplug, parent hub port disconnect) drops its
  subtree, children first, each with a `-gone` Diag entry.
* Root ports: same code path as before (lookups now ignore devices with a
  parent hub). `port_present()` (stick I/O) checks the chain's root port and
  the device's own `gone` flag.
* Diag: entries named by path (`p5.2:s3K-`), hubs `p5:s1H4hs` / `fs` / `ss`,
  `/tt<slot>.<port>` after a device that uses a TT, new error tags
  `-hubd`, `-hubctx<cc>`, `-noen`, `-deep`, `-full`. Diag is 1024 characters
  now. Conn and Msc are unchanged.
* Versions: `usosusb 1.2-nt6`, `usosusb 1.2-nt4`, `usosusb 1.1-nt31`
  (1.1-nt4 is taken by `feat/nt4-usb-sticks`).

## QEMU harness (QEMU only)

`tools/tests/usosusb_hub/run_hub_qemu.py --variant nt6|nt4|nt31` builds the
real `usosusb.c` together with `harness.c` (DriverEntry, stand-in class
service callbacks that print every keyboard / mouse record) and `shim.c`
(the imported kernel / HAL routines: TSC time, bump allocator, CF8h PCI,
registry writes printed to COM1) with WDK 7.1, turns it into a multiboot
image and boots it with `qemu -kernel` on q35 + qemu-xhci, no i8042. No
Windows install, no disk besides a 64 MiB scratch stick image in a temp
folder (deleted afterwards). About 2 minutes per variant under TCG.
`USOS_QEMU_HUB=1 python -m pytest tools/tests/test_usosusb_hubs.py` runs it
for nt6 and nt4.

Topology: hub on xHCI port 5 (QEMU numbers the USB 2 ports 5..8) with
keyboard 5.1, mouse 5.2, stick 5.3, second hub 5.4 with keyboard 5.4.1;
keyboard on root port 6.

Results 2026-10-21 (QEMU 11.1, TCG):

| build | result |
|---|---|
| nt6 (Vista / 2008 / Win7 x86) | 15/15 PASS |
| nt4 | 12/12 PASS (stick: `p5.3-nohid`, the NT4 build has no storage) |
| nt31 | 12/12 PASS (same) |

Final nt6 Diag:

    usosusb 1.2-nt6: hc0=00:02.0(8 ports) p5:s1H8fs p6:s2K- p5.1:s3K- p5.2:s4-M
    p5.3:s5--S(64M wp0 1v) p5.4:s6H8fs p5.4.1:s7K- p5.1-gone p5.4.2:s3K-
    p5.3-gone p5.3:s5--S(64M wp0 1v) p5.4.2-gone p5.4.1-gone p5.4-gone p5.1:s3K-

Checked: enumeration at boot through two hub tiers, keyboard make/break and
mouse move/buttons reaching the class callbacks from devices behind the
hub, keyboard unplug / plug behind the hub (also on the depth-2 hub), stick
unplug / replug behind the hub (BOT bring-up and LBA 0 read through the
hub), unplugging the depth-2 hub with its keyboards, root-port keyboard
unchanged.

Not covered by QEMU: QEMU's `usb-hub` is a full-speed USB 1.1 hub, so the
transaction translator fields (HS hub + LS/FS device), TT Think Time,
SuperSpeed hubs (descriptor 2Ah, SET_HUB_DEPTH, SS port status) and the
USB 3 hub companion split are written to the specifications but untested.
The mount manager path (drive letters) does not run in the harness; it is
the same code as on root ports.

## Risks for the X470

1. **TT path untested**: a keyboard / mouse (low or full speed) behind a
   USB 2.0 hub, the main case (keyboards with a hub, monitor hubs, a front
   panel hub), needs the TT Hub Slot ID / Port Number. Wrong values show up
   as `p<n>.<m>-addr<cc>`, `-dd` or a device that enumerates but sends no
   reports.
2. **USB 3 hub = two hubs**: the SuperSpeed half sits on a USB 3 root port,
   the USB 2 half on its paired USB 2 root port; Diag shows two `H` entries
   (`ss` and `hs`). Keyboards always end up on the `hs` half; USB 3 sticks
   on the `ss` half.
3. **SuperSpeed Plus (10 Gbit/s) hubs / devices**: everything behind a
   SuperSpeed hub is given speed ID 4 (5 Gbit/s). A Gen 2 hub with a Gen 2
   stick could be refused (`-addr<cc>`); USB 2 devices are not affected.
4. **Front panel ports**: on X470 boards they usually go straight to chipset
   root ports (then nothing changes); some boards put an onboard hub
   (Genesys / ASMedia / Realtek) in between. Diag shows which.
5. **Unplugging a hub during stick I/O**: the stick is noticed gone only
   after the transfer times out and the hub pass runs (a few seconds of
   blocked input).
6. **16 device entries per controller** count hubs too (USB 3 hub = 2).
7. **Branch overlap**: `feat/nt4-usb-sticks` changes the same `usosusb.c`
   (NT4 storage, version 1.1-nt4); merging both needs a manual resolve of
   `port_enum()` / `dev_enum()`.

## X470 test plan (yes / no answers, logs collected silently)

Target: the X470 Windows 7 SP1 x86 install that passed the stick test on
2026-10-21 (usosusb NT6 + usos-drivenotify), with `usosusb.sys` replaced by
this branch's `bin/nt6/i386/usosusb.sys`. Evidence: `Parameters\Diag` in the
SYSTEM hive (read offline from the target disk afterwards) and
`C:\USOS\Logs\usos-drivenotify.log` (Diag copied at logon and on every drive
change). Nothing is deployed by this branch; the deploy is a separate step.

1. Boot with a USB 2.0 hub on a rear port, keyboard and mouse on the hub.
   Q: "Do keyboard and mouse work at the logon screen?" (yes / no)
2. Same with a keyboard that has a built-in hub (or a monitor hub), mouse on
   the keyboard's hub. Q: "Do both work?" (yes / no)
3. Keyboard and mouse on the front panel ports. Q: "Do both work?" (yes / no)
4. FAT32 stick behind the hub, plugged in before boot. Q: "Is the stick in
   Explorer after logon?" (yes / no)
5. On the desktop: unplug the stick from the hub, plug it into another hub
   port. Q: "Did the stick come back in Explorer?" (yes / no)
6. On the desktop: unplug the keyboard from the hub, plug it back into a
   different hub port. Q: "Does the keyboard type again?" (yes / no)
7. Optional: USB 3 hub with a USB 3 stick and a keyboard. Q: "Do both
   work?" (yes / no)

Afterwards the Diag line answers the rest: hub speed (`hs` / `fs` / `ss`),
whether the TT was used (`/tt`), and any error tag per port.
