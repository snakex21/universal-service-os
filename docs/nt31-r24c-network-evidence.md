# NT 3.1 full-MAC: installed LAN qualification — QEMU only

R24c on `fix/nt31-net` qualifies the actual full-MAC driver with original
NT3.1 Workstation TCP/IP, installed through native NCPA on a preserved
R19c-derived installation. It is not a fresh automatic USOS network flow.

Installed own SYS: 16,384 B, SHA-256
`b49f2445a2e48dbf75b50f426ccc1cef09943a84e779d351747d4cbc8df27a8d`.
One CPU, sole Intel82576/8086:10C9 at explicit BDF00:05.0; 20ms polling.
Static address10.0.2.15/24, gateway10.0.2.2, DNS10.0.2.3. Stock NT3.1
TCP/IP has no DHCP here; it is not classified as a DHCP failure or PASS.

Two native ping runs each receive3/3 replies. Original ping does not print
RTT, so none is claimed. Strict UDP DNS from configured10.0.2.3 matches
ID4AC0/question/A in30ms; native gethostbyname returns the same address
in120ms. Strict TCP DNS passes, and HTTP68k.news returns200. The retained
frogfindHTTP timeout4005ms remains; the logger ICMP SKIP is not promoted
to PASS, with native ping supplying the independent ICMP proof.

Native safeShutdown/operator12 precedes QMPquit/rc0. Readback confirms
the exact own SYS,43 resolved original imports, frozen USBf537 and
i8042prt Start4; the R24 backing is unchanged. No Microsoft binary or
hive is exported to repository/outputs. Earlier R24 error193 and R24b
STOP1E remain recorded; alignment and NdisRegisterMac argument order
were independently corrected and tested before this successful run.

R19c remains the separate completed USB HID evidence. This LAN result
does not itself retest HID, MSC, reset/unload, Server, SMP, X470, I210/I211
or other PCI placement. Native shutdown is not a MAC unload test.
Full assessment: `nt31-net/artifacts/nt31-fullmac-runtime/r24c-guest-evaluation.json`;
stopped readback: `nt31-net/artifacts/nt31-fullmac-runtime/r24c-stopped-readback/readback.json`.

The completed R24d regression, commit3820cbfc, qualifies USB coexistence
with b49: absent-keyboard negative control, keyboard insertion/Run,
keyboard File/Run with mouse absent, and mouse movement plus File click
after insertion. Native ping3/3 still passes after replug. Native safe
shutdown/operator17 and exit0 precede stopped readback b49/f537/Start4;
the R24c backing is unchanged. Assessment:
`nt31-net/artifacts/nt31-fullmac-runtime/r24d-usb-evaluation.json`.

R24d also checks native service state. It finds Server RUNNING with
LanmanServer Start2 alongside Workstation/TCPIP. This is a network-policy
failure against client-without-sharing, even though functional LAN passes.
R24d keeps that configuration unchanged for isolation; a separate fix
and cold-boot policy qualification follow as R24e/R24f.
Selected RAS service names are absent, which is not a proof of complete
Dial-Up absence.

The owned helper fix2064ae00 applies only existing SCM Browser/LanmanServer
stop/Disabled, refusing unexpected active dependents and preserving
Workstation/TCPIP. Native policy has12 actual-C cases,19 host checks and
three actual-host OS refusal modes. R24e applies successfully; a separate
unchanged cold overlay R24f verifies readonly `/clientcheck`, native
service list and ping3/3. Browser/LanmanServer are STOPPED/Disabled and
Workstation/TCPIP RUNNING after cold boot. Both native shutdowns and exit0
precede actual helper/SYS/USB readback. Helper d00c has27 original imports;
b49/f537 remain unchanged. Final report commit8d269a40, assessment
`nt31-net/artifacts/nt31-fullmac-runtime/r24f-client-evaluation.json`.

This fixes the measured file-sharing service policy in the installed
fixture; original R24d failure remains. ClipBook/NetworkDDE are unchanged,
and fresh automatic NCPA integration, full Dial-Up absence and browser UI
are still unqualified. The HTTP200 above comes from the owned logger.
