# NT 3.x: exact network-driver import limits

This original-media check compares the new own NDIS3 candidate
`usosnet351.sys` SHA256
`dc8827954e6fe75ee8264c7382e87899cc9761890998198c126c7ea8aa5c55b6`
against original NT 3.1, 3.5 and 3.51 Workstation modules. Original ISOs
were extracted only to owned collection scratch and removed afterwards;
expanded modules stayed in memory. No Microsoft binary is included here.

| System | Missing imports in this exact candidate | Consequence |
|---|---:|---|
| NT 3.51 | 0 | Import preflight passes; ABI and fresh Windows runtime still need separate proof |
| NT 3.5 | 3 | Candidate cannot load unchanged; PCI resource and bus-selection path requires a port |
| NT 3.1 | 21 | Candidate cannot load unchanged; this NDIS miniport layer is unavailable |

NT 3.5 lacks `NdisMPciAssignResources`, `NdisMQueryAdapterResources`,
and `NdisOverrideBusNumber`. The own source actively uses these to find
the supported Intel card across PCI buses, select the bus, and obtain
resources. A no-op stub would neither select the correct bus nor prove
resource/IRQ ownership. A valid port needs the original NDIS/HAL contracts,
then actual initialization and network exchange in a guest.

NT 3.1 also lacks miniport registration, attributes, interrupt/DMA/shared
memory, mapping, status indication and PCI access functions used by this
candidate. Renaming the SYS, changing its declared NDIS version or retagging
the PE header cannot supply those functions. A full-MAC implementation or
another supported network path requires separate work. A test using an
original emulated legacy NIC would not prove support for Intel I211/82576.

Do not propagate a future NT351 PASS to NT3.5/3.1, other editions or X470.
Likewise a QEMU DHCP exchange alone is not an installed-Windows proof:
the actual guest address, driver hash, matching ping and DNS remain
separate required observations.

Metadata and source/member hashes:
`C:\Users\ASRock\usos-work\macierz-windows\artifacts\coverage\nt3-ndis3-candidate-original-exports.json`.
The old NDIS4 driver's larger missing-import counts are superseded only
for this new NDIS3 candidate. There is no runtime PASS in this document.
