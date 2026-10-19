# USB flash drives in Windows 95/98/98 SE/Me on the X470 without CSM: design (2026-10-19)

Status: design plus stage 0 in the flow (this branch, `feat/usb9x-hotswap`, base
`eb7138a` of `test/x470-98se-qemu`). Nothing here has run on the X470 or in a 9x VM yet.

## 0. Starting point (what is already known)

- The X470 has only xHCI controllers. Windows 9x has no xHCI driver, so the OS cannot see a USB stick
  through its own stack. The only xHCI owner is SeaBIOS inside CSMWrap (3.1.2-usos15). It handles the
  USB keyboard and mouse (INT 16h / INT 15h C2xxh emulation, USOSKEY / USOSMOUS) and INT 13h for USB
  disks.
- SeaBIOS runs all of its 32-bit code (xHCI, MSC, NVMe) **on CSMWrap's hidden helper core**.
  `__call32()` → `call32_proxy()` (`seabios/src/stacks.c`) writes `func_ptr` / `arg_*` into the
  `CSMPPrxy` mailbox in the F-segment and spins until the helper core (`romlayout.S`
  `.Lhelper_poll_loop`: flat 32-bit protected mode, no paging) clears `request_pending`. The helper core
  runs one request at a time, so it already serializes every xHCI access.
- USB enumeration happens **only at POST** (`usb_enumerate`, `xhci_check_ports`, `usb_msc_setup` are
  init code that is thrown away after POST). Port Status Change events at runtime are consumed and
  cleared by `xhci_process_events` and nothing else happens. A stick plugged in later is never seen,
  and a stick pulled out leaves a stale drive behind.
- A cold-plugged stick in QEMU (Codex, 2026-10-16, `Documents\Codex\2026-10-16\outputs\9x-usb-pendrive`):
  98 SE and Me on NVMe + qemu-xhci + usb-storage gave 80h = NVMe and 81h = stick, C: = NVMe,
  D: = stick through the IOS real-mode mapper ("Unit ... going through real mode drivers").
  64 MB write/compare PASSED, and the read-only check after a reboot PASSED. QEMU only.
- X470: Me on the Micron with a stick plugged in at boot stops with "cannot find KRNL386.EXE"
  (docs/nvme-9x-2026-10-14.md). Real-mode IO.SYS starts from the right C:, and after IOS switches to
  protected mode C: is something else. The failing step was never pinned down. Patch 0014
  (`int13_boot_disk_only`, in usos15 but **not written by any flow** before this branch) leaves the
  boot disk as the only BIOS hard disk.
- A side effect of the real-mode path (docs/nvme-9x-2026-10-14.md, IOS init): on every boot, 9x
  **writes a stamp into the MBR (bytes 0xDA..0xDF) of every BIOS hard disk** where those bytes are
  zero. That includes the user's stick, and any other SATA/NVMe disk SeaBIOS maps, such as a disk
  with a zero-filled protective-MBR boot area.

## 1. Architecture options

```
                 ┌────────────── X470 BSP (Windows 9x) ──────────────┐   ┌─ hidden helper core ─┐
 V86 (VM1)       │ SeaBIOS 16-bit: INT 13h / IRQ0 HID poll ──call32──┼──►│ channel 0 (CSMPPrxy) │
                 │                                                   │   │   SeaBIOS 32-bit:    │
 ring 0          │ IOS ─ SCSIPORT.PDR ─ USOSUSB.MPD ──(new) UDS──────┼──►│ channel 1 (USOSUDS1) │──► xHCI
                 │                                                   │   │   MSC/BOT, hot-plug  │   (only
                 └───────────────────────────────────────────────────┘   └──────────────────────┘    owner)
```

### (A) Recommended: SeaBIOS stays the only xHCI owner and offers a USB disk service (UDS) on a second helper channel, used by our own 9x SCSI miniport

- **SeaBIOS / CSMWrap side (new patch series 0021+):**
  - A second mailbox `USOSUDS1` in the same 64-byte line as `CSMPPrxy`, so the helper's existing
    MONITOR/MWAIT still wakes on it. The helper loop checks channel 0 first (unchanged ABI), then
    channel 1.
  - A channel 1 request is the physical address of a request block that the OS allocated in
    physically contiguous memory. The helper runs it with the existing runtime code:
    `usb_msc_send` / `usb_send_bulk` / `xhci_send_pipe`, plus a new `usos_msc_cdb()` (CBW, data,
    CSW with an arbitrary CDB and direction; the existing `CMD_SCSI` path is read-only).
  - Nothing else touches the xHCI, so keyboard, mouse, INT 13h and the OS driver cannot collide.
    There is no second owner and no handoff.
  - The helper core is not on the OS's CPU. A request runs **in parallel** with Windows, and Windows
    only polls a completion word.
- **9x side (new, own code): `USOSUSB.MPD`**, a SCSIPORT miniport like `usosnvme.mpd`
  (tools/nt/usosnvme, `USOSNVME_W9X`). Its devnode is root-enumerated (`Root\SCSIAdapter`, as the
  `--regbind` fixture already proved for usosnvme). It has no PCI resources and does not touch the
  xHCI devnode, which stays driverless as it is today.
  - It exposes each UDS device as SCSI target n, LUN = MSC LUN: **a removable direct-access device**
    (INQUIRY RMB = 1).
  - SRBs are forwarded as CDBs. A USB stick speaks the SCSI transparent command set, so READ(10),
    WRITE(10), READ CAPACITY, TEST UNIT READY, INQUIRY, MODE SENSE, START STOP UNIT and
    PREVENT/ALLOW go straight to the stick. A 64 KiB bounce buffer in the uncached extension avoids
    S/G lists, and MaximumTransferLength = 64 KiB.
  - IOS / DiskTSD / VFAT then handle the drive exactly like a ZIP or card-reader slot: a letter
    after the fixed disks, "Removable" in Device Manager, and media-change handling through sense
    data.
- **Hot-swap = media change in a permanent slot, not device arrival.**
  - The miniport keeps a slot (target) and its drive letter even when it is empty.
  - Stick absent: CHECK CONDITION, NOT READY / 3Ah "medium not present". Windows shows "insert a
    disk into drive D:".
  - New stick (the UDS generation changed): one CHECK CONDITION, UNIT ATTENTION / 28h "medium may
    have changed". IOS marks the media uncertain and VFAT re-reads the BPB.
  - This is the path 9x has supported since 95 for ZIP/Jaz/SyQuest and card readers. No CONFIGMG
    dynamic devnodes are needed (see C2).
- **Detection of plug/unplug (stage 2) is done by the helper core**, not by Windows:
  - About every 100 ms while idle (TSC deadline, as the 0011 watcher did with PAUSE + RDTSC), it
    reads `PORTSC.CCS` of every root port (and of the hub ports behind it, in a later step).
  - A one-bit "changed" latch is set in `xhci_process_events` (case `ER_PORT_STATUS_CHANGE`), because
    that function clears CSC itself and a fast unplug/replug would otherwise keep CCS = 1 and go
    unnoticed.
  - On connect it runs a runtime enumerator (section 3, stage 2) and bumps the generation. On
    disconnect it aborts outstanding requests (Stop Endpoint), sends Disable Slot, frees the device's
    rings, and the slot reports "absent".
  - Bonus: the same runtime enumerator can re-attach a **USB keyboard or mouse** plugged in after
    boot. Today that never works (docs/win9x-modern-2026-09-30.md: no mouse hot-plug).

Why (A):

| Requirement | (A) |
|---|---|
| no second xHCI owner, keyboard/mouse keep working | yes, single owner: the helper core already serializes everything |
| works on 95 OSR2 / 98 FE / 98 SE / Me alike | yes: SCSIPORT + MPD, the same as usosnvme (no NUSB, no 9x USB stack) |
| stable drive letters | yes: the stick never gets a BIOS number (stage 0), so it never takes part in the INT 13h unit / MBR-stamp matching, and its letter comes after every fixed disk |
| hot-swap | yes, as removable-media change, a semantics 9x has supported natively since 95 |
| no OS blocked in V86 | the I/O never enters V86 or the real-mode mapper: ring 0 → shared memory → helper core |
| size | stage 1 on the SeaBIOS side is small (≈1.5–2.5 KiB ROM: channel check, request validation, CDB/BOT, BOT reset recovery, record); stage 2 is large (section 3) |
| driver scope rule | own driver, needed for a usable system; no alternative on xHCI for 9x; covers the whole xHCI class (SeaBIOS's xHCI driver is generic), every MSC BOT stick, and UAS in a later step |

### (B) Rejected as the target: the IOS real-mode mapper on SeaBIOS INT 13h (what happens today)

- It works only for a stick present at POST, because SeaBIOS assigns BIOS numbers at POST only.
  INT 13h has no "disk arrived" notion, and the 9x real-mode mapper has no media change for a fixed
  BIOS hard disk (a USB stick in SeaBIOS is `DTYPE_USB`, registered as a hard disk).
- It changes **INT 13h unit numbering and DOS drive-letter assignment**. The stick is 81h, and DOS
  hands primary partitions out across disks (C: = first primary on 80h, D: = first primary on 81h,
  then the remaining partitions of 80h).
  - IOS later has to re-match every protected-mode disk to its INT 13h unit by the MBR 0xDA..0xDF
    stamp or a sector-0 checksum, and every volume by serial + unit + start.
  - Any mismatch (the X470 KRNL386 case) moves C: away from the Windows partition. The protected-mode
    switch is the point of no return.
- 9x **writes MBR stamps into the stick** (and into other BIOS disks) at every boot.
- All I/O runs in V86 through the global real-mode mapper. A long INT 13h blocks VM1, and an unplug
  during an INT 13h leaves SeaBIOS waiting for its transfer timeout. SeaBIOS's MSC code has no BOT
  reset recovery ("XXX - reset connection"), so after one stalled transfer the stick is gone until
  the next reboot.
- A hot-plug by re-enumeration would need new BIOS numbers at runtime, which 9x would never pick
  up (IOS reads the BIOS disk count once, at init).
- So (B) stays as it is for **DOS and Windows 3.x** (no IOS there, and the stick works through
  INT 13h). For 9x it is switched off by stage 0.

### (C) Rejected: our own xHCI driver for 9x (or xhci98 + an MSC class driver)

- It would be a second xHCI owner while SeaBIOS still serves the keyboard and mouse. The xhci98 trial
  on the X470 (2026-10-06) showed exactly that: the BIOS HID bridge died after the handoff. To make
  it work, the 9x driver would have to take over HID too: HID class driver, VKD/VMOUSE integration,
  and 95/FE without a WDM USB stack. That is a full USB stack (xHCI + hubs + HID + MSC) per 9x
  flavour, months of work, and NUSB binaries do not apply to 95/FE/Me in the same way.
- xhci98 + NUSB (98 SE only, user-supplied Microsoft binaries) stays an opt-in comparison
  (`win9x\xhci98.flag`). It and `USOSUSB.MPD` are mutually exclusive: the flow does not install
  USOSUSB when xhci98 is chosen.

### (C2) Considered for later: dynamic devnodes (one adapter devnode per stick via CONFIGMG)

- A VxD could create and remove a `Root\SCSIAdapter` child devnode per stick (the PC Card model),
  so the letter appears and disappears like Me's own USB mass-storage driver does.
- It is more code and depends on the 9x flavour (95 CONFIGMG vs 98/Me). IOS removal paths with open
  files are fragile, and letters would be assigned dynamically. The fixed-slot model gives the same
  usable result (copy files, swap sticks) with the media-change path that IOS has supported best
  since 95.
- Stage 3 at most, and only if users find the empty-slot letter confusing. Mitigation without C2:
  one slot by default (`Slots=1` in the class key), more only for multi-LUN card readers / 2+ sticks.

## 2. Drive-letter stability (independent of hot-swap): stage 0

Rule: on a 9x target **the boot disk is the only BIOS hard disk**.

- **Done on this branch:**
  - `tools/w9x_csmwrap_target.sh` exports `USOS_INT13_BOOT_DISK_ONLY=on` when the target uses
    usosnvme.mpd (NVMe + `nvme-experimental.txt`), the configuration with the X470 KRNL386 failure.
  - `tools/xp_csmwrap_esp.sh` then writes `int13_boot_disk_only = true` into the target's
    `csmwrap.ini` (patch 0014, present in the pinned 3.1.2-usos15).
  - Opt-out: an empty `EFI\USOS\win9x\int13-all-disks.flag` on the USOS stick keeps the old mapping
    (the stick through INT 13h for the real-mode mapper).
  - Test: `tools/tests/test_w9x_int13_boot_disk_only.py`.
- **Effects:**
  - The stick and other SATA/NVMe disks get no BIOS number. INT 13h therefore looks the same as with
    the Micron alone, which is the configuration that boots on the X470.
  - IOS no longer writes MBR stamps into the stick or other disks, and DOS letters cannot shift.
  - Cost until stage 1: no stick in 98 SE/Me on NVMe at all. Today Me has no stick anyway, and 98 SE's
    stick via INT 13h was never confirmed on the X470.
  - Other disks driven by a protected-mode driver (a second NVMe through usosnvme.mpd) still get
    letters after C:, because their DCBs no longer match a BIOS unit.
- **Not yet for 9x on SATA (MS-DOS compatibility mode).** C: there runs on the real-mode mapper
  itself. The letter-shift risk exists too, but no failure has been observed and the stick through
  INT 13h is the only stick path there. Extend the rule to every 9x target when stage 1 ships (one
  line in `w9x_csmwrap_target.sh`).
- **In-place check for the existing Micron install** (no reinstall, user step, not done here): add
  `int13_boot_disk_only = true` to `EFI\BOOT\csmwrap.ini` on the Micron's CSMWRAP partition.
  `BOOTX64.EFI` must be ≥ 3.1.2-usos12; usos15 is the release pin. Boot Me with a FAT32 stick
  plugged in.
  - Expected: Me reaches the desktop (no KRNL386), C: = Windows, no stick letter.
  - USOSLOG records the drive set (section 4).
- The root cause of the KRNL386 mismatch remains unexplained. Stage 0 removes the mechanism (a
  second BIOS disk) instead of fixing the matching. If it is ever needed, the section 4 records
  (BIOS drive table with the MBR stamp bytes of every disk, INT 13h call ring, DOS volume serials)
  are designed to pin it from one boot with the opt-out flag.

## 3. Staged plan

### Stage 1: cold-plug stick as a removable drive, read/write (no hot-swap yet)

SeaBIOS / CSMWrap (patch 0021 `usos-usb-disk-service`, own code, LGPL like the rest of the fork):

1. **Device table.** `usb_msc_lun_setup` records each `usbdrive_s` in `UdsDev[8]` (VARFSEG, 8
   pointers + state).
   - Per entry it records generation, state, root port / route string, slot id, the BIOS drive
     number after `usos_boot_disk_first` (0 = not mapped, the 0014 case), INQUIRY vendor/product
     and READ CAPACITY.
   - Only entries **without** a BIOS number are offered to the OS. That rules out a double mount
     (real-mode mapper and miniport on one FAT) even with the opt-out flag.
2. **Channel 1.** `struct usos_uds_mbox` (signature `USOSUDS1`, version, `req_phys`, `doorbell`,
   `done`) right after `bios_proxy`, which moves to `__aligned(64)` so both are in one MONITOR line.
   - The helper loop gets 6–8 instructions: after `request_pending`, test `doorbell != done` and call
     `usos_uds_service(req_phys)`. CSMWrap's signature scan is unchanged.
3. **Request block.** The OS supplies it in physically contiguous memory below 4 GiB; the header is
   validated before use. Ops:
   - `ENUM`: the device table, generation counters.
   - `SCSI`: CDB ≤ 16 bytes, direction, LUN, data phys/len ≤ 64 KiB. The result is the CSW status,
     the residue, and on CSW status 1 an automatic REQUEST SENSE (18 bytes).
   - `RESET`: BOT recovery.
   - `EJECT`: soft detach, see stage 2.
   - `STATUS`: counters for the logs.
   - Results: `OK`, `CHECK` (sense valid), `NODEV`, `GONE` (generation mismatch: the request belongs
     to a stick that is no longer there), `TIMEOUT`, `PHASE`, `BADREQ`.
4. **BOT reset recovery**, missing in SeaBIOS: on a stall/phase error, Bulk-Only Mass Storage Reset
   (class request FFh), CLEAR_FEATURE(ENDPOINT_HALT) on both endpoints, and on the xHCI side Reset
   Endpoint + Set TR Dequeue Pointer for a halted endpoint (xHCI 1.2 §4.6.8/§4.6.10). Without it a
   single stall kills the stick until reboot, for INT 13h too.
5. **Fast fail on unplug.** `xhci_event_wait` for a UDS request also reads the device's root-port
   `PORTSC.CCS`. When it drops to 0, the helper sends Stop Endpoint and the request ends with `GONE`
   at once instead of after the transfer timeout. The device is marked absent, and in stage 1 it
   stays absent until reboot.
6. **BAR guard**, as in 0010 for NVMe: before a UDS request, re-read the xHCI BAR from config space.
   If it moved, refuse (and log). If the command register lost memory decode, refuse.
7. **Diagnostics record `USOSUDSK`** (section 4).

Room:

- ROM: usos15 has 10496 bytes free. Stage 1 is estimated at 1.5–2.5 KiB of 32-bit flat runtime code,
  plus the record in VARLOW (≈512 B of low memory) and ≈96 B of F-segment variables (the zone has
  21418 B).
- Fallback if needed: drop `CONFIG_MEGASAS` (−2560 B) and `CONFIG_SDCARD` (−2752 B), which have no
  use on the target boards (Codex measurements, usos10).

9x side (`tools/nt/usosusb`, own code, GPL-3.0-or-later like usosnvme):

- **`USOSUSB.MPD`**, SCSIPORT miniport, `AdapterInterfaceType = Isa`, no access ranges, no
  interrupt, HwAdapterState (SCSIPORT.PDR needs it).
  - FindAdapter maps F0000h–FFFFFh with `_MapPhysToLinear` (INT 20h VMM 006Ch, as usosnvme) and
    finds `USOSUDS1` behind `CSMPPrxy`. If the version is wrong, or the signature is missing (an older
    CSMWrap or a firmware CSM), it returns SP_RETURN_NOT_FOUND and Device Manager shows "not present".
  - Uncached extension: request block + 64 KiB bounce buffer. Targets = `Slots` (registry, default
    1). INQUIRY RMB = 1 is answered by the miniport itself even when no stick is there.
- **StartIo, hybrid.** Post the request. Then spin for at most ~2 ms on `done` with
  ScsiPortStallExecution, which finishes most 4–64 KiB reads.
  - If not done: return and poll with `ScsiPortNotification(RequestTimerCall, …, 1000 µs)`. If this
    9x SCSIPORT turns out not to honour it, use VMM `Set_Global_Time_Out` through INT 20h. To verify
    in QEMU.
  - Never spin with interrupts disabled for longer than the short window. A slow stick's 64 KiB
    write takes 10–100 ms.
- **Sense state per slot.**
  - The generation is kept per target. A change gives one UNIT ATTENTION 06/28/00.
  - Absent gives NOT READY 02/3A/00.
  - `GONE` during a request gives NOT READY + 3A, and the request fails. VFAT reports an error; there
    is no silent retry onto a new stick.
  - `TIMEOUT` gives SRB_STATUS_TIMEOUT after one RESET.
  - SYNCHRONIZE CACHE / SRB flush / shutdown are forwarded; a stick that does not know them gets an
    ILLEGAL REQUEST, which is ignored.
  - START STOP UNIT with LoEj = 1 (the 9x "Eject" on a removable drive) → UDS `EJECT`. In stage 2
    the slot then reports absent until a stick is physically re-plugged.
- **Install.**
  - Copy `USOSUSB.MPD` to `C:\WINDOWS\SYSTEM\IOSUBSYS`.
  - A first-boot registry import (the REGBIND pattern from `run_w9x_nvme_qemu.py --regbind`):
    `Enum\Root\SCSIAdapter\USOSUSB` + `Services\Class\SCSIAdapter\nnnn` (DevLoader `*IOS`,
    PortDriver `usosusb.mpd`), and the removable-disk write-behind cache off.
  - Wired in `w9x_csmwrap_target.sh` / `INSTALL.BAT` like usosnvme, gated by a DATA flag
    `usb-storage-experimental.txt` until the hardware passes.
  - Not installed together with xhci98.

Exit criteria for stage 1:

- QEMU: 98 SE, Me and 95 OSR2: stick → letter after C:, 64 MB write/compare, a reboot with
  read-only compare (Codex's NVTEST data set), keyboard and mouse during the copy.
- X470: the same on 98 SE and Me (Micron), automatically logged.

Effort: SeaBIOS 0021 1.5–2 days (code + host tests + a QEMU protocol test), USOSUSB.MPD 2–3 days,
flow + QEMU 9x runs 1–2 days. **About 5–7 working days**, 1–2 X470 runs.

### Stage 2: hot-swap

SeaBIOS (patch 0022 `usos-usb-runtime-enum`). This is the big part.

1. **Runtime enumeration on the helper core.** The usb/xhci/msc setup code is init-only today. Two
   ways to get it:
   - (a) Make a compact own enumerator reachable from runtime: Enable Slot → Address Device →
     GET_DESCRIPTOR (device, config) → SET_CONFIGURATION → Configure Endpoint (bulk in/out) →
     GET_MAX_LUN → INQUIRY / READ CAPACITY. SeaBIOS's `layoutrom.py` then keeps the reached xHCI
     helpers (`xhci_cmd_submit`, `xhci_alloc_inctx`, …) in the runtime image.
   - (b) Reuse `usb_hub_port_setup` / `usb_msc_setup` as they are, by keeping the relocated init code
     resident.
   - Recommendation: (a). (b) drags POST-only state into runtime: `malloc_tmp*` zones freed after
     POST, `boot_add_hd` on a finalized BootList, threads, `in_post()`.
   - Estimated ROM cost of (a): 4–6 KiB. If room is short, build without `CONFIG_MEGASAS` /
     `CONFIG_SDCARD` / `CONFIG_LSI_SCSI` / `CONFIG_ESP_SCSI` / `CONFIG_MPT_SCSI`. Debug strings are
     the big reserve: without DEBUG_LEVEL about 26 KiB, which would mean a separate diag build.
2. **Pre-reserved runtime pool.** No runtime malloc exists; `malloc_prepboot` gives the unused
   ZoneHigh back to E820 as RAM.
   - At POST, reserve a fixed pool (e.g. 2 device slots × (output device context, input context,
     control ring, 2 bulk rings, a 512-byte descriptor buffer) ≈ 32 KiB) from ZoneHigh, which is
     E820 reserved and survives the OS.
   - The pool is reused on every plug. Unplug = Stop Endpoint, Disable Slot, rings zeroed, entry
     free. The swap count is unlimited, with no leak.
3. **Port watch.** About every 100 ms, the helper's idle loop (only when no channel 0/1 request is
   pending) checks the root-port `PORTSC.CCS` plus the CSC latch.
   - Connect, debounced 100 ms: port reset (USB2: PR; USB3: link training / warm reset if needed),
     enumerate into a free pool slot, generation++.
   - Disconnect: tear down, generation++, state absent.
   - Hubs: first step root ports only, because X470 rear ports sit on root ports of the two xHCIs.
     External/internal hubs come in a second step: status-change polling of the hub's ports through
     the hub's control pipe at the same 100 ms cadence.
4. **HID re-attach (optional in stage 2):** a keyboard/mouse found by the same path is put into
   `keyboard_pipe` / `mouse_pipe` if those are empty or their device is gone.
5. **Eject.** `EJECT` → SYNCHRONIZE CACHE (errors ignored), START STOP UNIT (LoEj), Disable Slot,
   state "ejected" (the port stays connected; it re-enumerates on the next physical connect).

9x side:

- The miniport needs no structural change: the generation → UNIT ATTENTION and absent → NOT READY
  paths are already there in stage 1.
- Added: a 1 s TEST UNIT READY poll is **not** needed; IOS polls removable media on access.
- Explorer's stale view after a swap is the usual 9x removable behaviour (F5).
- The risk to check in QEMU: IOS/DiskTSD must re-read capacity and BPB on UNIT ATTENTION for a
  stick of another size (as with ZIP 100 vs 250).

Exit criteria for stage 2:

- QEMU: plug, copy, remove, plug a different-size stick, copy. Pull the stick during a write → an
  error dialog, no hang, the next stick works. Keyboard and mouse active throughout; 100 cycles
  without a pool leak.
- X470: the same with two real sticks, automatically logged.

Effort: SeaBIOS 0022 4–6 days, QEMU harness (QMP device_del / device_add) 1 day, 9x runs + fixes
2 days. **About 7–9 working days**, 2–3 X470 runs. Hubs +2 days, HID re-attach +1 day.

### Test plan

- **Host:** unit tests of the new C pieces with `zig cc -fsanitize=undefined` (the csmwrap test
  pattern):
  - request validation, BOT/CSW parsing, sense mapping, generation logic;
  - the miniport's slot state machine: `src/platform/bios/win9x/usosuds_slot.c`, already prototyped
    on this branch;
  - patch-series and pin checks.
- **QEMU protocol test without Windows:** OVMF + CSMWrap + `-device qemu-xhci -device
  usb-storage,bus=xhci.0,drive=…,removable=on`, and a test MBR (the `nvme_rearm_mbr.S` pattern) that
  drives channel 1 from real mode with physical buffers.
  - Steps: ENUM, INQUIRY, READ sector 0 = image, WRITE + READ back, then QMP `device_del` → `GONE`
    within 200 ms, `device_add` of a second image → generation +1, its sector 0.
  - Keyboard/mouse: usb-kbd sends keys through QMP during transfers, checked through INT 16h.
- **QEMU with 9x:** Codex's controlled fixture (`codex-9x-usb` worktree, `controlled_usb_data.py`)
  with Root\SCSIAdapter for usosusb, NVTEST data set, then hot-plug via QMP. Private images only;
  keys from `%LOCALAPPDATA%\USOS\test-assets\private-keys`, never logged.
  - QEMU's limit: no SMM/firmware quirks of the AMI X470, other xHCI timings. A QEMU PASS is not a
    hardware PASS.
- **X470:** Micron in-place patch (the user replaces BOOTX64.EFI on the CSMWRAP partition, copies
  USOSUSB.MPD + the REG file, or a kit does it from the USOS menu).
  - USOSLOG runs from Startup and writes everything to `C:\USOS9X\LOGS` (section 4). The user's only
    action is plugging/unplugging a FAT32 test stick (never the USOS SanDisk, which is NTFS/GPT and
    not a 9x medium).
  - An automatic copy test: USOSLOG's `/USB` mode copies a 16 MB pattern to the first removable
    drive and compares it on each arrival, logging PASS/FAIL. No photos and no key presses.

## 4. Logging additions

SeaBIOS record **`USOSUDSK`** (VARLOW, 16-byte aligned, version 1, written only; patch 0021):

- **BIOS drive table at boot:** for each hard disk SeaBIOS found: type (NVMe/AHCI/USB/UAS…),
  controller BDF, USB root port / route, BIOS number or "not mapped (0014)", sector-0 FNV-1a hash,
  **MBR bytes 0xDA..0xDF**, the partition types of the 4 slots, sectors.
- **UDS devices:** generation, state, VID:PID, INQUIRY strings, capacity/block size, last CSW
  status, last sense key/ASC/ASCQ, counters (requests, bytes in/out, CHECK, TIMEOUT, BOT resets,
  GONE, BAR refusals).
- **Event ring (32 entries):** helper TSC ms, port, event (connect/disconnect/enumerated/failed with
  a reason code/ejected/reset), result.
- **INT 13h call ring (16 entries):** AH, DL, LBA, count, result, caller CS:IP. It shows which units
  the real-mode mapper actually uses; with the opt-out flag it is the KRNL386 evidence.

USOSDBG (new `DISK` section, also in `/L` mode for USOSLOG):

- The `USOSUDSK` record decoded, scanned like USOSMWHL in the first MiB. "none (CSMWrap before
  usos16)" when missing.
- The USOSUSB miniport status page, which shares the UDS mailbox: version, slots, per-slot
  generation seen, last SRB, last sense returned.
- The PCI xHCI section already prints PORTSC of connected ports; it stays.

USOSLOG:

- **Start record:**
  - `GetLogicalDrives` with GetDriveType, file system, label, volume serial and free space per
    letter.
  - Which letters are in MS-DOS compatibility mode (the IOS.LOG unit lines, with
    `C:\WINDOWS\IOS.LOG` copied to LOGS if present).
  - BOOTLOG.TXT tail (`[IOS]`, `KRNL386` lines).
  - The registry: `Enum\Root\SCSIAdapter`, `Enum\SCSI\*` (CurrentDriveLetterAssignment, Removable),
    `Services\Class\SCSIAdapter\*\PortDriver`.
  - The MBR 0xDA..0xDF bytes of BIOS unit 80h (INT 13h read through VWIN32, read only).
- **Watcher:**
  - `GetLogicalDrives` diff on the existing 250 ms tick → `+drive E: removable FAT32 serial … label …`
    / `-drive E:` / `media E: changed`, plus WM_DEVICECHANGE broadcasts.
  - On every change, one USOSDBG `DISK` snapshot.
  - `/USB` test mode: copy/compare on arrival (stage 1/2 hardware runs only).

## 5. Key risks

1. **9x SCSIPORT details:** RequestTimerCall support and its resolution in 95/98/Me SCSIPORT.PDR;
   removable-media handling (does DiskTSD give an empty RMB = 1 slot a letter, and does it re-read
   capacity after UNIT ATTENTION?). Fallbacks: a VMM timeout through INT 20h; report "medium present,
   0 sectors" instead of 3Ah. To settle first, in QEMU stage 1.
2. **Latency for keyboard/mouse:** a channel 1 transfer delays the V86 HID poll (channel 0 waits).
   The cap is 64 KiB per request; measure. If needed, 32 KiB, or channel 1 yields between TRB chunks.
3. **Runtime enumeration on the AMI X470** (stage 2): port reset / link training of USB3 sticks
   behind the Promontory and CPU xHCIs, debouncing, sticks that need several resets. Hardware-only
   behaviour; the event ring is the evidence.
4. **ROM room** for stage 2 (4–6 KiB beyond stage 1): solvable by dropping unused SeaBIOS drivers,
   but every removal must be checked against the other USOS targets (megasas/sdcard/lsi are unlikely
   there).
5. **Data safety on surprise removal:** as on any OS; the removable write-behind cache stays off, and
   GONE fails the request instead of retrying onto another stick. UAS-only sticks (no BOT alternate
   setting) are not covered by SeaBIOS MSC; SeaBIOS has a UAS driver, a later step.
6. **0014 side effect:** with the default on, a 9x NVMe target has no stick until stage 1, and no
   other INT 13h disk in DOS mode either ("Restart in MS-DOS mode"). Accepted; the opt-out flag is
   there.

## 6. Provenance

Own design. Sources:

- Public specifications: xHCI 1.2, USB 2.0, USB MSC BOT 1.0, SCSI SPC/SBC sense codes.
- SeaBIOS/CSMWrap 3.1.2 source with the USOS patches (LGPL; read for `stacks.c`, `romlayout.S`,
  `usb-xhci.c`, `usb-msc.c`, `blockcmd.c`, `clock.c`).
- The USOS repository: usosnvme 9x miniport, docs/nvme-9x-2026-10-14.md (its IOS/DiskTSD notes come
  from an earlier read-only disassembly for diagnosis), and Codex's 2026-10-16 cold-plug report.

No NT5 / Windows source was used for this design.
