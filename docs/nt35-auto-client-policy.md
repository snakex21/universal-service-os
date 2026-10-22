# NT3.5 Workstation AUTO client policy

Separate branch fix/nt35-auto-client-net starts at4cd6a3bf. Historical fresh
d94 policy FAIL (Browser/Server running/Start2) and diagnostic apply/cold
PASS remain unchanged. NT31, NT351, Server, HID and physical hardware are
outside this new qualification.

The existing installer POST can prepare next-boot service configuration.
It does not need a new first-logon process, network readiness polling or
another inner installer boot. Inner QEMU has no NIC; neither its DONE nor
this preparation is a running Client/noSharing or LAN PASS.

`usos_nt35_client_request` stages bounded CLNT35.REQ only after the NT35
network stage is enabled, original media ProductType is exactly0 and the
answer kind is DEFAULT or PROFILE. USER/unknown/Server/network-off do not
stage it. Only the minor50 branch calls this function.

Before any normal POST mutation, the requested path checks exact request
bytes, actual NT3.50 (Win9x high bit refused), actual ProductType WinNT and
absence of a prior terminal CLNT35.ERR. After verified NET35 takeover it
opens existing CurrentControlSet Browser/Server keys, never creates them,
and validates Type32/Start2–4. Browser may be absent; Server must exist.
WorkstationType32/Start2 and TcpipType1/Start3 are query-only. Only Browser
and LanmanServer Start become4, followed by checked readback of all four
services and a fully written/flushed/closed CLNT35.LOG.

Request/status/failure records remain beside staged USOSNT3 in the existing
C:\USOS\NT3 app folder; no profile/public/registry app-data fallback is
introduced. Registry writes configure the selected OS services only.
No helper policy test marker, serial completion hook or resident process
is added. The original finite SCM helpers remain separate evidence.

Failure propagates from network/policy through int post() to service_main:
no polish/completion/restart after failed post; no restart after checked
completion fails. The requested path checks disabling its existing post
service and writing/flushing/closing DONE. Service status and process exit
report failure, and /post exits3 on refusal. A partial policy failure is
terminal, not an automatic sharing rollback or retry. Other ControlSets
and other service configuration values are not targeted.

Tests compile the actual production header against fake APIs (19 cases),
actual service_main against a fake post/completion (four paths), and the
actual checked record writer (six write/flush/close paths). Actual shell
selector cases cover enabled/off, Workstation/Server/unknown product,
PROFILE/DEFAULT/USER/unknown answer and missing NET35 staging. Existing
NT35 parser/network-flow tests remain relevant. No test runs real POST on
the host or changes its services/registry.

Failure-stop qualification is limited to the newly requested CLIENT/NET35
path and its real DONE/restart gate. The pre-existing drivers[] copy loop
still only logs failed AHCINT/USOSRST/USOSUSB CopyFileA, and legacy
set_dword remains void. This experiment does not harden or qualify general
storage/USB-copy/registry-failure handling, and grants no fresh USB PASS.
A separate later change/test would be needed for those failure paths;
the frozen active POST/cache are not changed for this clarification.

Canonical build is tools/build_windows_usos_res.py:build_nt3. Original NT35
KERNEL32/ADVAPI bytes are read only in RAM from the pinned, closed previous
fresh target, via a temporary whole G disk. Only API/hash metadata are
saved; scratch is removed. Runtime qualification remains pending until
fresh normal blank-target USOS, actual desktop/native SCM service list,
DHCP/ping/DNS, native safe shutdown/QMP0 and stopped service/SYS readback.

## Pinned fresh experiment before runtime

Code1feadbaf, canonical build02 USOSNT3.EXE30208B SHA87cb43259878583758269b979c8e59411d69366ce5d58ec949a51638786d449f. All50 static imports resolve against actual original NT35 KERNEL32/ADVAPI in the stopped pinned prior fresh target. No new static API surface; old source baseline remains unchanged.

Private cache G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt35-client-auto01 uses initrd ae9568457e6af6150fb1d6fc672a7a841e73b4c2002fbef10107c0afd11e0bb5. Only three effective entries differ from qualified d94 fresh: USOSNT3.EXE, nt35_network_setup.sh, nt4_csmwrap_target.sh. All834 other entries (including d94 SYS, frozen USB and ff258504 logger) and all other cache files remain identical. Original compressed prefix preserved.

Plan artifacts/coverage/nt35-client-auto-fresh01/plan.json SHA79d9366fe00dd39a7eab72cde2a8ccff54994f60f91f2e0e9f383d7b32c06f95 changes only the tag from prior fresh NT35. Same original ISO109d2c28, fresh standalone4GiB blank target, normal USOS nested flow, PS/2 baseline explicit, NICigb. The immutable private60-file harness snapshot is copied from the completed prior fresh, with root relocation and four own policy/native-log paths added to its bounded readonly collector. ConsoleMode+isatty rejects both PIPE and Windows NUL before any VM; request policy/native SCM/LAN are not inferred from hashes/status/DONE.

Host checks: five new tests (actual header19cases, emitter4paths, record writer6paths, shell selectors and source boundaries), two metadata-parser tests, eleven existing NT35 network-flow tests, three cache-delta tests, canonical NT31 import-surface compatibility test. Prepared collector rejects unknown/private/ambiguous/wrong-OS evidence, preserves installed_runtime_pass=false even on matching d94; PIPE/NUL refusals verified with zero VMs. Full input/hash details are in docs/nt35-auto-client-inputs.json. Actual runtime remains pending at this commit.
