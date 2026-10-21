# usosusb: USB hubs (2026-10-21)

Branch `feat/usosusb-hubs`. Own xHCI driver `tools/nt4/usosusb` (shared
source of the NT 3.1, NT 4.0 and NT 6.0/6.1 x86 builds) now enumerates
devices behind USB 2.0 and USB 3.x hubs. Merged into `test/x470-98se-qemu`
on 2026-10-21. Design notes are in `tools/nt4/usosusb/README.md` ("Hubs").

Status (2026-10-21):

* **X470 PASS** (Windows 7 SP1 x86, usosusb 1.3-nt6, root-port replug fix):
  keyboard + mouse + stick on the front panel, stick at boot and hot-swap
  between ports, keyboard **and** mouse unplug / replug on rear and front
  ports.
* **Hubs: QEMU only.** The X470 front panel ports are chipset root ports
  and no real external hub was on hand, so the hub code (route string, TT,
  hub class requests, hot plug behind a hub) has not run on hardware yet.
* NT4 (1.3-nt4) and NT 3.1 (1.2-nt31) builds: QEMU only.

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
  (1.1-nt4 is taken by `feat/nt4-usb-sticks`); 1.3-nt6 / 1.3-nt4 /
  1.2-nt31 with the root port replug fix below.

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

## X470 round 1 (2026-10-21, Windows 7 SP1 x86, 1.2-nt6)

PASS: keyboard + mouse + stick on the front panel (HAF XB EVO USB 3 ports),
stick at boot, stick moved between ports, keyboard unplug / replug.
Topology from Diag: the front panel ports are chipset root ports (hc0
01:00.0, ports 13..16), no hub (no `H` entry); p17 is an onboard device
without HID (`p17-nohid`, then `p17-addr4`).

FAIL: USB mouse unplug / replug, every port. Diag of that session (stale
cell in the SYSTEM hive): `p15:s1K- p16:s2-M ... p15-gone p16-gone p16:s5K-
p16-gone p16-addr4 p16-addr4 p15-addr4`: the keyboard came back on p16, the
mouse failed Address Device with completion code 4 (USB Transaction Error)
on p16 and p15.

Cause: root port hot plug reset the port at once on the connect change, with
no connect debounce (USB 2.0 7.1.7.3: 100 ms before the reset; the hub path
already waited). A device that is still powering up (here the mouse) misses
that reset and never answers SET_ADDRESS. Later port events then went
straight to Address Device on the already enabled port without a new reset,
so it never recovered (same mechanism as `p17-addr4` after `p17-nohid`).
Present in 1.1-nt6 too (root port code unchanged by the hub work).

Fix (1.3-nt6 / 1.3-nt4 / 1.2-nt31): `port_enum(hc, p, csc)` waits 100 ms
after a connect change, resets the port again whenever the device on it was
already tried (`hc->tried`, cleared on disconnect), retries a failed
address / descriptor / configure step twice (100, 200 ms, new reset each
time; Diag `/r` after the failed entry), and ignores port events without a
connect change on a port whose device was already tried (no reset loop).

QEMU only: harness has a mouse on root port 3 (`p7`) plus mouse out / in on
p7 (twice) and on hub port 1.2, each followed by mouse_move / button
records at the mouse class callback: nt6 25/25, nt4 22/22, nt31 22/22 PASS.
QEMU devices are ready at once, so the hardware timing is not reproduced.

## X470 round 2 (2026-10-21, Windows 7 SP1 x86, 1.3-nt6)

PASS: front panel keyboard + mouse + stick, stick hot-swap, keyboard and
mouse unplug / replug on rear and front ports (the round 1 mouse FAIL is
fixed). No hub on hand: hubs remain QEMU only.

## Rebasing `feat/nt4-usb-sticks` (note for Codex)

`feat/nt4-usb-sticks` (usosusb 1.1-nt4 sticks) was **not** merged. A trial
merge (`git merge-tree`) onto `test/x470-98se-qemu` after this merge gives:

* `tools/nt4/usosusb/src/usosusb.c`: **one** textual conflict, the NT4
  `#else` block with `USOSUSB_VERSION`. Keep the sticks comment and
  `USOSUSB_MSC` / `USOSUSB_NT4MSC`, and take a version above both,
  `usosusb 1.4-nt4`.
* `tools/tests/test_nt60_usosusb.py`: the matching version string in the
  NT4 assertion (use the new version).
* `tools/nt4/usosusb/bin/i386/usosusb.sys` and
  `installer/internal/payload/legacy_boot_generated.go`: generated; rebuild
  the driver and run `build.bat` instead of resolving by hand.

What changed under the sticks code (auto-merged, but check it):

* `port_enum(hc, p)` is split: `port_enum(hc, p, csc)` is now only the root
  port part (100 ms connect debounce, reset before every retry, 2 retries,
  `hc->tried`), and descriptor / configuration work moved into the new
  `dev_enum(hc, hub, p, speed)`, which root ports and hub ports both call.
  The sticks branch's `g_storage &&` check on the mass storage interface
  (class 08/06/50) lands inside `dev_enum()` — it did auto-merge there.
* New hub functions: `queue_hub`, `hub_status`, `hub_clear`, `hub_child`,
  `hub_start`, `hub_port`, `hub_changes`, `hub_poll_all`; `port_changes`,
  `hc_poll`, `worker`, `dev_drop` and `port_present` were touched (a device
  can now sit behind a hub: `DEV` has hub / route fields, `port_present()`
  checks the root port (`d->rport`) plus `d->gone`, which the hub path sets). A stick on a hub reaches `msc_attach()` through
  `dev_enum()`; on unplug behind a hub `dev_drop()` is called from the hub
  path, so the volume removal (`mnt_remove` / `\DosDevices` links) must hang
  off `dev_drop()`, not off the root port code.
* `g_diag` grew to 1024 WCHARs; Diag gained `H` (hub) entries and `/r`
  retry marks.
* Run `tools/tests/test_nt60_usosusb.py`, `test_usosusb_hubs.py` and the
  NT4 sticks tests after the rebase; `USOS_QEMU_HUB=1` runs the hub harness.
