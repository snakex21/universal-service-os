# xHCI98 (yeokm1/xhci98): USB 3 host controller driver for Windows 9x in USOS

Status: 2026-09-26. Research only. No code changes and no disk writes.
Update 2026-09-29: the NT 5.2 systems (Server 2003 x86, XP x64) use xhci98
1.1.1.0 in Setup on branch `feature/nt52-xhci98`:
[../nt52-xhci98-2026-09-29.md](../nt52-xhci98-2026-09-29.md). The 9x notes below are unchanged.
Context: [win98-feasibility.md](win98-feasibility.md) §5 (USB) and §11 (plan),
[drivers.md](../drivers.md) (DATA\Drivers), [answer-file-generator.md](../design/answer-file-generator.md) §3.3 (msbatch.inf).
Source: <https://github.com/yeokm1/xhci98> (README, `LICENSE`, `src/xhci98.inf`,
`docs/using/release-notes.md`, `docs/contributing/roadmap.md`, `releases/history.md`, issues).

## 0. Verdict

| Question | Answer |
|---|---|
| What is it | A WDM **USB 2.0-only miniport** (`xhci98.sys`) for xHCI controllers. It plugs in under `usbport.sys`, so on 98 SE and ME it needs a separately installed USB 2.0 stack (NUSB 3.3/3.6 or SweetLow's). |
| Licence | **GPL-2.0-only**. Redistribution is allowed if the matching source is provided. |
| Install during Win98 Setup | **No, not realistically.** It installs after Setup, once the USB 2.0 stack is present. USOS could automate this after the first boot. |
| Does it work on the X470 (Promontory chipset xHCI + Matisse/Vermeer CPU xHCI) | **Unknown.** The author has never run it on an AMD controller. A third party reports B550 and X670 OK and X570 not OK. X470 is not on the list. |
| Recommendation | **Optional user-supplied download, documented.** Do not bundle it yet. First qualify it on the X470 with `XHCIQUAL` from DOS as part of the L6 spike. |

## 1. What it is

- **Type:** a WDM "generic USB host controller miniport" for PCI class `0C0330`. It runs on 98 SE, ME,
  2000 SP4, XP x86/x64, Vista and 7 (x64 needs signature enforcement off). It is not a
  complete stack: `xhci98.sys` imports `usbport.sys`, and on 9x `usbport.sys` comes from
  **NUSB 3.3/3.6** (98 SE only) or **SweetLow's USB 2.0 stack** (98 SE and ME; the only one
  supported on ME). Both are built from Windows 2000 USB binaries, so they are Microsoft files.
  **Windows 98 First Edition and 95 are not targets.**
- **Speed:** "this driver runs USB 2.0 on the controller only". It drives the USB 2.0 logical
  ports and leaves the SuperSpeed ports unpowered, so USB 3 devices fall back to High-Speed.
  Mass storage reaches about 33–35 MB/s since 1.1.1.0.
- **Device classes on real 98 SE hardware** (Intel ThinkPads E460 and P14s): HID mouse and keyboard
  (a composite keyboard types once Win98's own `usbhub.sys` is present), mass storage (flash drives
  and an ASMedia USB-SATA bridge), multi-TT and single-TT hubs, USB Ethernet (ASIX AX88772A)
  and UAC 1.0 audio. UAC 2.0 does not bind.
- **Controllers:**

  | Machine / controller | Result | Tested by |
  |---|---|---|
  | Intel 100-series (Skylake, E460 and H110) | OK | author and Omores |
  | Intel 300-series (B360) | OK | Omores |
  | Intel 400-series (Comet Lake, P14s) | OK | author |
  | AMD B550: chipset xHCI + Ryzen CPU xHCI | OK | Omores |
  | AMD X570: chipset xHCI + Ryzen CPU xHCI | **Not OK** | Omores |
  | AMD X670 (AM5) | OK | Omores |
  | Intel 7/8-series (XUSB2PR mux), ASMedia/Renesas/VIA/Fresco add-in cards | never run | — |

  The README says it is developed against the Intel xHCI spec and "tested mainly on Intel machines".
  The roadmap and history say: "No AMD controller has been tried" (by the author), and the DOS
  qualifier has "never run on AMD xHCI". Nobody has published why X570 fails.
- **Hard hardware requirements** (release notes): at least one USB 2.0 protocol port,
  **BAR0 below 4 GB**, and a **legacy INTx pin**. 9x has no MSI, so a controller with `Interrupt Pin = 0`
  cannot be driven at all. The driver needs working legacy 8259 INTx delivery.
- **Maturity:** repository created 2026-02-24. v1.0.0.0 came out on 2026-08-30, followed by six
  releases in four weeks. The latest is **v1.1.1.0 (2026-09-23)**, and the last push was 2026-09-23.
  The repo has 52 stars and 2 open issues (#4 USB internal requests, #5 MSI on 9x). It is a solo
  author with extensive AI assistance ("bugs are not unexpected"). The docs are unusually thorough:
  gates, an INF checker, a VM matrix, and a DOS qualifier tool `XHCIQUAL.EXE` (read-only
  `--probe-only` mode, and a full mode that tests handoff, reset, DMA, INTx and port reset).
- **Known limitations** (README): on NUSB, disabling, uninstalling or upgrading the driver in
  Device Manager **blue-screens** (an NUSB `usbport.sys` defect; SweetLow's stack survives it).
  Devices on root ports are reported as High-Speed, so HID polls at 1–4 ms; put a hub in between
  for true speed. Fast repeated plug and unplug (about 2/s) freezes 98. Audio can stutter during
  USB disk reads (tunable `XhciImodInterval250ns`, default 500). Issue #9 (closed) notes that errors
  found after the BIOS handoff leave BIOS-owned USB devices dead. The IRQ-absence check was moved
  before the handoff.

## 2. Licence

`LICENSE` (full GPLv2 text follows the header):

> This program is free software; you can redistribute it and/or modify it under the terms of the
> GNU General Public License, version 2, as published by the Free Software Foundation.
> … SPDX-License-Identifier: GPL-2.0-only

(GitHub shows "Other/NOASSERTION" only because of the added header and scope note.)

Consequences for USOS:
- **Redistribution on the stick or in the release is allowed** under GPLv2 §1/§3. USOS must
  ship the licence and either the **corresponding source for the exact version** (the tag's
  source zip) or a §3(b) written offer. Placing it next to USOS is mere aggregation and does not
  affect the USOS licence.
- The release zip is clean of Microsoft files **since 1.0.0.1**. 0.0.0.4–1.0.0.0 carried renamed
  `usbd.sys` and `usbhub.sys`, so never mirror those. The INF pulls `usbd.sys`, `usbhub.sys` and
  `usbui.dll` from the user's own Windows source through `LayoutFile=layout.inf`.
- `XHCIQUAL.EXE` and `XHCISNAP.EXE` embed the Open Watcom runtime with DOS/32A, and the MSVC 6
  runtime. They are "outside the grant" and have their own terms (`NOTICE.TXT`). Check those before
  bundling the tools. The `.sys` links no third-party runtime.
- **The required USB 2.0 stack (NUSB, SweetLow) contains Microsoft binaries → user-supplied only**
  (already the rule in win98-feasibility §11.2). Bundling xhci98 alone therefore gives the user
  nothing that works on its own.

## 3. Fit for USOS

### 3.1 During Setup or afterwards?
- The package is **INF-based** (`xhci98.inf`, `$CHICAGO$`, class USB, model `PCI\CC_0C0330`,
  `DevLoader=*NTKERN`, `NTMPDriver=xhci98.sys`). It has a `[DefaultInstall]` that pre-stages the INF
  and files with no device present.
- The Win98 Setup phases are the DOS phase (int13/int16), then the GUI/PnP detection phases.
  Setup has no USB 2.0 stack, and `xhci98.sys` cannot load without `usbport.sys`. Making it load
  during detection would mean integrating the NUSB or SweetLow stack into Setup's source as well.
  That is unsupported, untested upstream, and the stack is user-supplied Microsoft code.
  **Result: post-Setup only.**
- It also installs from the user's Win98 source: the INF copies `usbd.sys`, `usbhub.sys` and `usbui.dll`
  through `layout.inf`. USOS already keeps `C:\WIN98` on disk, which is the registered SourcePath,
  so this would not prompt for the CD.
- A feasible USOS automation, after the first logon (RunOnce from `msbatch.inf` `[Install]`, or a
  USOS post-install batch):
  1. SweetLow stack: `rundll setupx.dll,InstallHinfSection DefaultInstall 132 <path>\USB2.INF`
     (the README says "right-click Install", which is the same thing). NUSB is an EXE installer that needs a reboot.
  2. xhci98: the same `DefaultInstall` on `xhci98.inf` (it copies the INF to `%17%`), then reboot. PnP matches
     `PCI\CC_0C0330` and binds silently if no other INF claims it. **This must be verified in a VM
     (QEMU `qemu-xhci`) before hardware.**
  3. Keep `XhciImodInterval250ns` at the default.

### 3.2 Would it fix input and storage on the X470?
- **Setup itself does not need it.** Without an xHCI driver, 98 never takes over the controller,
  so AMI CSM SMM legacy emulation (ports 60h/64h, int13 for USB sticks) keeps working through Setup
  and afterwards. That is the pattern in the AM4 report (VOGONS t=88508). Emulation stops only
  under CSMWrap/SeaBIOS (no 8042 emulation), or **when a driver performs the xHCI BIOS→OS
  handoff, and xhci98 does exactly that when it loads.**
- So xhci98 does not rescue input when emulation is absent during Setup. It is useful
  **after** installation for hot-plug keyboard and mouse, USB flash, USB-SATA, USB NIC (the X470 I211 has no 9x
  driver) and USB audio.
- **Critical risk:** if xhci98 performs the handoff and then fails (IRQ routing, AMD quirk), the machine
  loses its USB keyboard and mouse in Windows. Keep a PS/2 keyboard available for the spike.
  Several ASRock X470 boards have a PS/2 combo port; check this board. Also, under `setup /p i`
  (non-ACPI, the recommended mode), INTx routing depends on the CSM `$PIR` table, which is
  unverified on the X470. That is exactly what xhci98 depends on.
- USB storage: Windows sees drive letters for USB sticks. Booting 98 from USB is unaffected (DOS/int13).
  Note the QuickInstall FAQ freezes when USB MSC legacy emulation is active.

### 3.3 AMD X470 controllers
- The X470 box has two xHCI candidates:
  1. **The chipset (Promontory, ASMedia-designed; `1022:43d5` per the feasibility study,
     confirm with `lspci -nn`)**. The same family as X370/B350/B450. **Untested.** B550's chipset
     (Promontory 21, also ASMedia) passed, which is weak positive evidence.
  2. **The CPU xHCI in the 5700X I/O die (Matisse/Vermeer cIOD, typically `1022:149c`)**. The X570
     chipset is derived from the same I/O die, and X570 is the one "Not OK" result. The B550 row says the
     "Ryzen CPU's own xHCI" was OK, but it does not name the CPU. **Mixed or unknown.**
- The requirements are INTx pin present, BAR0 < 4 GB (so **Above 4G Decoding off**, already in the
  §11.1 BIOS checklist) and working PIC-mode INTx. Only `XHCIQUAL` on the actual board can answer
  them.

### 3.4 DATA\Drivers and MSBATCH
- Today `Drivers\Windows 98 SE`, `Windows 98` and `Windows Me` are **folder-only**. They have no `Storage/USB/Other`
  class subfolders and USOS does not wire them (drivers.md, "Windows 98 / Me / 95 / 2000 / NT 4 - folder only").
- Proposed wiring when L6 is automated:
  - `Drivers\Windows 98 SE\USB\` (and `Windows Me\USB\`; **not** `Windows 98\`, because FE is unsupported)
    holds the user-supplied `USB2\` (SweetLow, with `USB2.INF`) and `xhci98\` (the unzipped `release-x86\`).
  - A Linux/DOS stager copies them to `C:\USOS98\DRV\USB\...`. The rendered `msbatch.inf` adds a
    RunOnce entry that runs `DefaultInstall` for `USB2.INF` first and then `xhci98.inf` in the order
    above, then reboots. The stager recognises the stack INF by name and refuses xhci98 without a stack.
  - Show xhci98 only for 98 SE/ME profiles on machines with an `0C0330` controller and no EHCI/UHCI
    (MS-7100 has OHCI/EHCI on nForce4 and does not need it).
- Optional pre-flight: `XHCIQUAL --probe-only` is read-only and can run from the existing legacy
  DOS path. The verdict could gate the RunOnce step. This needs the Open Watcom/DOS32A redistribution check first.

## 4. Risks

1. **Hardware support on the X470 is unproven.** AMD is a third-party result only, and X570 (the same IP as the CPU xHCI) fails.
2. **Loss of input after the handoff** if the driver fails after taking the controller. A PS/2 fallback is needed.
3. **IRQ/PnP under `/p i`:** depends on `$PIR`/INTx routing. The feasibility study already rates it as the top X470 risk.
4. **Dependency on the Microsoft-derived USB 2.0 stack:** it cannot be bundled, so the user must fetch it.
   NUSB makes the driver impossible to uninstall or upgrade in place (BSOD), so prefer SweetLow's stack.
5. **Young, fast-moving, AI-assisted code** (six releases in a month). USOS would need to pin a version by SHA-256 and track releases.
6. **GPL obligations** if bundled: source for the exact version, licence text, and the third-party tool runtimes.
7. **Scope:** it is USB 2.0 only, freezes on rapid replug, and needs a hub for true low/full-speed.

## 5. Recommendation

**Offer it as an optional, user-supplied download and document it. Do not bundle it now.**
- Now: add xhci98 to the L6 spike matrix. On the X470, run `XHCIQUAL --probe-only`, then the full run
  (with a PS/2 keyboard and the log not written to a USB drive on the tested controller). Then install
  SweetLow's stack + xhci98 1.1.1.0 on both controllers.
  Record the IDs, verdict and logs in `docs/evidence`, and report upstream (a hardware report is welcome).
- Document it in drivers.md or the 98 guide: 98 SE/ME only, SweetLow stack first, the minimal release zip,
  BIOS settings (Above 4G off), and PS/2 fallback advice.
- Later: if the X470 qualifies and the VM RunOnce flow works, consider a pinned (version + SHA-256)
  **optional download** step, the way Patcher9x is handled. Bundling would still be of little value
  while the required USB 2.0 stack has to come from the user.

## Sources
- <https://github.com/yeokm1/xhci98> (README, LICENSE, `src/xhci98.inf`, `docs/using/release-notes.md`,
  `docs/contributing/roadmap.md`, `releases/history.md`), <https://github.com/yeokm1/xhci98/releases>,
  <https://github.com/yeokm1/xhci98/issues/9>
- Omores' AMD/Intel results as linked from the README (reddit r/windows98, post 1whzyoa); a summary at
  <https://windowsforum.com/news/xhci98-1-1-1-0-raises-windows-98-usb-storage-speeds-to-33-mb-s.445727/>
- USB 2.0 stacks: <https://www.philscomputerlab.com/windows-98-usb-storage-driver.html> (NUSB),
  <http://sweetlow.orgfree.com/download/usb20_win9x.zip>, <https://msfn.org/board/topic/91336-usb-20-stack-for-win98me/>
- AM4 Win98 report: <https://www.vogons.org/viewtopic.php?t=88508>
