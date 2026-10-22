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

Canonical build is tools/build_windows_usos_res.py:build_nt3. Original NT35
KERNEL32/ADVAPI bytes are read only in RAM from the pinned, closed previous
fresh target, via a temporary whole G disk. Only API/hash metadata are
saved; scratch is removed. Runtime qualification remains pending until
fresh normal blank-target USOS, actual desktop/native SCM service list,
DHCP/ping/DNS, native safe shutdown/QMP0 and stopped service/SYS readback.
