# NT3 client policy integration plan for review

This is a source review and implementation plan, not an implementation or
new runtime qualification. Inputs are nt35-client e8bef69b, nt351-client
d268e499 and nt31-net 8d269a40, with their completed policy assessments.
No active image, private Setup screen, account file or Microsoft module
was read for this plan. No driver, API, service or cache is changed.

| OS | Qualified evidence to retain | Automatic integration still missing |
|---|---|---|
| NT3.1 | NET31CFG d00c: R24e `/client`, independent R24f `/clientcheck`, Browser/Server STOPPED/Disabled, Workstation/TCPIP RUNNING; b49 full-MAC and separate HID evidence | Original adapter/STREAMS/TCPIP NCPA and static-IP automation, production policy entry and fresh end-to-end qualification |
| NT3.5 | CLNT35 4a927: apply03 and cold01 policy PASS; installed d94 IRQ/LAN and separate HID PASS | Production policy entry and fresh AUTO policy qualification; R20 retains its old SYS and approximately2s history. A separate fresh d94 trial has no result added by this plan |
| NT3.51 | CLNT351 ce6: apply02 and cold01 policy PASS; f579 fresh normal USOS LAN PASS | Production policy entry and fresh AUTO policy qualification. The existing fresh baseline's Server/Browser RUNNING/Start2 policy FAIL remains |

The dedicated helpers' hashes and exact scopes remain in
`docs/nt35-client-service-policy.md`,
`nt351-client/docs/nt351-client-only-policy.md` and
`nt31-net/docs/nt31-fullmac-port-contract.md:537–613`. Modified production
frontends will have new hashes and require their own qualification.

## Actual ordering: the current POST is too early

`tools/nt3/clientcfg/service_policy.h:12–25` and the NT31
`client31_policy.h:11–21` require LanmanWorkstation and Tcpip RUNNING
before and after applying or checking policy. The finite operation stops
Browser first, then LanmanServer, disables only those existing services,
and rechecks state/config. It accepts an absent Browser, refuses an absent
Server, unexpected active dependents or failed calls/readback. It never
reconfigures Workstation/Tcpip or recursively stops arbitrary services.

In the reviewed `usosnt3.c`, `post()` calls `nt351_network()` and
`nt35_network()` at1233–1234. Those routines only copy/read back the own
SYS and configure the original LOOP/TCPIP binding; their status explicitly
says `installed_runtime_pass=false` and "next boot required". They do not
load the replacement driver or prove native TCP/IP running on the NIC.
The versioned routines are at971–1030 and1059–1120.

`service_main():1334–1357` then unconditionally disables usosnt3, writes
DONE.TXT, waits30s and restarts. `post()` and the network routines return
void, so a logged network failure does not currently suppress that path.
The `/post` entry also exits0 after `post()`. Inserting Client35Run there
without changing result propagation would be incorrect. Sleep30s is not
network readiness evidence.

There is also a storage/lifecycle boundary. `nt4_qemu_install.sh:254–269`
runs the installation guest with `-nic none -no-reboot`, using IDE or
Am53c974 SCSI. POST disables atdisk/atapi and, when present, amsint
(`usosnt3.c:1197–1211`); the installed target is prepared for AHCINT on
the subsequent native-target boot. The loop checks DONE.TXT only after
QEMU exits (`nt4_qemu_install.sh:342–380`), then finish restores files and
finalizes BOOT.INI. Do not merely add another inner installer boot after
those storage drivers are disabled, or wait there for the real NIC.

## Proposed insertion points and completion contract

Use the existing USOSNT3 coordinator in explicit phases for a requested
Workstation client/no-sharing profile. Keep service policy separate from
the installer's existing DONE.TXT contract; neither marker may imply LAN
or cold policy PASS. The following phases are proposed, not present code.

1. **Source staging, before Setup.** In the NT35/NT351 branches of
   `nt4_csmwrap_target.sh:567–581,727–734`, extend the existing versioned
   network preflight/staging to include the correct production helper,
   hash and bounded client-policy request. Preserve original LOOP/TCPIP
   creation and the distinct NT35 NetCardParameterList versus NT351
   AdapterParameters answer sections. Preserve NT35's exact bus/slot.
   Network-off, a user-owned answer or Server SKU must not silently enable
   this Workstation policy; define and test the exact selector first.
2. **Installer POST: prepare only.** Return an explicit success/skipped/
   failure result from the selected network routine through `post()` and
   its caller. After successful copy/config readback, persist a pending
   client phase beside USOSNT3.EXE. Retain the normal installer completion
   and restart so the existing micro-Linux finish/handoff can run. Keep
   the existing coordinator enabled for its later policy-only entry,
   instead of unconditionally disabling it at1348. No policy apply or
   readiness claim is made inside this NIC-less installation guest.
3. **First installed-target boot, after network activation.** Dispatch the
   pending coordinator phase before calling `post()` again: do not repeat
   driver copies, disk-driver changes, account processing or installation
   restart. This boot must use the installed AHCINT/NVMe stack and the
   selected actual NIC, as the qualified installed overlays do. Launch
   the OS-specific production policy helper only after SCM establishes
   Workstation/Tcpip readiness, then block for its process completion.
   Only exit0 plus the finite policy's real SCM readback commits the
   applied phase. Browser/Server become STOPPED/Disabled here. Workstation
   and Tcpip retain their original Start/config and remain RUNNING.
4. **Subsequent real boot: readonly recheck.** Leave a distinct pending
   recheck phase, invoke only the production readonly mode, and require
   stopped/disabled Server/Browser and running Workstation/Tcpip again.
   Disable the one-shot coordinator only after that succeeds. Do not
   force an immediate restart just because apply succeeded. The normal
   qualification harness must independently observe native shutdown,
   writer exit and a new boot before calling this a cold-boot PASS; a
   service/process restart and a phase file cannot prove a cold boot.

For passive readiness, review a phase-specific dependency of the existing
coordinator on **LanmanWorkstation and Tcpip only**, committed before the
installed-target boot. Verify the actual original NT3 SCM handling of
this Win32-service/kernel-service dependency combination before relying
on it. Do not depend on Browser or LanmanServer, which are to be disabled.
If readiness/dependency setup is not established, make one explicit SCM
check and refuse the requested phase if either service is not RUNNING;
do not add QueryServiceStatus loops or replace proof with a fixed sleep.
The helper's readiness precondition must remain intact in either design.

NT31 needs a distinct entry into this sequence. Its `nt31_usos()` currently
writes a GUI-Setup POST.CMD which calls `/polish` then DONE.TXT
(`nt4_csmwrap_target.sh:399–433`); it has no USOSNT3 post service. Do not
call the existing generic `/setup` or `/service` there and accidentally
run NT35/351 storage POST on NT31. Add a reviewed policy-only coordinator
mode only after the NT31 native NCPA adapter/STREAMS/TCPIP setup and its
required reboot exist. Then `/client` and a later `/clientcheck` have the
same readiness rules. The five fresh AUTO gaps are already explicit in
`nt31-net/docs/nt31-fullmac-port-contract.md:484–507,605–613`: original
USOSNET31/USOSNET3101 identity, actual8.3 USNET31.SYS/OEM staging, static
address/gateway/DNS, latest cache preservation, scoped collector and a
blank target. Policy R24e/R24f PASS does not close those NCPA gaps. Stock
NT31 DHCP remains not applicable; retain UP/explicit BDF limits.

## API, production frontend and data placement

Prefer separate small versioned policy frontends around the qualified
finite SCM core. The coordinator can launch them with its already used
CreateProcessA, WaitForSingleObject and GetExitCodeProcess, close both
process/thread handles, and propagate refusal/nonzero/timeout. Use an
absolute own EXE path and explicit arguments, without shell wildcards or
optional application staging. A parent wait budget must cover both
native NET60s stops and their bounded cleanup. Validate owned-child
cleanup; never kill unrelated NET processes. The current helper waits for
each native NET child, queries state once, and does not use `/y`.

The policy adapter uses exactly OpenSCManagerA, OpenServiceA,
QueryServiceStatus, QueryServiceConfigA, EnumDependentServicesA,
ChangeServiceConfigA and CloseServiceHandle. Only Browser/Server handles
receive change/dependent-enumeration rights; Workstation/Tcpip handles
remain query-only. The qualified NT35/351 frontends have21 imports
(14KERNEL32+7ADVAPI32); NET31CFG has27 (14+13, including its existing
registry/adapter guards), verified against actual original modules.

USOSNT3 is shared with NT31, PE3.10, and its current static-import contract
is `tools/tests/test_nt3_flow.py:593–619`. Those seven SCM configuration
imports are not in that existing USOSNT3 allowlist. Keep them inside the
versioned frontend, or explicitly validate and review a new common import
surface; do not merely relax the test. Preserve the dynamic GetVersion
lookup used by network POST. Keep the measured frontend OS gates: NT31
major3/minor1 or10, NT35 major3/minor5 or50, NT351 major3/minor51, with the
Win9x high-bit refusal. A matching filename or profile is not an OS gate.
Any new API, dependency mode and rebuilt EXE needs actual version-specific
original-export checks in RAM, in addition to source/PE tests.

Production is a new frontend variant, not the qualified test binary with
its marker deleted. CLNT35/CLNT351 currently require exact `.ON` test
strings and emit fixture COM1 completion; deleting the marker just makes
them refuse. NET31CFG requires its R24 marker and own-adapter guards.
Remove test-marker/COM1 behavior in the production source/build, while
retaining explicit mode, actual OS, requested Workstation policy, exact
own-adapter/binding and permission guards. Replace fixture authorization
with a bounded request produced only by the selected installer profile,
not an arbitrary missing-marker bypass. Parent process completion and
exit status supply production completion. Preserve test binaries and
their serial mechanism as separate historical evidence; new production
hashes inherit no runtime PASS automatically.

Keep logs and phase/request records beside each EXE, normally
C:\USOS\NT3. The dedicated helper already derives this path from
GetModuleFileNameA; USOSNT3 currently hardcodes DIR at53. New orchestration
state must derive the executable folder and refuse an unwritable folder,
with no profile, APPDATA, TEMP or registry fallback. Adding a direct
GetModuleFileNameA import to USOSNT3 requires updating its actual NT31
import proof; its availability in the qualified helpers is existing
evidence, not a substitute for checking the rebuilt coordinator.
Registry changes here concern the explicitly selected OS services only;
application phase/history/config data stay in local files.

## Failure handling and review gates

Requested-policy failure must propagate to `/post`/service result and a
bounded own failure record. Do not write a successful policy phase,
disable the pending coordinator as if completed, call the automatic
restart path, or let the outer collector grant Client/noSharing PASS.
Preserve the current failure and partial SCM state for an explicit retry;
do not automatically re-enable sharing as rollback. Add a fail state
that prevents silent retry/restart cycles. File writes/flush/rename and
service configuration readback must be checked; the current void
`write_file`/`set_dword` logging alone is insufficient for this commit.
Installer-stage failure must withhold installer DONE and restart; a later
policy failure leaves the already completed installer distinct. The
outer lifecycle must distinguish that terminal refusal from a slow VM.

Stage production helpers and metadata explicitly in
`tools/build_micro_linux.py` beside its existing USOSNT3/SYS entries
(789–802). Build USOSNT3 through the canonical
`tools/build_windows_usos_res.py:build_nt3`, shared by package/tests;
the legacy WDK build.cmd is not an interchangeable binary hash. Extend
the exact per-OS staging and normal completion collector, including the
current stopped log-copy allowlist in `nt4_qemu_install.sh:483–489`.
Keep frozen baselines immutable and inventory every effective cache
change; preserve later unrelated OS/USB changes when combining branches.
No complete USOS build is needed for reviewing this plan.

Before promotion, Claude should review the phase/dependency/error
contract, original API gates, production/test separation, normal graph
staging and immutable evidence. Future meaningful checks must cover
ready/not-ready/refusal, dependency/copy/log/write/child failure, no restart
on error, phase resume without rerunning storage POST, off/Server/other-OS
selectors, portable log paths, and absence of production serial/test
hooks. Then each OS needs a fresh normal blank-target flow through native
services and network proof, native shutdown, independent readonly cold
check and stopped readback with actual installed hashes. NT31 uses static
IP; NT35/351 require native DHCP plus strict ping/DNS/HTTP evidence. New
USB isolation/HID/MSC or hardware PASS requires its own evidence. No
current overlay assessment or DONE/status/hash alone closes this gate.
