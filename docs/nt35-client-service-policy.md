# NT35 client-only service policy — QEMU qualification

A bounded read of the completed NT35 USB regression finds Browser and
LanmanServer Start2, alongside the functional client/TCPIP. IRQ/LAN and
HID success therefore do not prove client-without-file-sharing policy.

`tools/nt3/clientcfg/` builds a dedicated GUI helper, without rebuilding
any network or USB driver. The finite policy and native SCM adapter are
adapted from our NT31 commit2064ae00; exact own-source provenance is
recorded. The frontend accepts only NT3.5, explicit `/apply` or `/check`,
and an adjacent `CLNT35.ON` fixture marker. Logs stay beside the EXE.
It stops Browser first, then existing LanmanServer, changes both to
Disabled, and verifies Workstation/TCPIP remain RUNNING. Unexpected active
dependents, API errors or incompatible Browser dependencies refuse the
operation. Native NET is hidden and waited to completion, without a
progress-query loop. This changes only required OS service configuration;
application data is never written to the profile or registry.

Build02:5632B, SHA256
`4a927eecb1a6c602f92c0a92c14bd7b56f684238735d36f8218d5bfcb5e3204a`.
PE3.10 GUI,21 imports verified against actual installed NT35 KERNEL32
and ADVAPI32 bytes in RAM. Twelve actual-C policy cases and two actual
host OS refusals pass. Host refusal never opens a serial device.

Stopped preparation adds only `USOS/NT3/CLNT35.EXE` and `CLNT35.ON`.
All920 original file contents, including SYSTEM and both own SYS files,
are byte-identical. Whole-disk scratch stays on G and is removed after
independent FAT readback and raw/overlay comparison; no Microsoft module
or hive is exported. SYSd94/USB2d455/i8042prtStart4 remain pinned.

The first run apply01 reaches the login screen, then fails because the
operator stdin pipe closes. No helper action was sent and no policy PASS
is claimed. The exact failure/preflight/source archives remain in
`artifacts/coverage/vm/nt35-client-apply01/` and `artifacts/nt35-client/apply/`.
The corrected launcher refuses redirected stdin before any VM start;
its actual headless-launch regression is tested. Apply02 uses a fresh
preparation from the unchanged clean parent and a live PTY, but Windows
stops with C000021A/C0000005 before any operator/helper invocation. The
own helper log is absent in stopped readback; the failed disk is unchanged
during that read and whole-disk scratch is removed. This is not a helper
or policy runtime PASS. An unchanged clean-parent cold control baseline01,
without adding any files, reaches Program Manager and native safe shutdown
(operator05, QMP quit/exit0). A new apply03 prepared from that same clean
parent reaches the desktop and executes the explicitly requested helper.
The isolated apply02 startup failure remains unresolved; a preferred-address
match in WINSRV is not a measured runtime call stack or a causal diagnosis.

Apply03 receives exact own COM1 completion `USOS_CLIENT35_DONE=0`.
Native log (operator09) reports Browser and LanmanServer STOPPED/Disabled,
with Workstation and TCPIP RUNNING. Native `net start` (operator11) lists
Workstation/DHCP Client and no Server/Computer Browser. The separately
logged native ping (operator13) receives three replies below10ms each.
Native Shutdown reaches safe-off on operator17, followed by QMP quit/exit0.
Bounded stopped readback confirms the own helper, SYSd94/USB2d455, clean
SYSTEM Select Current/Default1, i8042prt Start4, Browser/Server Start4,
Workstation Start2 and TCPIP Start3. Only the four own text files are
exported; SYSTEM and binary reads remain in RAM. The actual stopped target
SHA256 is `f798b3021c12fec3c56dd652530dc2cd3b1c1dc54a107b1e653eabe7b9e05836`;
the original USB parent92c2 is unchanged and whole-disk scratch is removed.

`readback_nt35_client.py` has explicit completed apply03/cold01 cases. A separate
`prepare_nt35_client_cold.py` creates an empty cold01 COW; actual
`qemu-img compare` confirms identical effective disk contents, including
SYSTEM and USB. It retains the helper/import proof and actual apply03
command hash without claiming newly added files or starting QEMU. The
initial cold launcher preflight rejects missing explicit compatibility
flags before QEMU; a repeated identical-disk comparison supports their
atomic manifest correction, with a `validation-fix-no-vm-started.json`
note. No image or guest content changes in that repair. This preparation
and apply result alone do not qualify persistent cold policy; the separate
native cold `/check` has its own completed evidence below.

The cold reader is prepared without reading the active cold VM. Only after
the actual completion may the operator write a bounded JSON below
`artifacts/nt35-client/cold01/` and pass it using
`--case cold01 --cold-evidence <absolute-review-json>`. It requires
`case: "nt35-client-cold01"`, `reviewed_after_completion: true`, and:

- `source_commands`: exact operator text under `check`, `services`, `ping`
  and `shutdown`. The first invokes `C:\USOS\NT3\CLNT35.EXE /check`;
  native `net start` and `ping -n 3 10.0.2.2` overwrite the respective
  `C:\USOS\NT3\NET35.LOG` and `PING35.LOG` using `>`.
- `reviewed_images`: actual `operator-NN.png` names under `check`, `scm`,
  `services`, `ping` and `safeoff`. The safe-off number is supplied after
  review. Each image must belong to the completed operator action record.

Typed commands are the operator's explicit review record: the runner's
actions JSON retains only key counts and image names, not typed text.
The reader pins that record, images, command argv and own COM1 completion.
It verifies the actual COW parent is the completed f798 apply03 target,
the original92c2 USB parent remains unchanged, preparation confirms
identical guest contents, and the new successful check log contains no
`NativeNetExit`. Identical native service/ping text can be valid after
fresh commands; content hashes alone do not establish execution freshness.
No optional application staging, guest command or VM start is performed.
Separate cold01 is now complete. `/check` emits completion0 on operator05,
and the new346-byte log on operator09 has no `NativeNetExit`: no service
stop operation is repeated. Browser/Server remain STOPPED/Disabled and
Workstation/Tcpip RUNNING. Fresh native net and ping commands overwrite
their own evidence files; operator11 and13 show the client-only service
list and three replies below10ms each. Native safe shutdown on operator17
precedes QMP quit/exit0. Stopped readback confirms clean REGF1.2/Select1,
Start4/4/2/3 for Browser/Server/Workstation/Tcpip and unchanged own binaries.
Cold target SHA256:
`c2a142e4ae39f23854b30c549ce966a1e0caca80bad555e3916ff7abd9b61fe4`.
Original USB parent and completed apply parent stay unchanged. Scratch is
removed; no Microsoft hive/module or own EXE is exported by the reader.
Assessments are `artifacts/nt35-client/{apply03,cold01}/evaluation.json`.
The explicit second source archive records the successful cold launch;
the first preparation-contract failure is retained and is not a Windows
failure. Apply and persistent cold policy pass in these installed overlays,
with no fresh AUTO integration or new HID/MSC claim.

The launcher now requires both `isatty()` and Windows `GetConsoleMode`:
Windows NUL can satisfy `isatty()` despite having no live operator.
Actual redirected-pipe and DEVNULL subprocess tests refuse before VM
start; the DEVNULL test covers both apply and cold phase launch paths.
Only an explicit owned phase selects the helper-only preparation or the
unchanged effective-disk cold check. No network/USB SYS is rebuilt.

The own helper emits a completion marker to virtual COM1 only inside
the explicitly marked NT35 fixture. The runner writes an atomic completion
JSON, and the operator waits for its exact filesystem event. No active
log, QMP status or screenshot is polled for progress. No physical media,
hub code, Windows module or frozen cache is modified.
