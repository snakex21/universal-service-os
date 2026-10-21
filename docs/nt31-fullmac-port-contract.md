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
