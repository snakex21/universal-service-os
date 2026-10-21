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

An additional original NT3.5 PCI audit found a possible starting point,
not a drop-in replacement: `NdisPciAssignResources` exists at RVA `0xee64`
in NDIS.SYS `fa392210418f6a5977ea8117d49b4d6a0b4cfc7d4fcc436fca2e3defdd6a5543`.
The bounded decode shows five stack arguments (`ret 0x14`), accesses to
the third handle at `+0x64` / `+0x6c`, and a call through the imported
`HalAssignSlotResources`. This differs from the three-argument
`NdisMPciAssignResources` used by our miniport. Aliasing the imports is
therefore not a demonstrated adaptation.

`NdisReadPciSlotInformation` RVA `0x4bfc` branches on the type of handle;
the first decoded path reads a bus field at handle `+0x104` before calling
`HalGetBusDataByOffset`. The other branch, wrapper bus initialization,
resource ownership and the matching miniport receive contract still need
proof before an NT3.5 variant can be built. The original HAL exports
`HalAssignSlotResources`, `HalGetBusDataByOffset` and `HalSetBusDataByOffset`.
This is a concrete audit target, not permission to write guessed private
handle fields. No new driver or Windows network PASS resulted.

The completed bounded decode and its repeatable input script are in
`artifacts/nt35-pci-audit/result.json` and `audit.py` in this worktree.
The NT3.5 ISO and compressed scratch files were removed after the audit;
expanded NDIS/HAL bytes were held only in memory. `dc21x4.sys` was absent
from this exact original medium, so it supplied no original-driver ABI
reference in this audit.
