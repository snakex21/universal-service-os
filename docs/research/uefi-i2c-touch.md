# UEFI touch on the ROG Ally (RC71L): I2C-HID research

Status: research only, nothing implemented. Date: 2026-09-24.

## Verdict

- **A reusable open-source driver exists:**
  [jlobue10/TouchI2cDxe](https://github.com/jlobue10/TouchI2cDxe), licensed
  BSD-2-Clause-Patent. It is a self-contained EDK2 DXE driver: FCH AOAC
  power-up, a polled DesignWare I2C master, the HID-over-I2C transport and a
  HID report parser, and it produces `EFI_ABSOLUTE_POINTER_PROTOCOL`. It is
  confirmed working on the ROG Xbox Ally X (same Novatek `NVTK0603` panel,
  same `AMDI0010` I2C0 at `0xFEDC2000`, address `0x01`), the Steam Deck
  LCD and OLED, and one Intel Zenbook. It already carries an RC71L profile,
  but only as an untested "sweep" profile, and its comments wrongly expect a
  Goodix panel.
- **The Ally's touch constants are known** from a public RC71L DSDT and
  Linux probes (see "Hardware facts" below). They match the Ally X exactly,
  so the sweep's very first probe (base `0xFEDC2000`, address `0x01`,
  descriptor register `0x0000`) is the right one.
- **Most promising route:** build TouchI2cDxe from source, sign it with the
  USOS MOK key, and load it from USOS through the existing verified driver
  path (`verified_image.zig` / `pe_loader`), gated on SMBIOS baseboard
  `RC71L`. Preferably add an exact RC71L profile first (a one-line table
  entry, also worth offering upstream) so the driver does not un-gate and
  sweep all four FCH I2C tiles. USOS already enumerates every
  AbsolutePointer handle and rescans them, so almost nothing changes on the
  USOS side.
- **Effort:** about 1–2 days for Route A, including one or two test boots on
  the Ally. A native Zig port (Route B) is about 1.5–3 weeks, and most of
  that time goes into hardware debugging of bring-up, not code volume.

## What the USOS Ally log shows

`artifacts/ally-logs/input-devices.txt` (build B260924-110301-FE1189E5):

- `EFI_ABSOLUTE_POINTER_PROTOCOL handles=1`: only the ConIn console splitter
  (no device path), with range `0..1920 x 0..1064`. No physical absolute
  pointer is bound, so the AMI firmware has no touch driver attached on a
  normal boot. The splitter's range looks screen-derived and is a virtual
  placeholder, not a device.
- There is no USB digitizer. The only USB HID device is the controller MCU
  `0b05:1abe` (keyboard/mouse emulation); the rest are the Xbox-360-mode pad,
  Bluetooth `0489:e0f5`, the `1c7a:0588` fingerprint reader and a hub. So the
  touchscreen is not on USB, which fits I2C.
- The `WinSetup-*` folders are installer logs. Their `setupapi.dev.log` files
  contain no ACPI/I2C device IDs, and the XHCI IDs in them (`1022:43D0`) look
  like the X470 test machine, so they don't help here.

## Hardware facts (RC71L)

Sources: the RC71L DSDT in hhd-dev/hwinfo (`devices/rog_ally/acpi/decoded/dsdt.dsl`,
AMI "ALASKA", OEM revision `0x01072009`; the refurbished-unit dump
`acpi_refurb`, BIOS RC71L.336, has the same touch entry), plus Linux
linux-hardware.org probes of several RC71L units
(`/proc/bus/input/devices`, `/proc/interrupts`).

| Fact | Value | Source |
|---|---|---|
| Panel ACPI device | `\_SB.I2CA.TPL0`, `_HID "NVTK0603"`, `_CID "PNP0C50"`, `_UID 1` | DSDT l.10659 |
| Vendor / HID IDs | Novatek, VID `0x0603`, PID `0xF200` | Linux input devices, several probes |
| I2C address | `0x01` (7-bit), 400 kHz (`0x61A80`) | `I2cSerialBusV2 (0x0001, …, "\\_SB.I2CA")` |
| `wHIDDescRegister` | `0x0000` (`_DSM 3CDFF6F7-…`, function 1 returns `Zero`) | DSDT |
| Interrupt | `GpioInt(Level, ActiveHigh)` pin 9 on `\_SB.GPIO` (AMD GPIO 9) | DSDT; Linux `amd_gpio 9 NVTK0603:00` |
| Reset / power GPIO | **none** (no `GpioIo`, no `_PS0`/`_PR0` on TPL0) | DSDT |
| Controller | `\_SB.I2CA`, `_HID "AMDI0010"`, `_UID 0`, Linux `AMDI0010:00` / `i2c-0` | DSDT l.5473; Linux sysfs path |
| Controller MMIO | `Memory32Fixed 0xFEDC2000`, length `0x1000`; IRQ 10 (edge) | `I2CA._CRS` |
| Controller power | `_PS0` → `DSAD(5, 0)` = AOAC device 5 at `0xFED81E4A/4B` (only when NVS `IC0D && IC0E`); `RSET` → `SRAD(5, 200 µs)` | DSDT |
| Other devices on I2CA | none (the IMU `BOSC0200` is at `0x68` on I2CB; the CS35L41 amplifiers at `0x40/0x41` on I2CD, 1 MHz) | DSDT |
| HID report | Report ID 1, Digitizer/Touch Screen, per finger: tip 1 bit, contact ID 7 bits, X 12 bits (logical max 1920), Y 12 bits (logical max 1080). Up to 10 contacts, panel native landscape 1920×1080 | hhd-dev/hwinfo `peripherals/hid/touchscreen.txt` |

Because there are no other devices on I2CA, firmware conflicts are unlikely
once AMI's own drivers have finished. Because there is no reset GPIO, no
panel power sequencing is needed beyond HID-over-I2C `SET_POWER(ON)` and
`RESET`.

## Candidate drivers

| Candidate | Licence | What it is | Fit for the Ally / USOS |
|---|---|---|---|
| **[jlobue10/TouchI2cDxe](https://github.com/jlobue10/TouchI2cDxe)** (successor to AllyTouchI2cDxe) | BSD-2-Clause-Patent | Standalone EDK2 DXE, about 2.5k LOC of C: `FchAoac.h` (AOAC un-gate), `DwI2c.c` (polled DW master, 150 MHz Phoenix timings, whole-transfer timeouts, error recovery), `I2cHid.c` (descriptor, SET_POWER, RESET, input register), `HidParse.c` (bounded parse of tip/X/Y), `TouchI2cDxe.c` (SMBIOS-gated profiles, 1 s retry timer for about 30 s, 10 ms poll timer, ExitBootServices hook, log to `\TouchI2c.log`). Releases up to v1.3.1 (2026-08-02), CI builds, 36 commits. | **Best fit.** It is built for boot-manager loading (rEFInd `drivers_x64`), not firmware inclusion, so it runs from USOS as is. It polls, needs no GPIO interrupt and does the controller bring-up itself. RC71L is a sweep profile that probes `0xFEDC2000`/`0x01`/`0x0000` first. Caveats are listed under Route A. |
| Project Mu [`mu_plus/HidPkg`](https://github.com/microsoft/mu_plus/tree/HEAD/HidPkg) (`UefiHidDxe(V2)`, `HidMouseAbsolutePointerDxe`, `HidIo.h`) | BSD-2-Clause-Patent | Generic HID stack: HidIo → keyboard / absolute pointer. The V2 version is Rust. There is only a USB transport (`UsbHidDxe`) and no I2C transport. | Reference only. It would need an I2C `HidIo` producer, which is the part TouchI2cDxe already has, plus the Rust build. |
| Surface UEFI (touch in Surface firmware) | proprietary | The touch drivers are not published in Project Mu. | Not available. |
| edk2-msm / WOA ports ([edk2-porting/edk2-msm](https://github.com/edk2-porting/edk2-msm) `SynapticsRmi4Dxe`, `SynapticsTCMDxe`; [WOA-Project/Lumia950XLPkg](https://github.com/WOA-Project/Lumia950XLPkg) `SynapticsTouchDxe`) | BSD-2-Clause | Synaptics RMI4/TCM (not HID) over Qualcomm's proprietary `EFI_QCOM_I2C` QUP protocol plus TLMM GPIO. | Wrong bus and wrong protocol. Useful only as an AbsolutePointer pattern. |
| edk2-platforms [`AmpereAltraPkg/Library/DwI2cLib`](https://github.com/tianocore/edk2-platforms/tree/master/Silicon/Ampere/AmpereAltraPkg/Library/DwI2cLib) | BSD-2-Clause-Patent | DesignWare I2C master library for the Ampere server SoC. | Reference for the DW register model. No HID, no AMD FCH power handling. |
| edk2-platforms `Platform/AMD/*` (AgesaModulePkg, AmdPlatformPkg, AmdCpmPkg…) | BSD-2-Clause-Patent | AMD's open-sourced server (Genoa/Turin) packages. The FCH I2C appears only as ASL (`FchSongshanI2C_I3C.asl`). | No client-side I2C DXE and no I2C-HID. No help. |
| coreboot `src/drivers/i2c/designware`, `soc/amd/common/block/aoac`; U-Boot `drivers/i2c/designware_i2c.c`; Linux `i2c-designware`, `i2c-hid` | GPL-2.0 | Reference implementations. | GPL: read them for the register sequence only, don't copy code into USOS. TouchI2cDxe already reimplemented this under BSD. |
| MrChromebox edk2 (coreboot UEFI payload) | BSD-2-Clause-Patent | No I2C touchpad or touchscreen input in the payload that I could find. | None. |
| AMI Aptio touch modules | proprietary | AMI firmware on the Ally X powers and initialises the panel when volume-up is held during the splash (reported by TouchI2cDxe). On RC71L a normal boot binds nothing (see the USOS log). | Can't be reused. Holding a key at power-on might be a user-side fallback on RC71L, but that is unverified. |

## Route A: load TouchI2cDxe from USOS (recommended)

Integration points in USOS:

1. **Build.** Use the EDK2 build (`test_build.sh` / GitHub Actions, edk2-stable202411).
   Build from a pinned commit rather than taking release binaries, so the
   binary is reproducible and can be signed.
2. **Sign.** Use the USOS MOK key. Load it through `verified_image.zig`:
   SHIM_LOCK verification plus the USOS `pe_loader`, the same path as the
   NTFS driver. The loader must provide `EFI_LOADED_IMAGE_PROTOCOL` with a
   valid `DeviceHandle` if the driver's ESP log should work. The driver
   treats a missing one as "no log", but check this.
3. **Gate** loading on SMBIOS baseboard `RC71L` (and optionally `RC72LA`,
   `RC73XA`, `RC73YA`). The driver fails closed on unknown hardware anyway.
4. **Pointer handling.** The driver installs its AbsolutePointer handle
   immediately, with placeholder ranges `0..0xFFFF` on both axes, and
   answers `EFI_NOT_READY` until the panel is live. After that it publishes
   `0..1920 x 0..1080`. `pointer.zig` computes `rotation` once at
   registration (`rotationFor`) from the placeholder square range. That
   needs a tweak: recompute rotation when `Mode` changes, or skip handles
   whose `GetState` still returns `EFI_NOT_READY`. USOS already scales from
   the live `protocol.mode` and rescans handles (`input.zig` calls
   `pointer.rescan()`).
5. **Exact profile (recommended).** Add
   `{ "ROG Ally (Novatek NVTK0603)", NULL, "RC71L", NULL, DW_I2C_FCH_BASE_0, NVTK_I2C_ADDR, 0x0000, FCH_AOAC_DEV_I2C0, 0 }`,
   which is the Ally X entry with a different board name. The facts above
   justify it. Without it, the RC71L sweep profile un-gates all four FCH I2C
   tiles (`TOUCH_AOAC_SWEEP`) before probing. In practice it succeeds on its
   first probe, but it also touches I2CB/I2CD (IMU and amplifiers) if the
   first probe fails.
6. **Logging.** The driver appends up to 32 KB to `\TouchI2c.log` on the ESP
   it was loaded from, which is the pendrive. That is a disk write. Keep it,
   or strip it in the USOS build.

Remaining risks for Route A:

- **Untested on RC71L.** The sweep and exact profile are untested. The Ally X
  needed the AOAC un-gate (the firmware leaves the tile gated), and the
  driver handles that.
- **Panel not alive.** The Ally X README has a fallback of "hold volume-up
  during the splash" for cases where the panel side is not up. On RC71L there
  is no reset GPIO, so `SET_POWER(ON)` + `RESET` should be enough, but this
  is unconfirmed.
- **Handover to the OS.** At `ExitBootServices` the driver cancels its timers
  but leaves the controller powered and enabled. Windows and Linux run
  `_PS0` and reinitialise the controller, so this should be harmless. Watch
  for touch problems after a boot from USOS, especially after Windows fast
  startup or hibernate resume.
- **Timings.** Clock timings assume a 150 MHz reference clock (Phoenix, which
  matches the Z1 and Z1 Extreme). They are only programmed if the registers
  read 0, otherwise the firmware's values are kept.

## Route B: native Zig implementation in USOS

Components and estimated size (Zig LOC, excluding tests):

| Component | LOC | Notes |
|---|---|---|
| AOAC power-up (`0xFED81E40 + 2·n`: target D0, `PwrOnDev`, wait `ADDS==7`) | 40 | As in the DSDT `DSAD`. Optional `SRAD`-style reset. |
| DesignWare master, polled | 250–350 | `IC_ENABLE` handshake, `IC_CON`, `IC_TAR`, SS/FS HCNT/LCNT, `IC_DATA_CMD` read/stop/restart, `TX_ABRT` decode, abort/recover, whole-transfer deadline, `IC_COMP_TYPE` (`0x44570140`) liveness check. |
| HID-over-I2C | 150–200 | 30-byte descriptor from `wHIDDescRegister`, report descriptor, `SET_POWER(ON)`, `RESET` plus draining the zero-length ack, read `wInputRegister` (2-byte length prefix, 0 = no data). |
| HID digitizer parse | 150–250 | USOS already parses HID for gamepads (`usb_gamepad.zig`). This needs bit-packed 12-bit X/Y, report ID, tip switch and the first contact only. |
| ACPI discovery | 150–400 | See below. `splash.zig` already has `findAcpiTable`. |
| Integration (timer/poll, synthetic AbsolutePointer or direct feed into `pointer.zig`, logging, gating) | 150–250 | USOS can feed its own pointer layer directly, with no protocol install needed. |

Total is about 900–1,400 LOC. Estimate 1.5–3 weeks, dominated by on-device
bring-up and debugging over the USB-stick deploy loop.

About ACPI parsing: USOS has no AML interpreter, and the useful values sit
inside methods (`_HID`, `_CRS` and `_DSM` are `Method`s on this DSDT). A
robust generic approach needs a small AML interpreter, which is a large
project. The practical options are:

- **Byte-pattern scan.** Find the `NVTK0603` / `PNP0C50` strings, then the
  nearby large resource descriptor `0x8E` (`I2cSerialBusV2`, type 1) with its
  slave address, speed and resource source `\_SB.I2CA`. Then find `I2CA`'s
  `Memory32Fixed` (`0x86`, base `0xFEDC2000`). This works for this DSDT
  because the templates are static `Name(SBFI, ResourceTemplate…)`. The HID
  descriptor register from `_DSM` can't reliably be pattern-matched. Default
  it to 0, and fall back to 1 and 0x20.
- **Profile table keyed by SMBIOS**, like TouchI2cDxe, with the scan used
  only as a cross-check. This is recommended for Route B too.

Route B risks: the same as Route A (untested power and bring-up), plus
bugs in freshly written code. What it gains is no EDK2 build or C
toolchain, one signed binary, and direct integration with the USOS
input stack.

## Risks common to both routes

1. **Controller power state.** It is AOAC-gated on a normal boot, confirmed
   on the Ally X, and MMIO reads return garbage until it is un-gated. Handle
   it by un-gating tile 5 exactly as `_PS0` does. The `IC0D && IC0E` NVS
   gate in `_PS0` means the firmware only toggles power when the tile is
   enabled in setup. We skip that check and should log what we did.
2. **Firmware left the controller disabled or unconfigured.** If
   `IC_COMP_TYPE` is not `0x44570140` after un-gating, stop. The pin mux for
   I2C0 SCL/SDA is set by AGESA/ABL early, and the OS relies on that too;
   the evidence that it stays set is that Windows and Linux touch works
   without any extra pinctrl setup.
3. **Conflicts with the firmware.** No AMI driver binds the panel on a normal
   boot (the log shows no absolute device), and nothing else sits on I2CA. If
   a future BIOS adds a touch driver, detect an existing physical
   AbsolutePointer handle and stay off the bus. TouchI2cDxe logs this case.
4. **Panel reset or power sequencing.** The RC71L DSDT has no reset or power
   GPIO and no power resource, so the HID-level `SET_POWER`/`RESET` is the
   whole sequence. Give the panel reset-to-ready time (tens of ms) and retry
   for a few seconds.
5. **Interrupt.** GPIO 9 is level-triggered active-high. Polling
   `wInputRegister` every 10 ms is fine; an empty read returns a length of
   0. Polling without honouring the interrupt can return stale or empty
   reports on some panels, which is harmless here.
6. **Leaving things safe for the OS.** Stop polling at ExitBootServices and
   optionally send `SET_POWER(SLEEP)`. Do not gate the tile again, because
   the OS's `_PS0` expects it in any state.

## Data needed from the Ally

Required, and all read-only on the device:

1. **SMBIOS strings**: `Win32_BaseBoard.Product` (expected `RC71L`) and the
   BIOS version (e.g. `RC71L.3xx`), to key the profile and compare against
   the public DSDT (OEM revision `0x01072009`).
2. **ACPI tables** (DSDT and all SSDTs) from this unit's BIOS, to confirm
   `TPL0` = `NVTK0603` at `0x01` on `\_SB.I2CA` / `0xFEDC2000`. Two ways:
   - From Windows: TouchI2cDxe's
     [`tools/collect-hardware-info.ps1`](https://github.com/jlobue10/TouchI2cDxe/blob/HEAD/tools/collect-hardware-info.ps1)
     reads `HKLM\HARDWARE\ACPI` plus PnP/CIM queries, with no writes except
     its own zip. Alternatively, a USOS-provided script doing the same, or
     `acpidump.exe` from ACPICA.
   - From UEFI: USOS can dump the XSDT tables to `EFI\USOS\Logs\acpi\` next
     to `input-devices.txt` (it already walks ACPI for BGRT). This needs no
     Windows and captures exactly what the firmware publishes at USOS time.
3. **First on-device probe log**: which AOAC status bits are set before
   un-gating, `IC_COMP_TYPE`, the HID descriptor read at `0x01`/`0x0000`
   (expected VID `0x0603`, PID `0xF200`, report descriptor length), and the
   first input report. TouchI2cDxe's `\TouchI2c.log` or `TouchProbe.efi`
   produces this, and so would a Route B debug build.

## Sources

- USOS log: `artifacts/ally-logs/input-devices.txt` (this repo).
- TouchI2cDxe: https://github.com/jlobue10/TouchI2cDxe (README, DESIGN.md, CLAUDE.md, `src/`, `tools/collect-hardware-info.ps1`); licence file BSD-2-Clause-Patent.
- RC71L ACPI dumps, HID descriptor, input devices: https://github.com/hhd-dev/hwinfo/tree/HEAD/devices/rog_ally (`acpi/decoded/dsdt.dsl` ll.5473–5570 `I2CA`, ll.10657–10740 `TPL0`, ll.4759–4830 `SRAD`/`DSAD`; `acpi_refurb/new_ally_dmi`; `peripherals/hid/touchscreen.txt`).
- Linux hardware probes, ROG Ally RC71L: https://linux-hardware.org/?probe=5956798f27 (input devices: `NVTK0603:00 0603:F200`, `/devices/platform/AMDI0010:00/i2c-0/…`), https://linux-hardware.org/?probe=cc55f54331 (interrupts: `amd_gpio 9 NVTK0603:00`, `AMDI0010:00` on IRQ 10), https://linux-hardware.org/?probe=3bd5a82dbd.
- The same panel on other handhelds: hhd-dev/hwinfo `legion_go_s`, `claw_a1m`, `msi_claw8`; ShadowBlip/InputPlumber `docs/usage.md`.
- Project Mu HidPkg: https://github.com/microsoft/mu_plus/tree/HEAD/HidPkg, https://microsoft.github.io/mu/dyn/mu_plus/HidPkg/HidMouseAbsolutePointerDxe/HidMouseAbsolutePointerDxe/
- edk2-msm touch drivers: https://github.com/edk2-porting/edk2-msm (`Silicon/Qualcomm/QcomPkg/Drivers/SynapticsRmi4Dxe`, `SynapticsTCMDxe`); https://github.com/WOA-Project/Lumia950XLPkg
- edk2-platforms: https://github.com/tianocore/edk2-platforms (`Silicon/Ampere/AmpereAltraPkg/Library/DwI2cLib`, `Platform/AMD/*`).
- edk2 I2C stack (for the I2C_MASTER/I2C_IO model if ever needed): https://github.com/tianocore/edk2/tree/master/MdeModulePkg/Bus/I2c/I2cDxe
- MrChromebox firmware docs: https://docs.mrchromebox.tech/docs/known-issues.html
- ASUS ROG Ally FAQ (BIOS entry: power + hold volume-down): https://www.asus.com/support/faq/1050046/
- Microsoft HID over I2C Protocol Specification v1.0 (descriptor layout, SET_POWER/RESET, input register).
