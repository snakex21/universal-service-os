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
3A40 accepts only InterfaceType1/2/3 and returns zero for PCIBus5. Memory
translation2730 follows an identity mapping without that interface filter.
These facts prevent treating the presence of HalGetBusData as PCI support
or renaming the device to an ISA adapter. DMA master registration through
HalGetAdapter3C60 still requires a separate dataflow assessment.

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
