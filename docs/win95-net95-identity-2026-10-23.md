# Preserve the answer network identity for 950 static NET95

R96 continued a saved pre-base RTM stage with the network-file fix. Native PnP
asked for a computer name/workgroup even though [Network] in MSBATCH.INF
already contained USOS-COVERAGE/WORKGROUP. The diagnostic entered those same
values, without manually selecting or adding network components. PnP then
copied the original network base files and finished GUI configuration.

The original REGEDIT in matching RTM DOS was used to examine registry state
in R100. VNETSUP lacked ComputerName/Workgroup in the prepared pre-GUI state;
the working installed reference contained those exact field names. Both
reference disks were immutable backing files of disposable overlays.

The existing REG95 converter now carries [Network] ComputerName, Workgroup
and Description into the VNETSUP ComputerName, Workgroup and Comment values.
It uses the existing quoted-field/string/registry escaping functions. Empty
or absent names/groups do not invent defaults; an explicitly empty Description
clears Comment. Other INF sections cannot supply these values. The writer
enables this only for exact source version 4 0 0 950 with static NET95.
Other versions and non-NET95 paths keep their previous conversion behavior.

Validation: six new identity cases and thirty existing REG95/NET95/file cases
pass; shell syntax and git diff --check pass. R101 generated the fragment from
the actual private answer using this production writer and imported only its
VNETSUP section through original RTM DOS REGEDIT on a new overlay of installed
base R87. QEMU exit85/1.87s. Original export was usos95r51/workgroup/empty
Comment; the completed new export was USOS-COVERAGE/WORKGROUP/Coverage.
SYSTEM.DAT and USER.DAT attributes were restored to7. Six core/driver files,
including IO.SYS, VMM32, NDIS and USOSNET, remained byte-identical. No base image
or original media was changed. A host CRLF-regex readback error was corrected
from the closed floppy only, without repeating the VM.

This proves generation and actual DOS registry import/readback. It does not yet
prove omission of the first-GUI identity prompt or Windows network runtime
with this fragment. That check belongs to the final normal installation after
remaining fixes/tests; no extra Setup rerun was started for this change.
No Microsoft payload, private key, registry dump or screenshot is committed.
QEMU only; real X470 and OSR1 runtime need their own checks.

Evidence metadata:
C:/Users/ASRock/Documents/Codex/2026-10-21/cz/work/r100-identity-reference.json
C:/Users/ASRock/Documents/Codex/2026-10-21/cz/work/r101-net95-identity-proof.json
Private VM folder: K:/USOS-VM/Windows95/sesja-cz-20261023/cases/r101-net95-identity-overlay.
