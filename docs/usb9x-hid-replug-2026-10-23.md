# USB keyboard / mouse replug without CSM (CSMWrap 3.1.2-usos18, 2026-10-23)

Status: QEMU only. Not run on the X470 and not in a Windows 9x VM yet.

## Input path (what replug has to restore)

- The X470 without CSM has only xHCI. SeaBIOS inside CSMWrap owns it for every BIOS-era OS.
  All 32-bit SeaBIOS code (xHCI included) runs on the hidden helper core: `call32()` →
  `call32_proxy()` → the `CSMPPrxy` mailbox, with the caller waiting.
- Input: the BIOS timer interrupt (IRQ 0, `handle_08` → `usb_check_event`) polls the HID interrupt
  pipes (`usb_poll_intr` → `xhci_poll_intr` on the helper).
  - Keyboard: reports become scan codes, which go to INT 15h/4Fh, the BDA buffer and INT 16h.
    USOSKEY.COM/.DRV forward them to Windows 3.x/9x.
  - Mouse: packets go to the INT 15h C2xxh pointing device. VBMOUSE (DOS), USOSMOUS.DRV
    (Windows) and USOSVMD.VXD (9x DOS boxes) read them.
  - Windows 9x reflects IRQ 0 into V86, so the same code serves 95/98/Me.
  - NT/XP/Vista/7 never call the BIOS timer interrupt after their kernel starts. Their own
    drivers (usosusb, the Windows xHCI stack) own the controller.
- Stick hot-swap in 9x (patch 0022): USOSUSB.MPD talks to SeaBIOS over channel 1. Once its
  first request arrives, a port watch runs in the helper idle loop every 100 ms. It only
  works with `int13_boot_disk_only` (the 9x flow).
- Before usos18, an unplugged keyboard or mouse stayed dead. Its slot and interrupt TD stayed
  on the old device, and the 0022 watch disabled a replugged HID device ("not a stick").

## Design

- **0023, by Codex** (branch `fix/win95-root-hid` 6fe7526a, used unchanged, QEMU Win95 RTM R85):
  - POST records each root-port HID device: VID/PID/revision, a hash of its configuration
    descriptor, its interfaces, and a 4 KiB page.
  - Unplug (seen by the 0022 watch): Disable Slot, park the pipes, inject a release of held
    keys and buttons.
  - Plug of the same device on the same port: port reset, Enable Slot, Address Device,
    SET_CONFIGURATION, SET_PROTOCOL, SET_IDLE (keyboard) and Configure Endpoint, all into the
    POST pipes and list nodes. Nothing is allocated at runtime.
  - Limit: it needs the 0022 pool and an armed watch, so only 9x with USOSUSB.MPD.
- **0024** (`tools/vendor/csmwrap/3.1.2-usos18/patches/0024-usb-hid-replug-everywhere.patch`):
  - Records root HID devices on every boot, with a separate input-context page when there is
    no pool.
  - Second driver of the same watch: `usb_check_event` → `call32(usos_hid_tick)`. It runs
    every 100 ms after POST (HaveRunPost 2) while the helper-side watch is not armed, and
    handles HID only (no stick bring-up, no media probe). This covers MS-DOS, FreeDOS,
    Windows 1-3.x, and 9x before or without USOSUSB.MPD. Arming reclassifies every port as in
    0022.
  - Ownership guard: a controller whose DCBAAP no longer points at SeaBIOS's array, or whose
    RS is 0, is never touched again. That covers xhci98 and any OS driver.
  - Any root port of the same controller: the lost device is matched by identity.
  - Retries: a failed bring-up stays pending for the next 2 watch passes, each with a new port
    reset. The debounce is one 100 ms pass (as in usosusb).
  - Fix in 0022 `xhci_usos_ctl_mps`: Evaluate Context named root port 1, so an EP0 size change
    failed whenever port 1 was empty.
  - USOSUDSK events 18 (keyboard/mouse unplugged) and 19 (back, with the retry count), and
    attach reason 12. USOSDBG names them.
- Not covered:
  - devices behind hubs (the X470 rear and front ports are root ports);
  - a keyboard or mouse that was not present at POST;
  - a different model in place of the lost one.
- ROM: 128768 of 131072 bytes, 2304 free (usos17: 5568 free).

## Tests (QEMU only)

- `run_dos_mouse_probe.py --replug` (FreeDOS 1.4 on NVMe, OVMF + CSMWrap, i8042 off,
  qemu-xhci usb-kbd + usb-mouse; tick path):
  - Cycle 1 replugs on the same ports (1, 2); cycle 2 moves to ports 3 and 4.
  - After each cycle the INT 33h mouse moves and clicks.
  - At the end the USB keyboard leaves M33TEST and types `echo USOS-REPLUG-OK` at the prompt.
  - usos18: PASS. usos17 control: FAIL (no movement or keys after replug).
- `run_csmwrap_uds_qemu.py --kbd-replug` (helper-side watch, the 9x path):
  - All usos17 steps run: stick hot-swap, 6 cycles and EJECT.
  - Then the keyboard is unplugged and plugged back on the port QEMU picks, and 'b' arrives
    through INT 16h.
  - The record shows attaches 9, events 18 and 19, and no failures. PASS.
- Regressions with usos18, all PASS:
  - `run_csmwrap_uds_qemu.py` (free + owned);
  - DOS mouse probe `--wheel`, session and `--mode dosmouse`;
  - boot disk (all layouts, with and without `--only`);
  - APM power-off;
  - PCI IRQ;
  - NVMe re-arm;
  - host tests `test_csmwrap_*.py` (new: `test_csmwrap_hid18.py`), `test_usosdbg_disk.py`,
    `test_w9x_usb_storage_flag.py`.
- Not run:
  - a Windows 98 SE VM. There is no 98 SE QEMU image on this machine, and Claude sessions do
    not run full Windows installs (Codex does).
  - MS-DOS itself. FreeDOS uses the same BIOS emulation path.
  - The X470.
- Build: offline VM run with the build kit mirror. The pinned musl-dev r2 is gone from the
  live Alpine mirror. python3 3.14.7-r1 and xxd 9.2.1091-r0 replaced the lock versions; the
  unpatched build still matches `upstream_rebuild`.
