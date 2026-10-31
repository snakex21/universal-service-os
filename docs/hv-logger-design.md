# USOS HV logger: a thin AMD-V hypervisor that records the boot (design, 2026-10-29)

## Podsumowanie (PL)

**Problem.** Natywny NT 3.51 na X470 czasem po restarcie (nie po wyłączeniu
zasilania) pada STOP 0x0A pod 0x801207DC (MiGrowWorkingSet, wyzerowany
nagłówek listy working set), potem nie działa USB, a restart z menu czasem
zawiesza komputer. Nasze breadcrumbsy wewnątrz NT tego nie widzą, bo awaria
jest wcześniej i prawdopodobnie nie jest winą procesora, tylko **DMA
urządzenia, którego nikt nie zresetował** (I211, xHCI albo NVMe dalej piszą
do RAM poprzedniego uruchomienia).

**Zalecenie.** Własny, mały hypervisor AMD SVM w Zig + asm (GPL, jak reszta
USOS), uruchamiany jako `\EFI\BOOT\BOOTX64.EFI` z partycji CSMWRAP na dysku
docelowym **przed** CSMWrap, tak że CSMWrap, SeaBIOS, nasz MBR, NTLDR i NT
działają jako gość. BitVisor (licencja BSD, ma SVM i loader UEFI) służy jako
źródło wiedzy i ewentualny szybki test zapasowy, ale **nie ma obsługi AMD
IOMMU** (tylko Intel VT-d), a IOMMU jest tu najważniejsze. SimpleSvm (MIT) to
sterownik Windows w stylu "blue pill", nie pre-boot, więc tylko jako
materiał referencyjny.

**Co logujemy (kolejność ważności):** (1) DMA przez AMD-Vi należące do
hypervisora: blokada bus-master I211/xHCI/NVMe do czasu, aż nasz sterownik NT
sam je włączy, każda próba trafia do event logu IOMMU z ID urządzenia i
adresem; (2) przy każdej próbie resetu (0xCF9, 0x64=FEh, 0x92, rejestr resetu
FADT) migawka adresów DMA urządzeń, żeby następne uruchomienie wiedziało,
gdzie stare urządzenie może pisać; (3) zapisy konfiguracji PCI (CF8/CFC,
MMCONFIG) do Command/BAR tych trzech urządzeń; (4) SHUTDOWN (triple fault),
INIT, wyjątki, a dla STOP 0x0A sam #PF: CR2, RIP, CR3 i zrzut zepsutej strony
fizycznej; (5) przejścia CR0/EFER (fazy rozruchu), wybrane MSR, banki MCA,
znaczniki czasu TSC.

**Zapis logów bez udziału użytkownika:** bufor pierścieniowy w RAM powyżej
4 GiB, ukryty przed gościem (NPT + E820), przeżywa ciepły reset; następny start
hypervisora (jeszcze w UEFI) zapisuje go do pliku na partycji CSMWRAP, a
następny start pendrive'a USOS kopiuje do `EFI\USOS\Logs`. Krótki skrót w
CMOS (jak `apm_breadcrumbs.zig`) przeżywa nawet odcięcie zasilania. Watchdog
na osobnym, ukrytym rdzeniu wykrywa zawieszenie, zrzuca stan i robi pełny
reset, więc nikt nie musi trzymać przycisku zasilania.

**Ryzyka:** w BIOS-ie X470 musi być włączone "SVM Mode" i IOMMU (USOS to
wykryje i zgłosi; to jedyna jednorazowa czynność użytkownika); CSMWrap
domyślnie wyłącza IOMMU (trzeba to wyłączyć i ukryć IVRS przed gościem);
pomocniczy rdzeń CSMWrap działa poza hypervisorem, dopóki nie zwirtualizujemy
AP; ciepły reset może nie zachować RAM (sprawdzamy w M1).

**Plan:** M1 hypervisor startuje, puszcza obecny łańcuch bez zmian, NT 3.51
dochodzi do pulpitu, logowane są ścieżki resetu; M2 PCI + reset + SHUTDOWN +
#PF; M3 IOMMU i atrybucja DMA; M4 watchdog i czysty pełny reset. Użytkownik
tylko uruchamia i odpowiada tak/nie. Szacunek: ok. 4 tys. linii, 12-18 sesji
agenta, M1 to 3-4 sesje.

---

## 0. Scope and status

Design only. No code, no VM runs, no disk writes. Every hardware statement
below that is not from the repo or a public spec is marked *verify*. The
design deliberately targets one machine (X470 Master SLI/ac, Ryzen 7 5700X,
32 GiB, Micron 3400 NVMe, Intel I211, AMD/Promontory xHCI) and one guest
chain; generality is a later concern.

## 1. Where it fits in the real code paths

Grep of the worktree (`svm|vmrun|hypervisor|bitvisor|vmcb|amd-vi|iommu`
over `*.zig *.c *.h *.S *.md *.go`, vendored toolchains excluded): **there is
no hypervisor or SVM code and no prior plan** in USOS. IOMMU appears only as
"CSMWrap disables it":

- `docs/research/csmwrap.md` step 6: CSMWrap calls ExitBootServices, `cli`,
  **disables IOMMUs (default)**, puts LAPIC/IO-APIC in ExtINT routing, masks
  the 8259, programs the PIT. Config key `iommu_disable` (line 60).
- `docs/nvme-nt6-2026-10-12.md:519`: "AMD-Vi is disabled before handoff
  (`iommu_disable` default true)". CSMWrap also hides one CPU in the MADT
  copy for its BIOS-proxy helper loop.

Boot paths into CSMWrap:

1. **Installed NT 3.51 (the failing case):** firmware boots
   `\EFI\BOOT\BOOTX64.EFI` from the 64 MiB FAT16 CSMWRAP ESP (MBR type 0xEF)
   at the tail of the target disk. That file *is* CSMWrap: written by
   `tools/xp_csmwrap_esp.sh` lines 129-131 (`mcopy ... ::/EFI/BOOT/BOOTX64.EFI`,
   `csmwrap.ini` next to it), pinned hash check line 37 and read-back check
   lines 163-166. NT 3.x/NT4 reach it through `tools/nt4_csmwrap_target.sh`.
   The USOS UEFI app is **not** in this path.
2. **USOS stick, Utilities -> Legacy BIOS mode:** `src/platform/uefi/bios_mode.zig`
   `start()` loads `\EFI\USOS\csmwrap\csmwrapx64.efi` with
   `esp_image_start.load` and `verified_image.start`.

Then SeaBIOS boots LBA 0 of the target disk: `src/platform/bios/nt3/nt3_e820_mbr.S`
(E820 filter: every non-RAM entry above A0000h becomes a copy of
F0000-FFFFF, entries above 4 GiB are dropped, RAM capped; HPET legacy off;
PCI BIOS hiding; sector-1 hooks; commits af100255 and 144dd62d add an MBR
bus-master quiesce sector and an MBR shutdown log in sector 4), then
syslinux/NTLDR and NT 3.51 with usosnvme, usosusb, usosnet351n, usosrst
(1.7: quiesce NVMe/xHCI, CF9h full reset), usosvbe.

**Insertion point:** a new EFI binary `usoshv.efi` becomes
`\EFI\BOOT\BOOTX64.EFI` on the CSMWRAP ESP; CSMWrap moves to
`\EFI\BOOT\CSMWRAP.EFI` (csmwrap.ini stays next to `BOOTX64.EFI`? *verify*
how CSMWrap locates its ini: `csmwrap.md` says "next to its own file", so it
goes next to `CSMWRAP.EFI`). `usoshv.efi` (a) flushes the previous boot's log,
(b) checks SVM/IOMMU, (c) virtualizes the BSP in place, (d) as the guest,
`LoadImage`/`StartImage`s CSMWrap. If any check fails it simply starts
CSMWrap natively and records why: **the machine always boots**.
`xp_csmwrap_esp.sh` gets an opt-in switch (default off) and an extra pinned
hash. For M1 experiments the ESP of the **Micron test disk only** is patched
(per the quick-hardware-check rule); the pendrive and the BIOSTAR SSD stay
read-only.

Reusable pieces already in the tree: `src/platform/uefi/acpi_dump.zig` (ACPI
walk: MCFG, IVRS, FADT, MADT), `src/platform/uefi/apm_breadcrumbs.zig` (CMOS
record + next-boot decode to `EFI\USOS\Logs\apm-off.txt`, TPL_HIGH_LEVEL CMOS
access), `src/platform/uefi/serial.zig`, the Zig x86_64-uefi build.

## 2. Base choice

| | BitVisor | SimpleSvm | Own minimal SVM HV (recommended) |
|---|---|---|---|
| Licence | BSD 3-clause, University of Tsukuba (+ The University of Tokyo for newer files), `LICENSE` in the repo. GPL-compatible. The same LICENSE file also lists bundled components (VPN module, OpenSSL/SSLeay, PCSC); the old OpenSSL licence is **not** GPL-compatible, so those modules must be left out of any USOS build. | MIT (GitHub licence field). GPL-compatible. | GPL-2.0-or-later, USOS's own. |
| AMD SVM | Yes: `core/x86/svm*.c` (init, I/O, MSR, nested paging `svm_np.c`, exit codes, INIT/SIPI handling). | Yes, with NPT. | Written for exactly what we need. |
| Boot model | UEFI loader `boot/uefi-loader/loadvmm.c` loads the VMM and returns to firmware as the guest; a legacy-BIOS loader also exists (`boot/loader`). Fits "launch before CSMWrap". | **Windows kernel driver** that virtualizes an already running Windows ("blue pill"). No pre-boot path. | Same model as BitVisor's UEFI loader. |
| IOMMU | Intel VT-d only (`core/x86/acpi_dmar.c`); **no AMD-Vi/IVRS code** (0 files match `ivrs|amd_iommu|amdvi`). | None. | AMD-Vi written by us (section 3.1). |
| Size/fit | Large: para-passthrough device mediation (ATA/AHCI, NVMe, USB, NICs incl. pro1000 and Realtek, VPN, storage encryption), its own build (GCC/Make, edk2 bits). Active: last push 2026-10-07, commits in 2026-09. | Small, educational. | ~4 kLOC, Zig + a little asm, built by `build.zig`. |
| Risk | Its device mediators would have to be disabled/kept out of the way; debugging an unfamiliar large tree on a machine with no console. | Would need the whole pre-boot launch, real-mode guest, AP handling, IOMMU added: effectively writing our own. | First boot under the HV is the main risk (no screen); mitigated by CMOS/NVRAM step breadcrumbs and automatic fallback. |

**Recommendation: write our own minimal SVM hypervisor**, using the AMD APM
vol. 2 (ch. 15 Secure Virtual Machine) and the AMD IOMMU specification
(pub. 48882) as the primary references and BitVisor's public BSD code as a
reference for the tricky parts (UEFI-launch-in-place, AP INIT/SIPI). Reasons:

1. The decisive feature for this bug is AMD-Vi ownership; no candidate has
   it, so it is our code in any case.
2. The required interception set is narrow (I/O bitmap, MSR bitmap, a few
   exceptions, SHUTDOWN, INIT, NPF on a handful of pages). A purpose-built HV
   keeps the guest timing closest to native, which matters for a
   non-deterministic bug.
3. Licence and build: native Zig/GPL fits the public repo with no third-party
   notice burden; if any BitVisor code is ever adapted, its BSD notice is kept
   in that file and in `docs/LICENSES-AUDIT.md`, which is permitted and
   GPL-compatible.

Fallback: if M1 stalls on "does this chain run under SVM at all", a BitVisor
UEFI build (VPN/OpenSSL modules off, device mediators off) is a reasonable
one-off feasibility spike, local only, not shipped.

**Effort estimate (agent sessions, each with one X470 boot round):** M1 3-4,
M2 2-3, M3 4-6, M4 2-3, decoder/integration 1-2: **12-18 sessions, ~4 kLOC**
(launch + VMCB from UEFI state ~700, NPT ~250, exit dispatch and handlers
~900, ring/flush ~400, ACPI/MCFG/IVRS/FADT ~200 reusing `acpi_dump.zig`,
AMD-Vi ~900, AP virtualization ~400, watchdog ~300, host decoder ~300).

### 2.1 Technical basis of the own HV

- **Launch in place (BSP):** in `usoshv.efi`, still in boot services:
  check CPUID 8000_0001h ECX bit 2 (SVM), `VM_CR` MSR C001_0114h bit 4
  (SVMDIS, set by the BIOS "SVM Mode: Disabled", with LOCK bit 3), CPUID
  8000_000Ah EDX bit 0 (nested paging), bit 3 (NRIP save), bit 7 (decode
  assists). Allocate the HV region (below), set `EFER.SVME`, `VM_HSAVE_PA`
  (C001_0117h), build a VMCB whose save area is the current UEFI long-mode
  state (segments, GDTR/IDTR, CR0/3/4, EFER, PAT, RSP, RIP = the instruction
  after VMRUN), then VMRUN. The guest continues inside `usoshv.efi`, which
  then starts CSMWrap. Boot services are never used from host context.
- **Real-mode / 16-bit guest:** with nested paging enabled, AMD-V runs the
  guest with CR0.PE=0 / PG=0 directly (no emulator is needed, unlike VMX
  without unrestricted guest). CSMWrap's switch to real mode for SeaBIOS,
  V86 mode, NTLDR's protected-mode switches and NT's paging all run natively.
  *Verify* the VMRUN consistency checks for the real-mode segment state in
  APM vol. 2 ch. 15 ("Canonicalization and Consistency Checks").
- **Nested paging:** identity map of all RAM and MMIO with 2 MiB pages
  (1 GiB where possible), memory type left to guest PAT/MTRR (NPT entries WB,
  guest PAT combining; *verify* the combining rules so legacy VGA A0000 and
  the framebuffer stay UC/WC). Exceptions: the HV region is **not mapped**
  (any access by the guest CPU = NPF = logged: catches wild CPU writes into
  it), IOMMU MMIO not mapped (guest must not reprogram it), selected 4 KiB
  pages read-only or not-present for MMIO watch (MMCONFIG function pages of
  the three devices, register page 0 of their BARs).
- **Hiding the HV memory:** `AllocatePages(AllocateAddress,
  EfiReservedMemoryType)` at a fixed 2 MiB-aligned address **above 4 GiB**
  (picked from the memory map, e.g. the top of the highest conventional
  range below 32 GiB). CSMWrap builds E820 from the UEFI memory map (step 3),
  so it becomes reserved; `nt3_e820_mbr.S` drops every entry above 4 GiB and
  NT 3.51 is capped at 1024 MiB anyway, so NT never sees it. Size: 64 MiB
  (HV code/data, VMCBs, NPT, IOMMU device table 2 MiB, I/O page tables,
  event log 512 KiB, ring buffer 32 MiB).
- **CPUID:** clear the SVM bit and the hypervisor-present bit for the guest
  (transparency; NT 3.51 ignores both). `VM_CR`/`VM_HSAVE_PA`/`EFER.SVME`
  accesses from the guest are intercepted and virtualized (SVM appears
  disabled).
- **APs:** CSMWrap starts its BIOS-proxy helper on one AP with INIT-SIPI
  from the guest. In M1 that AP runs **natively** (not virtualized): its I/O
  is invisible. M2 virtualizes it: the guest's ICR writes are caught (NPF on
  the xAPIC page, or MSR intercept if x2APIC — x2APIC must be off for CSMWrap
  anyway), and the HV starts the AP in its own VMCB at the SIPI vector
  (real mode, CS = vector << 8). A **second AP**, hidden from the guest by the
  HV's own MADT edit (or by CSMWrap's CPU block list, `csmwrap.md` line 60),
  runs the HV watchdog (M4).

## 3. What to intercept and log (prioritised for this bug)

Working hypothesis, consistent with "warm restart fails, power cycle
works" and "USB broken afterwards": a bus master from the previous boot
(I211 RX ring, xHCI event ring/scratchpad, NVMe completion queue) keeps
writing into RAM across a warm reset that does not fully reset it, and that
RAM now holds NT's working-set list. The commits af100255 (NIC BME off in
the MBR) and 144dd62d (usosrst 1.7 quiesce + CF9h full reset) already act on
this hypothesis; the HV is meant to **prove or disprove it** and attribute
the writer.

### 3.1 Device DMA via AMD-Vi (P1)

Without an IOMMU, DMA is completely invisible to any CPU-side mechanism
(NPT, breakpoints, page protection): a device writes RAM without the CPU
taking any exit. The IOMMU is the only hardware that can see it, and even
it only **reports faults**; a permitted DMA leaves no trace (v1 page tables
have no usable access/dirty tracking on Zen 3 — *verify* the EFR HASup/HDSup
bits; if present, they would allow a passive "which pages did device X
touch" mode).

Ownership:

- BIOS: "IOMMU" must be Enabled (AMD CBS/NBIO; X470 default Auto is often
  off — *verify*). Detect: ACPI IVRS present, IOMMU PCI function (00:00.2)
  visible. Report if missing (section 4).
- The HV parses IVRS (IVHD blocks: MMIO base, device entries incl. **alias
  and range entries** — devices behind the Promontory chipset bridge may
  DMA with the bridge's requester ID; the I211 and the chipset xHCI are
  likely affected, *verify* on the real IVRS), programs the device table,
  command buffer and event log, and enables the IOMMU before the guest
  continues.
- The guest must not see or disable it: IVRS is removed from the XSDT/RSDT
  copy the guest receives (or its signature changed), the IOMMU MMIO window
  is unmapped in NPT, and the IOMMU PCI function's config space writes are
  dropped. `csmwrap.ini` gets `iommu_disable = false` as a second safety.
  *Verify* in CSMWrap 3.1.2 `src/` how it finds the IOMMU (IVRS vs PCI scan).
- Interrupts: DTE IV=0 (no interrupt remapping; requests pass through
  unchanged, *verify* in the IOMMU spec DTE field descriptions), so the
  8259/IO-APIC behaviour CSMWrap set up is unchanged.

Default policy: every device gets an identity I/O page table (RW, all RAM
and MMIO except the HV region, which faults). That keeps the firmware,
SeaBIOS and NT working and already **protects and audits the HV region**.

Targeted policies for NVMe, xHCI, I211 (selected per boot by a flag file on
the CSMWRAP ESP, so experiments need no rebuild):

- **gate-until-enable** (main tool): from HV start, the device's DTE has
  translation valid with no read/write permission (all DMA faults, logged as
  IO_PAGE_FAULT with DeviceID, address, read/write). When the guest itself
  sets Command.BME=1 for that function (caught in 3.3) **after** the epoch
  start, the DTE switches to the identity table and an INVALIDATE_DEVTAB_ENTRY
  is issued. Every fault logged before that is DMA nobody in this boot asked
  for, i.e. stale DMA, with the exact target address. Epochs: I211 = from HV
  start until usosnet351n enables it (no firmware/SeaBIOS user of the NIC
  after ExitBootServices); xHCI and NVMe = the firmware, SeaBIOS (NVMe disk,
  USB keyboard) and NT legitimately use them, so their epoch starts at the
  first BME=0 or controller reset (NVMe CC.EN 1->0, xHCI USBCMD.HCRST) the
  guest performs, and ends at the next BME=1/run.
- **poison-previous-buffers:** the previous boot's reset-time snapshot
  (3.2) lists the DMA base addresses each device was given. In the new boot,
  those 4 KiB pages are marked not-present in that device's I/O page table
  until its driver programs new base registers. A fault there = the device
  is still running from the previous boot.
- Event log: 32 Ki entries (512 KiB), drained by the HV on each exit and by
  the watchdog AP; overflow counted. Fault suppression in the DTE off, so
  repeated faults are logged (with a per-device rate cap in the HV ring).

Limits stated honestly: DMA during the firmware POST after a reset happens
**before** the HV exists and the IOMMU is reset with the machine; the HV
cannot see it. It is bridged by (a) the previous boot's reset-time snapshot,
(b) an "inherited state" check at HV start (I211 RCTL.RXEN/TCTL.EN and BME,
xHCI USBSTS.HCH/USBCMD.RS, NVMe CC.EN/CSTS.RDY, logged before the guest
runs), and (c) a forensic dump of the corrupted page (3.4) compared with the
previous boot's buffer addresses. SMM DMA/CPU writes are also invisible
(SMM runs in host context outside NPT; SMI is not intercepted).

### 3.2 Reset paths (P1)

I/O permission bitmap, writes (and reads where noted), pass-through after
logging: `0xCF9` (value: 02h/06h warm, 0Eh full), `0x64` (command; FEh =
pulse reset, also D1h + `0x60` writes for A20/reset via output port),
`0x92` (bit 0 fast reset, bit 1 A20), the FADT `RESET_REG` (parsed at HV
start; on AMD typically I/O 0xCF9 — if it is memory space, NPF-watch that
page), ACPI `PM1a/PM1b_CNT` (SLP_TYP/SLP_EN = soft off), `0xB2`/`0xB3`
(APM/SMI command port: the X470 power-off path runs through SMM). Warm
boot flag at 0x472 (BDA, memory): one 4 KiB NPT write-watch on page 0
during the shutdown phase only (page 0 holds the IVT/BDA, heavily used in
real mode, so the watch is armed only after NT's kernel phase starts).

On a reset write the HV, before passing it through: logs TSC, guest RIP/CR3,
the port/value; takes the **reset-time device snapshot** (config space
Command/Status/BARs of NVMe/xHCI/I211; MMIO reads NVMe CC/CSTS/ASQ/ACQ, xHCI
USBCMD/USBSTS/DCBAAP/ERSTBA of interrupter 0, I211 RCTL/TCTL/RDBAL0/RDBAH0/
RDLEN0/TDBAL0 — offsets per the I211 and xHCI/NVMe specs, *verify* the igb
queue-0 register offsets in the I211 datasheet); drains the IOMMU event log;
seals the ring (header CRC). Optional M4 switch "hv-reset": the HV itself
clears BME on all endpoints, disables NVMe/xHCI/I211, then does CF9h 0Eh.

### 3.3 PCI configuration space (P1)

- `0xCF8` (dword) and `0xCFC-0xCFF`: track the address latch, log writes
  whose BDF is NVMe/xHCI/I211 or a bridge above them, offsets 04h
  (Command: BME, MEM, IO), 10h-24h (BARs), PM capability (D-state), MSI/MSI-X
  control. AMD CF8 extended config (NB_CFG EnableCf8ExtCfg) honoured.
- MMCONFIG (ACPI MCFG): the 4 KiB config pages of those functions are
  read-only in NPT. On a write NPF: log GPA, RIP; emulate the write using the
  decode-assist instruction bytes, or make the page writable, single-step the
  guest (RFLAGS.TF + #DB intercept), log the value read back, re-protect.
  NT 3.51 and SeaBIOS use CF8/CFC; MMCONFIG matters for the UEFI/CSMWrap part.
- Command.BME 0->1 transitions feed the IOMMU gate (3.1).

### 3.4 Exceptions, bugcheck, shutdown, INIT (P1/P2)

- **SHUTDOWN intercept** (triple fault): log, drain the IOMMU log, then the
  HV performs CF9h 0Eh. APM notes the guest state saved on a shutdown
  intercept may be inconsistent; log what is there plus the last recorded
  exception.
- **INIT intercept:** log (source unknown to the guest; on SVM a physical
  INIT is held and the HV decides; per APM the usual handling redirects it).
- **#PF intercept** from the NT kernel phase on (detected by the first CR3
  load after CR0.PG=1 with CR3 in NT's range and RIP >= 0x80000000). Each #PF
  is counted and reinjected unchanged (cost ~1 µs per fault). When the
  faulting RIP is in the bugcheck-relevant window (configurable, default
  0x801207DC +/- a page, from the STOP text) or the fault is a kernel-mode
  fault on an address not present in the guest page tables (the guest IRQL
  is not visible to the HV, so this is the trigger instead), the HV records CR2, RIP, error code,
  CR3, the guest register file, 256 bytes of stack, walks the guest page
  tables to translate CR2 and the faulting instruction's data pointer, and
  copies the **physical 4 KiB page** that holds the corrupted working-set
  list header into the ring. The host decoder then looks in that page for DMA
  signatures: Ethernet frames/igb descriptor write-backs, xHCI event TRBs
  (16 bytes, type field), NVMe completion entries (16 bytes, SQ head + phase
  bit), and compares its PA with the previous boot's snapshot (3.2) and the
  IOMMU faults (3.1).
- Optional bugcheck hook: NPT no-execute on the page holding KeBugCheckEx
  (address taken from the installed `ntoskrnl.exe` on disk at prep time),
  NPF on execute = record the five bugcheck arguments. Kept optional; the
  #PF capture above already sees the fault that leads to STOP 0x0A.
- #GP/#UD/#DF: counted, first N recorded with RIP/CR3.

### 3.5 Phases, MSRs, time (P2)

- CR0 write intercept (PE/PG transitions) and EFER write intercept give the
  phase timeline: UEFI long mode -> CSMWrap -> SeaBIOS real mode -> MBR/
  NTLDR -> loader protected mode -> paging -> kernel. CR3 writes are not
  intercepted after the kernel phase starts (context switches), only counted
  in the first second.
- MSR write intercepts: EFER, APIC_BASE (1Bh), MTRR variable/fixed
  (200h-20Fh, 250h-26Fh, 2FFh), PAT (277h), SYS_CFG (C001_0010h, CSMWrap's
  MtrrFixDramModEn), HWCR (C001_0015h), TOP_MEM/TOP_MEM2 (C001_001Ah/1Dh),
  SVM MSRs (virtualized). MCA: all bank STATUS/ADDR/MISC read at HV start
  (errors from the previous boot survive a warm reset) and at bugcheck/reset.
- Time: invariant TSC on Zen 3, passed through unchanged (no TSC offset, no
  RDTSC intercept), calibrated against the HPET at HV start; every record has
  a TSC stamp and a boot sequence number.

### 3.6 Cost

Intercepted events are rare (reset ports, config writes to three functions,
CR0/EFER, MSR writes, #PF ~10^5 per boot). The guest otherwise runs at native
speed; PIT/RTC/HPET and the VGA stay passed through, so NT 3.51 timing loops
are unchanged. No exits on the hot NVMe/xHCI doorbell pages.

## 4. Log persistence without user action

1. **RAM ring** in the HV region (above 4 GiB): fixed-size records (type,
   TSC, sequence, payload), header with magic, boot counter, write index,
   CRC per 64 KiB segment. Address stored once per boot in a UEFI variable
   `USOSHV` (one NVRAM write per boot, not per event) and as a 1-byte
   "slot" in CMOS.
2. **Next boot flush:** `usoshv.efi` starts, finds the previous ring (same
   address; valid magic/CRC), writes it as
   `\USOS\HVLOG\HV<boot>.BIN` on the CSMWRAP ESP through the firmware FAT
   driver (only the used part of the ring, capped at 1 MiB per boot, last 16
   boots kept, so the 64 MiB partition keeps room for CSMWrap), then clears it.
   The next start of the USOS stick (Kingston) copies new files to
   `EFI\USOS\Logs\hv\` and decodes a text summary, the same pattern as
   `apm_breadcrumbs.zig` -> `apm-off.txt`. No writes from host context to a
   disk the guest owns.
3. **CMOS summary** (survives power loss): a few bytes (last phase, last
   reset value, "IOMMU stale-DMA fault seen", "#PF capture taken"), encoded
   as valid RTC alarm values like `apm_breadcrumbs.zig` does; the exact CMOS
   bytes must not collide with 01h/03h/05h used by patch 0009 (*pick* from
   the X470's free extended CMOS bank, *verify* which bytes AMI leaves alone).
4. **Survival test:** whether warm reset keeps DRAM intact and the firmware
   leaves that range alone is not guaranteed (memory clear on MOR, retraining
   after CF9h 0Eh). M1 measures it: a known pattern written in boot N must be
   readable in boot N+1 after 06h and after 0Eh; the result decides whether
   the HV-initiated reset uses 06h (keeps the ring) after a full device
   quiesce, or writes the ring to a reserved area of the CSMWRAP ESP through
   the firmware at the next boot only.

**Watchdog (M4):** the hidden AP polls a heartbeat. Progress = guest exits
(PIC EOI `0x20` writes intercepted once per timer tick give a reliable ~100
Hz signal; plus the #PF counter). No progress for N seconds (default 15, and
not while the guest sits in a known idle HLT with IF=1) -> the AP sends an
NMI to the BSP (NMI intercepted): the BSP's HV records the guest state
(RIP, CR3, registers, stack, last 64 records), drains the IOMMU log, seals
the ring and performs the clean full reset (quiesce + CF9h). If the BSP does
not answer within 1 s (stuck in SMM or in the HV), the AP does the reset
itself. The "restart from the menu freezes" case is then a logged event plus
an automatic restart instead of a power-button press.

**Automatic fallback:** if two consecutive boots under the HV never reach
the "NT kernel phase" marker, `usoshv.efi` starts CSMWrap natively on the
next boot and logs that. The user is never left with a dead machine.

## 5. Risks

| Risk | Detail | Mitigation |
|---|---|---|
| SVM disabled in BIOS | X470 AMI "SVM Mode" (Advanced -> CPU Configuration) default is often Disabled; then VM_CR.SVMDIS=1 and LOCK=1, EFER.SVME cannot be set. | USOS UEFI app and `usoshv.efi` read CPUID + VM_CR and log/report "SVM Mode disabled in BIOS"; the stick menu can show it on the hardware summary. One-time BIOS change by the user (the only manual step), then yes/no. |
| IOMMU disabled in BIOS | No IVRS, no 00:00.2. | Same detection; M1/M2 do not need it, M3 does. |
| CSMWrap disables the IOMMU | Default `iommu_disable = true`. | IVRS hidden, MMIO unmapped, `iommu_disable=false`; *verify* in CSMWrap source. |
| CSMWrap/SeaBIOS under SVM | Unlocking 0xC0000-0xFFFFF via SYS_CFG/fixed MTRRs, real mode, V86 proxy, PIT/8259 programming. | MSR writes pass through (logged); NPT memory types must not override MTRR-based shadowing: NPT entries for 0-1 MiB use guest-controlled type (*verify* combining). |
| AP outside the HV | CSMWrap helper AP (M1) runs natively. | Accept in M1; virtualize from M2. |
| Legacy VGA / INT10 | VBIOS POST, A0000 window, framebuffer. | No intercepts on VGA ports/memory; NPT WB with guest PAT/MTRR UC. |
| SMM | SMIs run in host context; SMM writes and SMM-handled I/O traps (USB legacy, APM B2h power-off) are invisible after the trap. | Log the triggering I/O (B2h) only; state the gap in reports. |
| Timing | Bug is non-deterministic; extra latency could hide or move it. | Minimal intercept set, TSC unchanged; compare failure rate with/without HV over the same restart count. |
| First boot black box | No console under the HV. | Each launch step writes a CMOS/NVRAM breadcrumb; fallback (section 4). |
| Warm reset clears RAM | Ring lost. | Measured in M1; CMOS summary as last resort. |
| IVRS aliases | Chipset devices may DMA under a bridge requester ID. | Program aliases from IVRS device entries; log DeviceIDs raw. |

## 6. Staged plan

Each milestone: the agent builds and patches **only** the CSMWRAP ESP of the
Micron test disk (lowest-resistance rule), the user boots and later answers
yes/no; all evidence comes from the HV log files, never photos or key
presses.

**M0 (prerequisite, 1 boot):** stick UEFI app logs CPUID SVM/NP/NRIPS/
DecodeAssists, VM_CR, IVRS presence, MCFG, FADT RESET_REG to
`EFI\USOS\Logs\hv-caps.txt`. User: boot the stick once. Proof: the file.
If SVM is disabled: one BIOS change (SVM Mode, IOMMU Enabled), yes/no.

**M1 launch + pass-through + reset-path I/O (3-4 sessions).**
`usoshv.efi` as BOOTX64.EFI, BSP virtualized, NPT identity with the HV region
unmapped, I/O intercepts for CF9/64/60/92/B2/PM1/FADT reset, CR0/EFER phase
log, MCA at start, ring + next-boot flush, RAM-survival pattern test, fallback.
User: boot NT 3.51 as usual, restart it from the Start menu 3 times, answer
"did NT reach the desktop each time? yes/no". Proof: `HV<n>.BIN` files with
the phase timeline up to NT kernel phase for every boot, each restart's
reset port/value, the survival result for 06h/0Eh, NT behaviour unchanged.

**M2 PCI config + reset snapshot + SHUTDOWN/INIT + #PF capture + AP
virtualization (2-3 sessions).** User: same as M1, plus keep restarting
until a STOP or freeze happens (the watchdog is not there yet: a freeze still
needs one power cycle in M2, asked as yes/no "did it freeze?"). Proof: a
log with the config writes of NVMe/xHCI/I211 per boot, the reset-time DMA
snapshot, and, on a STOP 0x0A, the #PF record with CR2/RIP and the dumped
physical page; the decoder's verdict on DMA signatures and on whether the
page's PA matches a previous-boot DMA buffer.

**M3 IOMMU DMA attribution (4-6 sessions).** HV owns AMD-Vi, guest blind to
it, identity tables, HV region protected, gate-until-enable for I211 first,
then xHCI/NVMe epochs, poison-previous-buffers. User: restart cycles as in M2,
yes/no per boot. Proof: IO_PAGE_FAULT records naming a DeviceID and a target
address before the owning driver's BME=1, or a clean "no stale DMA in N warm
restarts" result that rules the hypothesis out; NT still reaches the desktop
with the gate on (if gate-until-enable itself fixes the STOP, that is the
attribution).

**M4 freeze watchdog + clean full reset (2-3 sessions).** Hidden AP, NMI
dump, HV-performed quiesce + reset, optional "hv-reset" switch replacing the
guest's reset. User: use the machine normally; answer yes/no "did any restart
need the power button?". Proof: freeze records with guest RIP/CR3 followed by
an automatic restart, and no power-button presses needed.

Exit: once the writer is identified, the fix belongs in the guest chain
(usosrst/usosnet351n/usosusb/MBR quiesce, as commits af100255/144dd62d
started); the HV stays an opt-in diagnostic, off by default.

## 7. Provenance and licence

This design uses the AMD APM vol. 2, the AMD IOMMU specification, the
public BitVisor and SimpleSvm repositories (only their structure, licence and
feature lists were read, no code was adopted) and the USOS repository. No
Microsoft source was needed for this document; NT internals named here
(MiGrowWorkingSet, KeBugCheckEx, address 0x801207DC) come from the X470 STOP
screen and earlier USOS notes. The planned implementation is new GPL code.

## Sources

- BitVisor repository and LICENSE: https://github.com/matsu/bitvisor
- SimpleSvm: https://github.com/tandasat/SimpleSvm
- AMD64 Architecture Programmer's Manual Vol. 2, ch. 15 (SVM), AMD pub. 24593
- AMD I/O Virtualization Technology (IOMMU) Specification, AMD pub. 48882
- USOS: `docs/research/csmwrap.md`, `docs/nvme-nt6-2026-10-12.md`,
  `tools/xp_csmwrap_esp.sh`, `src/platform/uefi/bios_mode.zig`,
  `src/platform/uefi/apm_breadcrumbs.zig`, `src/platform/uefi/acpi_dump.zig`,
  `src/platform/bios/nt3/nt3_e820_mbr.S`, `docs/nt-native-plan.md`
