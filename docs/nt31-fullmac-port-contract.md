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

### R24 prepared native installation overlay

Build12 retains the same driver source but has a fresh linker timestamp:
SYS15104B SHA256`1b6d3150f40ac1df88334c727ecccfb0dd23fe526525136996918fd1f9b0daab`.
NET31CFG now verifies each DWORD readback and RegFlushKey success;
its5120B SHA256 is`a46bf32cca31500ac7c435b4d43e33ab181f2462bc118a56f4caa88789c996aa`.
The strict DNS logger remains`ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7`.
All43 driver,14 helper and71 logger imports are available in the actual
stopped UP installation, not only in the original MP media module.

`tools/tests/prepare_nt31_fullmac.py` constructs only a new owned whole-disk
overlay of stopped R19c. Protected SYSTEM/USB/classes/kernel files remain
byte-identical. It stages1183 original compressed source files (30893968B),
the private OEM installer and own binaries; no Microsoft module or hive is
exported as a standalone artifact. ISO9660 DISK1./SETUPLDR. normalize only
the empty extension to FAT names. Arbitrary long names and collisions fail.
The first source guard failure removed its scratch raw; the verified-empty
directory was recreated. That was preparation failure, with no VM started.

The final preparation is recorded in
`artifacts/nt31-fullmac-runtime/r24-preparation.json`. Target overlay SHA256
`15a13789415fb171cf0c85d244f9300145b4aa758dfbc81c3f316e3709c0c6a1`
backs onto readonly R19c SHA256
`d736f6509fba4780e73a74ab7164dd4bfe7a1e6664ba1f0cfbc80c9e6169f644`.
`boot_nt31_fullmac.py` starts one retained overlay after one normal host
resource guard, using the same hardware i8042/USB isolation, firmware,
EPYC-Rome and2GiB. The added sole igb has explicit BDF00:05.0 and MAC
52:54:00:55:53:01. The own driver additionally requires an actual UP kernel.
The localhost VM-only network mirror has an8MiB hard cap. DHCP analysis is
not applicable to original NT31 static TCP/IP and cannot imply LAN PASS.

The native NetworkControlPanel must install the own OEM adapter and stock
TCP/IP, create STREAMS/bindings, configure10.0.2.15/24, gateway10.0.2.2 and
DNS10.0.2.3, then reboot. The private donor writes own BDF parameters into
its actual adapter HardwareParameterKey before first bind. NET31CFG verifies
one unambiguous USOSNET311 and the real USNET31.SYS ImagePath, and readbacks
only those own parameters. No offline guessed network hive schema is used.
At startup R24 is an unqualified candidate; all runtime PASS fields remain
false until actual guest echo/DNS evidence and stopped SYS readback exist.

Host command-adapter and source-name tests passed6cases. The actual-C
38policy/10callback/17original-cleanup preflight also passed. These results
do not qualify installed NT31 LAN, reset support or X470 hardware.

### R24 actual guest result: Intel LAN failed before working IP

The original NCPA accepted our OEM adapter, installed original TCP/IP and
created the real instance `USOSNET3101` (suffix01, not suffix1). The helper
correctly refused its unexpected identity; that refusal remains evidence.
Read-only native registry inspection and later stopped REGF1.1 readback
confirmed exactly one own driver plus one instance, BusType5/BusNumber0,
PciBus0/PciDevice5/PciFunction0, DebugPort233, Medium0 and static settings.
The editor changed no value. Stock TCPIP.SYS now exists,125172B SHA256
`a8b3bca004a3908dc0bb529d918936428c521b3ff374b010986ab9392b724bd0`.

After the required native reboot the Program Manager returned, but the
own service start failed with system error193: invalid Windows NT image
(`operator-64.png`). Compatible `ping -n 3 10.0.2.2` failed to open the IP
stream (`operator-65.png`). Direct USOSLOG execution worked and recorded
Winsock10050/DNS11004; ICMP was skipped because its newer adapter discovery
did not recognize NT31's original global gateway schema. **No LAN PASS.**
The first staged script separately used unsupported ping-w and START/wait,
and IPCONFIG is absent. Those failures remain in operator62/63 and POST.LOG;
future script text removes those assumptions. A completion marker merely
means commands were issued; it cannot qualify network replies.

Native shutdown reached safe-to-turn-off (`operator-70.png`), then normal
finish/QMP quit returned0. R24 elapsed3278.92s and retains its overlay
SHA256`769e75a2f9f13ba35a9912bb658a55213c7ae756e3c9a45dfc3a0c02dce8ff17`.
Stopped readback confirms the installed SYS is exactly build12's15104B,
all43 import names exist, frozen USB is unchanged and i8042prt remains4.
The6-frame bounded mirror does not imply working guest traffic. Base R19c
was unchanged; no Microsoft module/hive was exported.

Evidence: `artifacts/nt31-fullmac-runtime/r24-guest-evaluation.json`,
`r24-native-install-observations.json`, and `r24-stopped-readback-02/`.
The initial collector rejected a legitimate zero-byte redirected own log;
its partial output/failure.json remains. The fixed collector permits empty
selected text while preserving bounds/NUL/name checks (5host cases PASS).
No VM rerun was needed for that collection repair.

Code193 is still a concrete unresolved loader/entry failure, not an assumed
PCI problem. R24 debug logging starts only at Add, so its empty E9 stream
does not distinguish loader from earlier registration failure. Build13
adds explicit DriverEntry/wrapper/RegisterMac/Add trace and corrects helper
identity to the observed01, with14 actual-C identity/absence/ambiguity cases.
All52 native policy cases,17 original cleanup contracts and10 compiled
callbacks pass. SYS15360B SHA256
`1d2451df303712354f5bdfcb2d2334dd743f3456564090e038b9cfedc941b8e1`,
helper5120B`ae531c0f159232a9e338c5b92e41d740d2777ed1bb8f4ec5e2115b2ff5b23848`.
Build13 has not run in Windows. Other OS binaries/shared backend remain
unchanged. A following test must use a new overlay of stopped R24, preserving
the completed failure rather than reinstalling the OS.

### Demand-loader contract and R24b

Root measured the original NT31 media kernel, SHA256
`7848c8e6dc7348ff1cb121b9f638fd9d0a5b5b0bc19c94ad618d9d6cd766dbaf`,
image base80100000. At RVA772E4 it reads IMAGE_NT_HEADERS+3C
(FileAlignment),772E7 tests mask1FF and772EE returns C000007B when nonzero.
The following77300–7730C checks a power of two and7731A requires
SectionAlignment>=FileAlignment. Evidence is the completed metadata
`macierz-windows/artifacts/coverage/nt31-loader-review-r24.json`.
R24's128-byte file alignment fails this measured demand-loader contract.
Its comparison with a boot-start USB driver did not establish compatibility
with the later kernel loader. The installed UP kernel is a distinct hash;
R24b execution remains the final check of this correction in that guest.

Only the NT31 `sources` file now sets DRIVER_ALIGNMENT=0x1000. Build14
has FileAlignment0x200, SectionAlignment0x1000 and PE3.10. Its16384B SHA256
is`08ac4bb5a384629ba047926ff7867a10b01d485f38811bf47410b919d7ed310b`.
The helper5120B SHA256 is
`ab05aa9c414f3136039d065eaabbf611ecbdec5df5e989815d4d9657d397d7e3`.
Preflight now explicitly enforces the measured file-alignment checks,
section alignment and actual section RVAs, alongside52 native policy cases,
17 original cleanup contracts and10 compiled callbacks. Existing other OS
binaries and shared backend remain byte-identical.

`prepare_nt31_fullmac_retry.py --build artifacts/nt31-fullmac-build/build14`
creates only a new R24b overlay, not another installation. It verifies all
43 SYS and14 helper imports against the actual stopped installation,
preserves SYSTEM/USB/classes/NDIS/TCPIP/STREAMS/kernel/HAL bytes and changes
only three copies of the own SYS, the own helper and own command script.
R24 logs move only within the new guest overlay to USOS/NET31/R24BASE, so
stale output cannot be mistaken for a new test. The original R24 is unchanged.
A pyfatfs1.1 wb-growth failure removed its raw and left no started VM; the
completed fix recreates only the exact allowlisted own files and verifies
them independently. No failed preparation is called a Windows result.

Manifest `artifacts/nt31-fullmac-runtime/r24b-preparation.json` pins the new
overlay SHA256
`1a8ae8b03336a666bb70cc190ae558c23006aa9b7292d47ad25a3fb40a907b94`.
The fixed `boot_nt31_fullmac_retry.py` adapter uses the same one-guard runner,
firmware, CPU, memory, USB isolation and explicit igb BDF; it retains its
overlay and uses a passive300-second endpoint. At startup R24b has no LAN
PASS. Original TCP/IP and its configured static addressing are reused.

### R24b actual ABI failure; R24c call-order correction

R24b reached the own DriverEntry at CPUcount1/IRQL0 and created a wrapper
(E9 trace), confirming that the previous demand-image rejection was passed.
It then bugchecked1E/C0000005 in NDIS.SYS RVA2633, address34. This is an
actual own ABI error: the call supplied MacMacContext as argument3 and the
wrapper as argument4. The callee at2567–2633 reads argument3 into EDI,
loads EDI[0] as DriverObject and writes DriverObject+34. Our wrong argument
was also the just-zeroed output Mac variable, producing NULL.

The original NE2000 caller independently confirms order: local wrapper is
read at510, context pushed at514, wrapper at519, MacOut at51E, status at523,
call at524 (lifecycle05 internal420). The corrected own call is
`NdisRegisterMac(&st,&Mac,Wrapper,&Mac,&chars,sizeof(chars))`.
The full named declaration now documents Wrapper3/Context4; equal handle
types and a ret18 cleanup check alone did not establish this contract.

No HID was sent to the STOP. Normal finish/QMP quit returned0 and retained
R24b; no native clean shutdown was possible. It is an ABI FAIL, not a network
result. Assessment: `artifacts/nt31-fullmac-runtime/r24b-guest-evaluation.json`.
The following overlay uses clean stopped R24, never the faulted R24b disk.

`registration_test.c` compiles the exact current DriverEntry and U31_MAC
declaration extracted from own source. Its fake callee requires two distinct
handles with wrapper in position3/context4, verifies the wrapper DriverObject,
and checks four actual-C paths: success, SMP refusal, failed wrapper creation,
and failed registration with wrapper termination. These passed in build16,
alongside52 other native policy cases,43 imports and10 callback decorations.
Build15's test-shim compile error (missing NULL definition) is retained; it
was never a completed candidate or VM run.

Build16 SYS16384B SHA256
`b49f2445a2e48dbf75b50f426ccc1cef09943a84e779d351747d4cbc8df27a8d`,
helper5120B`a481fa745879eef9ef48f8d1c0870b097d8850111a35c7e5be0d409d9028fb7c`.
R24c manifest pins new overlay
`ef0983e2b227079263e093e08cf992b503d217bd17b0c715f818aeac0cdc1df9`,
with clean R24 backing. Original SYSTEM/TCPIP/USB and BDF settings remain
byte-identical; only own files change. R24c started after one normal guard
and awaits its passive endpoint. Its LAN result is still unqualified.


### R24c completed: original NT31 full-MAC static LAN qualified

R24c reached Program Manager (operator-02.png) without the previous SCM
alert. The actual E9 trace records CPUcount1/IRQL0, successful RegisterAdapter,
MapIoSpace and RegisterMac, MMIO81000000 and RX/TX rings00733080/00733B80,
both below16MiB. The SYS read back from the stopped guest is exactly build16
b49f2445a2e48dbf75b50f426ccc1cef09943a84e779d351747d4cbc8df27a8d,
16384B, PE3.10; all43 imports match the installed UP modules.

Original native ping completed3/3 twice, in PING31.LOG and POST.LOG.
Original NT31 ping does not print RTT, so none is claimed. The own logger
matched the configured DNS10.0.2.3 reply for frogfind.com, transaction4AC0,
answer64.227.13.248 after30ms. Native gethostbyname independently returned
that address after120ms. HTTP68k.news returned HTTP/1.1 200 OK; this was the
logger, not a page in Internet Explorer. Original NT31 has no bundled IE.
The separate frogfind.com HTTP timeout4005ms remains in the log. Logger ICMP
remains SKIP because its newer adapter-discovery path did not recognize the
old global NT31 gateway schema; native ping is the primary echo proof.

Native shutdown reached the safe screen (operator-12.png), then QMP quit
returned0; elapsed1013.96s. Retained target SHA256 is
05638a08cfd41460d5d1b96b3735859ac7b1ac33ed97b2bfa0951a5124a4de1d.
The bounded collector exported only selected own text plus hash/service
metadata. Frozen USBf5373eb3...ef05, i8042prtStart4, actual REGF1.1 current/
default1 and original TCPIP/STREAMS were confirmed. Raw scratch was removed;
base unchanged. Manual assessment is
artifacts/nt31-fullmac-runtime/r24c-guest-evaluation.json; primary stopped
readback is r24c-stopped-readback/readback.json. The8MiB-capped sole-VM PCAP
has48097B/251frames and is supplemental; automatic installed-pass/DORA flags
were not rewritten. Original NT31 uses static TCP/IP here, DHCP is N/A.

This qualifies the installed UP/QEMU82576 at explicit BDF00:05.0, staticIP
10.0.2.15/24, gateway10.0.2.2 and DNS10.0.2.3. The nominal20ms worker is not
an exact latency guarantee. Reset is unsupported; dynamic unload/worker join
is not runtime-qualified. Native shutdown is not evidence of MAC unload.
No X470, physical NIC, I210/I211, SMP or NT31Server claim follows. The R24
error193 and R24b ABI STOP remain failures. R24c did not repeat USB hotplug;
a following unchanged-binary overlay will assess that coexistence separately.

### Remaining work for fresh normal USOS network automation

1. Add an NT31-only selector/staging path in tools/nt4_csmwrap_target.sh for
   the proven82576/UP/explicitBDF candidate. Stage the pinned SYS as the
   actual8.3 USNET31.SYS, private OEM INF and NET31CFG helper; preserve other
   OS branches and frozen USB. The proven original NCPA identity is
   USOSNET31 plus USOSNET3101, not a guessed later miniport service scheme.
2. Implement and test original NT31 Setup/NCPA automation for the adapter,
   stock STREAMS/TCPIP and static address/gateway/DNS. Verify original INF
   fields instead of assuming NT35 NetworkAdapterData/TransportData. Preserve
   the required protocol/binding reboot. The current success used original
   NCPA manually on a retained R19c-derived installation.
3. Overlay only the owned NT31 payload into the latest cache, preserving
   later NT4/NT35/NT351 changes. Pin cache/initrd/SYS/helper/sourceISO hashes.
   The separate legacy IRQ source correction must be applied once by the
   integrator; this polling NT31 binary was not rebuilt with that change.
4. Integrate a scoped NT31 success collector and bounded VM-only capture in
   the normal coverage run_plan/boot_menu flow. A status or hash match alone
   must never grant LAN PASS; the current stopped collector is case-scoped.
5. Run a fresh blank-target normal USOS plan through Program Manager,
   native ping, matched DNS, USB isolation, native shutdown and stopped
   readback with the same pins. R24c is installed-overlay qualification,
   not fresh automatic network-installation PASS. Workstation/server and
   Dial-Up policy still need narrowly scoped presence/runtime evidence.
