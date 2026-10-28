# NT 3.5: qualified installed IRQ candidate — QEMU only

Separate branch `fix/nt35-net-irq`, commits `2d8d453e` and `fa6fab32`,
corrects the same four legacy Intel interrupt register offsets. Its own
NT35 SYS is 16,384 B, SHA-256
`d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85`.
Only that same-sized file changes in a stopped R20b overlay; SYSTEM,
USB and i8042prt Start4 remain unchanged.

Actual completed guest results: native DHCP renew/all, standard ping3/3
with every reply below10ms, matching ICMP0ms, strict UDP DNS80/30ms,
strict TCP DNS20ms, native name lookup and HTTP68k.news200/connect121ms.
Native safeShutdown/operator17 precedes QMPquit/rc0. Stopped readback
confirms the exact installed SYS; the R20b backing is unchanged.

The final complete logger snapshot is evaluated separately from its
retained historical slow/failed snapshots. Strict full-DORA remains
false; matching renew REQUEST/ACK and native lease output are separate
evidence. Gateway53/80 and frogfindHTTP failures remain recorded.

Separate regression `nt35-irq-usb01`, commit `cf8f7ca0`, now confirms HID
with the same d94 driver. The absent keyboard control leaves the desktop
unchanged; insertion enables Run. Keyboard Run works with the mouse
absent; after mouse insertion, movement and left click open File.
Native safeShutdown/operator13 and exit0 precede stopped readback of
d94, frozen USB and i8042prt Start4. The fixed01 backing stays unchanged.
Assessment: `nt35-irq/artifacts/nt35-irq-usb/assessment.json`.

41 host checks pass. These two runs remain installed-driver and separate
HID qualification, without fresh Setup/new-cache, MSC, Server or X470
claims from either run. The newer independent fresh normal USOS d94
qualification is [S15], `docs/nt35-fresh-irq-evidence.md`; its fresh
Client/noSharing FAIL stays separate from installed policy coldPASS [S13].
The source, preparation, exact manifest and assessment are in
`nt35-irq/docs/nt35-irq-canonical-registers.md` and
`nt35-irq/artifacts/nt35-irq/qualification-manifest.json`.
