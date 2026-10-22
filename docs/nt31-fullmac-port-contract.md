# NT3.1 Intel port: verified full-MAC boundary

This is original-media ABI evidence, **not a built Intel driver or network
runtime PASS**. NT31 USB HID was independently tested on R19c. The older
NT351 miniport still cannot load unchanged on NT31.

`tools/tests/audit_nt31_fullmac.py` checks the previously pinned archive,
ISO, NDIS.SYS and NE2000.SYS hashes, expands modules only in RAM and emits
bounded direct-branch metadata. Original ISO/compressed scratch stays in
owned G and is removed. The complete measurements are in
`artifacts/nt31-fullmac-contract/result-v2.json`; the first unextended
measurement is preserved as `result.json`.

Original NDIS.SYS SHA256:
`9f34331567762728ed67b25733583c248c635220d475b74014fda8f653556950`.
Original NE2000.SYS SHA256:
`c5fbffbf5d8de7b35f6812f46c176490c568853f2ea564bc363f5c826e17d7cb`.

At original NE2000 DriverEntry RVA420, the driver sets NDIS version3.0
and fills a56-byte full-MAC characteristics table, then registers it at
RVA524. Original NDIS NdisRegisterMac RVA2560 independently checks major3,
minor0 at2594/259d and minimum size38hex at25ab, with six-argument cleanup.
This agrees in table size/order with the public
[ReactOS DDK declaration](https://github.com/reactos/reactos/blob/master/sdk/include/ddk/ndis.h).
Current public callback typedefs alone are not proof of NT31 calling
conventions: the original callbacks below determine their actual cleanup.

| Characteristics offset | Callback | Original NE2000 RVA | Stack bytes removed |
|---|---|---|---:|
| 08 | OpenAdapter | cd0 | 36 |
| 0c | CloseAdapter | f50 | 4 |
| 10 | Send | 3320 | 8 |
| 14 | TransferData | 3100 | 24 |
| 18 | Reset | 1bf0 | 4 |
| 1c | Request | 10f0 | 8 |
| 20 | QueryGlobalStatistics | 1a00 | 8 |
| 24 | UnloadMac | 1b10 | 4 |
| 28 | AddAdapter | 680 | 12 |
| 2c | RemoveAdapter | 1b40 | 4 |

All ten callback direct CFGs completed within the bound. These are
stdcall-style cleanup observations; argument order, returned handles,
ownership and asynchronous completion still need dataflow proof. In
particular, Reset removes only one argument. Do not substitute the
two-argument miniport reset callback.

Additional original exports:

| Routine | RVA | Stack bytes removed |
|---|---|---:|
| NdisAllocateSharedMemory | 19e0 | 20 |
| NdisMapIoSpace | e60 | 24 |
| NdisInitializeTimer | 1320 | 12 |
| NdisSetTimer | 1350 | 8 |
| EthCreateFilter | 53a0 | 28 |
| EthFilterIndicateReceive | 5c40 | 32 |
| EthFilterIndicateReceiveComplete | 5e70 | 4 |

NdisRegisterAdapter RVA2780 has an observed six-argument return but its
large direct CFG hit the800-instruction bound. It is **not fully proven**;
the audit records truncation rather than inferring all resource semantics.

The next implementation gates are the registration/adapter contract,
actual PCI discovery and ownership on original NT31 HAL, mapped MMIO and
32-bit DMA, full-MAC bindings/filters/requests, receive/completion and
timer cancellation during remove/unload. The existing Intel ring/backend
may be reusable only after those interfaces are established. No private
NDIS handle fields, no renamed miniport imports and no no-op API stubs
are proposed. A legacy NE2000 baseline, if later run, would qualify only
that emulated NIC. Stock NT31 TCP/IP is static; DHCP is not applicable.

## Additional lifecycle/resource measurement

`audit_nt31_fullmac_lifecycle.py` produced `lifecycle-01.json` without a VM.
NdisRegisterAdapter now has a complete875-instruction direct CFG, with
truncated=false. MapIoSpace240, InitializeInterrupt253 and all measured
binding/filter/NE2000 timer routines also completed. The875 instructions
replace the earlier800-instruction truncation only for this newer measurement.

Original default HAL SHA256:
`301e7d13fb7c120657be7d911996aeefe2ec4e6b944fbc6db163ecffb12d872c`.
HalGetBusData RVA57B0 branches only for BusDataType0 and1; the default returns
zero, so the PCIConfiguration4 call is unsupported. HalGetInterruptVector
3A40 accepts only InterfaceType1/2/3 and returns zero for PCIBus 5. Memory
translation2730 follows an identity mapping without that interface filter.
These facts prevent treating the presence of HalGetBusData as PCI support
or renaming the device to an ISA adapter. DMA master registration through
HalGetAdapter 3C70 still requires a separate dataflow assessment. (3C60 in
the earlier note was an incorrect entry address.)

NdisRegisterAdapter2780 consumes the sixth argument as adapter information.
It reads type at information+0C, master at+4, physical-map count+10,
maximum mapping+14, port count+18 and descriptors starting+1C. The original
NE2000 helper940 zeros40bytes, sets type1/one port, then passes this record
at9B7. Names for unproved fields are not inferred from a later header.
The current [public ReactOS declaration](https://github.com/reactos/reactos/blob/master/sdk/include/ddk/ndis.h)
confirms the56-byte MAC characteristics but does not declare the old
RegisterAdapter/adapter-information interface. It cannot close this gap.

Original NTOS SHA256:
`7848c8e6dc7348ff1cb121b9f638fd9d0a5b5b0bc19c94ad618d9d6cd766dbaf`.
KeCancelTimer, KeRemoveQueueDpc, event/wait and contiguous/MMIO primitives
are present and have bounded complete CFGs. NdisCancelTimer is not a named
NDIS export. NdisInitializeTimer1320 uses the kernel timer at offset0 and
DPC at+28; NdisSetTimer1350 uses the same pair. NE2000 RemoveAdapter1B40
sets stop byte+269, calls KeCancelTimer on+220 at1BA8 and, if not canceled,
stalls500000us before freeing. That delay is not a general proof that a
queued callback is drained and will not be copied into the new driver.

A possible separate full-MAC design uses an owned system thread and a
stop-event/20ms wait, then joins the actual thread object before freeing
adapter data. It still needs verified Remove IRQL, thread-object APIs,
filter/binding serialization and resource ownership before implementation.
There is no Intel build or network runtime result from this audit.
All four protected NT4/NDIS5/NT35/NT351 binaries stayed identical; the
temporary ISO was removed and expanded Microsoft modules stayed in RAM.

## Checkpoint, 22 October 2026

The later measurements `lifecycle-02.json`, `lifecycle-03.json` and
`lifecycle-04.json` are completed static original-media audits. The final
measurement contains 1199834 bytes of instruction/name/RVA metadata, no raw
module bytes. Every selected direct CFG completed within its bound; the
report now separately lists unresolved indirect jumps. This is still not
an assertion that indirect calls or their callees were all proved.
Temporary ISO scratch was removed and the four protected driver binaries
retained their hashes. No Intel NT31 driver has been built or run.

The actual HAL path does not reject PCIBus 5 bus-master registration.
HalGetAdapter 3C70, for type 5 with Master set, selects UseChannel 0 at
3C7B–3C8E, calls allocator 48F0 at 3DC1 and returns the master adapter through
3E86–3E9D without programming 8237. The 177-instruction allocator CFG has no
InterfaceType rejection. HalAllocateCommonBuffer 4BB0 constructs the physical
limit 00FFFFFF at 4BB7–4BD6; master adapters bypass its 64KiB crossing check at
4C10–4C14. This is a 24-bit allocation limit, which an Intel 32-bit DMA ring
can use, not a general 32-bit allocation guarantee. The HAL import table
does contain MmAllocateContiguousMemory, MmFreeContiguousMemory and
MmGetPhysicalAddress. However, the section-wide thunk scan produced no HAL
matches. Exact decoding of targets 5E20/5E30/5E40 is still needed before
labelling those individual call targets as the corresponding imports.

NDIS DriverUnload 1950 calls the registered RemoveAdapter at 197C before
its own KeWaitForSingleObject at 1991, without raising IRQL in that path.
It then calls UnloadMac at 19A0. The measured cleanup helpers 3F90,3F20,
3FD0 and4130 close bindings/unlink wrapper objects and release allocations;
this is evidence for a removable full-MAC design, not permission to write
private wrapper fields. An owned worker must stop, terminate and be joined
through the actual thread object before adapter memory or driver code is
released. NtWaitForSingleObject 144D6 is an original export with a complete
81-instruction direct CFG and three-argument cleanup; the modern-looking
ZwWaitForSingleObject name is absent. The normal path should use the
already measured object-reference and KeWaitForSingleObject interfaces;
failure unwinding must also retain a provable join.

Original NE2000 FilterChange 21C0 removes 28 stack bytes, AddressChange 2240
removes 20 and DeferredClose 22C0 removes 4. These differ from miniport
callbacks and must be declared independently. Query helper 1610 confirms
request OID/buffer/length at+14/+18/+1C, with bytes-written/needed at+20/+24.
The measured filter indication routines release the supplied filter lock
around protocol callbacks. An owned worker must enter receive indication
at DISPATCH_LEVEL and must not hold the hardware lock across that call,
because a protocol can synchronously send from its receive callback.

Original RegisterAdapter calls IoReportResourceUsage at 2ABB and 2E82 and
tests both the returned status and conflict flag. MapIoSpace calls it at
F3E before translation/mapping. The next implementation must trace the
actual memory descriptor, bus/type and conditional reporting path through
these routines and honor failure/conflict; the presence of the calls
alone does not prove a particular future MMIO claim.

The agreed diagnostic PCI candidate is explicitly UP/QEMU only:
KeNumberProcessors must equal 1, BDF comes only from owned staging, and
vendor/device/class/BAR are revalidated. Each short IRQ-disabled CF8/CFC
transaction saves and restores CF8. No scan, BAR-sizing write, fake ISA
type or claim that CF8 is the NIC BAR is allowed. Save the original PCI
Command before enabling Memory/BusMaster; stop DMA and restore it on failed
initialization or removal. PCI interrupts/MSI are excluded because this
original HAL does not implement the PCIBus 5 interrupt-vector contract.

Next work is the exact HAL thunk decode, complete MMIO resource dataflow,
packet/buffer ABI and filter/binding ownership, followed by a separate
full-MAC source/build with import and unwind checks. Only then should an
owned overlay from stopped R19 be prepared for static IP, ping and DNS.
No new NT31 installation is needed. Stock DHCP remains not applicable.
No VM, build or additional original-media audit was queued at that checkpoint.

## Resumed implementation, 22 October 2026

`lifecycle-05.json` records exact HAL instructions:5E20 jumps through
IAT101B4,5E30 through101B8 and5E40 through101BC, relative to80400000.
Those entries name MmAllocateContiguousMemory, MmFreeContiguousMemory
and MmGetPhysicalAddress respectively. `lifecycle-06.json` also fixes the
audit scanner's signed32-bit displacement comparison and records these
resolved thunks explicitly. The earlier empty thunk map remains historical.
The kernel resource validator89F50 has140 direct instructions; a memory
descriptor follows89FB4–89FDE and passes the actual interface/bus through
both endpoint translations8A019/8A03C. It does not reject interface5.

There is an important unwind requirement: MapIoSpaceF45–F4E frees the old
resource list and installs its replacement before checking conflict/status.
Both registration and mapping use OverrideConflict=TRUE in
IoReportResourceUsage. Therefore even failed/conflicting mapping must call
the real NdisReleaseAdapterResources33E0 before NdisDeregisterAdapter.
Release zeroes PartialCount at33EF and reports that empty list at340D.
The candidate implements this on every registered cleanup path.

Corrected callback labels: EthCreateFilter argument2 becomes filter+14
(NE2000 RVA21C0, seven arguments: AddressChange). Argument3 becomes+18
(NE2240, five arguments: FilterChange). The previous checkpoint swapped
those names. NdisDeregisterMac2730 takes statusOut+handle and returns with
eight stack bytes removed, unlike a one-argument miniport deregistration.
The new declarations and import preflight use the actual old contracts.

The separate own implementation is `tools/nt/usosnet/src31/`; it compiles
the unchanged own igb source through a small wrapper. Existing NT4/95,
NDIS5, NT35 and NT351 binaries and their shared source were not changed.
Its runtime candidate is limited to Intel82576:8086:10C9, one explicitly
configured BDF and an actual UP kernel. It validates PCI identity, class,
header and BAR, reports actual MMIO, obtains shared DMA through NDIS with
checked24-bit bounds, and disables MSI/MSI-X plus INTx for polling.
Original PCI command/capability controls are retained for teardown.

An owned thread waits20ms, copies RX under the hardware lock and indicates
through the original Ethernet filter at DISPATCH_LEVEL after releasing that
lock. The filter owns destination/multicast policy; hardware accepts a
superset. Bounded software TX loopback handles local/broadcast/multicast
destinations. Deferred close completes after the filter's last receive
reference. Removal stops and joins the actual thread object before freeing
DMA; bus mastering is disabled and checked before DMA memory is released.
Impossible join/IRQL/DMA-stop violations fail-stop instead of freeing live
state. This still needs actual Windows execution and shutdown evidence.

Early Open is guarded under FilterLock: no filter callback is made while
Filter is NULL, hardware has not started or removal has begun. The actual
C gate is exercised by native host cases with a callback that would fail
if invoked with NULL. Reset currently returns the real NOT_RESETTABLE
status; a successful reset is not fabricated. There are no private NDIS
handle writes or missing-API stubs.

Build command:
`python -I -B tools/nt/usosnet/build31.py --wdk C:/Users/ASRock/Desktop/universal-service-os/tools/WinDDK71 --out artifacts/nt31-fullmac-build/build11`.
That completed directory is intentionally not reusable/overwritten. Its
candidate is15104B, PE3.10, SHA256
`f665b91d6bc8294e63c75625b19a8cc100164059a09735d8174d621801190ee7`.
`preflight_usosnet31.py` checks all43 imports against original exports,
17 original cleanup contracts,10 compiled callback decorations and the
38 native policy cases. All passed. The own NET31CFG.EXE is5120B,
SHA256`d5eee975c232971052f52619bb9455fc4fb3491df450401780bda13dd9c2819c`;
its host OS guard refused configuration and wrote only adjacent CFG31.LOG.
**These are host results; no installed NT31 Intel LAN PASS yet.**

Stopped R19c readback proves that TCPIP/PING/IPCONFIG and network services
were not installed. NDIS/AFD/TDI/STREAMS/WSOCK32 files are present. The
installed UP NTOS hash differs from the MP module selected by the original
media helper, so the final overlay preflight must also compare imports with
the actual stopped UP kernel. No raw hive/module was exported.

Original OEM identification corrects another filename assumption:
OEMNADN2 is NE2000, while OEMNADNE is NE3200/EISA. The scoped installation
donor is instead original OEMNADLB (NDISLoop), privately transformed in RAM
for our real SYS/adapter identity and copied only into the owned whole VM
disk. The original NetworkControlPanel will create stock TCP/IP STREAMS
configuration and bindings. NET31CFG refuses absent/ambiguous own adapter
instances and changes only the installed own adapter's bus/BDF parameters.
The required reboot and actual driver/IP/echo/DNS proof remain ahead.
