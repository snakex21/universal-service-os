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

## NT3.1: distinguish the missing Intel port from stock TCP/IP capabilities

A separate hash-bound original NT3.1 Workstation media audit used ISO
`ee2a27153c0942b6b82f9b15145f3b7eaa34b331add1d077cc6f8d69b9223c0b`.
It found original `ndis.sys`, `tcpip.sys` and `ne2000.sys`, but no
DHCP-named media members, `dhcp.exe` or `dhcpcsvc.dll`. Bounded excerpts
of original `OEMNXPTC.INF` describe static IP address, subnet mask and
gateway configuration; there is no DHCP/EnableDHCP hit in that audit.
Microsoft's [DHCP client overview](https://learn.microsoft.com/en-us/windows-server/troubleshoot/dynamic-host-configuration-protocol-basics)
lists NT Workstation/Server 3.5, 3.51 and 4.0, rather than NT3.1.
Together these support recording stock NT3.1 DHCP as not applicable,
instead of reporting a missing DHCP lease as an Intel-driver failure.

Original NE2000.SYS SHA256
`c5fbffbf5d8de7b35f6812f46c176490c568853f2ea564bc363f5c826e17d7cb`
uses the full-MAC `NdisRegisterMac`/`NdisRegisterAdapter` and Ethernet
filter contracts. Its presence permits a separate legacy-NIC baseline
experiment with static IP. It supplies neither an Intel I211/82576 port
nor an installed-Windows network PASS. No such baseline was run by this
media audit.

Completed metadata and repeatable script are
`artifacts/nt35-pci-audit/nt31-network-media.json` and
`audit-nt31-network-media.py`. ISO/compressed scratch was removed;
expanded binaries stayed in RAM. The NT3.5 branch-complete follow-up is
`result-v2.json` / `audit-v2.py`; direct branches are followed, indirect
calls and jumps still require separate contract proof. It confirms the
full-MAC resource result is written through the first handle at `+0x6c`,
which must not be guessed to be the miniport handle.
