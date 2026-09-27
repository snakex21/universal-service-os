# Windows 2000 on AMD AHCI (X470): driver options

Research, 2026-09-27. Nothing was downloaded or installed. Local checks used
only files already in the repo and the user's `W2KPLCMA4.811.iso` (kernel and
HAL extracted to the session scratchpad).

## Problem

The X470 test PC (ASRock X470, Ryzen 7 5700X) exposes SATA only as AHCI or
RAID. Windows 2000 SP4 has no AHCI driver, and the XP bundle (GenAHCI on a
patched storport plus the `ntoskrn8.sys` shim) does not load on NT 5.0
(`docs/windows-2000-uefi-2026-09-27.md`, section 3). Likely controllers:
`1022:7901` (FCH AHCI in the CPU) and/or `1022:43C8` (400-series Promontory
chipset SATA). Confirm with `lspci -nn -d ::0106` from USOS Linux before
choosing a driver.

Loader phase is not the problem: NTLDR reads the disk through INT 13h, which
the AMI CSM (or SeaBIOS under CSMWrap, which has an AHCI driver) provides.
Only the kernel-mode driver is missing.

## 1. Drivers that can run on NT 5.0

| Driver | Kind | Licence / source | AMD 7901 / 43C8 | Evidence | Verdict |
|---|---|---|---|---|---|
| **AHCINT** v1.2.0.0 (ages2001) | ScsiPort miniport, x86 + x64, 2000/XP/2003 | **GPL-3.0**, full source | **Yes, explicitly**: `AhciPciConfigIsAhci()` matches class `01-06-01` plus `1022:7901`, `1022:43C8`, `1022:43EB`; F6 floppy and `txtsetup.oem` included | New: first release 2026-09-16, v1.2.0.0 on 2026-09-25. No published Ryzen reports | **Try first** |
| **UniATA** 0.47b (Alter) | ScsiPort miniport, NT 3.51 to 7 | **GPLv2** (header in ReactOS's copy), source on the author's site and in ReactOS | Generic: "Generic AHCI support for unlisted controllers" since 2019. Only Hudson-2 AMD IDs are listed, so the INF/`txtsetup.oem` need the 7901/43C8 IDs added | Mature, used by ReactOS. AHCI is the weaker part (the changelog has several AHCI hang/crash fixes). Some MSFN users advise against mixing it with other drivers | **Second choice** |
| AMD `ahcix86` SB6xx-SB8xx builds from before 2008, or BlackWingCat's 2000 ports (3.1.1540.x, 3.2.1540.53) | Closed binary | AMD proprietary; BWC builds are modified AMD binaries with no redistribution grant | Built for `1002:438x/439x` (SB600-SB850). Nothing supports 7901/43C8 | MSFN: shutdown bugs on 760G/SB710; one user gave up and used a PCIe SAS HBA | No |
| Intel Matrix Storage 7.0 / 7.6 (patched by BWC) / 8.9 (needs BWC Extended Kernel) | Closed binary | Intel proprietary, and the BWC patches | Intel ICH/PCH only | Works on Intel only | No (Intel only) |
| `macosxamd/generic-ahci` | Floppy images plus `AHCINT-v1.2.0.0.zip` | No licence, no source, GitHub account created 2026-09-27 | Seems to be an unattributed re-upload of AHCINT | None | **Avoid**: use AHCINT upstream |
| BlackWingCat Extended Kernel / Extended Core | Replacement Microsoft kernel/system binaries | Modified Microsoft files, no licence that allows redistribution; hosted on BWC's blog and mirrored on archive.org | No AHCI driver of its own. BWC says **storport does not work on 2000**. It lets Intel IMSM 8.9 run | Popular on MSFN for Intel boards | Not for USOS (conflicts with the "no modified MS binaries" policy). It does not fix AMD AHCI anyway |
| KernelXE (Ximonite) | Unofficial 2000 kernel extension (kernel32/ntdll, PAE, KMDF) | Beta, no licence stated | No storage | none | Not relevant |

GenAHCI itself resolves fine on 2000 (0 unresolved). What blocks it is the
Win7 storport stack underneath.

## 2. Alternatives

**Add-in controllers with native Windows 2000 drivers.** The disk sits behind
the card's legacy option ROM, so **CSM must be on**. Under CSMWrap it is
untested whether SeaBIOS runs third-party option ROMs.

| Card | Bus | 2000 driver | Notes |
|---|---|---|---|
| LSI SAS1068E (LSI 3081E-R/3041E, Dell SAS 6/iR, IBM BR10i) | PCIe x4/x8 | LSI `symmpi.sys` (official 2000 support) | Cheap, robust, takes SATA disks. 2 TiB limit per disk. The MSFN AMD user who gave up on BWC's drivers used a PCIe SAS HBA |
| Silicon Image SiI 3132 | PCIe x1 | SiI SATALink `si3132.sys` (2000/XP/2003) | Needs the non-RAID ("IDE"/base) BIOS to match the SATALink driver, or RAID BIOS + SATARAID driver. Keep BIOS and driver of the same type |
| SiI 3112 / 3114 (PCI), SiI 3124 (PCI-X, runs in PCI) | PCI | Official 2000 drivers | ASRock X470 boards have no legacy PCI slot, so a PCIe-to-PCI bridge adapter is needed (more risk) |
| JMicron JMB363 / JMB361 | PCIe x1 | JMicron driver lists 2000; in IDE mode UniATA covers it too | The option ROM sets the SATA mode (IDE/AHCI/RAID) |
| Promise SATA300 TX2/TX4 | PCI | Official 2000 driver | Same PCI-slot problem |
| ASMedia ASM1061/1062, Marvell 88SE91xx | PCIe x1 | XP at best | Standard AHCI, so no gain over the onboard ports (same AHCINT/UniATA path) |

**NVMe.** **NVMe2K** (techomancer/nvme2k, BSD-3-Clause, ScsiPort miniport,
v1.2.0.0 2025-12): single queue, INTx only, experimental, tested mostly in
VMs and on Alpha, with a few real-SSD issue reports. Booting from NVMe also
needs INT 13h for NVMe (the AMI CSM usually does not provide it; SeaBIOS under
CSMWrap has an NVMe driver, which is plausible but untested) or a split
boot/system disk. This is a later experiment, not the first path.

## 3. Extending the ntoskrn8 shim for NT 5.0

The doc's list (ntoskrn8's own unresolved imports on 2000):
`ExAcquireRundownProtection`, `ExAcquireRundownProtectionEx`,
`ExReleaseRundownProtection`, `ExReleaseRundownProtectionEx`,
`ExInitializeRundownProtection`, `ExfReleasePushLock`,
`InterlockedPushEntrySList`, `KeGetRecommendedSharedDataAlignment`,
`PsGetThreadWin32Thread`, and from HAL `KeAcquireInStackQueuedSpinLock` and
`KeReleaseInStackQueuedSpinLock`. storport also imports those same 2 HAL
names **directly from `hal.dll`**.

**Correction: the gap is larger.** 1477 of ntoskrn8's 1697 exports are
*forwarders* to `ntoskrnl.*`, and 272 of them point at names that the 2000
kernel lacks. Following forwarders for the 188 storport imports adds **14
more names** that fail at load:
`InterlockedPushEntrySList`, `InterlockedPopEntrySList`,
`KeAcquireInStackQueuedSpinLockAtDpcLevel`,
`KeReleaseInStackQueuedSpinLockFromDpcLevel`, `KeFlushQueuedDpcs`,
`KeAcquireInterruptSpinLock`, `KeReleaseInterruptSpinLock`,
`MmProtectMdlSystemAddress`, `MmIsVerifierEnabled`, `MmAddVerifierThunks`,
`WmiTraceMessageVa`, `WmiQueryTraceInformation`, `vDbgPrintExWithPrefix`,
`_vsnwprintf`. That makes about **24 distinct names**, not 13. The resolver
behind the doc's table apparently did not follow export forwarders.
`check_xp_driver_imports.py` should.

Effort per item: most are small. Rundown protection is about 60 lines of
interlocked code. In-stack queued spinlocks can be plain spinlocks with the
old IRQL kept in the `KLOCK_QUEUE_HANDLE`. SList push/pop need a `cmpxchg8b`
loop. The alignment call returns 64. The verifier, WMI and debug-print calls
can be stubs. `PsGetThreadWin32Thread` needs a 2000 ETHREAD offset. Interrupt
spinlocks need the 2000 `KINTERRUPT` layout. The push lock must match XP's
inline acquire semantics. Maybe 1-2 days of code.

What makes it unrealistic:
- **Binary ownership.** ntoskrn8 is a prebuilt binary from NTOSKRNL_Emu
  (MovAX0xDEAD), whose repo has **no licence** and targets XP/2003/Vista/7
  only. USOS would have to write its own shim from scratch covering the
  166-name ntoskrn8 surface that storport uses.
- **HAL imports.** storport imports the in-stack spinlocks from `hal.dll`.
  Fixing that means patching the import table of a Microsoft binary (the
  bundled storport is already a third-party-patched **Win7 SP1** storport,
  6.1.7601.25735) or shipping a modified HAL. Both conflict with USOS's
  no-modified-Microsoft-binaries rule.
- **Runtime.** Win7 storport's PnP, power, DPC and work-item assumptions on
  the NT 5.0 I/O manager are unknown. Load success is only the first gate.
  Debugging needs a kernel debugger on the X470. Estimate: weeks, with an
  uncertain outcome. BWC, who has done the most 2000 kernel work, states
  storport does not work on 2000.

Verdict: not worth it while ScsiPort miniports (AHCINT, UniATA) exist that
need **zero** kernel extensions.

## 4. Recommendation

1. **AHCINT on the onboard ports.** Get the IDs with `lspci -nn`. Stage
   AHCINT's `txtsetup.oem`/`ahcint.sys` through the same TXTSETUP.SIF path
   USOS uses for XP drivers (GPL-3.0: ship the source or a written offer).
   Limits to accept: polling I/O (no interrupts, which also sidesteps IRQ
   routing), about 128 KB per request, no NCQ, 2 TiB cap (fine with the
   128 GiB partition plan). It is 11 days old, so treat the X470 run as a
   first field test.
2. If AHCINT fails, **UniATA 0.47b** with `1022:7901`/`43C8` added to its
   INF/`txtsetup.oem`.
3. **Hardware fallback** from the user's old cards: an **LSI SAS1068E**
   HBA, or else a **SiI 3132** or **JMB363** PCIe card with its official
   2000 driver, CSM on, disk on the card. PCI-only cards (SiI 3112/3114,
   Promise) need a PCIe-to-PCI bridge on this board. Old GPUs do not help
   with storage.
4. Skip BWC Extended Kernel, the AMD/Intel vendor drivers, the
   `macosxamd` re-upload and the shim extension. NVMe2K is a later
   experiment.

Independent of storage: the ACPI STOP 0xA5 risk on AM4
(`nt5-uefi-family.md` 3.1) remains. A working disk driver is necessary but
not sufficient.

## Sources

- AHCINT: https://github.com/ages2001/AHCINT (README; `src/2KXP/ahci_main.c`)
- UniATA: http://alter.org.ua/soft/win/uni_ata/ (changelog, compat list,
  `readme_w2k.txt`); ReactOS `drivers/storage/ide/uniata`
- NVMe2K: https://github.com/techomancer/nvme2k
- NTOSKRNL_Emu: https://github.com/MovAX0xDEAD/NTOSKRNL_Emu
- MSFN: "AMD SATA Controller on Windows 2000?" (topic 162493); "Big problem
  with BlackWingCat's AHCI drivers for AMD" (150751); "Integrating SATA
  Driver in Windows 2000" (181638); KernelXE (182051)
- VOGONS: "backporting of ACPI/AHCI/USB3/NVMe drivers for Windows 2000/ME?"
  (t=86268)
- BearWindows Windows 2000 page (IMSM 7.x on 2000):
  https://bearwindows.zcm.com.au/win2000.htm
- Win-Raid: AMD AHCI/RAID integration guide (ahcix86 vs amd_sata)
- Local: `media/.../Drivers/x86/Dependencies/{ntoskrn8,storport}.sys`
  import/forwarder analysis against the W2KPLCMA4.811 `ntkrnlmp.exe` and
  `halmacpi.dll`
