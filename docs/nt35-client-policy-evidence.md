# NT35 client service policy: separate apply and cold overlays — QEMU only

`fix/nt35-net-client` e8bef69b, following c3c4df59/8b0f5708, qualifies
the explicit client service-policy correction on installed NT35. It uses
the completed IRQ/HID parent [S9], not a new normal USOS installation.
Fresh R20 [S6] retains its old driver and historical approximately2s
latency. No fresh d94 or fresh AUTO client-policy PASS is added here.

Apply03 stages only the own CLNT35.EXE/ON and leaves original file
contents unchanged. The explicit `/apply` completes; operator09 shows
Browser/LanmanServer STOPPED and Disabled/Start4, with Workstation/Tcpip
RUNNING. Native services11 excludes Server/Computer Browser and includes
Workstation/DHCP Client. Native ping13 receives3/3 replies, all time<10ms.
Native safe shutdown17 and QMP quit/rc0 precede bounded stopped readback.

Cold01 uses an empty COW with identical effective guest disk contents,
verified by actual qemu-img comparison, and a new QEMU process. Readonly
`/check` completes with own COM1=0 on operator05. The new346-byte log09
contains CLIENT_POLICY_PASS and no NativeNetExit: no service stop operation
is repeated. Server/Browser remain STOPPED/Disabled; Workstation/Tcpip
remain RUNNING. Fresh native NET/ping commands overwrite the own evidence
files; services11 and ping13 confirm the client-only list and3/3<10ms.
Native safe shutdown17 and QMP quit/rc0 precede independent stopped readback.
The operator's exact commands and reviewed images are pinned in the cold
assessment; identical service/ping bytes alone are not freshness proof.

Both clean REGF1.2 reads select Current=Default1 and confirm i8042prt4,
Browser4/Server4, Workstation2/Tcpip3. The own helper is5632B, SHA256
`4a927eecb1a6c602f92c0a92c14bd7b56f684238735d36f8218d5bfcb5e3204a`.
SYSd94/16384B and frozen USB2d455/32128B remain pinned. Completed apply
parent SHA256 `f798b3021c12fec3c56dd652530dc2cd3b1c1dc54a107b1e653eabe7b9e05836`
and original USB parent92c2 remain unchanged. Cold target SHA256:
`c2a142e4ae39f23854b30c549ce966a1e0caca80bad555e3916ff7abd9b61fe4`.
Whole-disk scratch is removed; only four own text files are exported,
with SYSTEM and binary reads retained in RAM.

These are installed policy apply/cold PASS. They add no HID out/in, MSC,
DHCP/DNS/HTTP, Server SKU or X470 qualification. Earlier apply01 operator
failure, apply02 startup STOP and the cold preflight contract failure
remain historical; the last occurred before QEMU and is not a Windows
failure. Normal fresh AUTO integration requires its own completed test.

Source: `nt35-client/docs/nt35-client-service-policy.md` at e8bef69b and
`nt35-client/artifacts/nt35-client/{apply03,cold01}/evaluation.json`,
with corresponding `readback.json`. Evaluation SHA256 pins:

- apply03: `7983de1e8feea9e65a4020eae230bcbb7253ad172d2fd69cabb45e2031b7d2e5`
- cold01: `fdd02871ea2a0c7843fe76ee13af064ed5bd5b318521ff3dff4def2f7869f39c`
